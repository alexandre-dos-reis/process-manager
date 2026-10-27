//! zpawn daemon: owns the processes (each on its own PTY, or on a plain pipe
//! when it is declared `tty: false`), keeps a ring buffer of raw output per
//! process and serves clients over a Unix socket.
//!
//! Output is never rewritten: bytes coming from the PTY are stored and forwarded
//! untouched, so colors and escape sequences survive. The only thing ever
//! inserted is a "name |" prefix when several processes are followed together,
//! and the active SGR (color) state is re-applied right after it.
const std = @import("std");
const sys = @import("sys.zig");
const common = @import("common.zig");
const Buf = common.Buf;
const gpa = common.gpa;
const commands = @import("daemon/commands.zig");
const control = @import("daemon/control.zig");
const server = @import("daemon/server.zig");
const state = @import("daemon/state.zig");
const types = @import("daemon/types.zig");
const Proc = types.Proc;
const acceptAll = server.acceptAll;
const beginShutdown = commands.beginShutdown;
const finish = server.finish;
const flush = server.flush;
const pollTimeout = control.pollTimeout;
const readConn = server.readConn;
const readPty = control.readPty;
const sweep = server.sweep;
const tick = control.tick;

pub var chld_pipe: [2]c_int = .{ -1, -1 };

pub fn wake() void {
    const ep = sys.errnoPtr();
    const saved = ep.*;
    _ = sys.write(chld_pipe[1], "x", 1);
    ep.* = saved;
}

pub fn onTerm(_: c_int) callconv(.c) void {
    @atomicStore(u8, &state.got_term, 1, .release);
    wake();
}

pub fn onChld(_: c_int) callconv(.c) void {
    wake();
}

// -------------------------------------------------------------------- main

pub fn run(home: [:0]const u8) u8 {
    _ = sys.mkdir(home.ptr, 0o700);
    {
        // Keep the state directory out of version control.
        const gi = common.joinZ(&.{ home, "/.gitignore" });
        defer gpa.free(gi);
        const fd = sys.open(gi.ptr, sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, @as(c_uint, 0o644));
        if (fd >= 0) {
            _ = sys.write(fd, "*\n", 2);
            _ = sys.close(fd);
        }
    }
    state.logs_dir = common.joinZ(&.{ home, "/logs" });
    _ = sys.mkdir(state.logs_dir.ptr, 0o700);
    state.sock_path = common.dupeZ("sock"); // relative: we live in the state directory

    const probe = common.connectIn(home); // also chdir()s into `home`
    if (probe >= 0) {
        _ = sys.close(probe);
        return 0; // a daemon is already serving this socket
    }
    if (sys.chdir(home.ptr) != 0) return 1;
    _ = sys.unlink(state.sock_path.ptr);

    const addr = sys.makeAddr(state.sock_path) orelse return 1;
    const listen_fd = sys.socket(sys.AF_UNIX, sys.SOCK_STREAM, 0);
    if (listen_fd < 0) return 1;
    if (sys.bind(listen_fd, &addr, @sizeOf(sys.SockaddrUn)) != 0) return 1;
    if (sys.listen(listen_fd, 32) != 0) return 1;
    sys.setNonblock(listen_fd);
    sys.setCloexec(listen_fd);

    _ = sys.signal(sys.SIGPIPE, sys.SIG_IGN);

    // Signals wake poll() through a pipe: with nothing scheduled the daemon sleeps
    // until a client, a process or a child exit needs it (no periodic wake-ups).
    if (sys.pipe(&chld_pipe) != 0) return 1;
    for (chld_pipe) |fd| {
        sys.setNonblock(fd);
        sys.setCloexec(fd);
    }
    _ = sys.signal(sys.SIGTERM, @intFromPtr(&onTerm));
    _ = sys.signal(sys.SIGINT, @intFromPtr(&onTerm));
    _ = sys.signal(sys.SIGCHLD, @intFromPtr(&onChld));

    var fds: std.ArrayList(sys.PollFd) = .empty;
    var poll_procs: std.ArrayList(*Proc) = .empty;
    const readable: c_short = sys.POLLIN | sys.POLLHUP | sys.POLLERR;

    while (true) {
        if (@atomicLoad(u8, &state.got_term, .acquire) == 1 and !state.shutting_down) beginShutdown(null);

        fds.clearRetainingCapacity();
        poll_procs.clearRetainingCapacity();
        fds.append(gpa, .{ .fd = listen_fd, .events = sys.POLLIN, .revents = 0 }) catch @panic("oom");
        fds.append(gpa, .{ .fd = chld_pipe[0], .events = sys.POLLIN, .revents = 0 }) catch @panic("oom");
        for (state.conns.items) |c| {
            var ev: c_short = sys.POLLIN;
            if (c.out_pos < c.out.len) ev |= sys.POLLOUT;
            fds.append(gpa, .{ .fd = c.fd, .events = ev, .revents = 0 }) catch @panic("oom");
        }
        const nconns = state.conns.items.len;
        for (state.procs.items) |p| {
            if (p.master >= 0) {
                fds.append(gpa, .{ .fd = p.master, .events = sys.POLLIN, .revents = 0 }) catch @panic("oom");
                poll_procs.append(gpa, p) catch @panic("oom");
            }
        }

        _ = sys.poll(fds.items.ptr, @intCast(fds.items.len), pollTimeout(sys.nowMs()));

        var reap = false;
        if (fds.items[1].revents & readable != 0) {
            var junk: [64]u8 = undefined;
            while (sys.read(chld_pipe[0], &junk, junk.len) > 0) {}
            reap = true;
        }
        if (fds.items[0].revents & sys.POLLIN != 0) acceptAll(listen_fd);
        for (0..nconns) |i| {
            if (fds.items[2 + i].revents & readable != 0) readConn(state.conns.items[i]);
        }
        for (poll_procs.items, 0..) |p, j| {
            if (fds.items[2 + nconns + j].revents & readable != 0) _ = readPty(p);
        }

        const now = sys.nowMs();
        tick(now, reap);
        for (state.conns.items) |c| flush(c);
        sweep();

        if (state.shutting_down) {
            var alive = false;
            for (state.procs.items) |p| {
                if (p.pid > 0) alive = true;
            }
            if (!alive or now > state.shutdown_deadline) finish();
        }
    }
}
