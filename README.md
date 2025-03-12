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

Customizable layout configuration

Smart project sorting by parent directories

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

Sessions can be killed directly from the session picker using <C-d>

Multiple projects can be selected at once for batch operations

## Requirements

Neovim

Tmux running (plugin checks for $TMUX environment variable)

Telescope.nvim

Git repositories with .git directories

Fd command (optional, falls back to find if not available)
