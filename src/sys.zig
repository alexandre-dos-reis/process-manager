//! Thin libc bindings (Linux first, macOS best-effort). Declared by hand so the
//! program does not depend on the fast-moving parts of Zig's std.
const builtin = @import("builtin");

pub const is_linux = builtin.os.tag == .linux;

pub const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
pub const Winsize = extern struct { row: u16 = 0, col: u16 = 0, xpixel: u16 = 0, ypixel: u16 = 0 };
pub const Timespec = extern struct { sec: c_long, nsec: c_long };
pub const nfds_t = if (is_linux) c_ulong else c_uint;

pub const POLLIN: c_short = 0x001;
pub const POLLOUT: c_short = 0x004;
pub const POLLERR: c_short = 0x008;
pub const POLLHUP: c_short = 0x010;
pub const POLLNVAL: c_short = 0x020;

pub const O_RDONLY: c_int = 0;
pub const O_WRONLY: c_int = 1;
pub const O_RDWR: c_int = 2;
pub const O_CREAT: c_int = if (is_linux) 0o100 else 0x200;
pub const O_APPEND: c_int = if (is_linux) 0o2000 else 0x8;
pub const O_TRUNC: c_int = if (is_linux) 0o1000 else 0x400;
pub const O_EXCL: c_int = if (is_linux) 0o200 else 0x800;
pub const O_NONBLOCK: c_int = if (is_linux) 0o4000 else 0x4;

pub const F_GETFL: c_int = 3;
pub const F_SETFL: c_int = 4;
pub const F_SETFD: c_int = 2;
pub const FD_CLOEXEC: c_int = 1;

pub const EINTR: c_int = 4;
pub const EAGAIN: c_int = if (is_linux) 11 else 35;

pub const SIGHUP: c_int = 1;
pub const SIGKILL: c_int = 9;
pub const SIGPIPE: c_int = 13;
pub const SIGTERM: c_int = 15;
pub const SIGCHLD: c_int = if (is_linux) 17 else 20;
pub const SIGINT: c_int = 2;
pub const SIG_DFL: usize = 0;
pub const SIG_IGN: usize = 1;

pub const WNOHANG: c_int = 1;
pub const AF_UNIX: c_int = 1;
pub const SOCK_STREAM: c_int = 1;
pub const CLOCK_MONOTONIC: c_int = if (is_linux) 1 else 6;
pub const TIOCGWINSZ: c_ulong = if (is_linux) 0x5413 else 0x40087468;
pub const TIOCSWINSZ: c_ulong = if (is_linux) 0x5414 else 0x80087467;

pub extern "c" fn socket(domain: c_int, ty: c_int, proto: c_int) c_int;
pub extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
pub extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
pub extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*c_uint) c_int;
pub extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
pub extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
pub extern "c" fn poll(fds: [*]PollFd, n: nfds_t, timeout: c_int) c_int;
pub extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
pub extern "c" fn ioctl(fd: c_int, req: c_ulong, ...) c_int;
pub extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
pub extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
pub extern "c" fn unlink(path: [*:0]const u8) c_int;
pub extern "c" fn rename(from: [*:0]const u8, to: [*:0]const u8) c_int;
pub extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
pub extern "c" fn chdir(path: [*:0]const u8) c_int;
pub extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
pub extern "c" fn realpath(path: [*:0]const u8, resolved: ?[*]u8) ?[*:0]u8;
pub extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, n: usize) isize;
pub extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
pub extern "c" fn getuid() c_uint;
pub extern "c" fn fork() c_int;
pub extern "c" fn forkpty(amaster: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const Winsize) c_int;
pub extern "c" fn setsid() c_int;
pub extern "c" fn setpgid(pid: c_int, pgid: c_int) c_int;
pub extern "c" fn dup2(a: c_int, b: c_int) c_int;
pub extern "c" fn pipe(fds: *[2]c_int) c_int;
pub extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
pub extern "c" fn _exit(code: c_int) noreturn;
pub extern "c" fn exit(code: c_int) noreturn;
pub extern "c" fn waitpid(pid: c_int, status: *c_int, opts: c_int) c_int;
pub extern "c" fn kill(pid: c_int, sig: c_int) c_int;
pub extern "c" fn signal(sig: c_int, handler: usize) usize;
pub extern "c" fn usleep(us: c_uint) c_int;
pub extern "c" fn isatty(fd: c_int) c_int;
pub extern "c" fn clock_gettime(clk: c_int, ts: *Timespec) c_int;
pub extern "c" var environ: [*:null]?[*:0]u8;
pub extern "c" fn __errno_location() *c_int;
pub extern "c" fn __error() *c_int;
pub extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;

pub fn errnoPtr() *c_int {
    return if (is_linux) __errno_location() else __error();
}

pub fn errno() c_int {
    return errnoPtr().*;
}

pub fn nowMs() i64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

pub fn setNonblock(fd: c_int) void {
    const fl = fcntl(fd, F_GETFL);
    _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

pub fn setCloexec(fd: c_int) void {
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC);
}

pub const SockaddrUn = if (is_linux) extern struct {
    family: u16 = @intCast(AF_UNIX),
    path: [108]u8 = @splat(0),
} else extern struct {
    len: u8 = 0,
    family: u8 = @intCast(AF_UNIX),
    path: [104]u8 = @splat(0),
};

pub fn makeAddr(path: []const u8) ?SockaddrUn {
    var a: SockaddrUn = .{};
    if (path.len >= a.path.len) return null;
    @memcpy(a.path[0..path.len], path);
    return a;
}
