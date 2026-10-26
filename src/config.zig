//! Reads zpawn.yaml. Runs in the client only (the daemon never parses YAML).
//!
//! processes:
//!   web:
//!     cmd: python3 -m http.server 8000   # required
//!     cwd: ./web                         # optional, relative to this file
//!     restart: false                     # optional, default true
//!     tty: false                         # optional, default true (no pseudo-terminal)
//!     env:                               # optional, added to the client's environment
//!       PORT: "8000"
//!   api: npm run dev                     # short form: just the command
const std = @import("std");
const Yaml = @import("yaml").Yaml;
const sys = @import("sys.zig");
const common = @import("common.zig");
pub const Buf = common.Buf;
const Allocator = std.mem.Allocator;

pub const Item = struct {
    name: []const u8,
    cmd: []const u8,
    cwd: []const u8,
    restart: bool,
    /// Run on a pseudo-terminal (the default). `false` hands the process a pipe
    /// instead, so tools that redraw a screen when they see a terminal print
    /// plain lines — which is what a log file can hold.
    tty: bool,
    env: []const []const u8, // "KEY=value"
    deps: []const []const u8 = &.{}, // names this process waits for
    health: []const u8 = "", // readiness command ("" = none)
    health_interval: u32 = 1, // seconds
    health_timeout: u32 = 5, // seconds
    health_retries: u32 = 30,
};

/// `Invalid`: the file is wrong; `msg` explains why (already prefixed with the path).
pub const Error = error{ Invalid, OutOfMemory };

const allowed_keys = "cmd, cwd, restart, tty, env, depends_on, health";

fn fail(msg: *Buf, comptime f: []const u8, args: anytype) Error {
    msg.print(f, args);
    return error.Invalid;
}

fn describeSyntaxErrors(yaml: *const Yaml, path: []const u8, msg: *Buf) void {
    const eb = yaml.parse_errors;
    var any = false;
    for (eb.getMessages()) |idx| {
        const em = eb.getErrorMessage(idx);
        const text = eb.nullTerminatedString(em.msg);
        if (em.src_loc != .none) {
            const loc = eb.getSourceLocation(em.src_loc);
            msg.print("{s}:{d}:{d}: {s}\n", .{ path, loc.line + 1, loc.column + 1, text });
        } else {
            msg.print("{s}: {s}\n", .{ path, text });
        }
        any = true;
    }
    if (!any) msg.print("{s}: invalid YAML\n", .{path});
}

fn scalarOf(v: Yaml.Value) ?[]const u8 {
    return switch (v) {
        .scalar => |s| s,
        .boolean => |b| if (b) "true" else "false",
        else => null,
    };
}

fn parseBool(v: Yaml.Value) ?bool {
    if (v == .boolean) return v.boolean;
    const s = scalarOf(v) orelse return null;
    if (std.mem.eql(u8, s, "true")) return true;
    if (std.mem.eql(u8, s, "false")) return false;
    return null;
}

/// Resolve `cwd` against `base_dir` and make sure it exists.
fn resolveCwd(arena: Allocator, base_dir: []const u8, cwd: []const u8) ?[]const u8 {
    const sep = if (std.mem.endsWith(u8, base_dir, "/")) "" else "/";
    const joined = if (cwd.len > 0 and cwd[0] == '/')
        std.fmt.allocPrintSentinel(arena, "{s}", .{cwd}, 0) catch return null
    else
        std.fmt.allocPrintSentinel(arena, "{s}{s}{s}", .{ base_dir, sep, cwd }, 0) catch return null;
    var buf: [4096]u8 = undefined;
    const real = sys.realpath(joined.ptr, &buf) orelse return null;
    return arena.dupe(u8, std.mem.span(real)) catch null;
}

