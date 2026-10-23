-- One custom composition; composer/transcript remain native public primitives.
return {
  root = function(snapshot)
    return { kind = 'column', id = 'workspace', children = {
      { kind = 'text', id = 'heading', text = 'Spica · custom root' },
      { kind = 'transcript', id = 'conversation' },
      { kind = 'row', id = 'input-row', children = {
        { kind = 'composer', id = 'draft' },
        { kind = 'button', id = 'send-button', text = 'Send', action = 'send' },
      } },
      { kind = 'text', id = 'revision', text = snapshot.revision },
    } }
  end,
  render_block = function(block)
    return { text = '[custom] ' .. block.text, format = 'plain' }
  end,
  action = function(id, payload)
    assert(id == 'send', 'unknown action')
    return { kind = 'send', text = payload }
  end,
}
