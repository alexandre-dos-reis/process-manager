//! Everything the unit tests (test/*_test.zig) need, behind one module so that source
//! files keep their relative imports. Not used by the binary.
pub const config = @import("config.zig");
pub const common = @import("common.zig");
pub const Fmt = @import("daemon/fmt.zig").Fmt;
pub const Ring = @import("daemon/ring.zig").Ring;
pub const RING_MAX = @import("daemon/ring.zig").RING_MAX;
