const std = @import("std");
const builtin = @import("builtin");

const EXECUTABLES = .{
    .{ "awtfdb-manage", @import("main.zig") },
    .{ "ainclude", @import("include_main.zig") },
    .{ "afind", @import("find_main.zig") },
    .{ "als", @import("ls_main.zig") },
    .{ "arm", @import("rm_main.zig") },
    .{ "atags", @import("tags_main.zig") },
    .{ "awtfdb-metrics", @import("metrics_main.zig") },
    .{ "awtfdb-janitor", @import("janitor_main.zig") },
    .{ "amv", @import("mv_main.zig") },
} ++ switch (builtin.os.tag) {
    .linux => .{
        .{ "awtfdb-watcher", @import("rename_watcher_main.zig") },
    },
    else => .{},
};

pub const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn main() anyerror!u8 {
    var it = std.process.args();
    const exec_name = std.fs.path.basename(it.next().?);

    inline for (EXECUTABLES) |executable| {
        if (std.mem.eql(u8, exec_name, executable.@"0")) {
            const module = executable.@"1";
            const main_type = @typeInfo(@TypeOf(module.main));
            const ret_type = @typeInfo(main_type.Fn.return_type.?);
            const payload_type = ret_type.ErrorUnion.payload;
            if (payload_type == u8) {
                return module.main();
            } else {
                try module.main();
                return 0;
            }
        }
    }

    std.log.err("invalid executable name: '{s}'", .{exec_name});
    @panic("invalid executable name");
}
