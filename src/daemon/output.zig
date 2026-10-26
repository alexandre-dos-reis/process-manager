//! Where a process's bytes go: ring, log file, followers; plus daemon notes.
const std = @import("std");
const sys = @import("../sys.zig");
const common = @import("../common.zig");
const Buf = common.Buf;
const gpa = common.gpa;
const fmt = @import("fmt.zig");
const state = @import("state.zig");
const types = @import("types.zig");
const Conn = types.Conn;
const DIM = types.DIM;
const Fmt = fmt.Fmt;
const LOG_ROTATE = types.LOG_ROTATE;
const MAX_CONN_OUT = types.MAX_CONN_OUT;
const Proc = types.Proc;
const RESET = types.RESET;

// ------------------------------------------------------------ output paths

pub fn openLog(p: *Proc) void {
    if (p.log_fd >= 0) return;
    const path = common.joinZ(&.{ state.logs_dir, "/", p.name, ".log" });
    defer gpa.free(path);
    p.log_fd = sys.open(path.ptr, sys.O_WRONLY | sys.O_CREAT | sys.O_APPEND, @as(c_uint, 0o600));
    if (p.log_fd >= 0) sys.setCloexec(p.log_fd);
    p.log_bytes = 0;
}

pub fn writeLog(p: *Proc, bytes: []const u8) void {
    if (p.log_fd < 0) return;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = sys.write(p.log_fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    p.log_bytes += bytes.len;
    if (p.log_bytes > LOG_ROTATE) {
        _ = sys.close(p.log_fd);
        p.log_fd = -1;
        const path = common.joinZ(&.{ state.logs_dir, "/", p.name, ".log" });
        defer gpa.free(path);
        const old = common.joinZ(&.{ path, ".1" });
        defer gpa.free(old);
        _ = sys.rename(path.ptr, old.ptr);
        openLog(p);
    }
}

pub fn queue(c: *Conn, bytes: []const u8) void {
    if (c.dead) return;
    c.out.append(bytes);
    if (c.out.len - c.out_pos > MAX_CONN_OUT) c.dead = true; // client too slow
}

pub fn hasPrefixFollower(p: *Proc) bool {
    for (state.conns.items) |c| {
        if (c.dead) continue;
        const f = c.follow orelse continue;
        if (f.prefix and (f.all or f.proc == p)) return true;
    }
    return false;
}

/// Rebuild the formatter state from the history (used when a prefixed follower
/// shows up after a period where nobody needed it, so the common case stays free).
pub fn rebuildFmt(p: *Proc) void {
    p.fmt = .{};
    const r = &p.ring;
    if (r.len == 0) return;
    const first = @min(r.len, r.data.len - r.head);
    p.fmt.scan(r.data[r.head..][0..first]);
    p.fmt.scan(r.data[0 .. r.len - first]);
}

/// Record and broadcast bytes produced by a process (or a zpawn note).
pub fn emit(p: *Proc, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const want_fmt = hasPrefixFollower(p);
    if (want_fmt and p.fmt_stale) {
        rebuildFmt(p); // before the new bytes are added to the history
        p.fmt_stale = false;
    }
    p.ring.append(bytes);
    p.last_byte = bytes[bytes.len - 1];
    writeLog(p, bytes);

    if (want_fmt) {
        state.scratch.len = 0;
        p.fmt.run(&state.scratch, p.prefix, bytes);
    } else {
        p.fmt_stale = true;
    }

    for (state.conns.items) |c| {
        const f = c.follow orelse continue;
        if (!f.all and f.proc != p) continue;
        queue(c, if (f.prefix) state.scratch.slice() else bytes);
    }
    if (state.scratch.data.len > 256 * 1024) state.scratch.deinit();
}

pub fn note(p: *Proc, comptime f: []const u8, args: anytype) void {
    var m = Buf{};
    defer m.deinit();
    if (p.last_byte != '\n' and p.last_byte != '\r') m.append("\r\n");
    m.print(RESET ++ DIM ++ "[zpawn] " ++ f ++ RESET ++ "\r\n", args);
    emit(p, m.slice());
}

pub fn backlog(p: *Proc, n: usize, prefix: bool, out: *Buf) void {
    if (n == 0) return;
    const r = &p.ring;
    var start: usize = 0;
    var count: usize = 0;
    var i = r.len;
    if (i > 0 and r.at(i - 1) == '\n') i -= 1;
    while (i > 0) {
        i -= 1;
        if (r.at(i) == '\n') {
            count += 1;
            if (count == n) {
                start = i + 1;
                break;
            }
        }
    }
    if (!prefix) {
        r.appendTo(start, out);
    } else {
        var tmp = Buf{};
        defer tmp.deinit();
        r.appendTo(start, &tmp);
        var f: Fmt = .{};
        f.run(out, p.prefix, tmp.slice());
    }
}
