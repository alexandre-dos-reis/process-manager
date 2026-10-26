//! Unit tests for the zpawn.yaml loader. Run with `zig build test`.
const std = @import("std");
const config = @import("core").config;
const Buf = config.Buf;

const t = std.testing;

const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    items: []const config.Item,

    fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

fn ok(src: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    errdefer arena.deinit();
    var msg = Buf{};
    defer msg.deinit();
    const items = config.parse(arena.allocator(), src, "zpawn.yaml", "/", &msg) catch |err| {
        std.debug.print("unexpected failure: {s}\n", .{msg.slice()});
        return err;
    };
    return .{ .arena = arena, .items = items };
}

/// Expects a failure whose message contains `needle`.
fn rejects(src: []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var msg = Buf{};
    defer msg.deinit();
    const res = config.parse(arena.allocator(), src, "zpawn.yaml", "/", &msg);
    try t.expectError(error.Invalid, res);
    if (std.mem.indexOf(u8, msg.slice(), needle) == null) {
        std.debug.print("message {s} does not contain '{s}'\n", .{ msg.slice(), needle });
        return error.TestUnexpectedResult;
    }
}

test "short form: name -> command" {
    var p = try ok("processes:\n  web: python3 -m http.server\n  api: sh ./api.sh\n");
    defer p.deinit();
    try t.expectEqual(@as(usize, 2), p.items.len);
    try t.expectEqualStrings("web", p.items[0].name);
    try t.expectEqualStrings("python3 -m http.server", p.items[0].cmd);
    try t.expectEqualStrings("api", p.items[1].name);
}

test "declaration order is preserved" {
    var p = try ok("processes:\n  zeta: a\n  alpha: b\n  mid: c\n");
    defer p.deinit();
    try t.expectEqualStrings("zeta", p.items[0].name);
    try t.expectEqualStrings("alpha", p.items[1].name);
    try t.expectEqualStrings("mid", p.items[2].name);
}

test "defaults: restart on, cwd is the config directory, no env" {
    var p = try ok("processes:\n  web: sleep 1\n");
    defer p.deinit();
    try t.expect(p.items[0].restart);
    try t.expectEqualStrings("/", p.items[0].cwd);
    try t.expectEqual(@as(usize, 0), p.items[0].env.len);
}

test "full form: cmd, restart, env" {
    var p = try ok(
        \\processes:
        \\  worker:
        \\    cmd: sh ./worker.sh
        \\    restart: false
        \\    env:
        \\      WORKER_NAME: billing
        \\      EMPTY: ""
        \\      LEVEL: 3
        \\
    );
    defer p.deinit();
    const w = p.items[0];
    try t.expectEqualStrings("sh ./worker.sh", w.cmd);
    try t.expect(!w.restart);
    try t.expectEqual(@as(usize, 3), w.env.len);
    try t.expectEqualStrings("WORKER_NAME=billing", w.env[0]);
    try t.expectEqualStrings("EMPTY=", w.env[1]);
    try t.expectEqualStrings("LEVEL=3", w.env[2]);
}

test "cwd is resolved against the config directory" {
    var p = try ok("processes:\n  a:\n    cmd: ls\n    cwd: .\n");
    defer p.deinit();
    try t.expectEqualStrings("/", p.items[0].cwd);
}

test "quoted commands keep braces, quotes and colons" {
    var p = try ok(
        \\processes:
        \\  web: "python3 -m http.server ${PORT:-8000}"
        \\  loop: 'while true; do echo "x: y"; sleep 2; done'
        \\
    );
    defer p.deinit();
    try t.expectEqualStrings("python3 -m http.server ${PORT:-8000}", p.items[0].cmd);
    try t.expectEqualStrings("while true; do echo \"x: y\"; sleep 2; done", p.items[1].cmd);
}

test "comments are ignored" {
    var p = try ok("# header\nprocesses:\n  # one\n  web: sleep 1 # trailing\n");
    defer p.deinit();
    try t.expectEqual(@as(usize, 1), p.items.len);
    try t.expectEqualStrings("sleep 1", p.items[0].cmd);
}

test "empty file" {
    try rejects("", "empty");
}

test "missing top-level processes" {
    try rejects("web: sleep 1\n", "processes");
}

test "processes must be a mapping" {
    try rejects("processes: nope\n", "mapping");
}

test "no processes" {
    try rejects("processes:\n", "unexpected end of file");
}

test "full form without cmd" {
    try rejects("processes:\n  web:\n    restart: true\n", "missing `cmd:`");
}

test "unknown key names the key and the process" {
    try rejects("processes:\n  web:\n    cmd: ls\n    colour: red\n", "unknown key `colour`");
}

test "restart must be a boolean" {
    try rejects("processes:\n  web:\n    cmd: ls\n    restart: maybe\n", "restart must be true or false");
}

test "cwd that does not exist" {
    try rejects("processes:\n  web:\n    cmd: ls\n    cwd: /definitely/not/here\n", "no such directory");
}

test "env must be a mapping" {
    try rejects("processes:\n  web:\n    cmd: ls\n    env: FOO=bar\n", "env must be a mapping");
}

test "syntax errors carry a line number" {
    try rejects("processes:\n  web: 'unterminated\n", "zpawn.yaml:");
}

test "a key with no value at the very end gives a clear error, not a crash" {
    try rejects("processes:\n  web:\n    cmd: ls\n    env:\n      EMPTY:\n", "unexpected end of file");
}
