const std = @import("std");
const sqlite = @import("sqlite");
const manage_main = @import("main.zig");
const libpcre = @import("libpcre");
const Context = manage_main.Context;
const ID = manage_main.ID;

const logger = std.log.scoped(.arm);
const janitor = @import("janitor_main.zig");

const VERSION = "0.0.1";
const HELPTEXT =
    \\ arm: remove files from the index
    \\
    \\ usage:
    \\ 	arm [options] path
    \\
    \\ options:
    \\ 	-h				prints this help and exits
    \\ 	-V				prints version and exits
    \\ 	-f				forcefully delete a path
    \\ 					(TODO support folder paths)
    \\ 	-r				remove files recursively (in a folder)
    \\ 	-t tag				remove a tag from a file
    \\ 					(does not delete the file)
    \\ 	-p pool_id			remove a file from a pool
    \\ 					(does not delete the file)
    \\ 	--dry-run			don't edit the index database
    \\
    \\ examples:
    \\  arm path/to/file
    \\  arm -r path/to/folder
    \\  arm -t mytag path/to/file
    \\  arm -p 1234 file/in/pool
;

const StringList = std.ArrayList([]const u8);
const CoreList = std.ArrayList(Context.Hash);

const Args = struct {
    help: bool = false,
    version: bool = false,
    recursive: bool = false,
    force: bool = false,
    dry_run: bool = false,
    paths: StringList,
    tags: CoreList,
    pool: ?Context.Pool = null,
    cli_v1: bool = true,
    no_auto_gc: bool = false,
};

fn processFile(given_args: Args, file: *Context.File, hashes_to_check: *IDList) !usize {
    if (given_args.tags.items.len > 0) {
        for (given_args.tags.items) |tag_core| {
            try file.removeTag(tag_core);
            try hashes_to_check.append(tag_core.id);
        }

        return 0;
    } else if (given_args.pool) |pool| {
        try pool.removeFile(file.hash.id);
        try hashes_to_check.append(pool.hash.id);
        return 0;
    } else {
        try file.delete();
        try hashes_to_check.append(file.hash.id);
        return 1;
    }
}

pub var current_log_level: std.log.Level = .info;
pub const std_options = struct {
    pub const log_level = .debug;
    pub const logFn = manage_main.log;
};

