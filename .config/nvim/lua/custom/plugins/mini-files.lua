-- mini.files: filesystem-as-buffer explorer
-- (mini.nvim itself is already loaded in init.lua Section 3)

require('mini.files').setup {
  windows = {
    preview = true,
    width_focus = 30,
    width_preview = 50,
  },
  mappings = {
    close       = 'q',
    go_in       = 'l',
    go_in_plus  = 'L',
    go_out      = 'h',
    go_out_plus = 'H',
    reset       = '<BS>',
    reveal_cwd  = '@',
    show_help   = '?',
    synchronize = '=',
    trim_left   = '<',
    trim_right  = '>',
  },
}

-- Toggle the explorer with <leader>e, opens at the current buffer's location
vim.keymap.set('n', '<leader>e', function()
  local mf = require 'mini.files'
  if not mf.close() then
    mf.open(vim.api.nvim_buf_get_name(0))
  end
end, { desc = '[E]xplorer (mini.files)' })
