const std = @import("std");
const sqlite = @import("sqlite");
const manage_main = @import("main.zig");
const Context = manage_main.Context;
const ID = manage_main.ID;

const logger = std.log.scoped(.awtfdb_janitor);

const VERSION = "0.0.1";
const HELPTEXT =
    \\ awtfdb-metrics: run analytical queries on db and submit results inside db
    \\
    \\ run this daily, at a time you're not going to use your computer
    \\ that much. maybe 5am
    \\
    \\ usage:
    \\ 	awtfdb-metrics
    \\
    \\ options:
    \\ 	-h				prints this help and exits
    \\ 	-V				prints version and exits
;

const StringList = std.ArrayList([]const u8);
const Args = struct {
    help: bool = false,
    version: bool = false,
    full: bool = false,
};

const METRICS_COUNT_TABLES = .{ "metrics_count_files", "metrics_count_tag_cores", "metrics_count_tag_names" };

const Timestamp = i64;

fn runMetricsCounter(
    ctx: *Context,
    metrics_timestamp: Timestamp,
    comptime input_table: []const u8,
    comptime output_metrics_table: []const u8,
) !void {
    const row_count = (try ctx.db.one(i64, "select count(*) from " ++ input_table, .{}, .{})).?;
    logger.info("{d} rows in table '{s}'", .{ row_count, input_table });

    try ctx.db.exec(
        "insert into " ++ output_metrics_table ++ " (timestamp, value) values (?, ?)",
        .{},
        .{ metrics_timestamp, row_count },
    );
}

pub var current_log_level: std.log.Level = .info;
pub const std_options = struct {
    pub const log_level = .debug;
    pub const logFn = manage_main.log;
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
    const allocator = gpa.allocator();

    var args_it = std.process.args();
    _ = args_it.skip();

    var given_args = Args{};
    //var state: enum { None } = .None;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h")) {
            given_args.help = true;
        } else if (std.mem.eql(u8, arg, "-V")) {
            given_args.version = true;
        } else if (std.mem.eql(u8, arg, "-v")) {
            current_log_level = .debug;
        } else if (std.mem.eql(u8, arg, "--full")) {
            given_args.full = true;
        } else {
            return error.InvalidArgument;
        }
    }

    if (given_args.help) {
        std.debug.print(HELPTEXT, .{});
        return 1;
    } else if (given_args.version) {
        std.debug.print("awtfdb-metrics {s}\n", .{VERSION});
        return 1;
    }
    var ctx = try manage_main.loadDatabase(allocator, .{});
    defer ctx.deinit();

    // if metrics tables are count 0, insert first row:
    // timestamp = db creation (migration 0), count 0

    const metrics_timestamp = std.time.timestamp();
    logger.info("running metrics queries at timestamp {d}", .{metrics_timestamp});

    // execute inserts here
    {
        var savepoint = try ctx.db.savepoint("metrics");
        errdefer savepoint.rollback();
        defer savepoint.commit();

        try runAllMetricsCounters(given_args, &ctx, metrics_timestamp);
    }

    return 0;
}

