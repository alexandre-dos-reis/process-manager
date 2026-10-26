//! Readiness checks: `health: <command>` on a service. The command is run (through `sh -c`,
//! in the service's directory and with its environment) every `interval` until it exits 0
//! once; then the service is `healthy` and checking stops. After `retries` failures in a row
//! the service is `unhealthy` and the processes that depend on it fail instead of waiting.
//! Checks stop after the first success on purpose: a readiness gate, not a monitor, so a
//! healthy service costs no wake-ups.
const std = @import("std");
const sys = @import("../sys.zig");
const common = @import("../common.zig");
const gpa = common.gpa;
const types = @import("types.zig");
const Proc = types.Proc;
const control = @import("control.zig");
const output = @import("output.zig");
const note = output.note;

/// Is `p` currently being checked?
fn active(p: *Proc) bool {
    return p.health_cmd != null and p.pid > 0 and !p.stopping and !p.healthy and !p.health_failed;
}

/// When this process next needs the daemon's attention for its check, or -1.
pub fn due(p: *Proc) i64 {
    if (!active(p)) return -1;
    return if (p.hc_pid > 0) p.hc_deadline_ms else p.hc_next_ms;
}

pub fn tick(p: *Proc, now: i64, reap: bool) void {
    if (!active(p)) return;
    if (p.hc_pid > 0) {
        if (reap) {
            var st: c_int = 0;
            if (sys.waitpid(p.hc_pid, &st, sys.WNOHANG) == p.hc_pid) {
                p.hc_pid = 0;
                finished(p, st, now);
                return;
            }
        }
        if (now >= p.hc_deadline_ms) {
            // Too slow: kill it; the exit is collected as a failure on the next SIGCHLD.
            _ = sys.kill(-p.hc_pid, sys.SIGKILL);
            p.hc_deadline_ms = now + 2000;
        }
    } else if (now >= p.hc_next_ms) {
        spawn(p, now);
    }
}

fn finished(p: *Proc, status: c_int, now: i64) void {
    if (status == 0) { // exited normally with code 0
        p.healthy = true;
        note(p, "healthy", .{});
        return;
    }
    failed(p, now);
}

fn failed(p: *Proc, now: i64) void {
    p.hc_fails += 1;
    if (p.hc_fails >= p.health_retries) {
        p.health_failed = true;
        note(p, "unhealthy: {d} failed checks of `{s}`", .{ p.hc_fails, p.health_cmd.? });
        return;
    }
    p.hc_next_ms = now + p.health_interval_ms;
}

fn spawn(p: *Proc, now: i64) void {
    var envp: std.ArrayList(?[*:0]const u8) = .empty;
    defer envp.deinit(gpa);
    control.buildEnvp(p, &envp);

    const pid = sys.fork();
    if (pid < 0) return failed(p, now);
    if (pid == 0) {
        // Child. Only async-signal-safe calls from here on.
        _ = sys.setpgid(0, 0); // own group, so a timeout can kill the whole check
        _ = sys.signal(sys.SIGPIPE, sys.SIG_DFL);
        _ = sys.signal(sys.SIGTERM, sys.SIG_DFL);
        _ = sys.signal(sys.SIGINT, sys.SIG_DFL);
        const nul = sys.open("/dev/null", sys.O_RDWR);
        if (nul >= 0) {
            _ = sys.dup2(nul, 0);
            _ = sys.dup2(nul, 1);
            _ = sys.dup2(nul, 2);
        }
        if (p.cwd.len > 0 and sys.chdir(p.cwd.ptr) != 0) sys._exit(127);
        const argv = [_:null]?[*:0]const u8{ "sh", "-c", p.health_cmd.?.ptr };
        const ep: [*:null]const ?[*:0]const u8 = @ptrCast(envp.items.ptr);
        _ = sys.execve("/bin/sh", &argv, ep);
        sys._exit(127);
    }
    _ = sys.setpgid(pid, pid); // also from the parent, to avoid racing the child
    p.hc_pid = pid;
    p.hc_deadline_ms = now + p.health_timeout_ms;
}

/// Stops a running check (the service is going away).
pub fn killCheck(p: *Proc) void {
    if (p.hc_pid <= 0) return;
    _ = sys.kill(-p.hc_pid, sys.SIGKILL);
    var st: c_int = 0;
    _ = sys.waitpid(p.hc_pid, &st, 0);
    p.hc_pid = 0;
}
