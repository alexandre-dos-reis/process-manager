//! Client connections: accept, read requests, flush output, sweep dead ones.
const std = @import("std");
const sys = @import("../sys.zig");
const common = @import("../common.zig");
const Buf = common.Buf;
const gpa = common.gpa;
const commands = @import("commands.zig");
const output = @import("output.zig");
const state = @import("state.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const Conn = types.Conn;
const MAX_REQ = types.MAX_REQ;
const freeProc = util.freeProc;
const handleRequest = commands.handleRequest;
const queue = output.queue;
const recomputeMaxName = util.recomputeMaxName;

// ------------------------------------------------------------- connections

pub fn tryRequest(c: *Conn) void {
    if (c.in.len < 4) return;
    const len = std.mem.readInt(u32, c.in.data[0..4], .little);
    if (len > MAX_REQ) {
        c.dead = true;
        return;
    }
    const need = 4 + @as(usize, len);
    if (c.in.len < need) return;
    c.got_req = true;
    handleRequest(c, c.in.data[4..need]);
    c.in.deinit();
}

pub fn readConn(c: *Conn) void {
    var buf: [65536]u8 = undefined;
    while (!c.dead) {
        const n = sys.read(c.fd, &buf, buf.len);
        if (n > 0) {
            if (c.got_req) continue; // ignore anything after the request
            c.in.append(buf[0..@intCast(n)]);
            if (c.in.len > MAX_REQ) {
                c.dead = true;
                return;
            }
            tryRequest(c);
            continue;
        }
        if (n == 0) {
            c.dead = true;
            return;
        }
        const e = sys.errno();
        if (e == sys.EAGAIN) return;
        if (e == sys.EINTR) continue;
        c.dead = true;
        return;
    }
}

pub fn flush(c: *Conn) void {
    if (c.dead) return;
    while (c.out_pos < c.out.len) {
        const n = sys.write(c.fd, c.out.data.ptr + c.out_pos, c.out.len - c.out_pos);
        if (n > 0) {
            c.out_pos += @intCast(n);
            continue;
        }
        if (n < 0) {
            const e = sys.errno();
            if (e == sys.EAGAIN) return;
            if (e == sys.EINTR) continue;
        }
        c.dead = true;
        return;
    }
    c.out.len = 0;
    c.out_pos = 0;
    if (c.out.data.len > 64 * 1024) c.out.deinit();
    if (c.close_after_flush) c.dead = true;
}

pub fn acceptAll(listen_fd: c_int) void {
    while (true) {
        const fd = sys.accept(listen_fd, null, null);
        if (fd < 0) return;
        sys.setNonblock(fd);
        sys.setCloexec(fd);
        const c = gpa.create(Conn) catch @panic("oom");
        c.* = .{ .fd = fd };
        state.conns.append(gpa, c) catch @panic("oom");
    }
}

pub fn sweep() void {
    var i: usize = 0;
    while (i < state.conns.items.len) {
        const c = state.conns.items[i];
        if (c.dead and c != state.down_conn) {
            _ = sys.close(c.fd);
            c.in.deinit();
            c.out.deinit();
            gpa.destroy(c);
            _ = state.conns.orderedRemove(i);
        } else i += 1;
    }
    i = 0;
    while (i < state.procs.items.len) {
        const p = state.procs.items[i];
        if (p.remove_when_dead and p.pid == 0) {
            for (state.conns.items) |c| {
                if (c.follow) |f| {
                    if (f.proc == p) c.dead = true;
                }
            }
            _ = state.procs.orderedRemove(i);
            freeProc(p);
            recomputeMaxName();
        } else i += 1;
    }
}

pub fn finish() noreturn {
    if (state.down_conn) |c| {
        queue(c, "daemon stopped\n");
        c.dead = false;
        flush(c);
    }
    _ = sys.unlink(state.sock_path.ptr);
    sys.exit(0);
}
