const std = @import("std");
const sqlite = @import("sqlite");
const manage_main = @import("main.zig");
const libpcre = @import("libpcre");
const Context = manage_main.Context;
const ID = manage_main.ID;

const logger = std.log.scoped(.als);

const VERSION = "0.0.1";
const HELPTEXT =
    \\ amv: move files
    \\
    \\ usage:
    \\ 	amv [options] <path_from> <path_to>
    \\
    \\ options:
    \\ 	-h				prints this help and exits
    \\ 	-V				prints version and exits
    \\
    \\ examples:
    \\     amv path1 path2
    \\         move path1 to path2
;

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

    const StringList = std.ArrayList([]const u8);

    const Args = struct {
        help: bool = false,
        version: bool = false,
        paths: StringList,
    };

    var given_args = Args{ .paths = StringList.init(allocator) };
    defer given_args.paths.deinit();

    var state: enum { None, Path } = .None;

    while (args_it.next()) |arg| {
        logger.debug("state: {}, arg: {s}", .{ state, arg });
        switch (state) {
            .Path => {
                try given_args.paths.append(arg);
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
        } else {
            try given_args.paths.append(arg);
            state = .Path;
        }
    }

    if (given_args.help) {
        std.debug.print(HELPTEXT, .{});
        return;
    } else if (given_args.version) {
        std.debug.print("ainclude {s}\n", .{VERSION});
        return;
    }

    logger.debug("given paths: {s}", .{given_args.paths.items});
    const from_paths = given_args.paths.items[0 .. given_args.paths.items.len - 1];
    // TODO index check before crash
    const to_path = given_args.paths.items[given_args.paths.items.len - 1];

    if (from_paths.len == 0) {
        logger.err("no paths?", .{});
        return error.NoPathsGiven;
    }

    logger.debug("from={s}, to={s}", .{ from_paths, to_path });

    var ctx = try manage_main.loadDatabase(allocator, .{});
    defer ctx.deinit();

    try renameWithIndex(allocator, &ctx, from_paths, to_path);
}

const PathHandle = union(enum) {
    dir: std.fs.Dir,
    file: struct { dir: std.fs.Dir, basename: []const u8 },
    const Self = @This();

    pub fn close(self: *Self) void {
        switch (self.*) {
            .file => {
                // TODO this is a hack as Dir.close needs a ptr
                self.file.dir.close();
            },

            // TODO this is a hack as Dir.close needs a ptr
            .dir => self.dir.close(),
        }
    }

    fn openFile(path: []const u8, options: RuntimeOptions) !Self {
        const realpath = try std.fs.cwd().realpath(path, options.path_buffer.?);

        const dirname = std.fs.path.dirname(realpath).?;
        const basename = std.fs.path.basename(realpath);
        const dir = try std.fs.cwd().openDir(dirname, .{});
        return Self{ .file = .{
            .dir = dir,
            .basename = basename,
        } };
    }

    const Options = struct { want_file: bool = true };
    const RuntimeOptions = struct { path_buffer: ?[]u8 = null };

    pub fn openPath(
        path: []const u8,
        comptime options: Options,
        runtime_options: RuntimeOptions,
    ) !if (options.want_file) Self else ?Self {
        return Self{ .dir = std.fs.cwd().openDir(path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    logger.warn("path not found: {s}", .{path});
                    return if (options.want_file) err else null;
                },
                error.NotDir => {
                    return if (options.want_file) Self.openFile(path, runtime_options) else null;
                },
                else => return err,
            }
        } };
    }
};

fn renameWithIndex(
    allocator: std.mem.Allocator,
    ctx: *manage_main.Context,
    from_paths: [][]const u8,
    to_fspath: []const u8,
) !void {
    const maybe_to_path = try PathHandle.openPath(to_fspath, .{ .want_file = false }, .{});

    for (from_paths) |from_path_str| {
        var buffer: [std.posix.PATH_MAX]u8 = undefined;
        var from_path: PathHandle = try PathHandle.openPath(from_path_str, .{}, .{ .path_buffer = &buffer });
        defer from_path.close();

        // NOTE: these are not the same techniques as awtfdb-watcher
        // because this time we own the rename operation,
        // rather than having to do a bunch of logical
        // inferrence based on syscall data

        switch (from_path) {
            .dir => return error.TODO, // TODO support dir renames
            .file => |descriptors| {
                // dir1/file1 to dir2/file2 => renameat(dir1, file1, dir2, file2)

                const old_path = try std.fs.path.resolve(allocator, &[_][]const u8{from_path_str});
                defer allocator.free(old_path);

                const old_path_full = try std.fs.cwd().realpathAlloc(allocator, old_path);
                defer allocator.free(old_path_full);

                var old_file = (try ctx.fetchFileByPath(old_path_full)).?;
                defer old_file.deinit();

                var target_dir_fspath: ?[]const u8 = null;

                const target_name = if (maybe_to_path) |to_path| switch (to_path) {
                    .file => return error.FileAlreadyExists, // TODO let people overwrite files lmao
                    // file-to-dir (with unknown name target)
                    // we fallback to basename of from_path for this case
                    .dir => blk: {
                        target_dir_fspath = to_fspath;
                        break :blk std.fs.path.basename(from_path_str);
                    },
                } else blk: {
                    // this is file-to-file (with known name target)
                    target_dir_fspath = std.fs.path.dirname(to_fspath) orelse ".";
                    break :blk std.fs.path.basename(to_fspath);
                };
                logger.info(
                    "{s} -> {s} (target_dir_fspath={?s}, target_name={s})",
                    .{ from_path_str, to_fspath, target_dir_fspath, target_name },
                );

                const target_dir = try std.fs.cwd().openDir(target_dir_fspath.?, .{});

                try std.fs.rename(
                    descriptors.dir,
                    descriptors.basename,
                    target_dir,
                    target_name,
                );

                // now rename in the index

                const new_path = try std.fs.path.resolve(
                    allocator,
                    &[_][]const u8{ target_dir_fspath.?, target_name },
                );
                defer allocator.free(new_path);

                const new_path_full = try std.fs.cwd().realpathAlloc(allocator, new_path);
                defer allocator.free(new_path_full);

                logger.info("new_path: {s}", .{new_path_full});
                // ensure that the new path is an actually valid fspath
                var realpath_buffer: [std.posix.PATH_MAX]u8 = undefined;
                var new_path_handle = try PathHandle.openPath(new_path_full, .{ .want_file = true }, .{ .path_buffer = &realpath_buffer });
                defer new_path_handle.close();

                try old_file.setLocalPath(new_path_full);
            },
        }
    }
}

test "renaming with index support" {
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

    var paths = [_][]const u8{real};

    var buf2: [8192]u8 = undefined;
    const to_path = try std.fmt.bufPrint(&buf2, "{s}_coolversion", .{real});

    try renameWithIndex(ctx.allocator, &ctx, &paths, to_path);
    var indexed_file2 = (try ctx.fetchFile(indexed_file1.hash.id)).?;
    defer indexed_file2.deinit();
    try std.testing.expect(!std.mem.endsWith(u8, indexed_file2.local_path, "test_file1"));
    try std.testing.expect(std.mem.endsWith(u8, indexed_file2.local_path, "test_file1_coolversion"));
}
