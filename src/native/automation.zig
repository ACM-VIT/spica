/// Read-only native shell observations. There are no composer/domain controls.
/// SDL events travel through the ordinary dispatch path; SDL alone cannot
/// authenticate their physical source. The runner separately attests real vd input.
pub const Snapshot = struct {
    version: u32 = 1,
    generation: u64 = 1,
    frame_id: u64 = 0,
    event_sequence: u64 = 0,
    resize_events: u64 = 0,
    logical_width: i32 = 0,
    logical_height: i32 = 0,
    output_width: i32 = 0,
    output_height: i32 = 0,
    input_origin: []const u8 = "ordinary_sdl_event_path_unverified_source",
    close_reason: []const u8 = "none",
    running: bool = true,
    targets: [1]Target = .{.{}},
};

pub const Target = struct {
    id: []const u8 = "window.close",
    role: []const u8 = "window_lifecycle",
    key: []const u8 = "Escape",
    // This is a lifecycle target, not a fabricated clickable title-bar rectangle.
    pointer_bounds: ?[4]i32 = null,
};
