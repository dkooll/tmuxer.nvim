local M = {}

local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local entry_display = require('telescope.pickers.entry_display')

local project_cache = { with_archive = nil, without_archive = nil }
local has_fd = vim.fn.executable('fd') == 1

M.config = {
  nvim_alias = "nvim",
  layout_config = { height = 15, width = 80 },
  theme = nil,
  previewer = true,
  border = true,
  parent_highlight = { fg = "#9E8069", bold = false },
  show_archive = false,
  max_depth = 2,
}

local function apply_theme(opts)
  opts = opts or {}
  local base = {
    layout_config = vim.tbl_deep_extend("force", M.config.layout_config, opts.layout_config or {}),
    previewer = opts.previewer ~= nil and opts.previewer or M.config.previewer,
    border = opts.border ~= nil and opts.border or M.config.border,
  }

  local theme_name = opts.theme or M.config.theme
  if not theme_name then return base end

  local ok, themes = pcall(require, 'telescope.themes')
  if not ok then return base end

  if theme_name == "dropdown" then
    return themes.get_dropdown(base)
  elseif theme_name == "cursor" then
    return themes.get_cursor(base)
  elseif theme_name == "ivy" then
    return themes.get_ivy(base)
  end
  return base
end

local function is_tmux_running()
  return vim.fn.exists('$TMUX') == 1
end

local function switch_tmux_session(session_name, callback)
  vim.fn.jobstart({ "tmux", "switch-client", "-t", session_name }, {
    on_exit = function() if callback then callback() end end
  })
end

local function get_tmux_session_name_set()
  local sessions = {}
  for _, name in ipairs(vim.fn.systemlist("tmux list-sessions -F '#{session_name}'")) do
    if name ~= "" then sessions[name] = true end
  end
  return sessions
end

