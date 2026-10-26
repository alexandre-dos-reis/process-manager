//! zpawn daemon: owns the processes (each on its own PTY), keeps a ring buffer
//! of raw output per process and serves clients over a Unix socket.
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

const RING_MAX: usize = 128 * 1024; // history kept per process
const LOG_ROTATE: usize = 10 * 1024 * 1024;
const KILL_GRACE_MS: i64 = 5000;
const QUICK_EXIT_MS: i64 = 3000;
const MAX_QUICK_FAILS: u32 = 6;
const MAX_CONN_OUT: usize = 8 * 1024 * 1024;
const MAX_REQ: usize = 16 * 1024 * 1024;
const palette = [_]u8{ 96, 93, 92, 95, 94, 91 };

const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const DIM = "\x1b[2m";
const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const CYAN = "\x1b[36m";

const Style = struct {
    on: bool,
    fn c(self: Style, code: []const u8) []const u8 {
        return if (self.on) code else "";
    }
};

// ---------------------------------------------------------------- formatter

/// Tracks line, escape-sequence and color (SGR) state over a byte stream. With
/// `with_out`, copies the bytes to `out` and inserts `prefix` (then the active
/// color) at the start of each line. Never drops or changes a byte.
const Fmt = struct {
    at_line_start: bool = true,
    esc: u8 = 0, // 0 = text, 1 = after ESC, 2 = inside CSI
    csi: [64]u8 = undefined,
    csi_len: usize = 0,
    sgr: [256]u8 = undefined,
    sgr_len: usize = 0,

    fn applySgr(self: *Fmt) void {
        const params = self.csi[0..self.csi_len];
        if (params.len == 0 or std.mem.eql(u8, params, "0")) {
            self.sgr_len = 0;
            return;
        }
        if (std.mem.startsWith(u8, params, "0;")) self.sgr_len = 0;
        const need = params.len + 3;
        if (self.sgr_len + need > self.sgr.len) {
            self.sgr_len = 0; // too long to track; give up on restoring
            return;
        }
        self.sgr[self.sgr_len] = 0x1b;
        self.sgr[self.sgr_len + 1] = '[';
        @memcpy(self.sgr[self.sgr_len + 2 ..][0..params.len], params);
        self.sgr[self.sgr_len + 2 + params.len] = 'm';
        self.sgr_len += need;
    }

    fn runImpl(self: *Fmt, comptime with_out: bool, out: *Buf, prefix: []const u8, bytes: []const u8) void {
        var span: usize = 0; // start of the bytes not yet copied to `out`
        for (bytes, 0..) |b, i| {
            if (self.esc != 0 and b < 0x20 and b != 0x1b) self.esc = 0; // malformed sequence
            if (self.esc == 0) {
                if (b == '\r' or b == '\n') {
                    self.at_line_start = true;
                } else if (b == 0x1b) {
                    self.esc = 1;
                    self.csi_len = 0;
                } else if ((b >= 0x20 or b == '\t') and self.at_line_start) {
                    if (with_out) {
                        out.append(bytes[span..i]);
                        span = i;
                        out.append(prefix);
                        out.append(self.sgr[0..self.sgr_len]);
                    }
                    self.at_line_start = false;
                }
            } else if (self.esc == 1) {
                self.esc = if (b == '[') 2 else 0;
            } else if (b >= 0x40 and b <= 0x7e) {
                if (b == 'm') self.applySgr();
                self.esc = 0;
            } else if (self.csi_len < self.csi.len) {
                self.csi[self.csi_len] = b;
                self.csi_len += 1;
            } else {
                self.esc = 0;
            }
        }
        if (with_out) out.append(bytes[span..]);
    }

    fn run(self: *Fmt, out: *Buf, prefix: []const u8, bytes: []const u8) void {
        self.runImpl(true, out, prefix, bytes);
    }

    /// Update the state only (no output).
    fn scan(self: *Fmt, bytes: []const u8) void {
        var unused: Buf = .{};
        self.runImpl(false, &unused, "", bytes);
    }
};