fn runMetricsTagUsage(ctx: *Context, metrics_timestamp: Timestamp) !void {
    try ctx.db.exec(
        "insert into metrics_tag_usage_timestamps (timestamp) values (?)",
        .{},
        .{metrics_timestamp},
    );

    // for every file, count tag cores
    var files_stmt = try ctx.db.prepare(
        \\ select distinct file_hash
        \\ from files;
    );
    defer files_stmt.deinit();

    var string_arena = std.heap.ArenaAllocator.init(ctx.allocator);
    var string_allocator = string_arena.allocator();
    defer string_arena.deinit();

    var core_counts = std.StringHashMap(usize).init(ctx.allocator);
    defer core_counts.deinit();

    var files_it = try files_stmt.iterator(struct { file_hash: ID.SQL }, .{});
    var files_timer = try std.time.Timer.start();
    var files_all_timer = try std.time.Timer.start();
    var files_counter: usize = 0;

    var buffer: [512 * 1024]u8 = undefined;
    while (try files_it.next(.{})) |row| {
        var fba = std.heap.FixedBufferAllocator{
            .buffer = &buffer,
            .end_index = 0,
        };
        defer fba.reset();
        const tags_alloc = fba.allocator();

        const file_ref = Context.File{
            .ctx = ctx,
            .local_path = undefined,
            .hash = Context.Hash{
                .id = ID.new(row.file_hash),
                .hash_data = undefined,
            },
        };

        const tags = try file_ref.fetchTags(tags_alloc);

        for (tags) |file_tag| {
            const owned_data = try string_allocator.dupe(u8, &file_tag.core.id.data);
            const entry = try core_counts.getOrPut(owned_data);

            if (entry.found_existing) {
                entry.value_ptr.* += 1;
            } else {
                entry.value_ptr.* = 1;
            }
        }

        if (files_counter > 0 and files_counter % 10000 == 0) {
            const exec_time_ns = files_timer.lap();
            logger.info("up to {d} took {:.2}ms to fetch", .{ files_counter, exec_time_ns / std.time.ns_per_ms });
        }
        files_counter += 1;
    }
    const exec_all_time_ns = files_all_timer.lap();
    logger.info("all took {:.2}ms to fetch", .{exec_all_time_ns / std.time.ns_per_ms});

    var core_it = core_counts.iterator();
    var core_insert_timer = try std.time.Timer.start();
    var core_insert_counter: usize = 0;
    while (core_it.next()) |entry| {
        const core_hash: [26]u8 = entry.key_ptr.*[0..26].*;
        const relationship_count: usize = entry.value_ptr.*;

        try ctx.db.exec(
            "insert into metrics_tag_usage_values (timestamp, core_hash, relationship_count) values (?, ?, ?)",
            .{},
            .{ metrics_timestamp, core_hash, relationship_count },
        );
        core_insert_counter += 1;
    }
    const insert_all_time_ns = core_insert_timer.lap();
    logger.info(
        "insert all {d} cores took {:.2}ms",
        .{ core_insert_counter, insert_all_time_ns / std.time.ns_per_ms },
    );
}

fn runTagSourceCounters(ctx: *Context, metrics_timestamp: Timestamp) !void {
    var stmt = try ctx.db.prepare(
        \\ select distinct type, id,
        \\  (select count(*) from tag_files where tag_source_type  = tag_sources.type and tag_source_id=tag_sources.id) AS relationship_count
        \\  from tag_sources;
    );
    defer stmt.deinit();

    var it = try stmt.iterator(struct {
        tag_source_type: i64,
        tag_source_id: i64,
        relationship_count: usize,
    }, .{});
    var timer = try std.time.Timer.start();
    while (try it.next(.{})) |row| {
        const exec_time_ns = timer.lap();
        logger.info("{} took {:.2}ms to fetch", .{ row, exec_time_ns / std.time.ns_per_ms });

        try ctx.db.exec(
            "insert into metrics_tag_source_usage (timestamp, tag_source_type, tag_source_id, relationship_count) values (?, ?, ?, ?)",
            .{},
            .{ metrics_timestamp, row.tag_source_type, row.tag_source_id, row.relationship_count },
        );
    }
}

fn runAllMetricsCounters(given_args: Args, ctx: *Context, metrics_timestamp: Timestamp) !void {
    try runMetricsCounter(ctx, metrics_timestamp, "files", "metrics_count_files");
    try runMetricsCounter(ctx, metrics_timestamp, "tag_cores", "metrics_count_tag_cores");
    try runMetricsCounter(ctx, metrics_timestamp, "tag_names", "metrics_count_tag_names");
    try runMetricsCounter(ctx, metrics_timestamp, "tag_files", "metrics_count_tag_files");
    try runTagSourceCounters(ctx, metrics_timestamp);
    if (given_args.full) {
        try runMetricsTagUsage(ctx, metrics_timestamp);
    }
}

test "metrics (tags)" {
    var ctx = try manage_main.makeTestContext();
    defer ctx.deinit();

    const tag1 = try ctx.createNamedTag("test_tag1", "en", null, .{});
    const tag2 = try ctx.createNamedTag("test_tag2", "en", null, .{});
    _ = tag2;
    const tag3 = try ctx.createNamedTag("test_tag3", "en", null, .{});
    _ = tag3;
    const tag_named1 = try ctx.createNamedTag("test_tag1_samecore", "en", tag1.core, .{});
    _ = tag_named1;

    // run metrics code
    try runAllMetricsCounters(.{}, &ctx, std.time.timestamp());

    // fact on this test: names > cores

    const last_metrics_tag_core = (try ctx.db.one(usize, "select value from metrics_count_tag_cores", .{}, .{})).?;
    const last_metrics_tag_name = (try ctx.db.one(usize, "select value from metrics_count_tag_names", .{}, .{})).?;

    try std.testing.expect(last_metrics_tag_name > last_metrics_tag_core);
}

