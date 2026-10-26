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

test "depends_on: block list, flow list and single name" {
    var p = try ok(
        \\processes:
        \\  migrate:
        \\    cmd: ls
        \\    restart: false
        \\  cache: sleep 1
        \\  a:
        \\    cmd: ls
        \\    depends_on:
        \\      - migrate
        \\      - cache
        \\  b:
        \\    cmd: ls
        \\    depends_on: [migrate]
        \\  c:
        \\    cmd: ls
        \\    depends_on: cache
        \\
    );
    defer p.deinit();
    try t.expectEqual(@as(usize, 0), p.items[0].deps.len);
    try t.expectEqual(@as(usize, 2), p.items[2].deps.len);
    try t.expectEqualStrings("migrate", p.items[2].deps[0]);
    try t.expectEqualStrings("cache", p.items[2].deps[1]);
    try t.expectEqual(@as(usize, 1), p.items[3].deps.len);
    try t.expectEqualStrings("migrate", p.items[3].deps[0]);
    try t.expectEqualStrings("cache", p.items[4].deps[0]);
}

test "depends_on: unknown process" {
    try rejects("processes:\n  a:\n    cmd: ls\n    depends_on: [ghost]\n", "unknown process `ghost`");
}

test "depends_on: a process cannot wait for itself" {
    try rejects("processes:\n  a:\n    cmd: ls\n    depends_on: [a]\n", "cannot depend on itself");
}

test "depends_on: cycles are refused" {
    try rejects(
        \\processes:
        \\  a:
        \\    cmd: ls
        \\    depends_on: [b]
        \\  b:
        \\    cmd: ls
        \\    depends_on: [c]
        \\  c:
        \\    cmd: ls
        \\    depends_on: [a]
        \\
    , "cycle");
}

test "depends_on: a diamond is not a cycle" {
    var p = try ok(
        \\processes:
        \\  base: sleep 1
        \\  left:
        \\    cmd: ls
        \\    depends_on: [base]
        \\  right:
        \\    cmd: ls
        \\    depends_on: [base]
        \\  top:
        \\    cmd: ls
        \\    depends_on: [left, right]
        \\
    );
    defer p.deinit();
    try t.expectEqual(@as(usize, 4), p.items.len);
}

test "depends_on: wrong type" {
    try rejects("processes:\n  a:\n    cmd: ls\n    depends_on:\n      k: v\n", "depends_on");
}

test "health: short form is just the command, with defaults" {
    var p = try ok("processes:\n  api:\n    cmd: node server.js\n    health: \"curl -fs http://localhost:3000/health\"\n");
    defer p.deinit();
    try t.expectEqualStrings("curl -fs http://localhost:3000/health", p.items[0].health);
    try t.expectEqual(@as(u32, 1), p.items[0].health_interval);
    try t.expectEqual(@as(u32, 5), p.items[0].health_timeout);
    try t.expectEqual(@as(u32, 30), p.items[0].health_retries);
}

test "health: full form with interval, timeout and retries" {
    var p = try ok(
        \\processes:
        \\  db:
        \\    cmd: sleep 1
        \\    health:
        \\      cmd: pg_isready
        \\      interval: 2
        \\      timeout: 3
        \\      retries: 10
        \\
    );
    defer p.deinit();
    try t.expectEqualStrings("pg_isready", p.items[0].health);
    try t.expectEqual(@as(u32, 2), p.items[0].health_interval);
    try t.expectEqual(@as(u32, 3), p.items[0].health_timeout);
    try t.expectEqual(@as(u32, 10), p.items[0].health_retries);
}

test "health: none by default" {
    var p = try ok("processes:\n  a: sleep 1\n");
    defer p.deinit();
    try t.expectEqualStrings("", p.items[0].health);
}

test "health: refused on a one-shot process" {
    try rejects("processes:\n  m:\n    cmd: ls\n    restart: false\n    health: ls\n", "only for long-running");
}

test "health: bad numbers" {
    try rejects("processes:\n  a:\n    cmd: ls\n    health:\n      cmd: ls\n      interval: 0\n", "health.interval");
    try rejects("processes:\n  a:\n    cmd: ls\n    health:\n      cmd: ls\n      timeout: soon\n", "health.timeout");
    try rejects("processes:\n  a:\n    cmd: ls\n    health:\n      cmd: ls\n      retries: 99999\n", "health.retries");
}

test "health: unknown key and missing cmd" {
    try rejects("processes:\n  a:\n    cmd: ls\n    health:\n      cmd: ls\n      every: 2\n", "unknown key `every`");
    try rejects("processes:\n  a:\n    cmd: ls\n    health:\n      interval: 2\n", "missing `cmd:`");
}