/// Fixed-size circular history. Starts tiny and grows (up to RING_MAX) only when
/// a process actually produces output.
const Ring = struct {
    data: []u8 = &.{},
    head: usize = 0, // index of the oldest byte
    len: usize = 0,

    fn deinit(self: *Ring) void {
        if (self.data.len > 0) gpa.free(self.data);
        self.* = .{};
    }

    fn grow(self: *Ring, need: usize) void {
        if (need <= self.data.len or self.data.len >= RING_MAX) return;
        var cap: usize = if (self.data.len == 0) 4096 else self.data.len;
        while (cap < need and cap < RING_MAX) cap *= 2;
        cap = @min(cap, RING_MAX);
        const nd = gpa.alloc(u8, cap) catch @panic("oom");
        const first = @min(self.len, self.data.len - self.head);
        @memcpy(nd[0..first], self.data[self.head..][0..first]);
        @memcpy(nd[first..self.len], self.data[0 .. self.len - first]);
        if (self.data.len > 0) gpa.free(self.data);
        self.data = nd;
        self.head = 0;
    }

    fn append(self: *Ring, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const b = if (bytes.len > RING_MAX) bytes[bytes.len - RING_MAX ..] else bytes;
        self.grow(self.len + b.len);
        const cap = self.data.len;
        if (self.len + b.len > cap) {
            const drop = self.len + b.len - cap;
            self.head = (self.head + drop) % cap;
            self.len -= drop;
        }
        const tail = (self.head + self.len) % cap;
        const first = @min(b.len, cap - tail);
        @memcpy(self.data[tail..][0..first], b[0..first]);
        @memcpy(self.data[0 .. b.len - first], b[first..]);
        self.len += b.len;
    }

    fn at(self: *const Ring, i: usize) u8 {
        return self.data[(self.head + i) % self.data.len];
    }

    /// Append the history from logical index `start` to the end.
    fn appendTo(self: *const Ring, start: usize, out: *Buf) void {
        if (start >= self.len) return;
        const cap = self.data.len;
        const s = (self.head + start) % cap;
        const n = self.len - start;
        const first = @min(n, cap - s);
        out.append(self.data[s..][0..first]);
        out.append(self.data[0 .. n - first]);
    }
};

// ------------------------------------------------------------------- types

const State = enum { running, stopped, exited, backoff, failed };

const Proc = struct {
    name: []u8,
    cmd: [:0]u8,
    cwd: [:0]u8,
    env: std.ArrayList([:0]u8) = .empty, // the client's environment
    over: std.ArrayList([:0]u8) = .empty, // per-process overrides ("KEY=value")
    cols: u16,
    rows: u16,
    autorestart: bool,
    color: u8,

    state: State = .stopped,
    pid: c_int = 0,
    master: c_int = -1,
    started_ms: i64 = 0,
    exit_code: i32 = 0,
    exit_signal: i32 = 0,
    restarts: u32 = 0,
    fails: u32 = 0,
    next_start_ms: i64 = 0,
    stopping: bool = false,
    killed: bool = false,
    kill_at_ms: i64 = 0,
    restart_pending: bool = false,
    remove_when_dead: bool = false,

    ring: Ring = .{},
    fmt: Fmt = .{},
    fmt_stale: bool = false, // fmt not kept up to date while nobody follows with prefixes
    last_byte: u8 = '\n',
    prefix: []u8 = &.{},
    log_fd: c_int = -1,
    log_bytes: usize = 0,
};

const Follow = struct { all: bool, proc: ?*Proc, prefix: bool };

const Conn = struct {
    fd: c_int,
    in: Buf = .{},
    out: Buf = .{},
    out_pos: usize = 0,
    follow: ?Follow = null,
    got_req: bool = false,
    close_after_flush: bool = false,
    dead: bool = false,
};

var procs: std.ArrayList(*Proc) = .empty;
var conns: std.ArrayList(*Conn) = .empty;
var color_counter: usize = 0;
var max_name: usize = 4;
var shutting_down = false;
var shutdown_deadline: i64 = 0;
var down_conn: ?*Conn = null;
var got_term: u8 = 0;
var logs_dir: [:0]u8 = undefined;
var sock_path: [:0]u8 = undefined;
var scratch: Buf = .{};

var chld_pipe: [2]c_int = .{ -1, -1 };

fn wake() void {
    const ep = sys.errnoPtr();
    const saved = ep.*;
    _ = sys.write(chld_pipe[1], "x", 1);
    ep.* = saved;
}

fn onTerm(_: c_int) callconv(.c) void {
    @atomicStore(u8, &got_term, 1, .release);
    wake();
}

fn onChld(_: c_int) callconv(.c) void {
    wake();
}

// ----------------------------------------------------------------- helpers

fn findProc(name: []const u8) ?*Proc {
    for (procs.items) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

fn rebuildPrefix(p: *Proc) void {
    var b = Buf{};
    defer b.deinit();
    b.print("\x1b[0m\x1b[1;{d}m{s}", .{ p.color, p.name });
    if (max_name > p.name.len) b.appendNTimes(' ', max_name - p.name.len);
    b.append(" |\x1b[0m ");
    if (p.prefix.len > 0) gpa.free(p.prefix);
    p.prefix = gpa.dupe(u8, b.slice()) catch @panic("oom");
}

fn recomputeMaxName() void {
    var m: usize = 4;
    for (procs.items) |p| m = @max(m, p.name.len);
    max_name = m;
    for (procs.items) |p| rebuildPrefix(p);
}

fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len > 32) return false;
    for (n) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-' or ch == '.';
        if (!ok) return false;
    }
    return true;
}

