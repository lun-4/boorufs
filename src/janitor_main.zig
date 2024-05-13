const std = @import("std");
const sqlite = @import("sqlite");
const manage_main = @import("main.zig");
const libpcre = @import("libpcre");
const Context = manage_main.Context;
const ID = manage_main.ID;

const logger = std.log.scoped(.awtfdb_janitor);

const VERSION = "0.0.1";
const HELPTEXT =
    \\ awtfdb-janitor: investigate the semantic consistency of the index file
    \\
    \\ usage:
    \\ 	awtfdb-janitor
    \\
    \\ options:
    \\ 	-h				prints this help and exits
    \\ 	-V				prints version and exits
    \\ 	--full				validate hashes of all files (very slow)
    \\ 	--only <path>			only run full validation on given path
    \\ 	--repair			attempt to repair consistency
    \\ 					(this operation may be destructive to
    \\ 					the index file, only run this manually)
;

const Counter = struct { total: usize = 0, unrepairable: usize = 0 };
const ErrorCounters = struct {
    file_not_found: Counter = .{},
    incorrect_hash_files: Counter = .{},
    incorrect_hash_cores: Counter = .{},
    unused_hash: Counter = .{},
    invalid_tag_name: Counter = .{},
};

fn parseByteAmount(text: []const u8) !usize {
    const numeric_part_text = text[0 .. text.len - 1];
    logger.debug("numeric part {s}", .{numeric_part_text});
    const numeric_part = try std.fmt.parseInt(usize, numeric_part_text, 10);
    const unit = text[text.len - 1];
    logger.debug("unit {s}", .{&[_]u8{unit}});
    const modifier: usize = switch (unit) {
        'K' => 1024,
        'M' => 1024 * 1024,
        'G' => 1024 * 1024 * 1024,
        else => {
            logger.err("expected K, M, G, got {s}", .{&[_]u8{unit}});
            return error.InvalidByteAmount;
        },
    };
    const bytecount = numeric_part * modifier;
    logger.debug("will only hash files smaller than {d} bytes", .{bytecount});
    return bytecount;
}

const StringList = std.ArrayList([]const u8);
const Args = struct {
    help: bool = false,
    version: bool = false,
    repair: bool = false,
    full: bool = false,
    only: StringList,
    maybe_hash_files_smaller_than: ?usize = null,
    verbose: bool = false,
    from_report: ?[]const u8 = null,
};

pub fn janitorCheckCores(
    ctx: *Context,
    report: *Report,
    given_args: Args,
) !void {
    var cores_stmt = try ctx.db.prepare(
        \\ select core_hash, core_data
        \\ from tag_cores
        \\ order by core_hash asc
    );
    defer cores_stmt.deinit();

    var cores_iter = try cores_stmt.iterator(CoreWithBlob, .{});
    logger.info("checking tag cores...", .{});
    while (try cores_iter.nextAlloc(ctx.allocator, .{})) |core_with_blob| {
        try verifyTagCore(ctx, report, given_args, core_with_blob);
    }
}

const CoreWithBlob = struct {
    core_hash: ID.SQL,
    core_data: sqlite.Blob,
};

fn calculateHashFromMemory(ctx: *Context, block: []const u8) !Context.Hash {
    var hasher = std.crypto.hash.Blake3.initKdf(manage_main.AWTFDB_BLAKE3_CONTEXT, .{});
    hasher.update(block);

    var hash_entry: Context.Hash = undefined;
    hasher.final(&hash_entry.hash_data);

    const hash_blob = sqlite.Blob{ .data = &hash_entry.hash_data };
    const maybe_hash_id = try ctx.fetchHashId(hash_blob);
    if (maybe_hash_id) |hash_id| {
        hash_entry.id = hash_id;
    } else {
        hash_entry.id = .{ .data = undefined };
    }

    return hash_entry;
}