local function create_tmux_session_with_nvim(session_name, project_path, existing_sessions, callback)
  if existing_sessions and existing_sessions[session_name] then
    switch_tmux_session(session_name, callback)
    return
  end

  local cmd = { "tmux", "new-session", "-ds", session_name, "-c", project_path }
  local alias = M.config.nvim_alias or "nvim"

  if type(alias) == "table" then
    for _, part in ipairs(alias) do cmd[#cmd + 1] = part end
  else
    cmd[#cmd + 1] = vim.env.SHELL or "/bin/zsh"
    cmd[#cmd + 1] = "-lc"
    cmd[#cmd + 1] = alias
  end

  vim.fn.jobstart(cmd, {
    on_exit = function(_, code)
      if code == 0 then
        if existing_sessions then existing_sessions[session_name] = true end
        if callback then callback() end
        return
      end
      local refreshed = get_tmux_session_name_set()
      if refreshed[session_name] then
        if existing_sessions then existing_sessions[session_name] = true end
        switch_tmux_session(session_name, callback)
      elseif callback then
        callback()
      end
    end
  })
end

local function find_git_projects(workspace_path, include_archive)
  local cache_key = include_archive and "with_archive" or "without_archive"
  if project_cache[cache_key] then
    return project_cache[cache_key]
  end

  local expanded = vim.fn.expand(workspace_path)
  local escaped = vim.fn.shellescape(expanded)
  local depth = M.config.max_depth + 1
  local archive_depth = M.config.max_depth + 3 -- archive has extra nesting

  local cmd
  if has_fd then
    cmd = include_archive
        and string.format("fd -H -t d '^.git$' -d %d . %s -x echo {//}", archive_depth, escaped)
        or string.format("fd -H -t d '^.git$' -d %d --exclude archive . %s -x echo {//}", depth, escaped)
  else
    cmd = include_archive
        and string.format("find %s -maxdepth %d -type d -name .git -exec dirname {} \\;", escaped, archive_depth)
        or string.format("find %s -maxdepth %d -type d -name .git ! -path '*/archive/*' -exec dirname {} \\;", escaped,
          depth)
  end

  local raw = vim.fn.systemlist(cmd)
  local results = {}

  for i = 1, #raw do
    local project_path = raw[i]
    if project_path ~= "" then
      local name = project_path:match("[^/]+$")
      local parent = project_path:match("([^/]+)/[^/]+$")
      if name and parent then
        results[#results + 1] = {
          name = name,
          path = project_path,
          parent = parent,
          lower_name = name:lower(),
          lower_parent = parent:lower(),
        }
      end
    end
  end

  table.sort(results, function(a, b)
    if a.lower_parent == b.lower_parent then
      return a.lower_name < b.lower_name
    end
    return a.lower_parent < b.lower_parent
  end)

  project_cache[cache_key] = results
  return results
end

local function preload_cache(workspace_path)
  find_git_projects(workspace_path, false)
  vim.defer_fn(function()
    find_git_projects(workspace_path, true)
  end, 100)
end

function M.open_workspace_popup(workspace, opts)
  if not is_tmux_running() then
    vim.notify("Not in a tmux session", vim.log.levels.WARN)
    return
  end

  local projects = find_git_projects(workspace.path, M.config.show_archive)
  local picker_opts = apply_theme(opts)
  local existing_sessions = get_tmux_session_name_set()

  local displayer = entry_display.create {
    separator = "/",
    items = { { width = nil }, { width = nil } },
  }

  pickers.new(picker_opts, {
    prompt_title = "Select a project in " .. workspace.name,
    finder = finders.new_table {
      results = projects,
      entry_maker = function(entry)
        return {
          value = entry,
          display = function()
            return displayer {
              entry.name,
              { entry.parent, "TmuxerParentDir" }
            }
          end,
          ordinal = entry.name .. " " .. entry.parent,
        }
      end
    },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selections = picker:get_multi_selection()
        actions.close(prompt_bufnr)

        if #selections > 0 then
          local completed, total = 0, #selections
          for _, selection in ipairs(selections) do
            local project = selection.value
            local session_name = project.name:lower():gsub("[^%w_]", "_")
            create_tmux_session_with_nvim(session_name, project.path, existing_sessions, function()
              completed = completed + 1
              vim.notify(string.format("Created session (%d/%d): %s", completed, total, session_name),
                vim.log.levels.INFO)
            end)
          end
        else
          local project = action_state.get_selected_entry().value
          local session_name = project.name:lower():gsub("[^%w_]", "_")
          create_tmux_session_with_nvim(session_name, project.path, existing_sessions, function()
            switch_tmux_session(session_name)
          end)
        end
      end)
      return true
    end,
  }):find()
end

local function get_session_windows(session_name)
  local output = vim.fn.systemlist(string.format(
    'tmux list-windows -t %s -F "#{window_index}: #{window_name}"',
    vim.fn.shellescape(session_name)
  ))
  local windows = {}
  for _, line in ipairs(output) do
    local index, name = line:match("^(%d+): (.+)$")
    if index and name then
      windows[#windows + 1] = { index = tonumber(index), name = name }
    end
  end
  return windows
end

local function get_non_current_tmux_sessions()
  local output = vim.fn.systemlist('tmux list-sessions -F "#{?session_attached,1,0} #{session_name} #{session_path}"')
  local sessions = {}

  for _, line in ipairs(output) do
    local is_current, name, path = line:match("^(%d)%s+(%S+)%s+(.+)$")
    if name and path and is_current == "0" then
      local project_name = path:match("[^/]+$") or ""
      local parent = path:match("([^/]+)/[^/]+$") or ""
      local windows = get_session_windows(name)
      sessions[#sessions + 1] = {
        name = name,
        path = path,
        project_name = project_name,
        parent = parent,
        windows = windows,
      }
    end
  end

  table.sort(sessions, function(a, b)
    if a.parent == b.parent then return a.name < b.name end
    return a.parent < b.parent
  end)

  return sessions
end

local function build_session_entries(sessions)
  local entries = {}
  for _, session in ipairs(sessions) do
    -- Add session entry
    entries[#entries + 1] = {
      type = "session",
      session_name = session.name,
      parent = session.parent,
      display_name = session.name,
      window_count = #session.windows,
    }
    -- Add window entries if more than 1 window
    if #session.windows > 1 then
      for _, win in ipairs(session.windows) do
        entries[#entries + 1] = {
          type = "window",
          session_name = session.name,
          parent = session.parent,
          window_index = win.index,
          window_name = win.name,
          display_name = string.format("   %d: %s", win.index, win.name),
        }
      end
    end
  end
  return entries
end

local function switch_to_window(session_name, window_index)
  vim.fn.jobstart({ "tmux", "select-window", "-t", string.format("%s:%d", session_name, window_index) }, {
    on_exit = function()
      vim.fn.jobstart({ "tmux", "switch-client", "-t", session_name })
    end
  })
end

local function create_session_finder(sessions)
  local entries = build_session_entries(sessions)
  local displayer = entry_display.create {
    separator = "/",
    items = { { width = nil }, { width = nil } },
  }

  return finders.new_table {
    results = entries,
    entry_maker = function(entry)
      return {
        value = entry,
        display = function()
          if entry.type == "window" then
            return entry.display_name
          end
          return displayer { entry.display_name, { entry.parent, "TmuxerParentDir" } }
        end,
        ordinal = entry.session_name .. " " .. entry.parent .. " " .. (entry.window_name or ""),
      }
    end
  }
end

function M.tmux_sessions(opts)
  if not is_tmux_running() then
    vim.notify("Not in a tmux session", vim.log.levels.WARN)
    return
  end

  local sessions = get_non_current_tmux_sessions()
  local picker_opts = apply_theme(opts)

  pickers.new(picker_opts, {
    prompt_title = "Switch Tmux Session",
    finder = create_session_finder(sessions),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local entry = action_state.get_selected_entry().value
        if entry.type == "window" then
          switch_to_window(entry.session_name, entry.window_index)
        else
          switch_tmux_session(entry.session_name)
        end
      end)

      map("i", "<C-d>", function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selections = picker:get_multi_selection()
        local entries = {}

        if #selections > 0 then
          for _, sel in ipairs(selections) do
            entries[#entries + 1] = sel.value
          end
        else
          local sel = action_state.get_selected_entry()
          if sel then entries[#entries + 1] = sel.value end
        end

        if #entries == 0 then return end

        local sessions_to_kill = {}
        local windows_to_kill = {}

        for _, entry in ipairs(entries) do
          if entry.type == "session" then
            sessions_to_kill[entry.session_name] = true
          else
            if not sessions_to_kill[entry.session_name] then
              windows_to_kill[#windows_to_kill + 1] = {
                session = entry.session_name,
                index = entry.window_index,
              }
            end
          end
        end

        local pending = 0
        local function on_done()
          pending = pending - 1
          if pending > 0 then return end
          if not vim.api.nvim_buf_is_valid(prompt_bufnr) then return end
          local new_sessions = get_non_current_tmux_sessions()
          if #new_sessions == 0 then
            vim.schedule(function() actions.close(prompt_bufnr) end)
            return
          end
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(prompt_bufnr) then
              picker:refresh(create_session_finder(new_sessions), { reset_prompt = true })
            end
          end)
        end

        for session in pairs(sessions_to_kill) do
          pending = pending + 1
          vim.fn.jobstart({ "tmux", "kill-session", "-t", session }, { on_exit = on_done })
        end

        for _, win in ipairs(windows_to_kill) do
          pending = pending + 1
          vim.fn.jobstart({ "tmux", "kill-window", "-t", string.format("%s:%d", win.session, win.index) },
            { on_exit = on_done })
        end
      end)
      return true
    end,
  }):find()
end

function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.config, opts)
  M.workspaces = opts.workspaces or {}

  vim.api.nvim_set_hl(0, "TmuxerParentDir", M.config.parent_highlight)

  if #M.workspaces > 0 then
    preload_cache(M.workspaces[1].path)
  end

  vim.api.nvim_create_user_command("TmuxCreateSession", function()
    if #M.workspaces == 1 then
      M.open_workspace_popup(M.workspaces[1])
    else
      pickers.new(apply_theme(), {
        prompt_title = "Select Workspace",
        finder = finders.new_table {
          results = M.workspaces,
          entry_maker = function(entry)
            return { value = entry, display = entry.name, ordinal = entry.name }
          end
        },
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            actions.close(prompt_bufnr)
            M.open_workspace_popup(action_state.get_selected_entry().value)
          end)
          return true
        end,
      }):find()
    end
  end, {})

  vim.api.nvim_create_user_command("TmuxSwitchSession", M.tmux_sessions, {})

  vim.api.nvim_create_user_command("TmuxToggleArchive", function()
    M.config.show_archive = not M.config.show_archive
  end, {})
end

return M