fn fmtDuration(buf: []u8, ms: i64) []const u8 {
    const s: i64 = @divTrunc(@max(ms, 0), 1000);
    const r = if (s < 60)
        std.fmt.bufPrint(buf, "{d}s", .{s})
    else if (s < 3600)
        std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ @divTrunc(s, 60), @mod(s, 60) })
    else if (s < 86400)
        std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ @divTrunc(s, 3600), @divTrunc(@mod(s, 3600), 60) })
    else
        std.fmt.bufPrint(buf, "{d}d {d}h", .{ @divTrunc(s, 86400), @divTrunc(@mod(s, 86400), 3600) });
    return r catch "?";
}

fn parseU16(s: []const u8, default: u16) u16 {
    return std.fmt.parseInt(u16, s, 10) catch default;
}

// ------------------------------------------------------------ output paths

fn openLog(p: *Proc) void {
    if (p.log_fd >= 0) return;
    const path = common.joinZ(&.{ logs_dir, "/", p.name, ".log" });
    defer gpa.free(path);
    p.log_fd = sys.open(path.ptr, sys.O_WRONLY | sys.O_CREAT | sys.O_APPEND, @as(c_uint, 0o600));
    if (p.log_fd >= 0) sys.setCloexec(p.log_fd);
    p.log_bytes = 0;
}

fn writeLog(p: *Proc, bytes: []const u8) void {
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
        const path = common.joinZ(&.{ logs_dir, "/", p.name, ".log" });
        defer gpa.free(path);
        const old = common.joinZ(&.{ path, ".1" });
        defer gpa.free(old);
        _ = sys.rename(path.ptr, old.ptr);
        openLog(p);
    }
}

fn queue(c: *Conn, bytes: []const u8) void {
    if (c.dead) return;
    c.out.append(bytes);
    if (c.out.len - c.out_pos > MAX_CONN_OUT) c.dead = true; // client too slow
}

fn hasPrefixFollower(p: *Proc) bool {
    for (conns.items) |c| {
        if (c.dead) continue;
        const f = c.follow orelse continue;
        if (f.prefix and (f.all or f.proc == p)) return true;
    }
    return false;
}

/// Rebuild the formatter state from the history (used when a prefixed follower
/// shows up after a period where nobody needed it, so the common case stays free).
fn rebuildFmt(p: *Proc) void {
    p.fmt = .{};
    const r = &p.ring;
    if (r.len == 0) return;
    const first = @min(r.len, r.data.len - r.head);
    p.fmt.scan(r.data[r.head..][0..first]);
    p.fmt.scan(r.data[0 .. r.len - first]);
}

/// Record and broadcast bytes produced by a process (or a zpawn note).
fn emit(p: *Proc, bytes: []const u8) void {
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
        scratch.len = 0;
        p.fmt.run(&scratch, p.prefix, bytes);
    } else {
        p.fmt_stale = true;
    }

    for (conns.items) |c| {
        const f = c.follow orelse continue;
        if (!f.all and f.proc != p) continue;
        queue(c, if (f.prefix) scratch.slice() else bytes);
    }
    if (scratch.data.len > 256 * 1024) scratch.deinit();
}

fn note(p: *Proc, comptime f: []const u8, args: anytype) void {
    var m = Buf{};
    defer m.deinit();
    if (p.last_byte != '\n' and p.last_byte != '\r') m.append("\r\n");
    m.print(RESET ++ DIM ++ "[zpawn] " ++ f ++ RESET ++ "\r\n", args);
    emit(p, m.slice());
}

fn backlog(p: *Proc, n: usize, prefix: bool, out: *Buf) void {
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

// --------------------------------------------------------- process control

fn closeMaster(p: *Proc) void {
    if (p.master >= 0) {
        _ = sys.close(p.master);
        p.master = -1;
    }
}

/// Reads what the PTY has to say (batched into one emit). Returns true if the
/// batch buffer filled up, i.e. there may be more to read right away.
fn readPty(p: *Proc) bool {
    var buf: [65536]u8 = undefined;
    var len: usize = 0;
    var eof = false;
    while (p.master >= 0 and len < buf.len) {
        const n = sys.read(p.master, buf[len..].ptr, buf.len - len);
        if (n > 0) {
            len += @intCast(n);
            continue;
        }
        if (n < 0) {
            const e = sys.errno();
            if (e == sys.EAGAIN) break;
            if (e == sys.EINTR) continue;
        }
        eof = true; // EOF or EIO: the slave side is gone
        break;
    }
    if (len > 0) emit(p, buf[0..len]);
    if (eof) closeMaster(p);
    return len == buf.len;
}

/// Words, paths and simple flags only: no quoting, expansion, pipes, assignments or builtins.
fn isPlainCommand(cmd: []const u8) bool {
    if (cmd.len == 0) return false;
    for (cmd) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, " _-./:@%+,", ch) != null)) return false;
    }
    const first = std.mem.sliceTo(std.mem.trimStart(u8, cmd, " "), ' ');
    if (first.len == 0) return false;
    const builtins = [_][]const u8{ "cd", "export", "set", "unset", "exit", "trap", "wait", "source", ".", "eval", "exec", "read", "ulimit", "umask", "alias", "true", "false", ":" };
    for (builtins) |b| {
        if (std.mem.eql(u8, first, b)) return false;
    }
    return true;
}