/// Parses `source`. All returned memory belongs to `arena`.
pub fn parse(arena: Allocator, source: []const u8, path: []const u8, base_dir: []const u8, msg: *Buf) Error![]Item {
    var yaml: Yaml = .{ .source = source };
    yaml.load(arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailure => {
            describeSyntaxErrors(&yaml, path, msg);
            return error.Invalid;
        },
        // The parser gave up without recording a position (e.g. a key with no value at the very end).
        error.UnexpectedEof => return fail(msg, "{s}: unexpected end of file (a key without a value?)\n", .{path}),
        else => return fail(msg, "{s}: invalid YAML ({s})\n", .{ path, @errorName(err) }),
    };

    if (yaml.docs.items.len == 0) return fail(msg, "{s}: the file is empty\n", .{path});
    const root = yaml.docs.items[0].asMap() orelse
        return fail(msg, "{s}: expected a top-level `processes:` mapping\n", .{path});
    const procs_v = root.get("processes") orelse
        return fail(msg, "{s}: missing top-level `processes:`\n", .{path});
    const procs = procs_v.asMap() orelse
        return fail(msg, "{s}: `processes` must be a mapping of name -> definition\n", .{path});
    if (procs.count() == 0) return fail(msg, "{s}: `processes` is empty\n", .{path});

    var items: std.ArrayList(Item) = .empty;
    var it = procs.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const v = entry.value_ptr.*;

        // Short form: `name: command`
        if (v == .scalar) {
            if (v.scalar.len == 0) return fail(msg, "{s}: processes.{s}: empty command\n", .{ path, name });
            try items.append(arena, .{ .name = name, .cmd = v.scalar, .cwd = base_dir, .restart = true, .tty = true, .env = &.{} });
            continue;
        }

        const m = v.asMap() orelse
            return fail(msg, "{s}: processes.{s}: expected a command or a mapping with `cmd:`\n", .{ path, name });

        var kit = m.iterator();
        while (kit.next()) |kv| {
            const k = kv.key_ptr.*;
            if (!(std.mem.eql(u8, k, "cmd") or std.mem.eql(u8, k, "cwd") or
                std.mem.eql(u8, k, "restart") or std.mem.eql(u8, k, "tty") or
                std.mem.eql(u8, k, "env") or std.mem.eql(u8, k, "depends_on") or
                std.mem.eql(u8, k, "health")))
                return fail(msg, "{s}: processes.{s}: unknown key `{s}` (allowed: " ++ allowed_keys ++ ")\n", .{ path, name, k });
        }

        const cmd = if (m.get("cmd")) |c| (scalarOf(c) orelse
            return fail(msg, "{s}: processes.{s}.cmd must be text\n", .{ path, name })) else
            return fail(msg, "{s}: processes.{s}: missing `cmd:`\n", .{ path, name });
        if (cmd.len == 0) return fail(msg, "{s}: processes.{s}.cmd is empty\n", .{ path, name });

        var cwd: []const u8 = base_dir;
        if (m.get("cwd")) |c| {
            const raw = scalarOf(c) orelse
                return fail(msg, "{s}: processes.{s}.cwd must be text\n", .{ path, name });
            cwd = resolveCwd(arena, base_dir, raw) orelse
                return fail(msg, "{s}: processes.{s}.cwd: no such directory: {s}\n", .{ path, name, raw });
        }

        var restart = true;
        if (m.get("restart")) |r| {
            restart = parseBool(r) orelse
                return fail(msg, "{s}: processes.{s}.restart must be true or false\n", .{ path, name });
        }

        var tty = true;
        if (m.get("tty")) |v2| {
            tty = parseBool(v2) orelse
                return fail(msg, "{s}: processes.{s}.tty must be true or false\n", .{ path, name });
        }

        var env: std.ArrayList([]const u8) = .empty;
        if (m.get("env")) |e| {
            const em = e.asMap() orelse
                return fail(msg, "{s}: processes.{s}.env must be a mapping of NAME: value\n", .{ path, name });
            var eit = em.iterator();
            while (eit.next()) |ev| {
                const val = scalarOf(ev.value_ptr.*) orelse if (ev.value_ptr.* == .empty) "" else
                    return fail(msg, "{s}: processes.{s}.env.{s} must be a plain value\n", .{ path, name, ev.key_ptr.* });
                try env.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ ev.key_ptr.*, val }));
            }
        }

        var deps: std.ArrayList([]const u8) = .empty;
        if (m.get("depends_on")) |d| {
            if (scalarOf(d)) |one| {
                try deps.append(arena, one);
            } else if (d == .list) {
                for (d.list) |item| {
                    const dn = scalarOf(item) orelse
                        return fail(msg, "{s}: processes.{s}.depends_on must be a list of process names\n", .{ path, name });
                    try deps.append(arena, dn);
                }
            } else if (d != .empty) {
                return fail(msg, "{s}: processes.{s}.depends_on must be a name or a list of names\n", .{ path, name });
            }
        }

        var item = Item{ .name = name, .cmd = cmd, .cwd = cwd, .restart = restart, .tty = tty, .env = env.items, .deps = deps.items };
        if (m.get("health")) |h| try parseHealth(&item, h, path, msg);
        try items.append(arena, item);
    }
    try checkDeps(arena, items.items, path, msg);
    return items.items;
}

