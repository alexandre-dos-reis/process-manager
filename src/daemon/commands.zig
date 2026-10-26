//! Client requests: add (up), start/stop/restart, ls, logs, shutdown.
const std = @import("std");
const sys = @import("../sys.zig");
const common = @import("../common.zig");
const Buf = common.Buf;
const gpa = common.gpa;
const control = @import("control.zig");
const output = @import("output.zig");
const state = @import("state.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const BOLD = types.BOLD;
const Conn = types.Conn;
const DIM = types.DIM;
const GREEN = types.GREEN;
const KILL_GRACE_MS = types.KILL_GRACE_MS;
const Proc = types.Proc;
const RED = types.RED;
const RESET = types.RESET;
const Style = types.Style;
const YELLOW = types.YELLOW;
const backlog = output.backlog;
const findProc = util.findProc;
const fmtDuration = util.fmtDuration;
const freeStr = util.freeStr;
const newProc = util.newProc;
const parseU16 = util.parseU16;
const queue = output.queue;
const recomputeMaxName = util.recomputeMaxName;
const sameList = util.sameList;
const setList = util.setList;
const startProc = control.startProc;
const setHealth = util.setHealth;
const sameHealth = util.sameHealth;
const launch = control.launch;
const checkDeps = control.checkDeps;
const resolveWaiting = control.resolveWaiting;
const stopProc = control.stopProc;
const validName = util.validName;

// ---------------------------------------------------------------- commands

pub fn fail(out: *Buf, ok: *bool, st: Style, comptime f: []const u8, args: anytype) void {
    ok.* = false;
    out.print("{s}error:{s} " ++ f ++ "\n", .{ st.c(RED), st.c(RESET) } ++ args);
}

pub fn tag(out: *Buf, st: Style, p: *Proc) void {
    if (st.on) {
        out.print("\x1b[1;{d}m{s}" ++ RESET, .{ p.color, p.name });
    } else {
        out.append(p.name);
    }
}

pub fn report(out: *Buf, st: Style, p: *Proc, comptime f: []const u8, args: anytype) void {
    tag(out, st, p);
    out.print(" " ++ f ++ "\n", args);
}

pub fn collect(out: *Buf, ok: *bool, st: Style, target: []const u8, list: *std.ArrayList(*Proc)) bool {
    if (std.mem.eql(u8, target, "all")) {
        if (state.procs.items.len == 0) {
            fail(out, ok, st, "no processes defined yet (try `zpawn add NAME CMD`)", .{});
            return false;
        }
        for (state.procs.items) |p| list.append(gpa, p) catch @panic("oom");
        return true;
    }
    if (findProc(target)) |p| {
        list.append(gpa, p) catch @panic("oom");
        return true;
    }
    var names = Buf{};
    defer names.deinit();
    for (state.procs.items, 0..) |p, i| {
        if (i > 0) names.append(", ");
        names.append(p.name);
    }
    if (state.procs.items.len == 0) names.append("none");
    fail(out, ok, st, "no process named '{s}' (known: {s})", .{ target, names.slice() });
    return false;
}

/// Index just after the item that starts at `i` in an `add` request, or null if truncated.
/// Item: name, cmd, cwd, restart, nenv, "K=V" * nenv, ndeps, dep * ndeps,
///       health cmd ("" = none), interval s, timeout s, retries.
fn itemEnd(a: []const []const u8, i: usize) ?usize {
    if (a.len < i + 6) return null;
    const nenv = std.fmt.parseInt(usize, a[i + 4], 10) catch return null;
    const dpos = i + 5 + nenv;
    if (a.len <= dpos) return null;
    const ndeps = std.fmt.parseInt(usize, a[dpos], 10) catch return null;
    const end = dpos + 1 + ndeps + 4; // + health: cmd, interval, timeout, retries
    return if (a.len < end) null else end;
}

fn reportLaunch(out: *Buf, st: Style, p: *Proc) void {
    if (p.pid > 0) return report(out, st, p, "started (pid {d})", .{p.pid});
    switch (p.state) {
        .waiting => switch (checkDeps(p)) {
            .waiting => |n| report(out, st, p, "waiting for {s}", .{n}),
            else => report(out, st, p, "waiting", .{}),
        },
        .failed => report(out, st, p, "not started (see `zpawn logs {s}`)", .{p.name}),
        else => report(out, st, p, "not started", .{}),
    }
}

/// add: [verb, color, cols, rows, replace, n,
///       (name, cmd, cwd, restart, nenv, "K=V" * nenv, ndeps, dep * ndeps,
///        health cmd, interval, timeout, retries) * n,
///       client environment...]
pub fn cmdAdd(out: *Buf, ok: *bool, st: Style, a: []const []const u8) void {
    if (a.len < 6) return fail(out, ok, st, "malformed request", .{});
    const cols = parseU16(a[2], 160);
    const rows = parseU16(a[3], 48);
    const replace = a[4].len > 0 and a[4][0] == '1';
    const n = std.fmt.parseInt(usize, a[5], 10) catch 0;

    // The client's environment follows the items: walk them once to find where.
    var end: usize = 6;
    var k: usize = 0;
    while (k < n) : (k += 1) end = itemEnd(a, end) orelse return fail(out, ok, st, "malformed request", .{});
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
        const ndeps = std.fmt.parseInt(usize, a[i + 5 + nenv], 10) catch 0;
        const deps = a[i + 6 + nenv ..][0..ndeps];
        const hp = i + 6 + nenv + ndeps;
        const hs = types.HealthSpec{
            .cmd = a[hp],
            .interval_ms = @as(i64, std.fmt.parseInt(u32, a[hp + 1], 10) catch 1) * 1000,
            .timeout_ms = @as(i64, std.fmt.parseInt(u32, a[hp + 2], 10) catch 5) * 1000,
            .retries = std.fmt.parseInt(u32, a[hp + 3], 10) catch 30,
        };
        i = itemEnd(a, i).?;

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
            const same = std.mem.eql(u8, p.cmd, cmd) and std.mem.eql(u8, p.cwd, cwd) and sameList(&p.over, over) and sameList(&p.deps, deps) and sameHealth(p, hs);
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
            setList(&p.deps, deps);
            setHealth(p, hs);
            if (p.pid > 0) {
                stopProc(p);
                p.restart_pending = true;
                report(out, st, p, "definition changed, restarting", .{});
            } else {
                launch(p);
                reportLaunch(out, st, p);
            }
        } else {
            const p = newProc(name, cmd, cwd, cols, rows, autorestart, env, over, deps, hs);
            state.procs.append(gpa, p) catch @panic("oom");
            recomputeMaxName();
            launch(p);
            reportLaunch(out, st, p);
        }
    }

    // `up` is declarative: whatever the file no longer lists is stopped and forgotten.
    if (replace) {
        for (state.procs.items) |p| {
            if (p.remove_when_dead) continue;
            var listed = false;
            var j: usize = 6;
            k = 0;
            while (k < n) : (k += 1) {
                if (std.mem.eql(u8, a[j], p.name)) listed = true;
                j = itemEnd(a, j).?;
            }
            if (!listed) {
                p.remove_when_dead = true;
                stopProc(p);
                report(out, st, p, "removed (not in the file anymore)", .{});
            }
        }
    }
    resolveWaiting();
}