fn envKey(e: []const u8) []const u8 {
    return e[0 .. std.mem.indexOfScalar(u8, e, '=') orelse e.len];
}

fn isOverridden(p: *Proc, e: []const u8) bool {
    const k = envKey(e);
    for (p.over.items) |o| {
        if (std.mem.eql(u8, envKey(o), k)) return true;
    }
    return false;
}

fn startProc(p: *Proc) void {
    openLog(p);

    // Build environment before forking: TERM must allow colors.
    var envp: std.ArrayList(?[*:0]const u8) = .empty;
    defer envp.deinit(gpa);
    var has_term = false;
    for (p.env.items) |e| {
        if (isOverridden(p, e)) continue;
        if (std.mem.startsWith(u8, e, "TERM=")) {
            if (std.mem.eql(u8, e, "TERM=dumb")) continue;
            has_term = true;
        }
        envp.append(gpa, e.ptr) catch @panic("oom");
    }
    for (p.over.items) |e| {
        if (std.mem.startsWith(u8, e, "TERM=")) has_term = true;
        envp.append(gpa, e.ptr) catch @panic("oom");
    }
    if (!has_term) envp.append(gpa, "TERM=xterm-256color") catch @panic("oom");
    envp.append(gpa, null) catch @panic("oom");

    // A plain command (`node server.js`) is exec'd so it replaces the shell: signals reach it
    // directly and its last words are not lost when a middleman shell dies first.
    const sh_cmd: [:0]u8 = if (isPlainCommand(p.cmd)) common.joinZ(&.{ "exec ", p.cmd }) else common.dupeZ(p.cmd);
    defer gpa.free(sh_cmd);

    var ws = sys.Winsize{ .row = p.rows, .col = p.cols };
    var master: c_int = -1;
    const pid = sys.forkpty(&master, null, null, &ws);
    if (pid < 0) {
        p.state = .failed;
        note(p, "could not start: forkpty failed", .{});
        return;
    }
    if (pid == 0) {
        // Child. Only async-signal-safe calls from here on.
        _ = sys.signal(sys.SIGPIPE, sys.SIG_DFL);
        _ = sys.signal(sys.SIGTERM, sys.SIG_DFL);
        _ = sys.signal(sys.SIGINT, sys.SIG_DFL);
        if (p.cwd.len > 0 and sys.chdir(p.cwd.ptr) != 0) {
            const msg = "zpawn: cannot enter working directory\n";
            _ = sys.write(2, msg, msg.len);
            sys._exit(127);
        }
        const argv = [_:null]?[*:0]const u8{ "sh", "-c", sh_cmd.ptr };
        const ep: [*:null]const ?[*:0]const u8 = @ptrCast(envp.items.ptr);
        _ = sys.execve("/bin/sh", &argv, ep);
        sys._exit(127);
    }

    p.pid = pid;
    p.master = master;
    sys.setNonblock(master);
    sys.setCloexec(master);
    p.state = .running;
    p.started_ms = sys.nowMs();
    p.stopping = false;
    p.killed = false;
    p.restart_pending = false;
    note(p, "started (pid {d})", .{pid});
}

fn stopProc(p: *Proc) void {
    if (p.pid > 0) {
        if (!p.stopping) {
            p.stopping = true;
            p.killed = false;
            p.restart_pending = false;
            _ = sys.kill(-p.pid, sys.SIGTERM);
            p.kill_at_ms = sys.nowMs() + KILL_GRACE_MS;
        }
    } else if (p.state != .stopped) {
        p.state = .stopped;
        note(p, "stopped", .{});
    }
}

fn onExit(p: *Proc, status: c_int, now: i64) void {
    // Drain what is left, then close the PTY.
    while (readPty(p)) {}
    closeMaster(p);
    // Clean up stragglers left in the process group.
    _ = sys.kill(-p.pid, sys.SIGTERM);
    p.pid = 0;

    const sig = status & 0x7f;
    if (sig == 0) {
        p.exit_code = (status >> 8) & 0xff;
        p.exit_signal = 0;
    } else {
        p.exit_code = 128 + sig;
        p.exit_signal = sig;
    }

    const ran = now - p.started_ms;

    if (p.stopping) {
        p.stopping = false;
        p.state = .stopped;
        note(p, "stopped", .{});
        if (p.restart_pending) {
            p.restart_pending = false;
            p.fails = 0;
            startProc(p);
        }
        return;
    }

    if (p.exit_signal != 0) {
        note(p, "killed by signal {d}", .{p.exit_signal});
    } else {
        note(p, "exited with code {d}", .{p.exit_code});
    }

    if (!p.autorestart) {
        p.state = .exited;
        return;
    }

    if (ran < QUICK_EXIT_MS) p.fails += 1 else p.fails = 0;
    if (p.fails >= MAX_QUICK_FAILS) {
        p.state = .failed;
        note(p, "crashing too fast, giving up (try `zpawn restart {s}`)", .{p.name});
        return;
    }
    const shift: u5 = @intCast(@min(p.fails, 5));
    const delay: i64 = @min(@as(i64, 30000), @as(i64, 1000) << shift);
    p.state = .backoff;
    p.next_start_ms = now + delay;
    p.restarts += 1;
    note(p, "restarting in {d}s", .{@divTrunc(delay, 1000)});
}

