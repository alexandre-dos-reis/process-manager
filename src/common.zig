//! Shared helpers: growable byte buffer, paths, socket connect.
const std = @import("std");
const sys = @import("sys.zig");

pub const gpa = std.heap.c_allocator;

fn oom() noreturn {
    @panic("out of memory");
}

/// Minimal growable byte buffer. Allocation failure aborts.
pub const Buf = struct {
    data: []u8 = &.{},
    len: usize = 0,

    pub fn slice(self: *const Buf) []const u8 {
        return self.data[0..self.len];
    }

    pub fn deinit(self: *Buf) void {
        if (self.data.len > 0) gpa.free(self.data);
        self.data = &.{};
        self.len = 0;
    }

    pub fn reserve(self: *Buf, extra: usize) void {
        const need = self.len + extra;
        if (need <= self.data.len) return;
        var cap: usize = if (self.data.len == 0) 512 else self.data.len;
        while (cap < need) cap *= 2;
        if (self.data.len == 0) {
            self.data = gpa.alloc(u8, cap) catch oom();
        } else {
            self.data = gpa.realloc(self.data, cap) catch oom();
        }
    }

    pub fn append(self: *Buf, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.reserve(bytes.len);
        @memcpy(self.data[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn appendByte(self: *Buf, b: u8) void {
        self.reserve(1);
        self.data[self.len] = b;
        self.len += 1;
    }

    pub fn appendNTimes(self: *Buf, b: u8, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) self.appendByte(b);
    }

    pub fn print(self: *Buf, comptime f: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(gpa, f, args) catch oom();
        defer gpa.free(s);
        self.append(s);
    }

    /// Drop the first `n` bytes.
    pub fn consume(self: *Buf, n: usize) void {
        if (n >= self.len) {
            self.len = 0;
            return;
        }
        const rest = self.len - n;
        std.mem.copyForwards(u8, self.data[0..rest], self.data[n..self.len]);
        self.len = rest;
    }
};

/// Concatenate parts into a newly allocated NUL-terminated string.
pub fn joinZ(parts: []const []const u8) [:0]u8 {
    var total: usize = 0;
    for (parts) |p| total += p.len;
    const out = gpa.allocSentinel(u8, total, 0) catch oom();
    var off: usize = 0;
    for (parts) |p| {
        @memcpy(out[off..][0..p.len], p);
        off += p.len;
    }
    return out;
}

pub fn dupeZ(s: []const u8) [:0]u8 {
    return joinZ(&.{s});
}

/// State directory: $ZPAWN_HOME if set, else the nearest `.pm` directory that
/// has a live socket in the current directory or one of its parents (like git),
/// else `./.pm`. Nothing is ever written to the user's home directory.
pub fn homeDir() [:0]u8 {
    var buf: [4096]u8 = undefined;
    const cwd_p = sys.getcwd(&buf, buf.len) orelse return dupeZ(".pm");
    const cwd = std.mem.span(cwd_p);

    if (sys.getenv("ZPAWN_HOME")) |p| {
        const v = std.mem.span(p);
        if (v.len > 0 and v[0] == '/') return dupeZ(v);
        return joinZ(&.{ cwd, "/", v });
    }

    var dir: []const u8 = cwd;
    while (true) {
        const probe = joinZ(&.{ if (dir.len == 1) "" else dir, "/.pm/sock" });
        defer gpa.free(probe);
        if (sys.access(probe.ptr, 0) == 0) return joinZ(&.{ if (dir.len == 1) "" else dir, "/.pm" });
        if (dir.len <= 1) break;
        const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse break;
        dir = if (slash == 0) "/" else dir[0..slash];
    }
    return joinZ(&.{ if (cwd.len == 1) "" else cwd, "/.pm" });
}

/// Connect to the daemon whose state directory is `home`. Returns -1 on failure.
/// This chdir()s into `home` and connects to the relative path "sock", which
/// sidesteps the ~108 byte limit on Unix socket paths for deep project trees.
pub fn connectIn(home: [:0]const u8) c_int {
    if (sys.chdir(home.ptr) != 0) return -1;
    const addr = sys.makeAddr("sock") orelse return -1;
    const fd = sys.socket(sys.AF_UNIX, sys.SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (sys.connect(fd, &addr, @sizeOf(sys.SockaddrUn)) != 0) {
        _ = sys.close(fd);
        return -1;
    }
    return fd;
}