fn indexOf(items: []const Item, name: []const u8) ?usize {
    for (items, 0..) |it, i| {
        if (std.mem.eql(u8, it.name, name)) return i;
    }
    return null;
}

/// Every dependency must exist, and the graph must have no cycle.
fn checkDeps(arena: Allocator, items: []const Item, path: []const u8, msg: *Buf) Error!void {
    for (items) |it| {
        for (it.deps) |d| {
            if (std.mem.eql(u8, d, it.name))
                return fail(msg, "{s}: processes.{s}.depends_on: a process cannot depend on itself\n", .{ path, it.name });
            if (indexOf(items, d) == null)
                return fail(msg, "{s}: processes.{s}.depends_on: unknown process `{s}`\n", .{ path, it.name, d });
        }
    }

    // Depth-first search; 0 = unvisited, 1 = on the current path, 2 = done.
    const mark = try arena.alloc(u8, items.len);
    @memset(mark, 0);
    for (0..items.len) |start| {
        if (mark[start] == 0) try visit(items, mark, start, path, msg);
    }
}

fn visit(items: []const Item, mark: []u8, i: usize, path: []const u8, msg: *Buf) Error!void {
    mark[i] = 1;
    for (items[i].deps) |d| {
        const j = indexOf(items, d).?;
        if (mark[j] == 1)
            return fail(msg, "{s}: depends_on cycle: `{s}` and `{s}` wait for each other\n", .{ path, items[i].name, items[j].name });
        if (mark[j] == 0) try visit(items, mark, j, path, msg);
    }
    mark[i] = 2;
}

fn parseSeconds(v: Yaml.Value, path: []const u8, name: []const u8, key: []const u8, msg: *Buf) Error!u32 {
    const s = scalarOf(v) orelse
        return fail(msg, "{s}: processes.{s}.health.{s} must be a number of seconds\n", .{ path, name, key });
    const n = std.fmt.parseInt(u32, s, 10) catch 0;
    if (n == 0 or n > 3600)
        return fail(msg, "{s}: processes.{s}.health.{s} must be a whole number between 1 and 3600 (got `{s}`)\n", .{ path, name, key, s });
    return n;
}

/// `health: <command>` or `health: {cmd, interval, timeout, retries}`.
fn parseHealth(item: *Item, h: Yaml.Value, path: []const u8, msg: *Buf) Error!void {
    const name = item.name;
    if (!item.restart)
        return fail(msg, "{s}: processes.{s}.health: only for long-running processes (restart: false ones exit by design)\n", .{ path, name });
    if (scalarOf(h)) |cmd| {
        if (cmd.len == 0) return fail(msg, "{s}: processes.{s}.health: empty command\n", .{ path, name });
        item.health = cmd;
        return;
    }
    const hm = h.asMap() orelse
        return fail(msg, "{s}: processes.{s}.health must be a command or a mapping with `cmd:`\n", .{ path, name });
    var it = hm.iterator();
    while (it.next()) |kv| {
        const k = kv.key_ptr.*;
        const v = kv.value_ptr.*;
        if (std.mem.eql(u8, k, "cmd")) {
            item.health = scalarOf(v) orelse
                return fail(msg, "{s}: processes.{s}.health.cmd must be text\n", .{ path, name });
        } else if (std.mem.eql(u8, k, "interval")) {
            item.health_interval = try parseSeconds(v, path, name, k, msg);
        } else if (std.mem.eql(u8, k, "timeout")) {
            item.health_timeout = try parseSeconds(v, path, name, k, msg);
        } else if (std.mem.eql(u8, k, "retries")) {
            item.health_retries = try parseSeconds(v, path, name, k, msg);
        } else {
            return fail(msg, "{s}: processes.{s}.health: unknown key `{s}` (allowed: cmd, interval, timeout, retries)\n", .{ path, name, k });
        }
    }
    if (item.health.len == 0)
        return fail(msg, "{s}: processes.{s}.health: missing `cmd:`\n", .{ path, name });
}