fn verifyTagCore(ctx: *Context, report: *Report, given_args: Args, core_with_blob: CoreWithBlob) !void {
    defer ctx.allocator.free(core_with_blob.core_data.data);
    const core_hash = ID.new(core_with_blob.core_hash);

    const calculated_hash = try calculateHashFromMemory(ctx, core_with_blob.core_data.data);

    var hash_with_blob = (try ctx.db.oneAlloc(
        Context.HashSQL,
        ctx.allocator,
        \\ select id, hash_data
        \\ from hashes
        \\ where id = ?
    ,
        .{},
        .{core_hash.sql()},
    )).?;
    defer ctx.allocator.free(hash_with_blob.hash_data.data);

    const upstream_hash = hash_with_blob.toRealHash();

    if (!std.mem.eql(u8, &calculated_hash.hash_data, &upstream_hash.hash_data)) {
        report.counters.incorrect_hash_cores.total += 1;
        report.counters.incorrect_hash_cores.unrepairable += 1;

        logger.err(
            "hashes are incorrect for tag core {d} ({s} != {s})",
            .{ core_hash, calculated_hash, upstream_hash },
        );

        if (given_args.repair) {
            return error.ManualInterventionRequired;
        }
    }

    // TODO validate if there's any tag names to the core

}

pub fn isUnusedHash(ctx: *Context, hash_id_sql: ID.SQL, hash_id: ID) !bool {
    const doublecheck_id_sql = (try ctx.db.one(
        ID.SQL,
        "select id from hashes where id = ?",
        .{},
        .{hash_id.sql()},
    )).?;
    try std.testing.expectEqualStrings(&hash_id_sql, &doublecheck_id_sql);

    const core_count = (try ctx.db.one(
        usize,
        \\ select count(*) from tag_cores
        \\ where core_hash = ?
    ,
        .{},
        .{hash_id.sql()},
    )).?;

    if (core_count > 0) return false;

    const file_count = (try ctx.db.one(
        usize,
        \\ select count(*) from files
        \\ where file_hash = ?
    ,
        .{},
        .{hash_id.sql()},
    )).?;

    if (file_count > 0) return false;

    const pool_count = (try ctx.db.one(
        usize,
        \\ select count(*) from pools
        \\ where pool_hash = ?
    ,
        .{},
        .{hash_id.sql()},
    )).?;

    if (pool_count > 0) return false;

    return true;
}

pub fn janitorCheckUnusedHashes(
    ctx: *Context,
    counters: *ErrorCounters,
    given_args: Args,
) !void {
    var hashes_stmt = try ctx.db.prepare(
        \\ select id
        \\ from hashes
        \\ order by id asc
    );
    defer hashes_stmt.deinit();
    var hashes_iter = try hashes_stmt.iterator(ID.SQL, .{});
    while (try hashes_iter.next(.{})) |hash_id_sql| {
        const hash_id = ID.new(hash_id_sql);

        const is_unused_hash = try isUnusedHash(ctx, hash_id_sql, hash_id);
        if (!is_unused_hash) continue;
        logger.warn("unused hash in table: {d}", .{hash_id});

        counters.unused_hash.total += 1;

        if (given_args.repair) {
            try ctx.db.exec(
                \\ delete from hashes
                \\ where id = ?
            ,
                .{},
                .{hash_id.sql()},
            );
            logger.info("deleted hash {d}", .{hash_id});
        }
    }
}

pub fn janitorCheckTagNameRegex(
    ctx: *Context,
    counters: *ErrorCounters,
    given_args: Args,
) !void {
    var stmt = try ctx.db.prepare(
        \\ select core_hash, tag_text
        \\ from tag_names
        \\ order by core_hash asc
    );
    defer stmt.deinit();
    var it = try stmt.iterator(struct {
        core_hash: ID.SQL,
        tag_text: []const u8,
    }, .{});
    while (try it.nextAlloc(ctx.allocator, .{})) |row| {
        defer ctx.allocator.free(row.tag_text);
        logger.debug("verify tag: {s}", .{row.tag_text});

        ctx.verifyTagName(row.tag_text, .{}) catch |err| {
            logger.warn("tag name '{s}' does not match regex ({s})", .{ row.tag_text, @errorName(err) });
            counters.invalid_tag_name.total += 1;
            counters.invalid_tag_name.unrepairable += 1;
            if (given_args.repair) {
                return error.UnrepairableTagName;
            }
        };
    }
}

const FileRow = struct {
    file_hash: ID.SQL,
    local_path: []const u8,
};

