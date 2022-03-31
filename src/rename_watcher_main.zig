const std = @import("std");
const sqlite = @import("sqlite");
const manage_main = @import("main.zig");
const Context = manage_main.Context;

const log = std.log.scoped(.awtfdb_watcher);

const VERSION = "0.0.1";
const HELPTEXT =
    \\ awtfdb-watcher: watch the entire operating system for renames,
    \\  updating the database with such
    \\
    \\ currently only supports linux with bpftrace installed.
    \\
    \\ MUST be run as root.
    \\
    \\ usage:
    \\  awtfdb-watcher [options...] path_to_home_directory
    \\
    \\ options:
    \\ 	-h				prints this help and exits
    \\ 	-V				prints version and exits
;

const PidTid = struct { pid: std.os.pid_t, tid: std.os.pid_t };
const StringAsList = std.ArrayList(u8);
const ChunkedName = struct { state: enum { NeedMore, Complete }, data: StringAsList };
const ChunkedNameMap = std.AutoHashMap(PidTid, ChunkedName);
const NameMap = std.AutoHashMap(PidTid, []const u8);

const RenameContext = struct {
    allocator: std.mem.Allocator,
    oldnames: *ChunkedNameMap,
    newnames: *ChunkedNameMap,
    cwds: *NameMap,
    ctx: *Context,
    keep_running: bool = true,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.cwds.deinit();
        self.oldnames.deinit();
        self.newnames.deinit();
    }

    pub fn processLine(self: *Self, line: []const u8) !void {
        var line_it = std.mem.split(u8, line, ":");

        const version_string = line_it.next().?;
        const is_v1_message = std.mem.eql(u8, version_string, "v1");
        if (!is_v1_message) return;

        const message_type = line_it.next().?;

        const pid_string = line_it.next().?;
        const tid_string = line_it.next().?;
        const pid = try std.fmt.parseInt(std.os.pid_t, pid_string, 10);
        const tid = try std.fmt.parseInt(std.os.pid_t, tid_string, 10);
        const pid_tid_key = PidTid{ .pid = pid, .tid = tid };

        const is_oldname_message = std.mem.eql(u8, message_type, "oldname");
        const is_newname_message = std.mem.eql(u8, message_type, "newname");

        if (std.mem.eql(u8, message_type, "execve")) {
            var cwd_proc_path = try std.fmt.allocPrint(self.allocator, "/proc/{d}/cwd", .{pid});
            defer self.allocator.free(cwd_proc_path);

            var cwd_path = std.fs.realpathAlloc(self.allocator, cwd_proc_path) catch |err| switch (err) {
                error.AccessDenied, error.FileNotFound => {
                    log.debug("can't access cwd for {d}, ignoring rename", .{pid});
                    return;
                },
                else => return err,
            };

            try self.cwds.put(pid_tid_key, cwd_path);
        } else if (std.mem.eql(u8, message_type, "exit_execve")) {
            const return_value_as_string = line_it.next().?;

            // if unsuccessful execve, remove cwd
            if (!std.mem.eql(u8, return_value_as_string, "0")) {
                const cwd_path = self.cwds.get(pid_tid_key);
                defer if (cwd_path) |unpacked| self.allocator.free(unpacked);
                _ = self.cwds.remove(pid_tid_key);
            }
        } else if (std.mem.eql(u8, message_type, "exit_process")) {
            const cwd_path = self.cwds.get(pid_tid_key);
            defer if (cwd_path) |unpacked| self.allocator.free(unpacked);
            _ = self.cwds.remove(pid_tid_key);
        } else if (is_oldname_message or is_newname_message) {
            // i do this to account for paths that have the : character
            // in them. do not use line_it after this, or, use it very cautiously
            const chunk_data = line[(version_string.len + 1 + message_type.len + 1 + pid_string.len + 1 + tid_string.len + 1)..line.len];
            var map_to_put_in: *ChunkedNameMap =
                if (is_oldname_message) self.oldnames else self.newnames;

            var maybe_chunk = map_to_put_in.getPtr(pid_tid_key);

            if (maybe_chunk) |chunk| {
                switch (chunk.state) {
                    .NeedMore => {
                        const written_bytes = try chunk.data.writer().write(chunk_data);
                        std.debug.assert(written_bytes == chunk_data.len);
                        if (chunk_data.len < 200) {
                            chunk.state = .Complete;
                        }
                    },
                    .Complete => {},
                }
            } else {
                var chunk = ChunkedName{
                    .state = .NeedMore,
                    .data = StringAsList.init(self.allocator),
                };

                const written_bytes = try chunk.data.writer().write(chunk_data);
                std.debug.assert(written_bytes == chunk_data.len);
                if (chunk_data.len < 200) {
                    chunk.state = .Complete;
                }

                try map_to_put_in.put(
                    pid_tid_key,
                    chunk,
                );
            }
            std.debug.assert(map_to_put_in.count() > 0);
        } else if (std.mem.eql(u8, message_type, "exit_rename")) {
            // got a return from one of the rename syscalls,
            // we must (try to) resolve it
            const return_value_as_string = line_it.next().?;

            const old_name = self.oldnames.get(pid_tid_key);
            const new_name = self.newnames.get(pid_tid_key);
            const maybe_cwd = self.cwds.get(pid_tid_key);

            std.debug.assert(self.oldnames.count() > 0);
            std.debug.assert(self.newnames.count() > 0);

            if (std.mem.eql(u8, return_value_as_string, "0")) {
                defer _ = self.oldnames.remove(pid_tid_key);
                defer _ = self.newnames.remove(pid_tid_key);
                defer _ = self.cwds.remove(pid_tid_key);

                defer old_name.?.data.deinit();
                defer new_name.?.data.deinit();
                defer if (maybe_cwd) |cwd| self.allocator.free(cwd);

                try self.handleSucessfulRename(pid_tid_key, old_name.?.data.items, new_name.?.data.items, maybe_cwd);
            }
        }
    }

    fn handleSucessfulRename(
        self: *Self,
        pidtid_pair: PidTid,
        relative_old_name: []const u8,
        relative_new_name: []const u8,
        maybe_cwd: ?[]const u8,
    ) !void {
        const pid = pidtid_pair.pid;

        const is_oldname_absolute = std.fs.path.isAbsolute(relative_old_name);
        const is_newname_absolute = std.fs.path.isAbsolute(relative_new_name);

        var cwd_path: ?[]const u8 = null;
        if (maybe_cwd) |unpacked| {
            cwd_path = unpacked;
            // if any of them is relative, construct cwd_path and use it later
        } else if (!(is_oldname_absolute and is_newname_absolute)) {
            // if we don't have it already, try to fetch it from procfs
            // as this might be a process we didn't know about before

            var cwd_proc_path = try std.fmt.allocPrint(self.allocator, "/proc/{d}/cwd", .{pid});
            defer self.allocator.free(cwd_proc_path);

            cwd_path = std.fs.realpathAlloc(self.allocator, cwd_proc_path) catch |err| switch (err) {
                error.AccessDenied, error.FileNotFound => {
                    log.debug("can't access cwd for {d}, ignoring rename", .{pid});
                    return;
                },
                else => return err,
            };
        }

        // if we didn't receive maybe_cwd, that means we had to allocate
        // cwd_path ourselves by reading from /proc. so we own the lifetime here
        defer if (maybe_cwd == null and cwd_path != null)
            self.allocator.free(cwd_path.?);

        // applying cwd_path if the path is already absolute is incorrect behavior.
        var oldpath = if (!is_oldname_absolute)
            try std.fs.path.resolve(self.allocator, &[_][]const u8{
                cwd_path.?,
                relative_old_name,
            })
        else
            try std.fs.path.resolve(self.allocator, &[_][]const u8{relative_old_name});
        defer self.allocator.free(oldpath);
        var newpath = if (!is_newname_absolute)
            try std.fs.path.resolve(self.allocator, &[_][]const u8{
                cwd_path.?,
                relative_new_name,
            })
        else
            try std.fs.path.resolve(self.allocator, &[_][]const u8{relative_new_name});
        defer self.allocator.free(newpath);

        const is_old_in_home = std.mem.startsWith(u8, oldpath, self.ctx.home_path.?);
        const is_new_in_home = std.mem.startsWith(u8, newpath, self.ctx.home_path.?);

        if (!(is_new_in_home or is_old_in_home)) {
            log.debug("{d}: neither {s} or {s} are in home", .{ pid, oldpath, newpath });
            return;
        }

        log.info("{d}: relevant rename: {s} -> {s}", .{ pid, oldpath, newpath });

        // find out if this is a folder or not by sql count(*)
        //  with (local_path LIKE ? || '%')
        // if its 1, we need to compare paths to see if newpath is a folder
        //  that only has 1 indexed file or not
        // if its more than 1, it's 100% a folder, and we don't need to openDir

        var stmt = try self.ctx.db.?.prepare(
            \\ select file_hash, hashes.hash_data, local_path
            \\ from files
            \\ join hashes
            \\  on files.file_hash = hashes.id
            \\ where local_path LIKE ? || '%'
        );
        defer stmt.deinit();

        const raw_files = try stmt.all(
            struct {
                file_hash: i64,
                hash_data: sqlite.Blob,
                local_path: []const u8,
            },
            self.allocator,
            .{},
            .{ .local_path = oldpath },
        );
        defer for (raw_files) |*raw_file| raw_file.hash_data.close() catch unreachable;
        defer self.allocator.free(raw_files);

        if (raw_files.len >= 1) {
            // consider the following folder structure:
            //
            // /home/luna/b
            // /home/luna/abc/d
            //
            // if /home/luna/b gets renamed to /home/luna/a we would get
            // two elements in raw_files, so we have to disambiguate
            //
            // we do not want to access the filesystem as that can crash us
            // due to race conditions, so we must try to infer as much as
            // possible from db data

            // fact 1: if we have a file that has an exact match with newpath,
            // then we have a single file rather than folder (as folders cant
            // be indexed themselves)

            var starts_with_count: usize = 0;

            for (raw_files) |raw_file| {
                if (std.mem.eql(u8, raw_file.local_path, oldpath)) {
                    const real_hash = (Context.HashWithBlob{
                        .id = raw_file.file_hash,
                        .hash_data = raw_file.hash_data,
                    }).toRealHash();

                    var file = Context.File{
                        .ctx = self.ctx,
                        .local_path = raw_file.local_path,
                        .hash = real_hash,
                    };
                    // since setLocalPath copies ownership, deinit afterwards
                    defer file.deinit();

                    // confirmed single file
                    log.info(
                        "File {s} was renamed from {s} to {s}",
                        .{ real_hash, oldpath, newpath },
                    );

                    try file.setLocalPath(newpath);

                    return;
                } else if (std.mem.startsWith(u8, oldpath, raw_file.local_path)) {
                    starts_with_count += 1;
                }
            }

            var is_directory_move = false;

            // fact 2: if we had more than one path that starts with
            // the newpath, it's definitely a folder. rename it accordingly
            if (starts_with_count > 0) is_directory_move = true;

            // fact 3: if neither 1 or 2 are true, go to the filesystem and
            // find out

            if (!is_directory_move) {
                var dir: ?std.fs.Dir = std.fs.cwd().openDir(newpath, .{}) catch |err| switch (err) {
                    error.NotDir => null,
                    else => return err,
                };
                defer if (dir) |*unpacked_dir| unpacked_dir.close();
                is_directory_move = dir != null;
            }

            if (is_directory_move) {
                var oldpath_assumed_folder_buffer: [std.os.PATH_MAX]u8 = undefined;
                const oldpath_assumed_folder = try std.fmt.bufPrint(
                    &oldpath_assumed_folder_buffer,
                    "{s}{s}",
                    .{ oldpath, std.fs.path.sep_str },
                );

                for (raw_files) |raw_file| {
                    var replace_buffer: [std.os.PATH_MAX]u8 = undefined;
                    if (std.mem.startsWith(u8, raw_file.local_path, oldpath_assumed_folder)) {
                        // this is a file in a folder, update it accordingly

                        // to do this, we need to replace oldpath by newpath
                        // since we know it starts with oldpath, we just need
                        // to slice oldpath out of local_path
                        //
                        // then construct it back together by prepending
                        // newpath_assumed_folder into this
                        const path_after_oldpath = raw_file.local_path[oldpath.len + 1 ..];
                        const replaced_path = try std.fmt.bufPrint(
                            &replace_buffer,
                            "{s}{s}{s}",
                            .{ newpath, std.fs.path.sep_str, path_after_oldpath },
                        );

                        log.info(
                            "File {s} was renamed from {s} to {s}",
                            .{ &raw_file.file_hash, raw_file.local_path, replaced_path },
                        );

                        const real_hash = (Context.HashWithBlob{
                            .id = raw_file.file_hash,
                            .hash_data = raw_file.hash_data,
                        }).toRealHash();

                        var file = Context.File{
                            .ctx = self.ctx,
                            .local_path = raw_file.local_path,
                            .hash = real_hash,
                        };

                        // since setLocalPath copies ownership, deinit here
                        defer file.deinit();
                        try file.setLocalPath(replaced_path);
                    }
                }
            } else {
                // if not, then we don't update anything (we already should
                // have updated from fact 1).
            }
        } else {
            // nothing about this path is in the database, so, don't give a fuck.
        }
    }

    pub fn handleNewSignals(self: *Self) !void {
        while (true) {
            const signal_data = maybe_self_pipe.?.reader.reader().readStruct(SignalData) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            log.info("exiting! with signal {d}", .{signal_data.signal});
            self.keep_running = false;
            return;
        }
    }
};

