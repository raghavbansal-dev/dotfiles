-- lazygit.nvim: opens the lazygit TUI inside Neovim
-- Requires the `lazygit` binary to be installed system-wide

local function gh(repo) return 'https://github.com/' .. repo end

vim.pack.add { gh 'kdheepak/lazygit.nvim' }

vim.keymap.set('n', '<leader>gg', '<cmd>LazyGit<CR>', { desc = '[G]it: Lazy[G]it' })
