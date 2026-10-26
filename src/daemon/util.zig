//! Small helpers: lookups, names, durations, string lists, Proc allocation.
const std = @import("std");
const sys = @import("../sys.zig");
const common = @import("../common.zig");
const Buf = common.Buf;
const gpa = common.gpa;
const control = @import("control.zig");
const state = @import("state.zig");
const types = @import("types.zig");
const Proc = types.Proc;
const HealthSpec = types.HealthSpec;
const closeMaster = control.closeMaster;
const palette = types.palette;

// ----------------------------------------------------------------- helpers

pub fn findProc(name: []const u8) ?*Proc {
    for (state.procs.items) |p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

pub fn rebuildPrefix(p: *Proc) void {
    var b = Buf{};
    defer b.deinit();
    b.print("\x1b[0m\x1b[1;{d}m{s}", .{ p.color, p.name });
    if (state.max_name > p.name.len) b.appendNTimes(' ', state.max_name - p.name.len);
    b.append(" |\x1b[0m ");
    if (p.prefix.len > 0) gpa.free(p.prefix);
    p.prefix = gpa.dupe(u8, b.slice()) catch @panic("oom");
}

pub fn recomputeMaxName() void {
    var m: usize = 4;
    for (state.procs.items) |p| m = @max(m, p.name.len);
    state.max_name = m;
    for (state.procs.items) |p| rebuildPrefix(p);
}

pub fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len > 32) return false;
    for (n) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-' or ch == '.';
        if (!ok) return false;
    }
    return true;
}

pub fn fmtDuration(buf: []u8, ms: i64) []const u8 {
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

pub fn parseU16(s: []const u8, default: u16) u16 {
    return std.fmt.parseInt(u16, s, 10) catch default;
}

pub fn freeStr(s: [:0]u8) void {
    gpa.free(s);
}

pub fn setList(list: *std.ArrayList([:0]u8), strs: []const []const u8) void {
    for (list.items) |e| freeStr(e);
    list.clearRetainingCapacity();
    for (strs) |s| list.append(gpa, common.dupeZ(s)) catch @panic("oom");
}

pub fn sameList(list: *const std.ArrayList([:0]u8), strs: []const []const u8) bool {
    if (list.items.len != strs.len) return false;
    for (list.items, strs) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

pub fn setHealth(p: *Proc, hs: HealthSpec) void {
    if (p.health_cmd) |h| freeStr(h);
    p.health_cmd = if (hs.cmd.len > 0) common.dupeZ(hs.cmd) else null;
    p.health_interval_ms = hs.interval_ms;
    p.health_timeout_ms = hs.timeout_ms;
    p.health_retries = hs.retries;
}

pub fn sameHealth(p: *const Proc, hs: HealthSpec) bool {
    const cur: []const u8 = if (p.health_cmd) |h| h else "";
    return std.mem.eql(u8, cur, hs.cmd) and (hs.cmd.len == 0 or (p.health_interval_ms == hs.interval_ms and
        p.health_timeout_ms == hs.timeout_ms and p.health_retries == hs.retries));
}

pub fn newProc(name: []const u8, cmd: []const u8, cwd: []const u8, cols: u16, rows: u16, autorestart: bool, tty: bool, env: []const []const u8, over: []const []const u8, deps: []const []const u8, hs: HealthSpec) *Proc {
    const p = gpa.create(Proc) catch @panic("oom");
    p.* = .{
        .name = gpa.dupe(u8, name) catch @panic("oom"),
        .cmd = common.dupeZ(cmd),
        .cwd = common.dupeZ(cwd),
        .cols = cols,
        .rows = rows,
        .autorestart = autorestart,
        .tty = tty,
        .color = palette[state.color_counter % palette.len],
    };
    state.color_counter += 1;
    setList(&p.env, env);
    setList(&p.over, over);
    setList(&p.deps, deps);
    setHealth(p, hs);
    return p;
}

pub fn freeProc(p: *Proc) void {
    closeMaster(p);
    if (p.log_fd >= 0) _ = sys.close(p.log_fd);
    for (p.env.items) |e| freeStr(e);
    p.env.deinit(gpa);
    for (p.over.items) |e| freeStr(e);
    p.over.deinit(gpa);
    for (p.deps.items) |e| freeStr(e);
    p.deps.deinit(gpa);
    if (p.health_cmd) |h| freeStr(h);
    gpa.free(p.name);
    freeStr(p.cmd);
    freeStr(p.cwd);
    p.ring.deinit();
    if (p.prefix.len > 0) gpa.free(p.prefix);
    gpa.destroy(p);
}
