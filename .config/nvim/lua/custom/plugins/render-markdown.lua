local gh = function(repo)
  return { src = "https://github.com/" .. repo }
end

vim.pack.add { gh "MeanderingProgrammer/render-markdown.nvim" }

require("render-markdown").setup {
  completions = { lsp = { enabled = true } },
}
