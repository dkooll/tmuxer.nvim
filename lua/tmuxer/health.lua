local M = {}

M.check = function()
  vim.health.start("tmuxer.nvim")

  if vim.fn.has("nvim-0.10.4") == 1 then
    vim.health.ok("Neovim >= 0.10.4")
  else
    vim.health.error("Neovim >= 0.10.4 required (telescope dependency)")
  end

  if vim.fn.exists("$TMUX") == 1 then
    vim.health.ok("Running inside tmux")
  else
    vim.health.warn("Not running inside tmux")
  end

  local has_telescope = pcall(require, "telescope")
  if has_telescope then
    vim.health.ok("telescope.nvim installed")
  else
    vim.health.error("telescope.nvim required")
  end

  if vim.fn.executable("fd") == 1 then
    vim.health.ok("fd installed (faster search)")
  else
    vim.health.info("fd not installed (using find)")
  end

  local ok, tmuxer = pcall(require, "tmuxer")
  if ok and tmuxer.workspaces and #tmuxer.workspaces > 0 then
    for _, ws in ipairs(tmuxer.workspaces) do
      local expanded = vim.fn.expand(ws.path)
      if vim.fn.isdirectory(expanded) == 1 then
        vim.health.ok(string.format("Workspace '%s': %s", ws.name, ws.path))
      else
        vim.health.warn(string.format("Workspace '%s' not found: %s", ws.name, ws.path))
      end
    end
  else
    vim.health.warn("No workspaces configured")
  end
end

return M