/// `reap` is true when SIGCHLD fired: only then do we ask the kernel about exits.
fn tick(now: i64, reap: bool) void {
    for (procs.items) |p| {
        if (p.pid > 0) {
            if (reap) {
                var st: c_int = 0;
                if (sys.waitpid(p.pid, &st, sys.WNOHANG) == p.pid) {
                    onExit(p, st, now);
                    continue;
                }
            }
            if (p.stopping and !p.killed and now >= p.kill_at_ms) {
                _ = sys.kill(-p.pid, sys.SIGKILL);
                p.killed = true;
            }
        } else if (p.state == .backoff and now >= p.next_start_ms) {
            startProc(p);
        }
    }
}

/// How long poll() may sleep: until the next timer (restart delay, kill grace,
/// shutdown deadline), or forever when nothing is scheduled.
fn pollTimeout(now: i64) c_int {
    var best: i64 = -1;
    for (procs.items) |p| {
        var due: i64 = -1;
        if (p.pid > 0 and p.stopping and !p.killed) due = p.kill_at_ms else if (p.pid == 0 and p.state == .backoff) due = p.next_start_ms;
        if (due < 0) continue;
        const d = @max(due - now, 0);
        if (best < 0 or d < best) best = d;
    }
    if (shutting_down) {
        const d = @max(shutdown_deadline - now, 0);
        if (best < 0 or d < best) best = d;
    }
    if (best < 0) return -1;
    return @intCast(@min(best + 1, 3_600_000));
}

// ---------------------------------------------------------------- commands

fn fail(out: *Buf, ok: *bool, st: Style, comptime f: []const u8, args: anytype) void {
    ok.* = false;
    out.print("{s}error:{s} " ++ f ++ "\n", .{ st.c(RED), st.c(RESET) } ++ args);
}

fn tag(out: *Buf, st: Style, p: *Proc) void {
    if (st.on) {
        out.print("\x1b[1;{d}m{s}" ++ RESET, .{ p.color, p.name });
    } else {
        out.append(p.name);
    }
}

fn report(out: *Buf, st: Style, p: *Proc, comptime f: []const u8, args: anytype) void {
    tag(out, st, p);
    out.print(" " ++ f ++ "\n", args);
}

fn collect(out: *Buf, ok: *bool, st: Style, target: []const u8, list: *std.ArrayList(*Proc)) bool {
    if (std.mem.eql(u8, target, "all")) {
        if (procs.items.len == 0) {
            fail(out, ok, st, "no processes defined yet (try `zpawn add NAME CMD`)", .{});
            return false;
        }
        for (procs.items) |p| list.append(gpa, p) catch @panic("oom");
        return true;
    }
    if (findProc(target)) |p| {
        list.append(gpa, p) catch @panic("oom");
        return true;
    }
    var names = Buf{};
    defer names.deinit();
    for (procs.items, 0..) |p, i| {
        if (i > 0) names.append(", ");
        names.append(p.name);
    }
    if (procs.items.len == 0) names.append("none");
    fail(out, ok, st, "no process named '{s}' (known: {s})", .{ target, names.slice() });
    return false;
}

fn freeStr(s: [:0]u8) void {
    gpa.free(s);
}

fn setList(list: *std.ArrayList([:0]u8), strs: []const []const u8) void {
    for (list.items) |e| freeStr(e);
    list.clearRetainingCapacity();
    for (strs) |s| list.append(gpa, common.dupeZ(s)) catch @panic("oom");
}

