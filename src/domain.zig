//! App-owned durable conversation boundary. Domain values are independent of SDL.
pub const types = @import("domain/types.zig");
pub const store = @import("domain/store.zig");

test {
    _ = types;
    _ = @import("domain/domain_test.zig");
}
