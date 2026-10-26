//! The daemon's global state (single thread, so plain globals).
const std = @import("std");
const sys = @import("../sys.zig");
const common = @import("../common.zig");
const Buf = common.Buf;
const gpa = common.gpa;
const types = @import("types.zig");
const Conn = types.Conn;
const Proc = types.Proc;

pub var procs: std.ArrayList(*Proc) = .empty;
pub var conns: std.ArrayList(*Conn) = .empty;
pub var color_counter: usize = 0;
pub var max_name: usize = 4;
pub var shutting_down = false;
pub var shutdown_deadline: i64 = 0;
pub var down_conn: ?*Conn = null;
pub var got_term: u8 = 0;
pub var logs_dir: [:0]u8 = undefined;
pub var sock_path: [:0]u8 = undefined;
pub var scratch: Buf = .{};