fn sameList(list: *const std.ArrayList([:0]u8), strs: []const []const u8) bool {
    if (list.items.len != strs.len) return false;
    for (list.items, strs) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

fn newProc(name: []const u8, cmd: []const u8, cwd: []const u8, cols: u16, rows: u16, autorestart: bool, env: []const []const u8, over: []const []const u8) *Proc {
    const p = gpa.create(Proc) catch @panic("oom");
    p.* = .{
        .name = gpa.dupe(u8, name) catch @panic("oom"),
        .cmd = common.dupeZ(cmd),
        .cwd = common.dupeZ(cwd),
        .cols = cols,
        .rows = rows,
        .autorestart = autorestart,
        .color = palette[color_counter % palette.len],
    };
    color_counter += 1;
    setList(&p.env, env);
    setList(&p.over, over);
    return p;
}

fn freeProc(p: *Proc) void {
    closeMaster(p);
    if (p.log_fd >= 0) _ = sys.close(p.log_fd);
    for (p.env.items) |e| freeStr(e);
    p.env.deinit(gpa);
    for (p.over.items) |e| freeStr(e);
    p.over.deinit(gpa);
    gpa.free(p.name);
    freeStr(p.cmd);
    freeStr(p.cwd);
    p.ring.deinit();
    if (p.prefix.len > 0) gpa.free(p.prefix);
    gpa.destroy(p);
}

/// add: [verb, color, cols, rows, replace, n,
///       (name, cmd, cwd, restart, nenv, "K=V" * nenv) * n, client environment...]
fn cmdAdd(out: *Buf, ok: *bool, st: Style, a: []const []const u8) void {
    if (a.len < 6) return fail(out, ok, st, "malformed request", .{});
    const cols = parseU16(a[2], 160);
    const rows = parseU16(a[3], 48);
    const replace = a[4].len > 0 and a[4][0] == '1';
    const n = std.fmt.parseInt(usize, a[5], 10) catch 0;

    // The client's environment follows the items: walk them once to find where.
    var end: usize = 6;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        if (a.len < end + 5) return fail(out, ok, st, "malformed request", .{});
        const nenv = std.fmt.parseInt(usize, a[end + 4], 10) catch return fail(out, ok, st, "malformed request", .{});
        end += 5 + nenv;
    }
    if (a.len < end) return fail(out, ok, st, "malformed request", .{});
    const env = a[end..];

    var i: usize = 6;
    k = 0;
    while (k < n) : (k += 1) {
        const name = a[i];
        const cmd = a[i + 1];
        const cwd = a[i + 2];
        const autorestart = a[i + 3].len > 0 and a[i + 3][0] == '1';
        const nenv = std.fmt.parseInt(usize, a[i + 4], 10) catch 0;
        const over = a[i + 5 ..][0..nenv];
        i += 5 + nenv;

        if (!validName(name)) {
            fail(out, ok, st, "invalid name '{s}' (use letters, digits, - _ . ; max 32)", .{name});
            continue;
        }
        if (cmd.len == 0) {
            fail(out, ok, st, "'{s}': empty command", .{name});
            continue;
        }
        if (findProc(name)) |p| {
            if (!replace) {
                fail(out, ok, st, "'{s}' already exists (use `zpawn restart {s}`, or `zpawn rm {s}` first)", .{ name, name, name });
                continue;
            }
            const same = std.mem.eql(u8, p.cmd, cmd) and std.mem.eql(u8, p.cwd, cwd) and sameList(&p.over, over);
            setList(&p.env, env);
            p.cols = cols;
            p.rows = rows;
            p.autorestart = autorestart;
            if (same and p.pid > 0 and !p.stopping) {
                report(out, st, p, "unchanged", .{});
                continue;
            }
            freeStr(p.cmd);
            freeStr(p.cwd);
            p.cmd = common.dupeZ(cmd);
            p.cwd = common.dupeZ(cwd);
            setList(&p.over, over);
            if (p.pid > 0) {
                stopProc(p);
                p.restart_pending = true;
                report(out, st, p, "definition changed, restarting", .{});
            } else {
                p.fails = 0;
                startProc(p);
                report(out, st, p, "started (pid {d})", .{p.pid});
            }
        } else {
            const p = newProc(name, cmd, cwd, cols, rows, autorestart, env, over);
            procs.append(gpa, p) catch @panic("oom");
            recomputeMaxName();
            startProc(p);
            report(out, st, p, "started (pid {d})", .{p.pid});
        }
    }

    // `up` is declarative: whatever the file no longer lists is stopped and forgotten.
    if (replace) {
        for (procs.items) |p| {
            if (p.remove_when_dead) continue;
            var listed = false;
            var j: usize = 6;
            k = 0;
            while (k < n) : (k += 1) {
                if (std.mem.eql(u8, a[j], p.name)) listed = true;
                j += 5 + (std.fmt.parseInt(usize, a[j + 4], 10) catch 0);
            }
            if (!listed) {
                p.remove_when_dead = true;
                stopProc(p);
                report(out, st, p, "removed (not in the file anymore)", .{});
            }
        }
    }
}

fn cmdAction(out: *Buf, ok: *bool, st: Style, verb: []const u8, target: []const u8) void {
    var list: std.ArrayList(*Proc) = .empty;
    defer list.deinit(gpa);
    if (!collect(out, ok, st, target, &list)) return;

    for (list.items) |p| {
        if (std.mem.eql(u8, verb, "start")) {
            if (p.pid > 0 and !p.stopping) {
                report(out, st, p, "is already running", .{});
            } else if (p.pid > 0) {
                p.restart_pending = true;
                report(out, st, p, "will start once it has stopped", .{});
            } else {
                p.fails = 0;
                startProc(p);
                report(out, st, p, "started (pid {d})", .{p.pid});
            }
        } else if (std.mem.eql(u8, verb, "stop")) {
            if (p.pid == 0 and p.state == .stopped) {
                report(out, st, p, "is already stopped", .{});
            } else {
                stopProc(p);
                p.restart_pending = false;
                report(out, st, p, "stopping", .{});
            }
        } else if (std.mem.eql(u8, verb, "restart")) {
            if (p.pid > 0) {
                stopProc(p);
                p.restart_pending = true;
                report(out, st, p, "restarting", .{});
            } else {
                p.fails = 0;
                startProc(p);
                report(out, st, p, "started (pid {d})", .{p.pid});
            }
        } else if (std.mem.eql(u8, verb, "rm")) {
            p.remove_when_dead = true;
            stopProc(p);
            report(out, st, p, "removed", .{});
        }
    }
}

