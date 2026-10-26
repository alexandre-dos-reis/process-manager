//! Shared types of the daemon (Proc, Conn, State...) and its tunables.
const std = @import("std");
const sys = @import("../sys.zig");
const common = @import("../common.zig");
const Buf = common.Buf;
const gpa = common.gpa;
const fmt = @import("fmt.zig");
const ring = @import("ring.zig");
const Fmt = fmt.Fmt;
const Ring = ring.Ring;

pub const LOG_ROTATE: usize = 10 * 1024 * 1024;
pub const KILL_GRACE_MS: i64 = 5000;
pub const QUICK_EXIT_MS: i64 = 3000;
pub const MAX_QUICK_FAILS: u32 = 6;
pub const MAX_CONN_OUT: usize = 8 * 1024 * 1024;
pub const MAX_REQ: usize = 16 * 1024 * 1024;
pub const palette = [_]u8{ 96, 93, 92, 95, 94, 91 };

pub const RESET = "\x1b[0m";
pub const BOLD = "\x1b[1m";
pub const DIM = "\x1b[2m";
pub const RED = "\x1b[31m";
pub const GREEN = "\x1b[32m";
pub const YELLOW = "\x1b[33m";
pub const CYAN = "\x1b[36m";

pub const Style = struct {
    on: bool,
    pub fn c(self: Style, code: []const u8) []const u8 {
        return if (self.on) code else "";
    }
};


// ------------------------------------------------------------------- types

pub const State = enum { running, stopped, exited, backoff, failed, waiting };

pub const Proc = struct {
    name: []u8,
    cmd: [:0]u8,
    cwd: [:0]u8,
    env: std.ArrayList([:0]u8) = .empty, // the client's environment
    over: std.ArrayList([:0]u8) = .empty, // per-process overrides ("KEY=value")
    deps: std.ArrayList([:0]u8) = .empty, // names of the processes this one waits for
    cols: u16,
    rows: u16,
    autorestart: bool,
    tty: bool,
    color: u8,

    state: State = .stopped,
    pid: c_int = 0,
    master: c_int = -1,
    started_ms: i64 = 0,
    exit_code: i32 = 0,
    exit_signal: i32 = 0,
    restarts: u32 = 0,
    fails: u32 = 0,
    next_start_ms: i64 = 0,
    stopping: bool = false,
    killed: bool = false,
    kill_at_ms: i64 = 0,
    restart_pending: bool = false,
    remove_when_dead: bool = false,

    // Readiness check: runs until it succeeds once (or gives up), then stops.
    health_cmd: ?[:0]u8 = null,
    health_interval_ms: i64 = 1000,
    health_timeout_ms: i64 = 5000,
    health_retries: u32 = 30,
    healthy: bool = false,
    health_failed: bool = false,
    hc_pid: c_int = 0, // the running check, if any
    hc_next_ms: i64 = 0,
    hc_deadline_ms: i64 = 0,
    hc_fails: u32 = 0,

    ring: Ring = .{},
    fmt: Fmt = .{},
    fmt_stale: bool = false, // fmt not kept up to date while nobody follows with prefixes
    last_byte: u8 = '\n',
    prefix: []u8 = &.{},
    log_fd: c_int = -1,
    log_bytes: usize = 0,
};

/// Optional readiness check of a service (`health:` in zpawn.yaml). Empty `cmd` = none.
pub const HealthSpec = struct {
    cmd: []const u8 = "",
    interval_ms: i64 = 1000,
    timeout_ms: i64 = 5000,
    retries: u32 = 30,
};

pub const Follow = struct { all: bool, proc: ?*Proc, prefix: bool };

pub const Conn = struct {
    fd: c_int,
    in: Buf = .{},
    out: Buf = .{},
    out_pos: usize = 0,
    follow: ?Follow = null,
    got_req: bool = false,
    close_after_flush: bool = false,
    dead: bool = false,
};