pub fn janitorCheckFiles(
    ctx: *Context,
    report: *Report,
    given_args: Args,
) !void {
    var possible_files_to_check = std.AutoHashMap(ID.SQL, FileRow).init(ctx.allocator);
    defer possible_files_to_check.deinit();
    if (report.using_loaded_file) {
        for (report.files_not_found.items) |row| {
            try possible_files_to_check.put(row.file_hash, row);
        }
        for (report.incorrect_file_hashes.items) |row| {
            try possible_files_to_check.put(row.file_hash, row);
        }

        var iter = possible_files_to_check.valueIterator();

        while (iter.next()) |row| {
            try checkFile(ctx, report, given_args, row.*);
        }
    } else {
        var stmt = try ctx.db.prepare(
            \\ select file_hash, local_path
            \\ from files
            \\ order by file_hash asc
        );
        defer stmt.deinit();

        var iter = try stmt.iterator(FileRow, .{});
        while (try iter.nextAlloc(ctx.allocator, .{})) |row| {
            defer ctx.allocator.free(row.local_path);
            try checkFile(ctx, report, given_args, row);
        }
    }
}

fn checkFile(
    ctx: *Context,
    report: *Report,
    given_args: Args,
    row: FileRow,
) !void {
    const file_hash = ID.new(row.file_hash);

    const indexed_file = (try ctx.fetchFileExact(file_hash, row.local_path)) orelse return error.InconsistentIndex;
    defer indexed_file.deinit();

    var file = std.fs.openFileAbsolute(row.local_path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => {
            logger.err("file {s} not found", .{row.local_path});
            try report.addFileNotFound(row);

            const repeated_count = (try ctx.db.one(
                usize,
                \\ select count(*)
                \\ from files
                \\ where file_hash = ?
            ,
                .{},
                .{file_hash.sql()},
            )).?;

            std.debug.assert(repeated_count != 0);

            if (repeated_count > 1) {
                // repair action: delete old entry to keep index consistent
                logger.warn(
                    "found {d} files with same hash, assuming a file move happened for {d}",
                    .{ repeated_count, file_hash },
                );

                if (given_args.repair) {
                    try indexed_file.delete();
                }
            } else if (repeated_count == 1) {
                logger.err(
                    "can not repair {s} as it is not indexed, please index a file with same contents or remove it manually from the index",
                    .{row.local_path},
                );

                report.counters.file_not_found.unrepairable += 1;

                if (given_args.repair) {
                    return error.ManualInterventionRequired;
                }
            }

            return;
        },
        else => return err,
    };
    defer file.close();

    if (given_args.full) {
        var can_do_full_hash: bool = false;
        if (given_args.only.items.len > 0) {
            for (given_args.only.items) |prefix| {
                if ((!can_do_full_hash) and std.mem.startsWith(u8, row.local_path, prefix)) {
                    can_do_full_hash = true;
                }
            }
        } else {
            can_do_full_hash = true;
        }

        if (can_do_full_hash) {
            // if we're still allowed to check full hash, do a stat
            // and find out if this is up on the filter
            if (given_args.maybe_hash_files_smaller_than) |hash_files_smaller_than| {
                const file_stat = try file.stat();
                if (file_stat.size > hash_files_smaller_than) {
                    can_do_full_hash = false;
                }
            }
        }

        if (!can_do_full_hash) return;

        var calculated_hash = try ctx.calculateHash(file, .{ .insert_new_hash = false });

        if (!std.mem.eql(u8, &calculated_hash.hash_data, &indexed_file.hash.hash_data)) {
            // repair option: fuck
            try report.addIncorrectHash(row);

            logger.err(
                "hashes are incorrect for file {d} (wanted '{s}', got '{s}')",
                .{ file_hash, calculated_hash, indexed_file.hash },
            );

            if (given_args.repair) {
                logger.warn("repair: forcefully setting hash for file {d} '{s}'", .{ row.file_hash, calculated_hash.toHex() });
                const hash_blob = sqlite.Blob{ .data = &calculated_hash.hash_data };

                const maybe_preexisting_hash_id = try ctx.db.one(
                    ID.SQL,
                    "select id from hashes where hash_data = ?",
                    .{},
                    .{hash_blob},
                );
                if (maybe_preexisting_hash_id) |preexisting_hash_id| {
                    // we already have calculated_hash in the table, and so,
                    // running an update would cause issues with UNIQUE
                    // constraint.
                    //
                    // the fix here is to repoint file hash to the existing
                    // one, then garbage collect the old one in a separate
                    // janitor run
                    logger.info("target hash already exists {s}, setting file to it", .{preexisting_hash_id});

                    try ctx.db.exec(
                        \\ update files
                        \\ set file_hash = ?
                        \\ where file_hash = ?
                    ,
                        .{},
                        .{
                            sqlite.Text{ .data = &preexisting_hash_id },
                            file_hash.sql(),
                        },
                    );
                } else {
                    try ctx.db.exec(
                        \\ update hashes
                        \\ set hash_data = ?
                        \\ where id = ?
                    ,
                        .{},
                        .{ hash_blob, file_hash.sql() },
                    );
                }
            }
            return;
        }
    }
    logger.debug("path {s} ok", .{row.local_path});
}