fn padTo(out: *Buf, have: usize, want: usize) void {
    if (want > have) out.appendNTimes(' ', want - have);
}

fn cmdLs(out: *Buf, st: Style) void {
    if (procs.items.len == 0) {
        out.print("{s}no processes. Try:{s} zpawn add web \"python3 -m http.server\"\n", .{ st.c(DIM), st.c(RESET) });
        return;
    }
    const now = sys.nowMs();
    out.print("{s}{s}", .{ st.c(DIM), st.c(BOLD) });
    out.append("   NAME");
    padTo(out, 4, max_name);
    out.append("  STATE         PID      UPTIME    RESTARTS  COMMAND");
    out.print("{s}\n", .{st.c(RESET)});

    for (procs.items) |p| {
        var label_buf: [32]u8 = undefined;
        var glyph: []const u8 = "○";
        var color: []const u8 = DIM;
        var label: []const u8 = "stopped";
        switch (p.state) {
            .running => {
                glyph = "●";
                color = GREEN;
                label = if (p.stopping) "stopping" else "running";
            },
            .stopped => {},
            .exited => {
                if (p.exit_code == 0) {
                    color = GREEN;
                } else {
                    glyph = "✖";
                    color = RED;
                }
                label = std.fmt.bufPrint(&label_buf, "exited ({d})", .{p.exit_code}) catch "exited";
            },
            .backoff => {
                glyph = "◌";
                color = YELLOW;
                label = "restarting";
            },
            .failed => {
                glyph = "✖";
                color = RED;
                label = "failed";
            },
        }

        out.append(" ");
        out.print("{s}{s}{s} ", .{ st.c(color), glyph, st.c(RESET) });
        tag(out, st, p);
        padTo(out, p.name.len, max_name);
        out.print("  {s}{s}{s}", .{ st.c(color), label, st.c(RESET) });
        padTo(out, label.len, 12);

        var pidb: [16]u8 = undefined;
        const pid_s = if (p.pid > 0) (std.fmt.bufPrint(&pidb, "{d}", .{p.pid}) catch "?") else "-";
        out.print("  {s}", .{pid_s});
        padTo(out, pid_s.len, 7);

        var upb: [32]u8 = undefined;
        const up_s = if (p.state == .running) fmtDuration(&upb, now - p.started_ms) else "-";
        out.print("  {s}", .{up_s});
        padTo(out, up_s.len, 8);

        var rb: [16]u8 = undefined;
        const r_s = std.fmt.bufPrint(&rb, "{d}", .{p.restarts}) catch "?";
        out.print("  {s}", .{r_s});
        padTo(out, r_s.len, 8);

        out.print("  {s}{s}{s}\n", .{ st.c(DIM), p.cmd, st.c(RESET) });
    }
}

/// logs: [verb, color, target, n, follow]
fn cmdLogs(c: *Conn, out: *Buf, ok: *bool, st: Style, a: []const []const u8) void {
    if (a.len < 5) return fail(out, ok, st, "malformed request", .{});
    const target = a[2];
    const n = std.fmt.parseInt(usize, a[3], 10) catch 100;
    const follow = a[4].len > 0 and a[4][0] == '1';
    const all = target.len == 0 or std.mem.eql(u8, target, "all");

    if (all) {
        if (procs.items.len == 0) return fail(out, ok, st, "no processes", .{});
        for (procs.items) |p| backlog(p, n, true, out);
        if (follow) c.follow = .{ .all = true, .proc = null, .prefix = true };
    } else {
        var list: std.ArrayList(*Proc) = .empty;
        defer list.deinit(gpa);
        if (!collect(out, ok, st, target, &list)) return;
        const p = list.items[0];
        backlog(p, n, false, out);
        if (follow) c.follow = .{ .all = false, .proc = p, .prefix = false };
    }
}

fn beginShutdown(c: ?*Conn) void {
    shutting_down = true;
    shutdown_deadline = sys.nowMs() + KILL_GRACE_MS + 2000;
    down_conn = c;
    for (procs.items) |p| {
        p.remove_when_dead = false;
        stopProc(p);
        p.restart_pending = false;
    }
}

