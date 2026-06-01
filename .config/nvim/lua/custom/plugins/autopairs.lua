-- nvim-autopairs: auto-close brackets, quotes, etc.
local function gh(repo) return 'https://github.com/' .. repo end

vim.pack.add { gh 'windwp/nvim-autopairs' }

require('nvim-autopairs').setup {}
