# tmuxer

This is a neovim plugin that streamlines workspace management and tmux session handling.

It allows you to quickly navigate between different project directories and automatically creates or switches to corresponding tmux sessions.

## Features

Quickly browse and open Git projects from configured workspaces

Automatically create tmux sessions for selected projects

Start Neovim instances within tmux sessions

List and switch between existing tmux sessions

Multi-select support for batch operations

Kill tmux sessions without leaving Neovim

Smart project sorting by parent directories

## Usage

To configure the plugin with [lazy.nvim](https://github.com/folke/lazy.nvim), use the following setup:

```lua
return {
  "dkooll/tmuxer.nvim",
  dependencies = { "nvim-telescope/telescope.nvim" },
  cmd = { "WorkspaceOpen", "TmuxSessions" },
  config = function()
    require("tmuxer").setup({
      workspaces = {
        {
          name = "workspaces",
          path = "~/Documents/workspaces"
        }
      },
      max_depth = 2,
      theme = "ivy",
      previewer = false,
      border = true,
      parent_highlight = {
        fg = "#9E8069",
        bold = true,
      },
      layout_config = {
        width = 0.5,
        height = 0.31,
      }
    })
  end,
  keys = {
    {
      "<leader>tc",
      function()
        require("tmuxer").open_workspace_popup({
          name = "workspaces",
          path = "~/Documents/workspaces"
        })
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

## Commands

`:WorkspaceOpen`

Opens a Telescope picker to select a workspace, then shows Git projects within that workspace

`:TmuxSessions`

Lists all non-attached tmux sessions and allows switching between them or killing sessions with <C-d>

## Notes

The plugin uses Telescope for an intuitive, searchable interface

Projects are discovered by finding .git directories (uses fd if available for better performance)

Automatically excludes folders named archive from search results

Session names are generated from project names (non-alphanumeric characters replaced with underscores)

Sessions can be killed directly from the session picker

Multiple projects can be selected at once for batch operations

If you want to use different neovim configurations or versions, you can override the default command within the config

```lua
nvim_alias = "NVIM_APPNAME=nvim-dev nvim",
```

## Contributors

We welcome contributions from the community! Whether it's reporting a bug, suggesting a new feature, or submitting a pull request, your input is highly valued. <br><br>

<a href="https://github.com/dkooll/tmuxer.nvim/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=dkooll/tmuxer.nvim" />
</a>

## Requirements

[Neovim](https://neovim.io/) 0.7.0 or higher

[Tmux](https://github.com/tmux) running (plugin checks for $TMUX environment variable)

[Telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)

[Fd](https://github.com/sharkdp/fd) command (optional, falls back to find if not available)