fn handleRequest(c: *Conn, payload: []const u8) void {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    var start: usize = 0;
    for (payload, 0..) |b, i| {
        if (b == 0) {
            list.append(gpa, payload[start..i]) catch @panic("oom");
            start = i + 1;
        }
    }
    const a = list.items;

    var out = Buf{};
    defer out.deinit();
    var ok = true;
    const st = Style{ .on = a.len > 1 and a[1].len > 0 and a[1][0] == '1' };
    var keep_open = false;

    if (a.len < 2) {
        fail(&out, &ok, st, "malformed request", .{});
    } else if (shutting_down) {
        fail(&out, &ok, st, "daemon is shutting down", .{});
    } else if (std.mem.eql(u8, a[0], "ping")) {
        out.append("pong\n");
    } else if (std.mem.eql(u8, a[0], "add")) {
        cmdAdd(&out, &ok, st, a);
    } else if (std.mem.eql(u8, a[0], "ls")) {
        cmdLs(&out, st);
    } else if (std.mem.eql(u8, a[0], "logs")) {
        cmdLogs(c, &out, &ok, st, a);
    } else if (std.mem.eql(u8, a[0], "down")) {
        out.print("stopping {d} process(es)...\n", .{procs.items.len});
        beginShutdown(c);
        keep_open = true;
    } else if (a.len >= 3 and (std.mem.eql(u8, a[0], "start") or std.mem.eql(u8, a[0], "stop") or
        std.mem.eql(u8, a[0], "restart") or std.mem.eql(u8, a[0], "rm")))
    {
        cmdAction(&out, &ok, st, a[0], a[2]);
    } else {
        fail(&out, &ok, st, "unknown command '{s}'", .{a[0]});
    }

    queue(c, &[_]u8{if (ok) 'O' else 'E'});
    queue(c, out.slice());
    if (c.follow == null and !keep_open) c.close_after_flush = true;
}

// ------------------------------------------------------------- connections

fn tryRequest(c: *Conn) void {
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

fn readConn(c: *Conn) void {
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

fn flush(c: *Conn) void {
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

fn acceptAll(listen_fd: c_int) void {
    while (true) {
        const fd = sys.accept(listen_fd, null, null);
        if (fd < 0) return;
        sys.setNonblock(fd);
        sys.setCloexec(fd);
        const c = gpa.create(Conn) catch @panic("oom");
        c.* = .{ .fd = fd };
        conns.append(gpa, c) catch @panic("oom");
    }
}

fn sweep() void {
    var i: usize = 0;
    while (i < conns.items.len) {
        const c = conns.items[i];
        if (c.dead and c != down_conn) {
            _ = sys.close(c.fd);
            c.in.deinit();
            c.out.deinit();
            gpa.destroy(c);
            _ = conns.orderedRemove(i);
        } else i += 1;
    }
    i = 0;
    while (i < procs.items.len) {
        const p = procs.items[i];
        if (p.remove_when_dead and p.pid == 0) {
            for (conns.items) |c| {
                if (c.follow) |f| {
                    if (f.proc == p) c.dead = true;
                }
            }
            _ = procs.orderedRemove(i);
            freeProc(p);
            recomputeMaxName();
        } else i += 1;
    }
}

fn finish() noreturn {
    if (down_conn) |c| {
        queue(c, "daemon stopped\n");
        c.dead = false;
        flush(c);
    }
    _ = sys.unlink(sock_path.ptr);
    sys.exit(0);
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
    logs_dir = common.joinZ(&.{ home, "/logs" });
    _ = sys.mkdir(logs_dir.ptr, 0o700);
    sock_path = common.dupeZ("sock"); // relative: we live in the state directory

    const probe = common.connectIn(home); // also chdir()s into `home`
    if (probe >= 0) {
        _ = sys.close(probe);
        return 0; // a daemon is already serving this socket
    }
    if (sys.chdir(home.ptr) != 0) return 1;
    _ = sys.unlink(sock_path.ptr);

    const addr = sys.makeAddr(sock_path) orelse return 1;
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
        if (@atomicLoad(u8, &got_term, .acquire) == 1 and !shutting_down) beginShutdown(null);

        fds.clearRetainingCapacity();
        poll_procs.clearRetainingCapacity();
        fds.append(gpa, .{ .fd = listen_fd, .events = sys.POLLIN, .revents = 0 }) catch @panic("oom");
        fds.append(gpa, .{ .fd = chld_pipe[0], .events = sys.POLLIN, .revents = 0 }) catch @panic("oom");
        for (conns.items) |c| {
            var ev: c_short = sys.POLLIN;
            if (c.out_pos < c.out.len) ev |= sys.POLLOUT;
            fds.append(gpa, .{ .fd = c.fd, .events = ev, .revents = 0 }) catch @panic("oom");
        }
        const nconns = conns.items.len;
        for (procs.items) |p| {
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
            if (fds.items[2 + i].revents & readable != 0) readConn(conns.items[i]);
        }
        for (poll_procs.items, 0..) |p, j| {
            if (fds.items[2 + nconns + j].revents & readable != 0) _ = readPty(p);
        }

        const now = sys.nowMs();
        tick(now, reap);
        for (conns.items) |c| flush(c);
        sweep();

        if (shutting_down) {
            var alive = false;
            for (procs.items) |p| {
                if (p.pid > 0) alive = true;
            }
            if (!alive or now > shutdown_deadline) finish();
        }
    }
}
