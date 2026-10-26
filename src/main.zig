//! zpawn: a small, friendly process manager (client + daemon in one binary).
const std = @import("std");
const sys = @import("sys.zig");
const common = @import("common.zig");
const daemon = @import("daemon.zig");
const config = @import("config.zig");
const clap = @import("clap");
const Buf = common.Buf;
const gpa = common.gpa;

// Single source of truth: `.version` in build.zig.zon.
const VERSION = @import("build_options").version;

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
        \\Usage: zpawn <command> [options]
        \\
        \\  init                    create a basic zpawn.yaml
        \\  up [-d] [-f FILE]       start everything from FILE (default zpawn.yaml); stays attached (Ctrl-C stops it), -d detaches
        \\  down [-f FILE]          stop everything started with `up -d`
        \\  ls                      show processes (default command)
        \\  logs [SERVICE] [-f] [-n N]   output, colors intact (no SERVICE: all, prefixed)
        \\  restart [SERVICE]       restart (or start) one service, or all
        \\  kill [SERVICE]          stop one service, or all (the daemon keeps running)
        \\
        \\Run `zpawn <command> -h` for the options of a command.
        \\
        \\
    );
    _ = writeAll(1, d);
    _ = writeAll(1,
        \\State lives in ./.zpawn (nearest parent .zpawn wins; override with $ZPAWN_HOME).
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
            eprint("no daemon running. Start with `zpawn up`.", .{});
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
        req.num(it.deps.len);
        for (it.deps) |d| req.str(d);
    }
    // The client's own environment comes last (PATH, HOME...); per-process env wins over it.
    var e = sys.environ;
    while (e[0]) |entry| : (e += 1) req.str(std.mem.span(entry));
    return transact(home, &req, .autostart);
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

/// Reads and parses the config; on failure prints why and returns null.
fn loadConfig(arena: std.mem.Allocator, file: ?[]const u8) ?[]const config.Item {
    const path: []const u8 = file orelse if (fileExists("zpawn.yaml"))
        "zpawn.yaml"
    else if (fileExists("zpawn.yml"))
        "zpawn.yml"
    else {
        eprint("no zpawn.yaml in this directory (create one with `zpawn init`)", .{});
        return null;
    };

    var text = Buf{};
    defer text.deinit();
    if (!readFile(path, &text)) {
        eprint("cannot read {s}", .{path});
        return null;
    }
    const abs = absPath(path) orelse path;
    const slash = std.mem.lastIndexOfScalar(u8, abs, '/') orelse 0;
    const dir = arena.dupe(u8, if (slash == 0) "/" else abs[0..slash]) catch return null;

    var msg = Buf{};
    defer msg.deinit();
    return config.parse(arena, text.slice(), path, dir, &msg) catch |err| switch (err) {
        error.Invalid => {
            _ = writeAll(2, msg.slice());
            return null;
        },
        error.OutOfMemory => {
            eprint("out of memory", .{});
            return null;
        },
    };
}

// ------------------------------------------------------------ up (attached)

var stop_pipe: [2]c_int = .{ -1, -1 };

fn onStop(_: c_int) callconv(.c) void {
    const ep = sys.errnoPtr();
    const saved = ep.*;
    _ = sys.write(stop_pipe[1], "x", 1);
    ep.* = saved;
}

/// Streams every service's output until Ctrl-C (or until the daemon goes away),
/// then shuts the daemon down.
fn attach(home: [:0]const u8, color: bool) u8 {
    if (sys.pipe(&stop_pipe) != 0) return 1;
    for (stop_pipe) |fd| {
        sys.setNonblock(fd);
        sys.setCloexec(fd);
    }
    _ = sys.signal(sys.SIGINT, @intFromPtr(&onStop));
    _ = sys.signal(sys.SIGTERM, @intFromPtr(&onStop));

    const fd = common.connectIn(home);
    if (fd < 0) {
        eprint("cannot reach the daemon", .{});
        return 1;
    }
    var req = newReq("logs", color);
    defer req.b.deinit();
    req.str("");
    req.str("0");
    req.str("1");
    if (!req.send(fd)) return 1;

    var buf: [65536]u8 = undefined;
    var first = true;
    var interrupted = false;
    while (true) {
        var fds = [2]sys.PollFd{
            .{ .fd = fd, .events = sys.POLLIN, .revents = 0 },
            .{ .fd = stop_pipe[0], .events = sys.POLLIN, .revents = 0 },
        };
        if (sys.poll(&fds, 2, -1) < 0) {
            if (sys.errno() == sys.EINTR) continue;
            break;
        }
        if (fds[1].revents != 0) {
            interrupted = true;
            break;
        }
        if (fds[0].revents != 0) {
            const n = sys.read(fd, &buf, buf.len);
            if (n < 0 and sys.errno() == sys.EINTR) continue;
            if (n <= 0) break; // the daemon is gone
            var chunk = buf[0..@intCast(n)];
            if (first) {
                chunk = chunk[1..]; // status byte
                first = false;
            }
            if (chunk.len > 0 and !writeAll(1, chunk)) break;
        }
    }
    _ = sys.close(fd);
    if (!interrupted) return 0;

    _ = writeAll(1, "\nstopping...\n");
    _ = sys.signal(sys.SIGINT, sys.SIG_IGN); // a second Ctrl-C must not abort the shutdown
    var down = newReq("down", color);
    defer down.b.deinit();
    return transact(home, &down, .optional);
}

