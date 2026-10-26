//! Fixed-size circular history of a process's raw output.
const std = @import("std");
const sys = @import("../sys.zig");
const common = @import("../common.zig");
const Buf = common.Buf;
const gpa = common.gpa;

pub const RING_MAX: usize = 512 * 1024; // history kept per process

/// Fixed-size circular history. Starts tiny and grows (up to RING_MAX) only when
/// a process actually produces output.
pub const Ring = struct {
    data: []u8 = &.{},
    head: usize = 0, // index of the oldest byte
    len: usize = 0,

    pub fn deinit(self: *Ring) void {
        if (self.data.len > 0) gpa.free(self.data);
        self.* = .{};
    }

    pub fn grow(self: *Ring, need: usize) void {
        if (need <= self.data.len or self.data.len >= RING_MAX) return;
        var cap: usize = if (self.data.len == 0) 4096 else self.data.len;
        while (cap < need and cap < RING_MAX) cap *= 2;
        cap = @min(cap, RING_MAX);
        const nd = gpa.alloc(u8, cap) catch @panic("oom");
        const first = @min(self.len, self.data.len - self.head);
        @memcpy(nd[0..first], self.data[self.head..][0..first]);
        @memcpy(nd[first..self.len], self.data[0 .. self.len - first]);
        if (self.data.len > 0) gpa.free(self.data);
        self.data = nd;
        self.head = 0;
    }

    pub fn append(self: *Ring, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const b = if (bytes.len > RING_MAX) bytes[bytes.len - RING_MAX ..] else bytes;
        self.grow(self.len + b.len);
        const cap = self.data.len;
        if (self.len + b.len > cap) {
            const drop = self.len + b.len - cap;
            self.head = (self.head + drop) % cap;
            self.len -= drop;
        }
        const tail = (self.head + self.len) % cap;
        const first = @min(b.len, cap - tail);
        @memcpy(self.data[tail..][0..first], b[0..first]);
        @memcpy(self.data[0 .. b.len - first], b[first..]);
        self.len += b.len;
    }

    pub fn at(self: *const Ring, i: usize) u8 {
        return self.data[(self.head + i) % self.data.len];
    }

    /// Append the history from logical index `start` to the end.
    pub fn appendTo(self: *const Ring, start: usize, out: *Buf) void {
        if (start >= self.len) return;
        const cap = self.data.len;
        const s = (self.head + start) % cap;
        const n = self.len - start;
        const first = @min(n, cap - s);
        out.append(self.data[s..][0..first]);
        out.append(self.data[0 .. n - first]);
    }
};
