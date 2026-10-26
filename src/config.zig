//! Reads zpawn.yaml. Runs in the client only (the daemon never parses YAML).
//!
//! processes:
//!   web:
//!     cmd: python3 -m http.server 8000   # required
//!     cwd: ./web                         # optional, relative to this file
//!     restart: false                     # optional, default true
//!     env:                               # optional, added to the client's environment
//!       PORT: "8000"
//!   api: npm run dev                     # short form: just the command
const std = @import("std");
const Yaml = @import("yaml").Yaml;
const sys = @import("sys.zig");
const common = @import("common.zig");
const Buf = common.Buf;
const Allocator = std.mem.Allocator;

pub const Item = struct {
    name: []const u8,
    cmd: []const u8,
    cwd: []const u8,
    restart: bool,
    env: []const []const u8, // "KEY=value"
};

/// `Invalid`: the file is wrong; `msg` explains why (already prefixed with the path).
pub const Error = error{ Invalid, OutOfMemory };

const allowed_keys = "cmd, cwd, restart, env";

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
    const joined = if (cwd.len > 0 and cwd[0] == '/')
        std.fmt.allocPrintSentinel(arena, "{s}", .{cwd}, 0) catch return null
    else
        std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ base_dir, cwd }, 0) catch return null;
    var buf: [4096]u8 = undefined;
    const real = sys.realpath(joined.ptr, &buf) orelse return null;
    return arena.dupe(u8, std.mem.span(real)) catch null;
}

/// Parses `source`. All returned memory belongs to `arena`.
pub fn parse(arena: Allocator, source: []const u8, path: []const u8, base_dir: []const u8, msg: *Buf) Error![]Item {
    var yaml: Yaml = .{ .source = source };
    yaml.load(arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            describeSyntaxErrors(&yaml, path, msg);
            return error.Invalid;
        },
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
            try items.append(arena, .{ .name = name, .cmd = v.scalar, .cwd = base_dir, .restart = true, .env = &.{} });
            continue;
        }

        const m = v.asMap() orelse
            return fail(msg, "{s}: processes.{s}: expected a command or a mapping with `cmd:`\n", .{ path, name });

        var kit = m.iterator();
        while (kit.next()) |kv| {
            const k = kv.key_ptr.*;
            if (!(std.mem.eql(u8, k, "cmd") or std.mem.eql(u8, k, "cwd") or
                std.mem.eql(u8, k, "restart") or std.mem.eql(u8, k, "env")))
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

        try items.append(arena, .{ .name = name, .cmd = cmd, .cwd = cwd, .restart = restart, .env = env.items });
    }
    return items.items;
}