// --------------------------------------------------------------- commands

/// With `-f FILE`, the project is the directory that holds FILE: its state lives in
/// FILE's `.zpawn`, whatever the current directory is (unless $ZPAWN_HOME says otherwise).
fn homeForFile(file: ?[]const u8, default_home: [:0]const u8) ?[:0]const u8 {
    const f = file orelse return default_home;
    if (sys.getenv("ZPAWN_HOME") != null) return default_home;
    const abs = absPath(f) orelse {
        eprint("cannot find {s}", .{f});
        return null;
    };
    const slash = std.mem.lastIndexOfScalar(u8, abs, '/') orelse 0;
    const dir = if (slash == 0) "" else abs[0..slash];
    return common.joinZ(&.{ dir, "/.zpawn" });
}

const Parsed = struct {
    fn Of(comptime params: []const clap.Param(clap.Help)) type {
        return clap.ResultEx(clap.Help, params, clap.parsers.default);
    }
};

/// Writes clap output (help or diagnostics) through a growable buffer to `fd`.
fn emitHelp(comptime params: []const clap.Param(clap.Help), head: []const u8) void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    aw.writer.print("{s}\n\n", .{head}) catch return;
    clap.help(&aw.writer, clap.Help, params, .{ .spacing_between_parameters = 0 }) catch return;
    _ = writeAll(1, aw.written());
}

fn parseSub(
    comptime params: []const clap.Param(clap.Help),
    it: *clap.args.SliceIterator,
    comptime head: []const u8,
    code: *u8,
) ?Parsed.Of(params) {
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, params, clap.parsers.default, it, .{
        .diagnostic = &diag,
        .allocator = gpa,
    }) catch |err| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        aw.writer.writeAll("zpawn: ") catch {};
        diag.report(&aw.writer, err) catch {};
        _ = writeAll(2, aw.written());
        _ = writeAll(2, "try `zpawn " ++ comptime std.mem.sliceTo(head, ' ') ++ " -h`\n");
        code.* = 2;
        return null;
    };
    if (@hasField(@TypeOf(res.args), "help") and res.args.help != 0) {
        emitHelp(params, "Usage: zpawn " ++ head);
        res.deinit();
        code.* = 0;
        return null;
    }
    return res;
}

const init_template =
    \\# zpawn.yaml
    \\#   zpawn up        run everything attached (Ctrl-C stops it all)
    \\#   zpawn up -d     run in the background; stop with `zpawn down`
    \\#
    \\# Put a command in quotes when it contains { } " # or ': '.
    \\processes:
    \\  web: "python3 -m http.server ${PORT:-8000}"
    \\  worker:
    \\    cmd: "while true; do echo working; sleep 2; done"
    \\    # cwd: ./jobs          # relative to this file
    \\    # restart: false       # default: restart after a crash
    \\    # env:
    \\    #   LOG_LEVEL: debug
    \\
;

fn cmdInit(it: *clap.args.SliceIterator) u8 {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help   Show this help.
        \\--force      Overwrite an existing zpawn.yaml.
        \\
    );
    var code: u8 = 0;
    var res = parseSub(&params, it, "init [--force]", &code) orelse return code;
    defer res.deinit();
    if (res.args.force == 0 and (fileExists("zpawn.yaml") or fileExists("zpawn.yml"))) {
        eprint("zpawn.yaml already exists (use --force to overwrite)", .{});
        return 1;
    }
    const fd = sys.open("zpawn.yaml", sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) {
        eprint("cannot write zpawn.yaml", .{});
        return 1;
    }
    defer _ = sys.close(fd);
    if (!writeAll(fd, init_template)) return 1;
    _ = writeAll(1, "created zpawn.yaml - edit it, then run `zpawn up`\n");
    return 0;
}

fn cmdUp(home: [:0]const u8, color: bool, it: *clap.args.SliceIterator) u8 {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help         Show this help.
        \\-d, --detach       Run in the background and return.
        \\-f, --file <str>   Config file (default: zpawn.yaml).
        \\
    );
    var code: u8 = 0;
    var res = parseSub(&params, it, "up [-d] [-f FILE]", &code) orelse return code;
    defer res.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const items = loadConfig(arena_state.allocator(), res.args.file) orelse return 1;
    const proj = homeForFile(res.args.file, home) orelse return 1;
    const rc = addItems(proj, color, true, items);
    if (rc != 0 or res.args.detach != 0) return rc;
    return attach(proj, color);
}

