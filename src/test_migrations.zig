const std = @import("std");
const sqlite = @import("sqlite");
const manage_main = @import("./main.zig");

const Context = manage_main.Context;
const Migration = manage_main.Migration;

const logger = std.log.scoped(.migration_tests);

/// Make test context without any migrations loaded for proper testing.
///
/// Inspired by manage_main.makeTestContext
pub fn makeTestContext() !Context {
    const homepath = try std.fs.cwd().realpath(".", &manage_main.test_db_path_buffer);
    var ctx = Context{
        .args_it = undefined,
        .stdout = undefined,
        .db = null,
        .allocator = std.testing.allocator,
        .home_path = homepath,
        .db_path = null,
    };

    ctx.db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .Memory = {} },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });

    try ctx.loadDatabase(.{ .create = true });
    return ctx;
}

// Inspired by loadMigration
fn loadSingleMigration(ctx: *Context, comptime index: usize) !void {
    try ctx.loadDatabase(.{});
    try ctx.db.?.exec(manage_main.MIGRATION_LOG_TABLE, .{}, .{});

    const current_version: i32 = (try ctx.db.?.one(i32, "select max(version) from migration_logs", .{}, .{})) orelse 0;
    logger.info("db version: {d}", .{current_version});

    // before running migrations, copy the database over

    var savepoint = try ctx.db.?.savepoint("migrations");
    errdefer savepoint.rollback();
    defer savepoint.commit();

    var run: bool = false;

    inline for (manage_main.MIGRATIONS) |migration_decl| {
        const migration = Migration.fromTuple(migration_decl);

        if (index == migration.version) {
            run = true;

            logger.info("running migration {d} '{s}'", .{ migration.version, migration.name });
            var diags = sqlite.Diagnostics{};
            ctx.db.?.execMulti(migration.sql.?, .{ .diags = &diags }) catch |err| {
                logger.err("unable to prepare statement, got error {s}. diagnostics: {s}", .{ @errorName(err), diags });
                return err;
            };

            try ctx.db.?.exec(
                "INSERT INTO migration_logs (version, applied_at, description) values (?, ?, ?);",
                .{},
                .{
                    .version = migration.version,
                    .applied_at = std.time.timestamp(),
                    .description = migration.name,
                },
            );
        }
    }
}

test "single migration test" {
    var ctx = try makeTestContext();
    defer ctx.deinit();

    try loadSingleMigration(&ctx, 1);
    const count = try ctx.db.?.one(i64, "select count(*) from hashes", .{}, .{});
    try std.testing.expectEqual(@as(?i64, 0), count);
}
