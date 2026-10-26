//! zpawn: a small, friendly process manager (client + daemon in one binary).
const std = @import("std");
const sys = @import("sys.zig");
const common = @import("common.zig");
const daemon = @import("daemon.zig");
const config = @import("config.zig");
const Buf = common.Buf;
const gpa = common.gpa;

const VERSION = "0.1.0";

// ------------------------------------------------------------------ output

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = sys.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            if (sys.errno() == sys.EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn eprint(comptime f: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(gpa, "zpawn: " ++ f ++ "\n", args) catch return;
    defer gpa.free(s);
    _ = writeAll(2, s);
}

fn usage(color: bool) void {
    const b = if (color) "\x1b[1m" else "";
    const d = if (color) "\x1b[2m" else "";
    const r = if (color) "\x1b[0m" else "";
    _ = writeAll(1, b);
    _ = writeAll(1, "zpawn " ++ VERSION ++ " - a small, friendly process manager");
    _ = writeAll(1, r);
    _ = writeAll(1,
        \\
        \\
        \\Usage: zpawn <command> [args]
        \\
        \\  add [--cwd DIR] [--no-restart] NAME CMD...   define and start a process
        \\  up [FILE]                                    start everything from zpawn.yaml
        \\  ls                                           show processes (default command)
        \\  logs [NAME] [-f] [-n N]                      show output, colors intact; no NAME = all
        \\  start | stop | restart NAME|all
        \\  rm NAME|all                                  stop and forget
        \\  down                                         stop everything and quit the daemon
        \\
        \\
    );
    _ = writeAll(1, d);
    _ = writeAll(1,
        \\One argument after NAME is run by a shell as-is ("a | b" works);
        \\several arguments are quoted individually.
        \\State lives in ./.pm (nearest parent .pm wins; override with $ZPAWN_HOME).
    );
    _ = writeAll(1, r);
    _ = writeAll(1, "\n");
}

// ----------------------------------------------------------------- request

const Req = struct {
    b: Buf = .{},

    fn str(self: *Req, s: []const u8) void {
        self.b.append(s);
        self.b.appendByte(0);
    }

    fn num(self: *Req, n: anytype) void {
        var tmp: [32]u8 = undefined;
        self.str(std.fmt.bufPrint(&tmp, "{d}", .{n}) catch "0");
    }

    fn send(self: *Req, fd: c_int) bool {
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(self.b.len), .little);
        return writeAll(fd, &hdr) and writeAll(fd, self.b.slice());
    }
};

fn exePath(buf: []u8) ?[:0]const u8 {
    if (sys.is_linux) {
        const n = sys.readlink("/proc/self/exe", buf.ptr, buf.len - 1);
        if (n <= 0) return null;
        buf[@intCast(n)] = 0;
        return buf[0..@intCast(n) :0];
    } else {
        var size: u32 = @intCast(buf.len - 1);
        if (sys._NSGetExecutablePath(buf.ptr, &size) != 0) return null;
        const len = std.mem.indexOfScalar(u8, buf, 0) orelse return null;
        return buf[0..len :0];
    }
}

fn startDaemon(home: [:0]const u8) c_int {
    var exe_buf: [4096]u8 = undefined;
    const exe = exePath(&exe_buf) orelse return -1;
    _ = sys.mkdir(home.ptr, 0o700);
    const log_path = common.joinZ(&.{ home, "/daemon.log" });

    const pid = sys.fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        _ = sys.setsid();
        const lf = sys.open(log_path.ptr, sys.O_WRONLY | sys.O_CREAT | sys.O_APPEND, @as(c_uint, 0o600));
        const nul = sys.open("/dev/null", sys.O_RDONLY);
        if (nul >= 0) _ = sys.dup2(nul, 0);
        if (lf >= 0) {
            _ = sys.dup2(lf, 1);
            _ = sys.dup2(lf, 2);
        }
        const argv = [_:null]?[*:0]const u8{ exe.ptr, "daemon", home.ptr };
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(sys.environ);
        _ = sys.execve(exe.ptr, &argv, envp);
        sys._exit(127);
    }

    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        const fd = common.connectIn(home);
        if (fd >= 0) return fd;
        _ = sys.usleep(100_000);
    }
    return -1;
}

const Mode = enum { autostart, need_daemon, optional };