fn cmdLogs(home: [:0]const u8, color: bool, it: *clap.args.SliceIterator) u8 {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help       Show this help.
        \\-f, --follow     Keep streaming new output.
        \\-n, --lines <usize>   Lines of history to show (default 100).
        \\<str>
        \\
    );
    var code: u8 = 0;
    var res = parseSub(&params, it, "logs [SERVICE] [-f] [-n N]", &code) orelse return code;
    defer res.deinit();
    var req = newReq("logs", color);
    defer req.b.deinit();
    req.str(res.positionals[0] orelse "");
    req.num(res.args.lines orelse 100);
    req.str(if (res.args.follow != 0) "1" else "0");
    return transact(home, &req, .need_daemon);
}

fn cmdTarget(home: [:0]const u8, color: bool, it: *clap.args.SliceIterator, comptime name: []const u8, verb: []const u8) u8 {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help   Show this help.
        \\<str>
        \\
    );
    var code: u8 = 0;
    var res = parseSub(&params, it, name ++ " [SERVICE]", &code) orelse return code;
    defer res.deinit();
    var req = newReq(verb, color);
    defer req.b.deinit();
    req.str(res.positionals[0] orelse "all");
    return transact(home, &req, .need_daemon);
}

fn cmdSimple(home: [:0]const u8, color: bool, verb: []const u8, mode: Mode) u8 {
    var req = newReq(verb, color);
    defer req.b.deinit();
    return transact(home, &req, mode);
}

/// Commands without options: only `-h`.
fn cmdPlain(home: [:0]const u8, color: bool, it: *clap.args.SliceIterator, comptime name: []const u8, verb: []const u8) u8 {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help   Show this help.
        \\
    );
    var code: u8 = 0;
    var res = parseSub(&params, it, name, &code) orelse return code;
    res.deinit();
    return cmdSimple(home, color, verb, .optional);
}

fn cmdDown(home: [:0]const u8, color: bool, it: *clap.args.SliceIterator) u8 {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help         Show this help.
        \\-f, --file <str>   Stop the project of this config file (default: the one found from here).
        \\
    );
    var code: u8 = 0;
    var res = parseSub(&params, it, "down [-f FILE]", &code) orelse return code;
    defer res.deinit();
    const proj = homeForFile(res.args.file, home) orelse return 1;
    return cmdSimple(proj, color, "down", .optional);
}

const Command = enum { init, up, down, ls, logs, restart, kill, help };

pub fn main(init: std.process.Init.Minimal) u8 {
    var args: std.ArrayList([]const u8) = .empty;
    for (init.args.vector[1..]) |a| args.append(gpa, std.mem.span(a)) catch return 1;
    const argv = args.items;

    _ = sys.signal(sys.SIGPIPE, sys.SIG_IGN);

    const color = sys.isatty(1) != 0 and sys.getenv("NO_COLOR") == null;
    const home = common.homeDir();

    // Internal: the client re-executes itself as the daemon.
    if (argv.len >= 1 and std.mem.eql(u8, argv[0], "daemon"))
        return daemon.run(if (argv.len > 1) common.dupeZ(argv[1]) else home);

    if (argv.len == 0) return cmdSimple(home, color, "ls", .optional);

    const top = comptime clap.parseParamsComptime(
        \\-h, --help     Show help.
        \\-V, --version  Show version.
        \\<command>
        \\
    );
    var it = clap.args.SliceIterator{ .args = argv };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &top, .{ .command = clap.parsers.enumeration(Command) }, &it, .{
        .diagnostic = &diag,
        .allocator = gpa,
        .terminating_positional = 0, // the rest belongs to the subcommand
    }) catch |err| {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        if (err == error.NameNotPartOfEnum) {
            aw.writer.print("zpawn: unknown command '{s}'\n", .{argv[0]}) catch {};
        } else {
            aw.writer.writeAll("zpawn: ") catch {};
            diag.report(&aw.writer, err) catch {};
        }
        _ = writeAll(2, aw.written());
        _ = writeAll(2, "try `zpawn -h`\n");
        return 2;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        usage(color);
        return 0;
    }
    if (res.args.version != 0) {
        _ = writeAll(1, "zpawn " ++ VERSION ++ "\n");
        return 0;
    }
    const command = res.positionals[0] orelse {
        usage(color);
        return 2;
    };
    return switch (command) {
        .help => blk: {
            usage(color);
            break :blk 0;
        },
        .init => cmdInit(&it),
        .up => cmdUp(home, color, &it),
        .down => cmdDown(home, color, &it),
        .ls => cmdPlain(home, color, &it, "ls", "ls"),
        .logs => cmdLogs(home, color, &it),
        .restart => cmdTarget(home, color, &it, "restart", "restart"),
        .kill => cmdTarget(home, color, &it, "kill", "stop"),
    };
}
