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

Toggle visibility of archived projects

Health check for verifying plugin setup

## Requirements

Neovim 0.10.4 or higher

Tmux running (plugin checks for $TMUX environment variable)

Telescope.nvim

Fd command (optional, falls back to find if not available)

## Usage

To configure the plugin with [lazy.nvim](https://github.com/folke/lazy.nvim), use the following setup:

```lua
return {
  "dkooll/tmuxer.nvim",
  dependencies = { "nvim-telescope/telescope.nvim" },
  cmd = { "TmuxCreateSession", "TmuxSwitchSession", "TmuxToggleArchive" },
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
    { "<leader>tc", "<cmd>TmuxCreateSession<cr>", desc = "Tmuxer: Create Session" },
    { "<leader>ts", "<cmd>TmuxSwitchSession<cr>", desc = "Tmuxer: Switch Session" },
    { "<leader>ta", "<cmd>TmuxToggleArchive<cr>", desc = "Tmuxer: Toggle Archive" },
    { "<leader>th", "<cmd>checkhealth tmuxer<cr>", desc = "Tmuxer: Health Check" },
  },
}
```

## Configuration

`workspaces`

List of workspaces with `name` and `path` (default: `{}`)

`nvim_alias`

Command to run in new tmux sessions (default: `"nvim"`)

`max_depth`

Directory depth for git project search (default: `2`)

`theme`

Telescope theme: `"dropdown"`, `"cursor"`, `"ivy"` or `nil` (default: `nil`)

`previewer`

Show telescope previewer (default: `true`)

`border`

Show border around picker (default: `true`)

`show_archive`

Show archived projects by default (default: `false`)

`layout_config`

Telescope layout dimensions (default: `{ height = 15, width = 80 }`)

`parent_highlight`

Highlight for parent directory (default: `{ fg = "#9E8069", bold = false }`)

## Commands

`:TmuxCreateSession`

Opens a Telescope picker to browse Git projects within configured workspaces and create tmux sessions

`:TmuxSwitchSession`

Lists all non-attached tmux sessions and allows switching between them or killing sessions with `<C-d>`

`:TmuxToggleArchive`

Toggles visibility of projects inside `archive` folders

## Notes

The plugin uses Telescope for an intuitive, searchable interface

Projects are discovered by finding .git directories (uses fd if available for better performance)

Excludes folders named `archive` by default (toggle with `:TmuxToggleArchive`)

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