pub fn cmdAction(out: *Buf, ok: *bool, st: Style, verb: []const u8, target: []const u8) void {
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
                launch(p);
                reportLaunch(out, st, p);
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
                launch(p);
                reportLaunch(out, st, p);
            }
        } else if (std.mem.eql(u8, verb, "rm")) {
            p.remove_when_dead = true;
            stopProc(p);
            report(out, st, p, "removed", .{});
        }
    }
    resolveWaiting();
}

pub fn padTo(out: *Buf, have: usize, want: usize) void {
    if (want > have) out.appendNTimes(' ', want - have);
}

pub fn cmdLs(out: *Buf, st: Style) void {
    if (state.procs.items.len == 0) {
        out.print("{s}no processes. Try:{s} zpawn add web \"python3 -m http.server\"\n", .{ st.c(DIM), st.c(RESET) });
        return;
    }
    const now = sys.nowMs();
    out.print("{s}{s}", .{ st.c(DIM), st.c(BOLD) });
    out.append("   NAME");
    padTo(out, 4, state.max_name);
    out.append("  STATE         PID      UPTIME    RESTARTS  COMMAND");
    out.print("{s}\n", .{st.c(RESET)});

    for (state.procs.items) |p| {
        var label_buf: [32]u8 = undefined;
        var glyph: []const u8 = "○";
        var color: []const u8 = DIM;
        var label: []const u8 = "stopped";
        switch (p.state) {
            .running => {
                glyph = "●";
                color = GREEN;
                label = if (p.stopping) "stopping" else "running";
                if (!p.stopping and p.health_cmd != null) {
                    if (p.health_failed) {
                        color = RED;
                        label = "unhealthy";
                    } else if (p.healthy) {
                        label = "healthy";
                    } else {
                        color = YELLOW;
                        label = "starting";
                    }
                }
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
            .waiting => {
                glyph = "◌";
                color = YELLOW;
                label = "waiting";
            },
        }

        out.append(" ");
        out.print("{s}{s}{s} ", .{ st.c(color), glyph, st.c(RESET) });
        tag(out, st, p);
        padTo(out, p.name.len, state.max_name);
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
pub fn cmdLogs(c: *Conn, out: *Buf, ok: *bool, st: Style, a: []const []const u8) void {
    if (a.len < 5) return fail(out, ok, st, "malformed request", .{});
    const target = a[2];
    const n = std.fmt.parseInt(usize, a[3], 10) catch 100;
    const follow = a[4].len > 0 and a[4][0] == '1';
    const all = target.len == 0 or std.mem.eql(u8, target, "all");

    if (all) {
        if (state.procs.items.len == 0) return fail(out, ok, st, "no processes", .{});
        for (state.procs.items) |p| backlog(p, n, true, out);
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

pub fn beginShutdown(c: ?*Conn) void {
    state.shutting_down = true;
    state.shutdown_deadline = sys.nowMs() + KILL_GRACE_MS + 2000;
    state.down_conn = c;
    for (state.procs.items) |p| {
        p.remove_when_dead = false;
        stopProc(p);
        p.restart_pending = false;
    }
}

pub fn handleRequest(c: *Conn, payload: []const u8) void {
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
    } else if (state.shutting_down) {
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
        out.print("stopping {d} process(es)...\n", .{state.procs.items.len});
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