pub var current_log_level: std.log.Level = .info;
pub const std_options = struct {
    pub const log_level = .debug;
    pub const logFn = manage_main.log;
};

const FileNotFoundReport = struct {
    row: FileRow,
};

const FileRowList = std.ArrayList(FileRow);

const Report = struct {
    allocator: std.mem.Allocator,
    counters: ErrorCounters,
    files_not_found: FileRowList,
    incorrect_file_hashes: FileRowList,
    using_loaded_file: bool = false,
    const Self = @This();
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .counters = ErrorCounters{},
            .files_not_found = FileRowList.init(allocator),
            .incorrect_file_hashes = FileRowList.init(allocator),
        };
    }

    pub fn addFileNotFound(self: *Self, row: FileRow) !void {
        try self.files_not_found.append(FileRow{
            .file_hash = row.file_hash,
            .local_path = try self.allocator.dupe(u8, row.local_path),
        });
    }
    pub fn addIncorrectHash(self: *Self, row: FileRow) !void {
        try self.incorrect_file_hashes.append(FileRow{
            .file_hash = row.file_hash,
            .local_path = try self.allocator.dupe(u8, row.local_path),
        });
    }

    pub fn deinit(self: Self) void {
        for (self.files_not_found.items) |row| {
            self.allocator.free(row.local_path);
        }
        self.files_not_found.deinit();
        for (self.incorrect_file_hashes.items) |row| {
            self.allocator.free(row.local_path);
        }
        self.incorrect_file_hashes.deinit();
    }

    pub fn readFrom(self: *Self, io_reader: anytype) !void {
        var reader = std.json.reader(self.allocator, io_reader);
        defer reader.deinit();
        var read_data = try std.json.parseFromTokenSource(struct {
            version: usize,
            counters: ErrorCounters,
            timestamp: i64,
            files_not_found: []FileRow,
            incorrect_hashes: []FileRow,
        }, self.allocator, &reader, .{});
        defer read_data.deinit();

        if (read_data.value.version != 1) {
            return error.InvalidVersion;
        }

        const delta = std.time.timestamp() - read_data.value.timestamp;
        if (delta > 60 * 60) {
            return error.ReportFileTooOld;
        }

        for (read_data.value.files_not_found) |file| {
            try self.addFileNotFound(file);
        }

        for (read_data.value.incorrect_hashes) |file| {
            try self.addIncorrectHash(file);
        }
        self.using_loaded_file = true;
    }
};