const Pipe = struct {
    reader: std.fs.File,
    writer: std.fs.File,
};

var maybe_self_pipe: ?Pipe = null;

const SignalData = extern struct {
    signal: c_int,
    info: std.os.siginfo_t,
    uctx: ?*const anyopaque,
};
const SignalList = std.ArrayList(SignalData);

fn signalHandler(
    signal: c_int,
    info: *const std.os.siginfo_t,
    uctx: ?*const anyopaque,
) callconv(.C) void {
    if (maybe_self_pipe) |self_pipe| {
        const signal_data = SignalData{
            .signal = signal,
            .info = info.*,
            .uctx = uctx,
        };
        self_pipe.writer.writer().writeStruct(signal_data) catch return;
    }
}

pub fn main() anyerror!void {
    const rc = sqlite.c.sqlite3_config(sqlite.c.SQLITE_CONFIG_LOG, manage_main.sqliteLog, @as(?*anyopaque, null));
    if (rc != sqlite.c.SQLITE_OK) {
        std.log.err("failed to configure: {d} '{s}'", .{
            rc, sqlite.c.sqlite3_errstr(rc),
        });
        return error.ConfigFail;
    }

    const self_pipe_fds = try std.os.pipe();
    maybe_self_pipe = .{
        .reader = .{ .handle = self_pipe_fds[0] },
        .writer = .{ .handle = self_pipe_fds[1] },
    };
    defer {
        maybe_self_pipe.?.reader.close();
        maybe_self_pipe.?.writer.close();
    }

    var mask = std.os.empty_sigset;
    // only linux and darwin implement sigaddset() on zig stdlib. huh.
    std.os.linux.sigaddset(&mask, std.os.SIG.TERM);
    std.os.linux.sigaddset(&mask, std.os.SIG.INT);
    var sa = std.os.Sigaction{
        .handler = .{ .sigaction = signalHandler },
        .mask = mask,
        .flags = 0,
    };
    try std.os.sigaction(std.os.SIG.TERM, &sa, null);
    try std.os.sigaction(std.os.SIG.INT, &sa, null);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var args_it = std.process.args();
    _ = args_it.skip();

    const Args = struct {
        help: bool = false,
        version: bool = false,
        home_path: ?[]const u8 = null,
    };

    var given_args = Args{};
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h")) {
            given_args.help = true;
        } else if (std.mem.eql(u8, arg, "-V")) {
            given_args.version = true;
        } else {
            given_args.home_path = arg;
        }
    }

    if (given_args.help) {
        std.debug.print(HELPTEXT, .{});
        return;
    } else if (given_args.version) {
        std.debug.print("awtfdb-watcher {s}\n", .{VERSION});
        return;
    }

    if (given_args.home_path == null) {
        std.debug.print("home path is a required argument", .{});
        return;
    }

    var ctx = Context{
        .home_path = given_args.home_path,
        .args_it = undefined,
        .stdout = undefined,
        .db = null,
        .allocator = allocator,
    };
    defer ctx.deinit();

    try ctx.loadDatabase(.{});

    std.log.info("args: {}", .{given_args});

    const bpftrace_program = @embedFile("./rename_trace.bt");

    var proc = try std.ChildProcess.init(
        &[_][]const u8{ "bpftrace", "-e", bpftrace_program },
        allocator,
    );

    var envmap = std.BufMap.init(allocator);
    defer envmap.deinit();
    try envmap.put("BPFTRACE_STRLEN", "200");
    proc.env_map = &envmap;

    defer proc.deinit();

    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;
    try proc.spawn();

    var wait_pipe = try std.os.pipe();
    defer std.os.close(wait_pipe[0]);
    defer std.os.close(wait_pipe[1]);

    var pidfd: ?std.os.fd_t = null;

    const pidfd_rc = std.os.linux.pidfd_open(proc.pid, 0);
    switch (std.os.errno(pidfd_rc)) {
        .SUCCESS => pidfd = @intCast(std.os.fd_t, pidfd_rc),
        .INVAL => unreachable,
        .NFILE, .MFILE => return error.TooManyFileDescriptors,
        .NODEV => return error.NoDevice,
        .NOMEM => return error.SystemResources,
        .SRCH => unreachable, // race condition
        else => |err| return std.os.unexpectedErrno(err),
    }

    var sockets = [_]std.os.pollfd{
        .{ .fd = proc.stdout.?.handle, .events = std.os.POLL.IN, .revents = 0 },
        .{ .fd = proc.stderr.?.handle, .events = std.os.POLL.IN, .revents = 0 },
        .{ .fd = pidfd orelse return error.InvalidPidFd, .events = std.os.POLL.IN, .revents = 0 },
        .{ .fd = maybe_self_pipe.?.reader.handle, .events = std.os.POLL.IN, .revents = 0 },
    };

    var oldnames = ChunkedNameMap.init(allocator);
    var newnames = ChunkedNameMap.init(allocator);
    var cwds = NameMap.init(allocator);

    var rename_ctx = RenameContext{
        .allocator = allocator,
        .oldnames = &oldnames,
        .newnames = &newnames,
        .cwds = &cwds,
        .ctx = &ctx,
    };
    defer rename_ctx.deinit();

    while (rename_ctx.keep_running) {
        const available = try std.os.poll(&sockets, -1);
        if (available == 0) {
            log.info("timed out, retrying", .{});
            continue;
        }

        // have a max of 16kb per thing given by bpftrace
        var line_buffer: [16 * 1024]u8 = undefined;

        for (sockets) |pollfd| {
            if (pollfd.revents == 0) continue;

            if (pollfd.fd == maybe_self_pipe.?.reader.handle) {
                try rename_ctx.handleNewSignals();
                _ = try proc.kill();
            } else if (proc.stdout != null and pollfd.fd == proc.stdout.?.handle) {
                const line = proc.stdout.?.reader().readUntilDelimiter(&line_buffer, '\n') catch |err| {
                    log.err("error reading from stdout {s}", .{@errorName(err)});
                    switch (err) {
                        // process might have died while we're in the middle of a read
                        error.NotOpenForReading, error.EndOfStream => {
                            proc.stdout = null;
                            continue;
                        },
                        else => return err,
                    }
                };
                //log.info("got out: {s}", .{line});
                try rename_ctx.processLine(line);
            } else if (proc.stderr != null and pollfd.fd == proc.stderr.?.handle) {
                const buffer_offset = proc.stderr.?.reader().readAll(&line_buffer) catch |err| {
                    log.err("error reading from stderr {s}", .{@errorName(err)});
                    switch (err) {
                        // process might have died while we're in the middle of a read
                        error.NotOpenForReading => {
                            proc.stderr = null;
                            continue;
                        },
                        else => return err,
                    }
                };

                const line = line_buffer[0..buffer_offset];
                log.warn("got stderr: {s}", .{line});
            } else if (pollfd.fd == pidfd) {
                var siginfo: std.os.siginfo_t = undefined;
                const waitid_rc = std.os.linux.waitid(.PIDFD, pidfd.?, &siginfo, 0);
                switch (std.os.errno(waitid_rc)) {
                    .SUCCESS => {},
                    .CHILD => unreachable, // unknown process. race condition
                    .INVAL => unreachable, // programming error
                    else => |err| {
                        log.err("wtf {}", .{err});
                        return std.os.unexpectedErrno(err);
                    },
                }
                log.err("bpftrace exited with {d}", .{siginfo.signo});
                return;
            }
        }
    }

    log.info("exiting main loop", .{});
}

