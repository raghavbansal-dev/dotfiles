-- rainbow_csv: colors CSV/TSV columns
local function gh(repo) return 'https://github.com/' .. repo end

vim.pack.add { gh 'cameron-wags/rainbow_csv.nvim' }
vim.cmd.packadd 'rainbow_csv.nvim'

require('rainbow_csv').setup()

-- Stop treesitter from highlighting CSV/TSV (it overrides rainbow_csv's colors)
vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'csv', 'tsv', 'csv_semicolon', 'csv_whitespace', 'csv_pipe', 'rfc_csv', 'rfc_semicolon' },
  callback = function()
    pcall(vim.treesitter.stop)
  end,
})

