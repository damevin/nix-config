local function open_periodic_note(command_id)
  local command = vim
    .system({
      "obsidian",
      "command",
      "id=" .. command_id,
    }, { text = true })
    :wait()

  if command.code ~= 0 then
    vim.notify(command.stderr or "Obsidian command failed", vim.log.levels.ERROR)
    return
  end

  vim.wait(100)

  local file = vim
    .system({
      "obsidian",
      "file",
    }, { text = true })
    :wait()

  local vault = vim
    .system({
      "obsidian",
      "vault",
      "info=path",
    }, { text = true })
    :wait()

  if file.code ~= 0 or vault.code ~= 0 then
    vim.notify("Could not resolve Obsidian note", vim.log.levels.ERROR)
    return
  end

  local relative_path = file.stdout:match("path\t([^\r\n]+)")

  if not relative_path then
    vim.notify("Could not resolve Obsidian note path", vim.log.levels.ERROR)
    return
  end

  local vault_path = vim.trim(vault.stdout)
  local absolute_path = vim.fs.joinpath(vault_path, relative_path)

  vim.cmd.edit(vim.fn.fnameescape(absolute_path))
end

return {
  {
    "obsidian-nvim/obsidian.nvim",
    version = "*",
    cmd = "Obsidian",
    ft = "markdown",

    opts = {
      legacy_commands = false,

      workspaces = {
        {
          name = "main",
          path = "~/Documents/observatory",
        },
      },

      picker = {
        name = "fzf-lua",
      },

      templates = {
        folder = "Templates",
      },

      ui = {
        enable = false,
      },
    },

    keys = {
      { "<leader>of", "<cmd>Obsidian quick_switch<cr>", desc = "Find note" },
      { "<leader>os", "<cmd>Obsidian search<cr>", desc = "Search notes" },
      { "<leader>on", "<cmd>Obsidian new<cr>", desc = "New note" },
      { "<leader>op", "<cmd>Obsidian new_from_template<cr>", desc = "New from template" },
      { "<leader>ob", "<cmd>Obsidian backlinks<cr>", desc = "Backlinks" },
      {
        "<leader>od",
        function()
          open_periodic_note("periodic-notes:open-daily-note")
        end,
        desc = "Daily note",
      },
      {
        "<leader>ow",
        function()
          open_periodic_note("periodic-notes:open-weekly-note")
        end,
        desc = "Weekly note",
      },
    },
  },

  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = "markdown",
    opts = {},
  },
}
