-- Keep the full native coding interface and edit its shared presentation API.
-- Run from the repository after building:
-- zig-out/bin/spica --state-directory /tmp/spica-theme-demo --lua-module examples/t3-theme.lua
-- F5 stages edits atomically; an invalid edit preserves the last-good visuals.
-- F9 switches between this configuration and the native defaults.
-- Colors follow T3 Code eb1510d T3_CODE_DARK_THEME_COLORS (MIT).
return {
  root = function(snapshot)
    return {
      kind = 'native',
      id = 'workspace',
      -- Native roots use design only; per-node style belongs to custom roots.
      design = {
        colors = {
          background = '#0a0a0a',
          sidebar = '#000000',
          surface = '#111111',
          raised = '#111111',
          border = '#191919',
          foreground = '#f5f5f5',
          muted = '#818181',
          accent = '#346bf1',
          accent_text = '#ffffff',
          selection = '#343a47',
        },
        layout = {
          sidebar_width = 272,
          content_width = 880,
          header_height = 56,
          composer_height = 160,
          gutter = 24,
          gap = 12,
          radius = 16,
        },
      },
    }
  end,
  -- Required by the module contract. A native root keeps native rendering;
  -- this descriptor is validated, but is not installed as its text renderer.
  render_block = function(snapshot)
    return { text = snapshot.text, format = 'plain' }
  end,
  -- Native controls retain native admission. No custom action is declared here.
  -- This function is available if you later replace the root with a custom tree
  -- containing a button with action='send', as in examples/minimal.lua.
  action = function(id, payload)
    assert(id == 'send', 'unknown action')
    return { kind = 'send', text = payload }
  end,
}
