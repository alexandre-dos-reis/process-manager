//! Line/escape/color (SGR) tracker used to insert "name |" prefixes without breaking colors.
const std = @import("std");
const sys = @import("../sys.zig");
const common = @import("../common.zig");
const Buf = common.Buf;
const gpa = common.gpa;

/// Tracks line, escape-sequence and color (SGR) state over a byte stream. With
/// `with_out`, copies the bytes to `out` and inserts `prefix` (then the active
/// color) at the start of each line. Never drops or changes a byte.
pub const Fmt = struct {
    at_line_start: bool = true,
    esc: u8 = 0, // 0 = text, 1 = after ESC, 2 = inside CSI
    csi: [64]u8 = undefined,
    csi_len: usize = 0,
    sgr: [256]u8 = undefined,
    sgr_len: usize = 0,

    pub fn applySgr(self: *Fmt) void {
        const params = self.csi[0..self.csi_len];
        if (params.len == 0 or std.mem.eql(u8, params, "0")) {
            self.sgr_len = 0;
            return;
        }
        if (std.mem.startsWith(u8, params, "0;")) self.sgr_len = 0;
        const need = params.len + 3;
        if (self.sgr_len + need > self.sgr.len) {
            self.sgr_len = 0; // too long to track; give up on restoring
            return;
        }
        self.sgr[self.sgr_len] = 0x1b;
        self.sgr[self.sgr_len + 1] = '[';
        @memcpy(self.sgr[self.sgr_len + 2 ..][0..params.len], params);
        self.sgr[self.sgr_len + 2 + params.len] = 'm';
        self.sgr_len += need;
    }

    pub fn runImpl(self: *Fmt, comptime with_out: bool, out: *Buf, prefix: []const u8, bytes: []const u8) void {
        var span: usize = 0; // start of the bytes not yet copied to `out`
        for (bytes, 0..) |b, i| {
            if (self.esc != 0 and b < 0x20 and b != 0x1b) self.esc = 0; // malformed sequence
            if (self.esc == 0) {
                if (b == '\r' or b == '\n') {
                    self.at_line_start = true;
                } else if (b == 0x1b) {
                    self.esc = 1;
                    self.csi_len = 0;
                } else if ((b >= 0x20 or b == '\t') and self.at_line_start) {
                    if (with_out) {
                        out.append(bytes[span..i]);
                        span = i;
                        out.append(prefix);
                        out.append(self.sgr[0..self.sgr_len]);
                    }
                    self.at_line_start = false;
                }
            } else if (self.esc == 1) {
                self.esc = if (b == '[') 2 else 0;
            } else if (b >= 0x40 and b <= 0x7e) {
                if (b == 'm') self.applySgr();
                self.esc = 0;
            } else if (self.csi_len < self.csi.len) {
                self.csi[self.csi_len] = b;
                self.csi_len += 1;
            } else {
                self.esc = 0;
            }
        }
        if (with_out) out.append(bytes[span..]);
    }

    pub fn run(self: *Fmt, out: *Buf, prefix: []const u8, bytes: []const u8) void {
        self.runImpl(true, out, prefix, bytes);
    }

    /// Update the state only (no output).
    pub fn scan(self: *Fmt, bytes: []const u8) void {
        var unused: Buf = .{};
        self.runImpl(false, &unused, "", bytes);
    }
};