pub fn main() anyerror!void {
    const rc = sqlite.c.sqlite3_config(sqlite.c.SQLITE_CONFIG_LOG, manage_main.sqliteLog, @as(?*anyopaque, null));
    if (rc != sqlite.c.SQLITE_OK) {
        logger.err("failed to configure: {d} '{s}'", .{
            rc, sqlite.c.sqlite3_errstr(rc),
        });
        return error.ConfigFail;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_it = std.process.args();
    _ = args_it.skip();

    var given_args = Args{
        .paths = StringList.init(allocator),
        .tags = CoreList.init(allocator),
    };
    defer given_args.paths.deinit();
    defer given_args.tags.deinit();

    var state: enum { FetchTag, None, FetchPool } = .None;
    var ctx = try manage_main.loadDatabase(allocator, .{});
    defer ctx.deinit();

    while (args_it.next()) |arg| {
        switch (state) {
            .FetchTag => {
                const tag = (try ctx.fetchNamedTag(arg, "en")) orelse {
                    logger.err("tag '{s}' not found", .{arg});
                    return error.UnknownNamedTag;
                };
                try given_args.tags.append(tag.core);
                state = .None;
                continue;
            },

            .FetchPool => {
                const pool_id = ID.fromString(arg);
                given_args.pool = (try ctx.fetchPool(pool_id)) orelse return error.PoolNotFound;
                state = .None;
                continue;
            },

            .None => {},
        }

        if (std.mem.eql(u8, arg, "-h")) {
            given_args.help = true;
        } else if (std.mem.eql(u8, arg, "-V")) {
            given_args.version = true;
        } else if (std.mem.eql(u8, arg, "-v")) {
            current_log_level = .debug;
        } else if (std.mem.eql(u8, arg, "-r")) {
            given_args.recursive = true;
        } else if (std.mem.eql(u8, arg, "-f")) {
            given_args.force = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            given_args.dry_run = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            state = .FetchTag;
        } else if (std.mem.eql(u8, arg, "-p")) {
            state = .FetchPool;
        } else if (std.mem.eql(u8, arg, "--no-auto-gc")) {
            given_args.no_auto_gc = true;
        } else if (std.mem.eql(u8, arg, "--v1")) {
            given_args.cli_v1 = true; // doesn't do anything yet
        } else {
            try given_args.paths.append(arg);
        }
    }

    if (given_args.help) {
        std.debug.print(HELPTEXT, .{});
        return;
    } else if (given_args.version) {
        std.debug.print("ainclude {s}\n", .{VERSION});
        return;
    }

    try runRemove(&ctx, given_args);
}

const IDList = std.ArrayList(ID);

fn runRemove(ctx: *Context, given_args: Args) !void {
    if (given_args.paths.items.len == 0) {
        logger.err("path is a required argument", .{});
        return error.MissingPath;
    }
    if (given_args.dry_run) try ctx.turnIntoMemoryDb();

    defer if (given_args.pool) |pool| pool.deinit();

    var savepoint = try ctx.db.savepoint("remove_files");
    errdefer savepoint.rollback();
    defer savepoint.commit();

    var count: usize = 0;
    var hashes_to_check = IDList.init(ctx.allocator);
    defer hashes_to_check.deinit();

    for (given_args.paths.items) |path| {
        var full_path_buffer: [std.posix.PATH_MAX]u8 = undefined;
        // if forcing a deletion, do not give a shit about filesystem
        const full_path = std.fs.cwd().realpath(path, &full_path_buffer) catch |err| blk: {
            if (given_args.force) {
                logger.warn("ignoring error {s} while resolving '{s}'", .{ @errorName(err), path });
                break :blk path;
            } else {
                logger.err("error resolving path '{s}'", .{path});
                return err;
            }
        };
        var maybe_file = try ctx.fetchFileByPath(full_path);

        if (maybe_file) |*file| {
            defer file.deinit();
            count += try processFile(given_args, file, &hashes_to_check);
        } else {
            var dir = std.fs.cwd().openDir(full_path, .{}) catch |err| {
                logger.warn("ignoring file {s} ({s})", .{ full_path, @errorName(err) });
                continue;
            };

            if (!given_args.recursive) {
                logger.err("given path is a folder but -r is not set", .{});
                return error.MissingRecursiveFlag;
            }

            var walker = try dir.walk(ctx.allocator);
            defer walker.deinit();

            while (try walker.next()) |entry| {
                if (entry.kind != .file) continue;
                logger.debug("checking path {s}", .{entry.path});
                var inner_realpath_buffer: [std.posix.PATH_MAX]u8 = undefined;
                const inner_full_path = try entry.dir.realpath(entry.basename, &inner_realpath_buffer);
                var maybe_inner_file = try ctx.fetchFileByPath(inner_full_path);

                if (maybe_inner_file) |*file| {
                    defer file.deinit();
                    logger.info("removing path {s}", .{entry.path});
                    count += try processFile(given_args, file, &hashes_to_check);
                }
            }
        }
    }

    if (count > 0) {
        logger.info("deleted {d} files", .{count});
    }

    if (!given_args.no_auto_gc) for (hashes_to_check.items) |hash_to_check| {
        const is_unused_hash = try janitor.isUnusedHash(ctx, hash_to_check.data, hash_to_check);
        if (!is_unused_hash) continue;

        try ctx.db.exec(
            \\ delete from hashes
            \\ where id = ?
        ,
            .{},
            .{hash_to_check.sql()},
        );
        logger.info("deleted hash {d}", .{hash_to_check});
    };
}

test "remove file without autogc" {
    var ctx = try manage_main.makeTestContext();
    defer ctx.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file1 = try tmp.dir.createFile("test_file1", .{});
    defer file1.close();
    _ = try file1.write("awooga1");

    var indexed_file1 = try ctx.createFileFromDir(tmp.dir, "test_file1", .{});
    defer indexed_file1.deinit();

    var buf: [8192]u8 = undefined;
    const real = try tmp.dir.realpath("test_file1", &buf);
    std.debug.print("\n{s}\n", .{real});

    var given_args = Args{
        .paths = StringList.init(ctx.allocator),
        .tags = CoreList.init(ctx.allocator),
        .no_auto_gc = true,
    };
    defer given_args.paths.deinit();
    defer given_args.tags.deinit();

    try given_args.paths.append(real);

    try runRemove(&ctx, given_args);

    // assert hash exists in files table

    const hash_count = try ctx.db.one(
        usize,
        \\ select count(*) from hashes where id = ?
    ,
        .{},
        .{indexed_file1.hash.id.sql()},
    );
    try std.testing.expectEqual(@as(usize, 1), hash_count.?);
}

test "remove file with autogc" {
    var ctx = try manage_main.makeTestContext();
    defer ctx.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file1 = try tmp.dir.createFile("test_file1", .{});
    defer file1.close();
    _ = try file1.write("awooga1");

    var indexed_file1 = try ctx.createFileFromDir(tmp.dir, "test_file1", .{});
    defer indexed_file1.deinit();

    var buf: [8192]u8 = undefined;
    const real = try tmp.dir.realpath("test_file1", &buf);
    std.debug.print("\n{s}\n", .{real});

    var given_args = Args{
        .paths = StringList.init(ctx.allocator),
        .tags = CoreList.init(ctx.allocator),
        .no_auto_gc = false,
    };
    defer given_args.paths.deinit();
    defer given_args.tags.deinit();

    try given_args.paths.append(real);

    try runRemove(&ctx, given_args);

    // assert hash DOESNT in files table

    const hash_count = try ctx.db.one(
        usize,
        \\ select count(*) from hashes where id = ?
    ,
        .{},
        .{indexed_file1.hash.id.sql()},
    );
    try std.testing.expectEqual(@as(usize, 0), hash_count.?);
}
