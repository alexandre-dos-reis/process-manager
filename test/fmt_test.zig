//! Unit tests for the prefix/color tracker (src/daemon/fmt.zig). Run with `zig build test`.
const std = @import("std");
const core = @import("core");

const Fmt = core.Fmt;
const Buf = core.common.Buf;
const t = std.testing;

const ESC = "\x1b";
const P = "P|";

/// Runs `input` through a fresh Fmt in one go and returns the output (caller frees).
fn run(input: []const u8) !Buf {
    var f = Fmt{};
    var out = Buf{};
    f.run(&out, P, input);
    return out;
}

fn expectRun(input: []const u8, expected: []const u8) !void {
    var out = try run(input);
    defer out.deinit();
    try t.expectEqualStrings(expected, out.slice());
}

test "a prefix starts every non-empty line" {
    try expectRun("a\nb\n", P ++ "a\n" ++ P ++ "b\n");
}

test "empty lines get no prefix" {
    try expectRun("a\n\nb", P ++ "a\n\n" ++ P ++ "b");
}

test "no input, no output" {
    try expectRun("", "");
}

test "tab counts as text at the start of a line" {
    try expectRun("\tindented\n", P ++ "\tindented\n");
}

test "carriage return starts a new line (progress bars)" {
    try expectRun("10%\r20%\r", P ++ "10%\r" ++ P ++ "20%\r");
}

test "CRLF does not double the prefix" {
    try expectRun("a\r\nb\r\n", P ++ "a\r\n" ++ P ++ "b\r\n");
}

test "an escape sequence at the start of a line is copied before the prefix" {
    // The prefix goes at the first printable character, after the leading ESC[..m.
    try expectRun(ESC ++ "[32mgreen\n", ESC ++ "[32m" ++ P ++ ESC ++ "[32m" ++ "green\n");
}

test "an open color is re-applied after the prefix on the next lines" {
    try expectRun(
        ESC ++ "[1;35mone\ntwo\n",
        ESC ++ "[1;35m" ++ P ++ ESC ++ "[1;35m" ++ "one\n" ++ P ++ ESC ++ "[1;35m" ++ "two\n",
    );
}

test "a reset stops the color from being re-applied" {
    try expectRun(
        ESC ++ "[31mred" ++ ESC ++ "[0m\nplain\n",
        ESC ++ "[31m" ++ P ++ ESC ++ "[31m" ++ "red" ++ ESC ++ "[0m\n" ++ P ++ "plain\n",
    );
}

test "an empty SGR (ESC[m) is a reset too" {
    try expectRun(
        ESC ++ "[31mred" ++ ESC ++ "[m\nplain\n",
        ESC ++ "[31m" ++ P ++ ESC ++ "[31m" ++ "red" ++ ESC ++ "[m\n" ++ P ++ "plain\n",
    );
}

test "0;N restarts the tracked state instead of stacking" {
    var f = Fmt{};
    var out = Buf{};
    defer out.deinit();
    f.run(&out, "", ESC ++ "[1m" ++ ESC ++ "[0;31mx\n");
    out.deinit();
    out = .{};
    f.run(&out, P, "y\n");
    try t.expectEqualStrings(P ++ ESC ++ "[0;31m" ++ "y\n", out.slice());
}

test "colors stack until reset" {
    var f = Fmt{};
    var out = Buf{};
    defer out.deinit();
    f.run(&out, "", ESC ++ "[1m" ++ ESC ++ "[34mx\n");
    out.deinit();
    out = .{};
    f.run(&out, P, "y\n");
    try t.expectEqualStrings(P ++ ESC ++ "[1m" ++ ESC ++ "[34m" ++ "y\n", out.slice());
}

test "non-SGR sequences (cursor moves) are copied and do not touch the color" {
    try expectRun(
        ESC ++ "[2K" ++ ESC ++ "[1Gtext\nnext\n",
        ESC ++ "[2K" ++ ESC ++ "[1G" ++ P ++ "text\n" ++ P ++ "next\n",
    );
}

test "a newline inside an unfinished sequence aborts it" {
    try expectRun(ESC ++ "[3\nabc", ESC ++ "[3\n" ++ P ++ "abc");
}

test "unicode and truecolor pass through untouched" {
    try expectRun(
        ESC ++ "[48;2;10;20;30m漢字" ++ ESC ++ "[0m\n",
        ESC ++ "[48;2;10;20;30m" ++ P ++ ESC ++ "[48;2;10;20;30m" ++ "漢字" ++ ESC ++ "[0m\n",
    );
}

test "too many stacked colors give up restoring but never crash" {
    var f = Fmt{};
    var out = Buf{};
    defer out.deinit();
    var i: usize = 0;
    while (i < 200) : (i += 1) f.run(&out, "", ESC ++ "[38;5;196m");
    f.run(&out, "", "x\n");
    out.deinit();
    out = .{};
    f.run(&out, P, "y\n");
    // Either nothing or a valid prefix + sequences + text: always ends with the text.
    try t.expect(std.mem.endsWith(u8, out.slice(), "y\n"));
    try t.expect(std.mem.startsWith(u8, out.slice(), P));
}

test "scan() tracks the same state as run() without producing output" {
    var f = Fmt{};
    f.scan(ESC ++ "[32mgreen\n");
    var out = Buf{};
    defer out.deinit();
    f.run(&out, P, "x\n");
    try t.expectEqualStrings(P ++ ESC ++ "[32m" ++ "x\n", out.slice());
}

test "splitting the input anywhere gives the same output" {
    const sample = "plain\n" ++ ESC ++ "[1;35mviolet A\r\n  second" ++ ESC ++ "[0m line\n" ++
        ESC ++ "[2K" ++ ESC ++ "[38;2;1;2;3m漢字\n\n10%\r20%\r" ++ ESC ++ "[31mred\nend";

    var whole = try run(sample);
    defer whole.deinit();

    var cut: usize = 0;
    while (cut <= sample.len) : (cut += 1) {
        var f = Fmt{};
        var out = Buf{};
        defer out.deinit();
        f.run(&out, P, sample[0..cut]);
        f.run(&out, P, sample[cut..]);
        try t.expectEqualStrings(whole.slice(), out.slice());
    }
}

test "removing what was inserted gives back the original bytes" {
    // Property: nothing from the input is ever dropped or changed.
    const sample = ESC ++ "[1;35mviolet\nline two\n\n" ++ ESC ++ "[0mdone\r\n";
    var out = try run(sample);
    defer out.deinit();

    var f2 = Fmt{};
    var no_prefix = Buf{};
    defer no_prefix.deinit();
    f2.run(&no_prefix, "", sample); // restores colors but inserts no prefix

    // Strip the prefix and everything inserted after it: compare the input as a subsequence.
    var i: usize = 0;
    for (out.slice()) |b| {
        if (i < sample.len and sample[i] == b) i += 1;
    }
    try t.expectEqual(sample.len, i);
}
