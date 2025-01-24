# tmuxer

This is a neovim plugin that streamlines workspace management and tmux session handling.

It allows you to quickly navigate between different project directories and automatically creates or switches to corresponding tmux sessions.

With tmuxer.nvim, you can effortlessly organize your development environment, making it easier to juggle multiple projects.

The plugin uses telescope for an intuitive, searchable interface to select workspaces and tmux sessions.

## Usage

To configure the plugin with [lazy.nvim](https://github.com/folke/lazy.nvim), use the following setup:

```lua
return {
  "dkooll/tmuxer.nvim",
  dependencies = { "nvim-telescope/telescope.nvim" },
  opts = {
    layout_config = {
      height = 15,
      width = 80,
    }
  },
  keys = {
    {
      "<leader>tc",
      function()
        require("tmuxer").open_workspace_popup(
          { name = "workspaces", path = "~/Documents/workspaces" }
        )
      end,
      desc = "Tmuxer: Create Tmux Session"
    },
    {
      "<leader>ts",
      function()
        require("tmuxer").tmux_sessions()
      end,
      desc = "Tmuxer: Switch Tmux Session"
    },
  },
}
```

## Notes

The Telescope picker scans one or more base directories, which can be configured in the settings, identifying subfolders and displaying only projects that contain a .git folder.

By default, all contents within the archive folder are excluded from the results.

Multiple session handling is supported in parallel, enabling the creation and removal of sessions while filtering out the current one.
