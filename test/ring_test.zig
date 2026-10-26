//! Unit tests for the circular history (src/daemon/ring.zig). Run with `zig build test`.
const std = @import("std");
const core = @import("core");

const Ring = core.Ring;
const RING_MAX = core.RING_MAX;
const Buf = core.common.Buf;
const t = std.testing;

fn dump(r: *const Ring, start: usize) !Buf {
    var out = Buf{};
    r.appendTo(start, &out);
    return out;
}

test "a new ring is empty and allocates nothing" {
    var r = Ring{};
    defer r.deinit();
    try t.expectEqual(@as(usize, 0), r.len);
    try t.expectEqual(@as(usize, 0), r.data.len);
    var out = try dump(&r, 0);
    defer out.deinit();
    try t.expectEqual(@as(usize, 0), out.slice().len);
}

test "small appends are kept in order" {
    var r = Ring{};
    defer r.deinit();
    r.append("hello ");
    r.append("world");
    var out = try dump(&r, 0);
    defer out.deinit();
    try t.expectEqualStrings("hello world", out.slice());
    try t.expectEqual(@as(usize, 11), r.len);
}

test "appendTo with an offset returns the tail" {
    var r = Ring{};
    defer r.deinit();
    r.append("0123456789");
    var out = try dump(&r, 6);
    defer out.deinit();
    try t.expectEqualStrings("6789", out.slice());
    var past = try dump(&r, 10);
    defer past.deinit();
    try t.expectEqual(@as(usize, 0), past.slice().len);
}

test "at() indexes from the oldest byte" {
    var r = Ring{};
    defer r.deinit();
    r.append("abc");
    try t.expectEqual(@as(u8, 'a'), r.at(0));
    try t.expectEqual(@as(u8, 'c'), r.at(2));
}

test "empty appends change nothing" {
    var r = Ring{};
    defer r.deinit();
    r.append("");
    try t.expectEqual(@as(usize, 0), r.len);
    try t.expectEqual(@as(usize, 0), r.data.len);
}

test "it starts small and doubles on demand" {
    var r = Ring{};
    defer r.deinit();
    r.append("x");
    try t.expectEqual(@as(usize, 4096), r.data.len);
    const filler: [5000]u8 = @splat('y');
    r.append(&filler);
    try t.expectEqual(@as(usize, 8192), r.data.len);
    try t.expectEqual(@as(usize, 5001), r.len);
}

test "never grows past RING_MAX and keeps the newest bytes" {
    var r = Ring{};
    defer r.deinit();
    var chunk: [1000]u8 = undefined;
    var total: usize = 0;
    var n: u8 = 0;
    while (total < RING_MAX * 3) : (total += chunk.len) {
        @memset(&chunk, 'a' + n % 26);
        n +%= 1;
        r.append(&chunk);
    }
    try t.expect(r.data.len <= RING_MAX);
    try t.expectEqual(RING_MAX, r.len);

    // The last byte appended is the last byte of the history.
    try t.expectEqual(@as(u8, 'a' + (n -% 1) % 26), r.at(r.len - 1));
}

test "one append bigger than RING_MAX keeps only its tail" {
    var r = Ring{};
    defer r.deinit();
    const big = try t.allocator.alloc(u8, RING_MAX + 5000);
    defer t.allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast(i % 251);
    r.append(big);
    try t.expectEqual(RING_MAX, r.len);
    var out = try dump(&r, 0);
    defer out.deinit();
    try t.expectEqualSlices(u8, big[big.len - RING_MAX ..], out.slice());
}

test "random appends always equal the last RING_MAX bytes of the stream" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();

    var r = Ring{};
    defer r.deinit();
    var reference: std.ArrayList(u8) = .empty;
    defer reference.deinit(t.allocator);

    var buf: [20000]u8 = undefined;
    var round: usize = 0;
    while (round < 60) : (round += 1) {
        const n = rnd.intRangeAtMost(usize, 0, buf.len);
        rnd.bytes(buf[0..n]);
        r.append(buf[0..n]);
        try reference.appendSlice(t.allocator, buf[0..n]);

        const keep = @min(reference.items.len, RING_MAX);
        var out = try dump(&r, 0);
        defer out.deinit();
        try t.expectEqualSlices(u8, reference.items[reference.items.len - keep ..], out.slice());
    }
}

test "deinit resets the ring" {
    var r = Ring{};
    r.append("data");
    r.deinit();
    try t.expectEqual(@as(usize, 0), r.len);
    try t.expectEqual(@as(usize, 0), r.data.len);
    r.append("again");
    try t.expectEqual(@as(usize, 5), r.len);
    r.deinit();
}