/// Sends the request and prints the answer. Returns the process exit code.
fn transact(home: [:0]const u8, req: *Req, mode: Mode) u8 {
    var fd = common.connectIn(home);
    if (fd < 0) switch (mode) {
        .autostart => {
            fd = startDaemon(home);
            if (fd < 0) {
                eprint("could not start the daemon (see {s}/daemon.log)", .{home});
                return 1;
            }
        },
        .need_daemon => {
            eprint("no daemon running. Start something with `zpawn add` or `zpawn up`.", .{});
            return 1;
        },
        .optional => {
            _ = writeAll(1, "no processes (daemon not running)\n");
            return 0;
        },
    };
    defer _ = sys.close(fd);

    if (!req.send(fd)) {
        eprint("connection to the daemon failed", .{});
        return 1;
    }

    var buf: [65536]u8 = undefined;
    var status: u8 = 0;
    while (true) {
        const n = sys.read(fd, &buf, buf.len);
        if (n < 0) {
            if (sys.errno() == sys.EINTR) continue;
            break;
        }
        if (n == 0) break;
        var chunk = buf[0..@intCast(n)];
        if (status == 0) {
            status = chunk[0];
            chunk = chunk[1..];
        }
        if (chunk.len > 0 and !writeAll(if (status == 'E') 2 else 1, chunk)) return 0; // e.g. `| head`
    }
    if (status == 0) {
        eprint("the daemon closed the connection without answering", .{});
        return 1;
    }
    return if (status == 'E') 1 else 0;
}

fn newReq(verb: []const u8, color: bool) Req {
    var r = Req{};
    r.str(verb);
    r.str(if (color) "1" else "0");
    return r;
}

// ------------------------------------------------------------- add / up

fn termSize() struct { cols: u16, rows: u16 } {
    var ws: sys.Winsize = .{};
    for ([_]c_int{ 1, 0, 2 }) |fd| {
        if (sys.ioctl(fd, sys.TIOCGWINSZ, &ws) == 0 and ws.col > 0) {
            return .{ .cols = ws.col, .rows = if (ws.row > 0) ws.row else 48 };
        }
    }
    return .{ .cols = 160, .rows = 48 };
}

fn currentDir() []const u8 {
    const static = struct {
        var buf: [4096]u8 = undefined;
    };
    if (sys.getcwd(&static.buf, static.buf.len)) |p| return std.mem.span(p);
    return "";
}

fn absPath(path: []const u8) ?[]const u8 {
    const z = common.dupeZ(path);
    defer gpa.free(z);
    const static = struct {
        var buf: [4096]u8 = undefined;
    };
    const r = sys.realpath(z.ptr, &static.buf) orelse return null;
    return std.mem.span(r);
}

fn addItems(home: [:0]const u8, color: bool, replace: bool, items: []const config.Item) u8 {
    const ts = termSize();
    var req = newReq("add", color);
    defer req.b.deinit();
    req.num(ts.cols);
    req.num(ts.rows);
    req.str(if (replace) "1" else "0");
    req.num(items.len);
    for (items) |it| {
        req.str(it.name);
        req.str(it.cmd);
        req.str(it.cwd);
        req.str(if (it.restart) "1" else "0");
        req.num(it.env.len);
        for (it.env) |e| req.str(e);
    }
    // The client's own environment comes last (PATH, HOME...); per-process env wins over it.
    var e = sys.environ;
    while (e[0]) |entry| : (e += 1) req.str(std.mem.span(entry));
    return transact(home, &req, .autostart);
}

fn isSafeChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "_-./:=@%+,", ch) != null;
}

fn shellQuote(out: *Buf, s: []const u8) void {
    var plain = s.len > 0;
    for (s) |ch| {
        if (!isSafeChar(ch)) plain = false;
    }
    if (plain) return out.append(s);
    out.appendByte('\'');
    for (s) |ch| {
        if (ch == '\'') out.append("'\\''") else out.appendByte(ch);
    }
    out.appendByte('\'');
}

fn cmdAdd(home: [:0]const u8, color: bool, args: []const []const u8) u8 {
    var cwd: []const u8 = currentDir();
    var restart = true;
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else if (std.mem.eql(u8, a, "--no-restart")) {
            restart = false;
        } else if (std.mem.eql(u8, a, "--cwd")) {
            i += 1;
            if (i >= args.len) {
                eprint("--cwd needs a directory", .{});
                return 2;
            }
            cwd = absPath(args[i]) orelse {
                eprint("no such directory: {s}", .{args[i]});
                return 1;
            };
        } else {
            eprint("unknown option {s}", .{a});
            return 2;
        }
    }
    if (args.len < i + 2) {
        eprint("usage: zpawn add [--cwd DIR] [--no-restart] NAME CMD...", .{});
        return 2;
    }
    const name = args[i];
    var cmd = Buf{};
    defer cmd.deinit();
    if (args.len == i + 2) {
        cmd.append(args[i + 1]); // single argument: shell snippet, used as-is
    } else {
        for (args[i + 1 ..], 0..) |a, k| {
            if (k > 0) cmd.appendByte(' ');
            shellQuote(&cmd, a);
        }
    }
    return addItems(home, color, false, &.{.{ .name = name, .cmd = cmd.slice(), .cwd = cwd, .restart = restart, .env = &.{} }});
}