pub fn main() anyerror!u8 {
    const rc = sqlite.c.sqlite3_config(sqlite.c.SQLITE_CONFIG_LOG, manage_main.sqliteLog, @as(?*anyopaque, null));
    if (rc != sqlite.c.SQLITE_OK) {
        logger.err("failed to configure: {d} '{s}'", .{
            rc, sqlite.c.sqlite3_errstr(rc),
        });
        return error.ConfigFail;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var args_it = std.process.args();
    _ = args_it.skip();

    var given_args = Args{ .only = StringList.init(allocator) };
    defer {
        for (given_args.only.items) |path| allocator.free(path);
        given_args.only.deinit();
    }

    var state: enum { None, Only, HashFilesSmallerThan, FromReport } = .None;

    while (args_it.next()) |arg| {
        switch (state) {
            .Only => {
                try given_args.only.append(try std.fs.path.resolve(
                    allocator,
                    &[_][]const u8{arg},
                ));
                state = .None;
                continue;
            },
            .HashFilesSmallerThan => {
                given_args.maybe_hash_files_smaller_than = try parseByteAmount(arg);
                state = .None;
                continue;
            },
            .FromReport => {
                given_args.from_report = arg;
                state = .None;
                continue;
            },
            .None => {},
        }
        if (std.mem.eql(u8, arg, "-h")) {
            given_args.help = true;
        } else if (std.mem.eql(u8, arg, "-v")) {
            current_log_level = .debug;
        } else if (std.mem.eql(u8, arg, "-V")) {
            given_args.version = true;
        } else if (std.mem.eql(u8, arg, "--repair")) {
            given_args.repair = true;
        } else if (std.mem.eql(u8, arg, "--full")) {
            given_args.full = true;
        } else if (std.mem.eql(u8, arg, "--only")) {
            state = .Only;
        } else if (std.mem.eql(u8, arg, "--hash-files-smaller-than")) {
            state = .HashFilesSmallerThan;
        } else if (std.mem.eql(u8, arg, "--from-report")) {
            state = .FromReport;
        } else {
            return error.InvalidArgument;
        }
    }

    if (given_args.help) {
        std.debug.print(HELPTEXT, .{});
        return 1;
    } else if (given_args.version) {
        std.debug.print("awtfdb-janitor {s}\n", .{VERSION});
        return 1;
    }

    var ctx = try manage_main.loadDatabase(allocator, .{});
    defer ctx.deinit();

    var report = Report.init(allocator);
    defer report.deinit();

    if (given_args.from_report) |report_path| {
        var report_file = try std.fs.cwd().openFile(report_path, .{ .mode = .read_only });
        defer report_file.close();
        try report.readFrom(report_file.reader());
    }

    logger.info("running PRAGMA integrity_check", .{});
    var stmt = try ctx.db.prepare("PRAGMA integrity_check;");
    defer stmt.deinit();

    var it = try stmt.iterator([]const u8, .{});
    const val = (try it.nextAlloc(ctx.allocator, .{})) orelse return error.PossiblyFailedIntegrityCheck;
    defer ctx.allocator.free(val);
    logger.info("integrity check returned '{?s}'", .{val});
    if (!std.mem.eql(u8, val, "ok")) {
        while (try it.nextAlloc(ctx.allocator, .{})) |row| {
            defer ctx.allocator.free(row);
            logger.info("integrity check returned '{?s}'", .{row});
        }
        return error.FailedIntegrityCheck;
    }
    logger.info("running PRAGMA foreign_key_check...", .{});
    const maybe_row = try ctx.db.oneAlloc(struct {
        source_table: []const u8,
        invalid_rowid: ?i64,
        referenced_table: []const u8,
        foreign_key_constraint_index: i64,
    }, ctx.allocator, "PRAGMA foreign_key_check", .{}, .{});
    logger.info("foreign key check returned {?any}", .{maybe_row});

    if (maybe_row) |row| {
        defer allocator.free(row.source_table);
        defer allocator.free(row.referenced_table);
        return error.FailedForeignKeyCheck;
    }

    var savepoint = try ctx.db.savepoint("janitor");
    errdefer savepoint.rollback();
    defer savepoint.commit();

    // calculate hashes for tag_cores
    try janitorCheckFiles(&ctx, &report, given_args);
    try janitorCheckCores(&ctx, &report, given_args);
    try janitorCheckUnusedHashes(&ctx, &report.counters, given_args);
    try janitorCheckTagNameRegex(&ctx, &report.counters, given_args);

    try writeReport(report);

    const CountersTypeInfo = @typeInfo(ErrorCounters);

    var total_problems: usize = 0;
    inline for (CountersTypeInfo.Struct.fields) |field| {
        const total = @field(report.counters, field.name).total;

        logger.info("problem {s}, {d} found, {d} unrepairable", .{
            field.name,
            total,
            @field(report.counters, field.name).unrepairable,
        });

        total_problems += total;
    }

    if ((!given_args.repair) and total_problems > 0) {
        logger.info("this database has identified problems, please run --repair", .{});
        return 2;
    }
    return 0;
}

test "janitor functionality" {
    var ctx = try manage_main.makeTestContext();
    defer ctx.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("test_file", .{});
    defer file.close();
    _ = try file.write("awooga");

    var indexed_file = try ctx.createFileFromDir(tmp.dir, "test_file", .{});
    defer indexed_file.deinit();

    const tag = try ctx.createNamedTag("test_tag", "en", null, .{});
    try indexed_file.addTag(tag.core, .{});

    const given_args = Args{ .only = undefined };

    var report = Report.init(std.testing.allocator);
    defer report.deinit();

    try janitorCheckFiles(&ctx, &report, given_args);
    try janitorCheckCores(&ctx, &report, given_args);
    try janitorCheckUnusedHashes(&ctx, &report.counters, given_args);
    try janitorCheckTagNameRegex(&ctx, &report.counters, given_args);
}

test "tag name regex retroactive checker" {
    var ctx = try manage_main.makeTestContext();
    defer ctx.deinit();

    _ = try ctx.createNamedTag("correct_tag", "en", null, .{});
    _ = try ctx.createNamedTag("incorrect tag", "en", null, .{});
    _ = try ctx.createNamedTag("abceddef", "en", null, .{});
    _ = try ctx.createNamedTag("tag2", "en", null, .{});

    // TODO why doesnt a constant string on the stack work on this query
    // TODO API for changing library config

    const TEST_TAG_REGEX = try std.testing.allocator.dupe(u8, "[a-zA-Z0-9_]+");
    defer std.testing.allocator.free(TEST_TAG_REGEX);
    try ctx.updateLibraryConfig(.{ .tag_name_regex = TEST_TAG_REGEX });

    var counters: ErrorCounters = .{};
    const given_args = Args{ .only = undefined };

    try janitorCheckTagNameRegex(&ctx, &counters, given_args);

    try std.testing.expectEqual(@as(usize, 1), counters.invalid_tag_name.total);
    try std.testing.expectEqual(@as(usize, 1), counters.invalid_tag_name.unrepairable);
}

/// Caller owns the returned memory.
pub fn temporaryName(allocator: std.mem.Allocator) ![]u8 {
    const template_start = "/temp/awtfdb-janitor_";
    const template = "/tmp/awtfdb-janitor_XXXXXXXXXXXXXXXXXXXXX";
    var nam = try allocator.alloc(u8, template.len);
    std.mem.copyForwards(u8, nam, template);

    const seed = @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));
    var r = std.rand.DefaultPrng.init(seed);

    var fill = nam[template_start.len..nam.len];

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // generate a random uppercase letter, that is, 65 + random number.
        for (fill, 0..) |_, f_idx| {
            const idx = @as(u8, @intCast(r.random().uintLessThan(u5, 24)));
            const letter = @as(u8, 65) + idx;
            fill[f_idx] = letter;
        }

        // if we fail to access it, we assume it doesn't exist and return it.
        var tmp_file: std.fs.File = std.fs.cwd().openFile(
            nam,
            .{ .mode = .read_only },
        ) catch |err| {
            if (err == error.FileNotFound) return nam else continue;
        };

        // if we actually found someone, close the handle so that we don't
        // get EMFILE later on.
        tmp_file.close();
    }

    return error.TempGenFail;
}

fn writeReport(report: Report) !void {
    var allocator = report.allocator;

    const temp_path = try temporaryName(allocator);
    defer allocator.free(temp_path);

    var temp_file = try std.fs.createFileAbsolute(temp_path, .{});
    defer temp_file.close();

    var write_stream = std.json.writeStream(temp_file.writer(), .{});
    try write_stream.beginObject();
    try write_stream.objectField("version");
    try write_stream.write(1);
    try write_stream.objectField("counters");
    try write_stream.write(report.counters);
    try write_stream.objectField("timestamp");
    try write_stream.write(std.time.timestamp());
    try write_stream.objectField("files_not_found");
    try write_stream.write(report.files_not_found.items);
    try write_stream.objectField("incorrect_hashes");
    try write_stream.write(report.incorrect_file_hashes.items);
    try write_stream.endObject();

    logger.info("report written to {s}", .{temp_path});
}
