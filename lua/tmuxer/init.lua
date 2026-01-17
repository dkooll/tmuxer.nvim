local M = {}

local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local sorters = require('telescope.sorters')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')

local project_cache = {}
local expanded_sessions = {}
local expanded_windows = {}
local has_fd = vim.fn.executable('fd') == 1

M.config = {
  nvim_alias = "nvim",
  layout_config = { height = 15, width = 80 },
  theme = nil,
  previewer = true,
  border = true,
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

  local theme_fn = {
    dropdown = themes.get_dropdown,
    cursor = themes.get_cursor,
    ivy = themes.get_ivy,
  }
  return theme_fn[theme_name] and theme_fn[theme_name](base) or base
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
  local cache_key = workspace_path .. (include_archive and ":with_archive" or ":without_archive")
  if project_cache[cache_key] then return project_cache[cache_key] end

  local expanded = vim.fn.expand(workspace_path)
  local escaped = vim.fn.shellescape(expanded)
  local depth = M.config.max_depth + 1
  local archive_depth = M.config.max_depth + 3

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

  local results = {}
  for _, path in ipairs(vim.fn.systemlist(cmd)) do
    if path ~= "" then
      local name = path:match("[^/]+$")
      local parent = path:match("([^/]+)/[^/]+$")
      if name and parent then
        results[#results + 1] = {
          name = name,
          path = path,
          parent = parent,
          lower_name = name:lower(),
          lower_parent = parent:lower(),
        }
      end
    end
  end

  table.sort(results, function(a, b)
    if a.lower_parent == b.lower_parent then return a.lower_name < b.lower_name end
    return a.lower_parent < b.lower_parent
  end)

  project_cache[cache_key] = results
  return results
end

local function preload_cache(workspace_path)
  find_git_projects(workspace_path, false)
  vim.defer_fn(function() find_git_projects(workspace_path, true) end, 100)
end

function M.open_workspace_popup(workspace, opts)
  if not is_tmux_running() then
    vim.notify("Not in a tmux session", vim.log.levels.WARN)
    return
  end

  local projects = find_git_projects(workspace.path, M.config.show_archive)
  local existing_sessions = get_tmux_session_name_set()

  pickers.new(apply_theme(opts), {
    prompt_title = "Select a project in " .. workspace.name,
    finder = finders.new_table {
      results = projects,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.name .. "/" .. entry.parent,
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

local function get_all_panes_batched()
  local panes_by_window = {}
  for _, line in ipairs(vim.fn.systemlist('tmux list-panes -a -F "#{session_name}|#{window_index}|#{pane_index}|#{pane_current_command}"')) do
    local session, win_idx, pane_idx, cmd = line:match("^([^|]+)|(%d+)|(%d+)|(.+)$")
    if session and win_idx and pane_idx and cmd then
      local key = session .. ":" .. win_idx
      if not panes_by_window[key] then
        panes_by_window[key] = {}
      end
      local panes = panes_by_window[key]
      panes[#panes + 1] = { index = tonumber(pane_idx), command = cmd }
    end
  end
  return panes_by_window
end

local function get_all_windows_batched()
  local panes_by_window = get_all_panes_batched()
  local windows_by_session = {}
  for _, line in ipairs(vim.fn.systemlist('tmux list-windows -a -F "#{session_name}|#{window_index}|#{window_name}"')) do
    local session, index, name = line:match("^([^|]+)|(%d+)|(.+)$")
    if session and index and name then
      if not windows_by_session[session] then
        windows_by_session[session] = {}
      end
      local wins = windows_by_session[session]
      local key = session .. ":" .. index
      wins[#wins + 1] = {
        index = tonumber(index),
        name = name,
        panes = panes_by_window[key] or {},
      }
    end
  end
  return windows_by_session
end

local function get_non_current_tmux_sessions()
  local windows_by_session = get_all_windows_batched()
  local sessions = {}
  for _, line in ipairs(vim.fn.systemlist('tmux list-sessions -F "#{?session_attached,1,0} #{session_name} #{session_path}"')) do
    local is_current, name, path = line:match("^(%d)%s+(%S+)%s+(.+)$")
    if name and path and is_current == "0" then
      sessions[#sessions + 1] = {
        name = name,
        parent = path:match("([^/]+)/[^/]+$") or "",
        windows = windows_by_session[name] or {},
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
    local is_expanded = expanded_sessions[session.name]
    local win_count = #session.windows

    local session_indicator = is_expanded and "─" or "+"
    local window_suffix = win_count == 1 and ": 1 window" or string.format(": %d windows", win_count)
    local display_str = string.format("%s %s/%s%s", session_indicator, session.name, session.parent, window_suffix)

    entries[#entries + 1] = {
      type = "session",
      session_name = session.name,
      parent = session.parent,
      window_count = win_count,
      expanded = is_expanded,
      display_str = display_str,
      ordinal_str = session.name .. " " .. session.parent,
    }

    if is_expanded then
      for j, win in ipairs(session.windows) do
        local win_is_last = (j == win_count)
        local win_key = session.name .. ":" .. win.index
        local win_is_expanded = expanded_windows[win_key]
        local pane_count = #win.panes

        local win_indicator = ""
        if pane_count > 1 then
          win_indicator = win_is_expanded and "─" or "+"
        end

        local win_branch = win_is_last and "└─› " or "├─› "
        local pane_suffix = pane_count > 1 and string.format(": %d panes", pane_count) or ""
        local win_display = string.format("  %s%s%d: %s%s", win_branch, win_indicator, win.index, win.name, pane_suffix)

        -- Use session ordinal + unique suffix to keep windows grouped with their session
        local win_ordinal = session.name .. " " .. session.parent .. " " .. string.format("%03d", win.index) .. " " .. win.name

        entries[#entries + 1] = {
          type = "window",
          session_name = session.name,
          parent = session.parent,
          window_index = win.index,
          window_name = win.name,
          pane_count = pane_count,
          panes = win.panes,
          expanded = win_is_expanded,
          is_last = win_is_last,
          display_str = win_display,
          ordinal_str = win_ordinal,
        }

        if win_is_expanded and pane_count > 1 then
          for k, pane in ipairs(win.panes) do
            local pane_is_last = (k == pane_count)
            local pane_prefix = win_is_last and "      " or "  │   "
            local pane_branch = pane_is_last and "└─› " or "├─› "
            local pane_display = string.format("%s%s%d: %s", pane_prefix, pane_branch, pane.index, pane.command)

            -- Use window ordinal + pane suffix to keep panes grouped with their window
            local pane_ordinal = win_ordinal .. " " .. string.format("%03d", pane.index) .. " " .. pane.command

            entries[#entries + 1] = {
              type = "pane",
              session_name = session.name,
              parent = session.parent,
              window_index = win.index,
              window_name = win.name,
              pane_index = pane.index,
              pane_command = pane.command,
              display_str = pane_display,
              ordinal_str = pane_ordinal,
            }
          end
        end
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

local function switch_to_pane(session_name, window_index, pane_index)
  vim.fn.jobstart({ "tmux", "select-window", "-t", string.format("%s:%d", session_name, window_index) }, {
    on_exit = function()
      vim.fn.jobstart({ "tmux", "select-pane", "-t", string.format("%s:%d.%d", session_name, window_index, pane_index) },
        {
          on_exit = function()
            vim.fn.jobstart({ "tmux", "switch-client", "-t", session_name })
          end
        })
    end
  })
end

local function create_session_finder(sessions)
  local entries = build_session_entries(sessions)

  return finders.new_table {
    results = entries,
    entry_maker = function(entry)
      return {
        value = entry,
        display = entry.display_str,
        ordinal = entry.ordinal_str,
      }
    end
  }
end

-- Custom sorter that filters but preserves original order
local function create_preserve_order_sorter()
  return sorters.new {
    scoring_function = function(_, prompt, _, entry)
      if not prompt or prompt == "" then
        return 1 -- Show all entries with same score
      end

      local ordinal = entry.ordinal:lower()
      local search = prompt:lower()

      -- Check if entry matches (simple substring match)
      if ordinal:find(search, 1, true) then
        return 1 -- All matches get same score to preserve order
      end

      return -1 -- Filter out non-matches
    end,
    highlighter = function(_, prompt, display)
      if not prompt or prompt == "" then return {} end
      local highlights = {}
      local search = prompt:lower()
      local display_lower = display:lower()
      local start_pos = display_lower:find(search, 1, true)
      if start_pos then
        table.insert(highlights, { start = start_pos - 1, finish = start_pos + #search - 1 })
      end
      return highlights
    end,
  }
end

local function refresh_picker(prompt_bufnr, sessions)
  if not vim.api.nvim_buf_is_valid(prompt_bufnr) then return end
  local picker = action_state.get_current_picker(prompt_bufnr)
  if #sessions == 0 then
    vim.schedule(function() actions.close(prompt_bufnr) end)
  else
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(prompt_bufnr) then
        picker:refresh(create_session_finder(sessions), { reset_prompt = true })
      end
    end)
  end
end

function M.tmux_sessions(opts)
  if not is_tmux_running() then
    vim.notify("Not in a tmux session", vim.log.levels.WARN)
    return
  end

  expanded_sessions = {}
  expanded_windows = {}
  local state = { sessions = get_non_current_tmux_sessions() }

  local function refresh_state(prompt_bufnr)
    state.sessions = get_non_current_tmux_sessions()
    refresh_picker(prompt_bufnr, state.sessions)
  end

  pickers.new(apply_theme(opts), {
    prompt_title = "Switch Tmux Session",
    finder = create_session_finder(state.sessions),
    sorter = create_preserve_order_sorter(),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry().value
        actions.close(prompt_bufnr)
        if entry.type == "pane" then
          switch_to_pane(entry.session_name, entry.window_index, entry.pane_index)
        elseif entry.type == "window" then
          switch_to_window(entry.session_name, entry.window_index)
        else
          switch_tmux_session(entry.session_name)
        end
      end)

      local function find_entry_index(picker, target_type, session_name, window_index)
        for i = 1, picker.manager:num_results() do
          local e = picker.manager:get_entry(i)
          if e and e.value then
            local v = e.value
            if v.type == target_type and v.session_name == session_name then
              if target_type == "session" or (target_type == "window" and v.window_index == window_index) then
                return i
              end
            end
          end
        end
        return nil
      end

      local function toggle_expand(expand)
        local sel = action_state.get_selected_entry()
        if not sel then return end
        local entry = sel.value
        local picker = action_state.get_current_picker(prompt_bufnr)


        if entry.type == "session" then
          local is_expanded = expanded_sessions[entry.session_name]
          if expand and not is_expanded then
            expanded_sessions[entry.session_name] = true
          elseif not expand and is_expanded then
            expanded_sessions[entry.session_name] = nil
          else
            return
          end
          picker:refresh(create_session_finder(state.sessions), { reset_prompt = false })
          vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(prompt_bufnr) then
              local idx = find_entry_index(picker, "session", entry.session_name)
              if idx then picker:set_selection(picker:get_row(idx)) end
            end
          end, 10)
        elseif entry.type == "window" and entry.pane_count > 1 then
          local win_key = entry.session_name .. ":" .. entry.window_index
          local is_expanded = expanded_windows[win_key]
          if expand and not is_expanded then
            expanded_windows[win_key] = true
          elseif not expand and is_expanded then
            expanded_windows[win_key] = nil
          else
            return
          end
          picker:refresh(create_session_finder(state.sessions), { reset_prompt = false })
          vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(prompt_bufnr) then
              local idx = find_entry_index(picker, "window", entry.session_name, entry.window_index)
              if idx then picker:set_selection(picker:get_row(idx)) end
            end
          end, 10)
        end
      end

      map("i", "<Right>", function() toggle_expand(true) end)
      map("i", "<Left>", function() toggle_expand(false) end)

      local function toggle_all(mode)
        local picker = action_state.get_current_picker(prompt_bufnr)
        local check = mode == "panes" and expanded_windows or expanded_sessions
        if next(check) ~= nil then
          expanded_sessions = {}
          expanded_windows = {}
        else
          expanded_sessions = {}
          expanded_windows = {}
          for _, session in ipairs(state.sessions) do
            local dominated_pane = false
            for _, win in ipairs(session.windows) do
              if #win.panes > 1 then
                if mode == "panes" or mode == "all" then
                  expanded_windows[session.name .. ":" .. win.index] = true
                  dominated_pane = true
                end
              end
            end
            if mode == "all" or mode == "sessions" or (mode == "panes" and dominated_pane) then
              expanded_sessions[session.name] = true
            end
          end
        end
        picker:refresh(create_session_finder(state.sessions), { reset_prompt = false })
      end

      map("i", "<C-e>", function() toggle_all("sessions") end)
      map("i", "<C-p>", function() toggle_all("panes") end)
      map("i", "<C-x>", function() toggle_all("all") end)

      map("i", "<C-d>", function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selections = picker:get_multi_selection()

        local entries = #selections > 0 and vim.tbl_map(function(s) return s.value end, selections)
            or { action_state.get_selected_entry() and action_state.get_selected_entry().value }

        if #entries == 0 or not entries[1] then return end

        local sessions_to_kill, windows_to_kill = {}, {}
        for _, entry in ipairs(entries) do
          if entry.type == "session" then
            sessions_to_kill[entry.session_name] = true
          elseif not sessions_to_kill[entry.session_name] then
            windows_to_kill[#windows_to_kill + 1] = { session = entry.session_name, index = entry.window_index }
          end
        end

        local function refresh()
          refresh_state(prompt_bufnr)
        end

        local session_count = 0
        for _ in pairs(sessions_to_kill) do session_count = session_count + 1 end

        if session_count > 0 and #windows_to_kill == 0 then
          local pending = session_count
          for session in pairs(sessions_to_kill) do
            vim.fn.jobstart({ "tmux", "kill-session", "-t", session }, {
              on_exit = function()
                pending = pending - 1
                if pending == 0 then refresh() end
              end
            })
          end
        elseif #windows_to_kill > 0 then
          table.sort(windows_to_kill, function(a, b)
            if a.session ~= b.session then return a.session < b.session end
            return a.index > b.index
          end)
          local function kill_next(idx)
            if idx > #windows_to_kill then
              refresh()
              return
            end
            local win = windows_to_kill[idx]
            vim.fn.jobstart({ "tmux", "kill-window", "-t", string.format("%s:%d", win.session, win.index) }, {
              on_exit = function() kill_next(idx + 1) end
            })
          end
          kill_next(1)
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