fn readFile(path: []const u8, out: *Buf) bool {
    const z = common.dupeZ(path);
    defer gpa.free(z);
    const fd = sys.open(z.ptr, sys.O_RDONLY);
    if (fd < 0) return false;
    defer _ = sys.close(fd);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf, buf.len);
        if (n < 0) {
            if (sys.errno() == sys.EINTR) continue;
            return false;
        }
        if (n == 0) return true;
        out.append(buf[0..@intCast(n)]);
    }
}

fn fileExists(path: []const u8) bool {
    const z = common.dupeZ(path);
    defer gpa.free(z);
    return sys.access(z.ptr, 0) == 0;
}

fn cmdUp(home: [:0]const u8, color: bool, args: []const []const u8) u8 {
    const path: []const u8 = if (args.len > 0) args[0] else if (fileExists("zpawn.yaml"))
        "zpawn.yaml"
    else if (fileExists("zpawn.yml"))
        "zpawn.yml"
    else {
        eprint("no zpawn.yaml in this directory (see examples/ for the format)", .{});
        return 1;
    };

    var text = Buf{};
    defer text.deinit();
    if (!readFile(path, &text)) {
        eprint("cannot read {s}", .{path});
        return 1;
    }
    const abs = absPath(path) orelse path;
    const slash = std.mem.lastIndexOfScalar(u8, abs, '/') orelse 0;
    const dir = if (slash == 0) "/" else abs[0..slash];

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var msg = Buf{};
    defer msg.deinit();
    const items = config.parse(arena_state.allocator(), text.slice(), path, dir, &msg) catch |err| switch (err) {
        error.Invalid => {
            _ = writeAll(2, msg.slice());
            return 1;
        },
        error.OutOfMemory => {
            eprint("out of memory", .{});
            return 1;
        },
    };
    return addItems(home, color, true, items);
}

// -------------------------------------------------------------- the rest

fn cmdLogs(home: [:0]const u8, color: bool, args: []const []const u8) u8 {
    var target: []const u8 = "";
    var n: []const u8 = "100";
    var follow = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--follow")) {
            follow = true;
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--lines")) {
            i += 1;
            if (i >= args.len) {
                eprint("-n needs a number", .{});
                return 2;
            }
            n = args[i];
        } else if (a.len > 0 and a[0] == '-') {
            eprint("unknown option {s}", .{a});
            return 2;
        } else target = a;
    }
    if (std.fmt.parseInt(usize, n, 10) catch null == null) {
        eprint("-n expects a number, got '{s}'", .{n});
        return 2;
    }
    var req = newReq("logs", color);
    defer req.b.deinit();
    req.str(target);
    req.str(n);
    req.str(if (follow) "1" else "0");
    return transact(home, &req, .need_daemon);
}

fn cmdTarget(home: [:0]const u8, color: bool, verb: []const u8, args: []const []const u8) u8 {
    if (args.len != 1) {
        eprint("usage: zpawn {s} NAME|all", .{verb});
        return 2;
    }
    var req = newReq(verb, color);
    defer req.b.deinit();
    req.str(args[0]);
    return transact(home, &req, .need_daemon);
}

fn cmdSimple(home: [:0]const u8, color: bool, verb: []const u8, mode: Mode) u8 {
    var req = newReq(verb, color);
    defer req.b.deinit();
    return transact(home, &req, mode);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var args: std.ArrayList([]const u8) = .empty;
    for (init.args.vector[1..]) |a| args.append(gpa, std.mem.span(a)) catch return 1;
    const argv = args.items;

    _ = sys.signal(sys.SIGPIPE, sys.SIG_IGN);

    const color = sys.isatty(1) != 0 and sys.getenv("NO_COLOR") == null;
    const home = common.homeDir();

    if (argv.len == 0) return cmdSimple(home, color, "ls", .optional);
    const verb = argv[0];
    const rest = argv[1..];

    if (eq(verb, "daemon")) return daemon.run(if (rest.len > 0) common.dupeZ(rest[0]) else home);
    if (eq(verb, "-h") or eq(verb, "--help") or eq(verb, "help")) {
        usage(color);
        return 0;
    }
    if (eq(verb, "-v") or eq(verb, "--version") or eq(verb, "version")) {
        _ = writeAll(1, "zpawn " ++ VERSION ++ "\n");
        return 0;
    }
    if (eq(verb, "ls") or eq(verb, "status") or eq(verb, "ps")) return cmdSimple(home, color, "ls", .optional);
    if (eq(verb, "add")) return cmdAdd(home, color, rest);
    if (eq(verb, "up")) return cmdUp(home, color, rest);
    if (eq(verb, "logs") or eq(verb, "log")) return cmdLogs(home, color, rest);
    if (eq(verb, "start") or eq(verb, "stop") or eq(verb, "restart")) return cmdTarget(home, color, verb, rest);
    if (eq(verb, "rm") or eq(verb, "remove")) return cmdTarget(home, color, "rm", rest);
    if (eq(verb, "down")) return cmdSimple(home, color, "down", .optional);

    eprint("unknown command '{s}'", .{verb});
    usage(false);
    return 2;
}
