-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
vim.opt.errorbells = false
vim.opt.visualbell = false
vim.opt.belloff = "all"
local function update_terminal_title()
  vim.opt.title = true
  vim.opt.titlestring = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
end

update_terminal_title()

vim.api.nvim_create_autocmd("DirChanged", {
  callback = update_terminal_title,
})