test "metrics (tags and files)" {
    var ctx = try manage_main.makeTestContext();
    defer ctx.deinit();

    // setup tags

    const tag1 = try ctx.createNamedTag("test_tag1", "en", null, .{});
    const tag2 = try ctx.createNamedTag("test_tag2", "en", null, .{});
    const tag3 = try ctx.createNamedTag("test_tag3", "en", null, .{});
    const tag_named1 = try ctx.createNamedTag("test_tag1_samecore", "en", tag1.core, .{});

    // setup files

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file1 = try tmp.dir.createFile("test_file1", .{});
    defer file1.close();
    _ = try file1.write("awooga1");

    var file2 = try tmp.dir.createFile("test_file2", .{});
    defer file2.close();
    _ = try file2.write("awooga2");

    var file3 = try tmp.dir.createFile("test_file3", .{});
    defer file3.close();
    _ = try file3.write("awooga3");

    var indexed_file1 = try ctx.createFileFromDir(tmp.dir, "test_file1", .{});
    defer indexed_file1.deinit();
    var indexed_file2 = try ctx.createFileFromDir(tmp.dir, "test_file2", .{});
    defer indexed_file2.deinit();
    var indexed_file3 = try ctx.createFileFromDir(tmp.dir, "test_file3", .{});
    defer indexed_file3.deinit();

    // setup tag links

    try indexed_file1.addTag(tag1.core, .{});
    try indexed_file1.addTag(tag_named1.core, .{}); // should be a noop in db terms
    try indexed_file2.addTag(tag1.core, .{});
    try indexed_file3.addTag(tag1.core, .{});
    try indexed_file2.addTag(tag2.core, .{});
    try indexed_file2.addTag(tag3.core, .{});
    try indexed_file3.addTag(tag3.core, .{});

    // run metrics code
    try runAllMetricsCounters(.{ .full = true }, &ctx, std.time.timestamp());

    // fact on this test: there are 6 file<->tag relations
    const last_metrics_tag_file = (try ctx.db.one(usize, "select value from metrics_count_tag_files", .{}, .{})).?;
    try std.testing.expectEqual(@as(usize, 6), last_metrics_tag_file);

    // fact on this test: there are 3 files
    const last_metrics_file = (try ctx.db.one(usize, "select value from metrics_count_files", .{}, .{})).?;
    try std.testing.expectEqual(@as(usize, 3), last_metrics_file);

    // fact on this test:
    // 	tag1 has 3 relationships,
    // 	tag2 has 1 relationship,
    // 	tag3 has 2 relationships

    const last_metrics_tag_usage_timestamp = (try ctx.db.one(usize, "select timestamp from metrics_tag_usage_timestamps", .{}, .{})).?;

    var metrics_tag_usage_values_stmt = try ctx.db.prepare(
        \\ select core_hash, relationship_count
        \\ from metrics_tag_usage_values
        \\ where timestamp = ?
    );
    defer metrics_tag_usage_values_stmt.deinit();

    var it = try metrics_tag_usage_values_stmt.iterator(
        struct { core_hash: ID.SQL, relationship_count: usize },
        .{last_metrics_tag_usage_timestamp},
    );

    var checked_count: usize = 0;

    while (try it.next(.{})) |row| {
        checked_count += 1;
        const core_hash = ID.new(row.core_hash);
        if (std.meta.eql(core_hash, tag1.core.id))
            try std.testing.expectEqual(@as(usize, 3), row.relationship_count)
        else if (std.meta.eql(core_hash, tag2.core.id))
            try std.testing.expectEqual(@as(usize, 1), row.relationship_count)
        else if (std.meta.eql(core_hash, tag3.core.id))
            try std.testing.expectEqual(@as(usize, 2), row.relationship_count)
        else
            return error.InvalidCoreHashFound;
    }

    try std.testing.expectEqual(@as(usize, 3), checked_count);

    // fact on this test
    // source type=0 and id=0 has 6 relationships

    const source_usage = try ctx.db.one(usize,
        \\ select relationship_count
        \\ from metrics_tag_source_usage
        \\ where timestamp = ? and tag_source_type = 0 and tag_source_id = 0
    , .{}, .{last_metrics_tag_usage_timestamp});

    try std.testing.expectEqual(@as(?usize, 6), source_usage);
}
