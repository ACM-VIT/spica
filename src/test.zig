test {
    _ = @import("app.zig");
    _ = @import("platform/executables.zig");
    _ = @import("core/protocol_test.zig");
    _ = @import("core/store_test.zig");
    _ = @import("core/draft.zig");
    _ = @import("core/catalog.zig");
    _ = @import("core/search.zig");
    _ = @import("core/search_source.zig");
    _ = @import("features/library/panel.zig");
    _ = @import("ui/theme.zig");
    _ = @import("features/transcript/view.zig");
    _ = @import("text/edit.zig");
    _ = @import("text/composer.zig");
    _ = @import("text/utf8.zig");
    _ = @import("text/bounded.zig");
    _ = @import("ui/hit_targets.zig");
    _ = @import("ui/label_cache.zig");
    _ = @import("features/models/thinking.zig");
    _ = @import("native/markdown_test.zig");
    _ = @import("content/markdown_test.zig");
    _ = @import("native/images_test.zig");
    _ = @import("native/highlight_test.zig");
    _ = @import("native/text_test.zig");
}
