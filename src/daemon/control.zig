//! Process control: spawn on a PTY, stop, reap, restart timers, dependencies.
const std = @import("std");
const sys = @import("../sys.zig");
const common = @import("../common.zig");
const Buf = common.Buf;
const gpa = common.gpa;
const output = @import("output.zig");
const state = @import("state.zig");
const types = @import("types.zig");
const KILL_GRACE_MS = types.KILL_GRACE_MS;
const MAX_QUICK_FAILS = types.MAX_QUICK_FAILS;
const Proc = types.Proc;
const QUICK_EXIT_MS = types.QUICK_EXIT_MS;
const emit = output.emit;
const note = output.note;
const openLog = output.openLog;

// --------------------------------------------------------- process control

pub fn closeMaster(p: *Proc) void {
    if (p.master >= 0) {
        _ = sys.close(p.master);
        p.master = -1;
    }
}

/// Reads what the PTY has to say (batched into one emit). Returns true if the
/// batch buffer filled up, i.e. there may be more to read right away.
pub fn readPty(p: *Proc) bool {
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
pub fn isPlainCommand(cmd: []const u8) bool {
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

pub fn envKey(e: []const u8) []const u8 {
    return e[0 .. std.mem.indexOfScalar(u8, e, '=') orelse e.len];
}

pub fn isOverridden(p: *Proc, e: []const u8) bool {
    const k = envKey(e);
    for (p.over.items) |o| {
        if (std.mem.eql(u8, envKey(o), k)) return true;
    }
    return false;
}

pub fn startProc(p: *Proc) void {
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

pub fn stopProc(p: *Proc) void {
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

pub fn onExit(p: *Proc, status: c_int, now: i64) void {
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
pub fn tick(now: i64, reap: bool) void {
    for (state.procs.items) |p| {
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
pub fn pollTimeout(now: i64) c_int {
    var best: i64 = -1;
    for (state.procs.items) |p| {
        var due: i64 = -1;
        if (p.pid > 0 and p.stopping and !p.killed) due = p.kill_at_ms else if (p.pid == 0 and p.state == .backoff) due = p.next_start_ms;
        if (due < 0) continue;
        const d = @max(due - now, 0);
        if (best < 0 or d < best) best = d;
    }
    if (state.shutting_down) {
        const d = @max(state.shutdown_deadline - now, 0);
        if (best < 0 or d < best) best = d;
    }
    if (best < 0) return -1;
    return @intCast(@min(best + 1, 3_600_000));
}
