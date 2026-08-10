return {
  {
    "scottmckendry/cyberdream.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      transparent = false,
      saturation = 1,
      colors = {
        bg = "#020202",
        bg_alt = "#080808",
        bg_highlight = "#151515",
      },
    },
  },

  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "cyberdream",
    },
  },
}