//test "rename syscalls trigger db rename" {
//    const allocator = std.testing.allocator;
//
//    var ctx = try manage_main.makeTestContext();
//    defer ctx.deinit();
//
//    var oldnames = ChunkedNameMap.init(allocator);
//    var newnames = ChunkedNameMap.init(allocator);
//    var cwds = NameMap.init(allocator);
//
//    var rename_ctx = RenameContext{
//        .allocator = allocator,
//        .oldnames = &oldnames,
//        .newnames = &newnames,
//        .cwds = &cwds,
//        .ctx = &ctx,
//    };
//    defer rename_ctx.deinit();
//
//    var tmp = std.testing.tmpDir(.{});
//    defer tmp.cleanup();
//
//    var file = try tmp.dir.createFile("test_file", .{});
//    defer file.close();
//    _ = try file.write("awooga");
//
//    var indexed_file = try ctx.createFileFromDir(tmp.dir, "test_file");
//    defer indexed_file.deinit();
//
//    // TODO system layer so we can attach a test procfs and test filesystem too
//    // also should help if we think about going beyond bpftrace
//    //  (dtrace for macos and bsds maybe?)
//
//    var full_tmp_dir_path = try tmp.dir.realpathAlloc(allocator, ".");
//    defer allocator.free(full_tmp_dir_path);
//
//    var oldname = try std.fs.path.resolve(allocator, &[_][]const u8{
//        full_tmp_dir_path,
//        "test_file",
//    });
//    defer allocator.free(oldname);
//    var newname = try std.fs.path.resolve(allocator, &[_][]const u8{
//        full_tmp_dir_path,
//        "test_file2",
//    });
//    defer allocator.free(newname);
//
//    const lines_preprint =
//        \\v1:oldname:6969:6969:{s}
//        \\v1:newname:6969:6969:{s}
//        \\v1:exit_rename:6969:6969:0
//    ;
//
//    var buf: [8192]u8 = undefined;
//    const lines = try std.fmt.bufPrint(
//        &buf,
//        lines_preprint,
//        .{ oldname, newname },
//    );
//
//    // give those lines to context
//    var it = std.mem.split(u8, lines, "\n");
//    while (it.next()) |line|
//        try rename_ctx.processLine(line);
//
//    const oldname_count = (try ctx.db.?.one(
//        usize,
//        "select count(*) from files where local_path = ?",
//        .{},
//        .{oldname},
//    )).?;
//
//    try std.testing.expectEqual(@as(usize, 0), oldname_count);
//
//    const newname_count = (try ctx.db.?.one(
//        usize,
//        "select count(*) from files where local_path = ?",
//        .{},
//        .{newname},
//    )).?;
//    try std.testing.expectEqual(@as(usize, 1), newname_count);
//}
