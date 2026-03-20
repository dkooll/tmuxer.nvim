local M = {}

local pickers, finders, sorters, conf, actions, action_state

local function load_telescope()
  if pickers then return end
  pickers = require('telescope.pickers')
  finders = require('telescope.finders')
  sorters = require('telescope.sorters')
  conf = require('telescope.config').values
  actions = require('telescope.actions')
  action_state = require('telescope.actions.state')
end

local project_cache = {}
local expanded_sessions = {}
local expanded_windows = {}
local expanded_floating = {}
local has_fd = vim.fn.executable('fd') == 1

local HL_WINDOW_ICON = "TmuxerWindowIcon"
local HL_FLOATING_ICON = "TmuxerFloatingIcon"
local HL_PANE_ICON = "TmuxerPaneIcon"

M.config = {
  nvim_alias = "nvim",
  layout_config = { height = 15, width = 80 },
  theme = nil,
  previewer = true,
  border = true,
  show_archive = false,
  max_depth = 2,
  icons = {
    window = "■",
    window_hl = nil,
    floating = "▣",
    floating_hl = nil,
    pane = "▪",
    pane_hl = nil,
  },
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

local function parse_git_projects(lines)
  local results = {}
  for _, path in ipairs(lines) do
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
  return results
end

local function build_git_cmd(workspace_path, include_archive)
  local expanded = vim.fn.expand(workspace_path)
  local escaped = vim.fn.shellescape(expanded)
  local depth = M.config.max_depth + 1
  local archive_depth = M.config.max_depth + 3

  if has_fd then
    return include_archive
        and string.format("fd -H -t d '^.git$' -d %d . %s -x echo {//}", archive_depth, escaped)
        or string.format("fd -H -t d '^.git$' -d %d --exclude archive . %s -x echo {//}", depth, escaped)
  else
    return include_archive
        and string.format("find %s -maxdepth %d -type d -name .git -exec dirname {} \\;", escaped, archive_depth)
        or string.format("find %s -maxdepth %d -type d -name .git ! -path '*/archive/*' -exec dirname {} \\;", escaped,
          depth)
  end
end

local function find_git_projects_async(workspace_path, include_archive, callback)
  local cache_key = workspace_path .. (include_archive and ":with_archive" or ":without_archive")
  if project_cache[cache_key] then
    callback(project_cache[cache_key])
    return
  end

  local cmd = build_git_cmd(workspace_path, include_archive)
  local stdout_data = {}

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then stdout_data = data end
    end,
    on_exit = function(_, code)
      local results = parse_git_projects(code == 0 and stdout_data or {})
      project_cache[cache_key] = results
      vim.schedule(function() callback(results) end)
    end,
  })
end

local function preload_cache(workspace_path)
  find_git_projects_async(workspace_path, false, function()
    find_git_projects_async(workspace_path, true, function() end)
  end)
end

function M.open_workspace_popup(workspace, opts)
  load_telescope()
  if not is_tmux_running() then
    vim.notify("Not in a tmux session", vim.log.levels.WARN)
    return
  end

  local existing_sessions = get_tmux_session_name_set()

  local function show_picker(projects)
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

  find_git_projects_async(workspace.path, M.config.show_archive, show_picker)
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

local function float_display_label(entry)
  return (entry.windows[1] and entry.windows[1].name) or entry.name
end

local function get_non_current_tmux_sessions()
  local windows_by_session = get_all_windows_batched()
  local sessions = {}
  local floating = {}
  local current_session = nil

  for _, line in ipairs(vim.fn.systemlist('tmux list-sessions -F "#{?session_attached,1,0}|#{session_name}|#{session_path}|#{@floating}|#{@floating-parent}"')) do
    local is_current, name, path, is_float, float_parent = line:match("^(%d)|([^|]+)|([^|]*)|([^|]*)|(.*)$")
    if name then
      if is_current == "1" then
        current_session = name
      elseif is_current == "0" then
        if is_float == "1" and float_parent ~= "" then
          if not floating[float_parent] then floating[float_parent] = {} end
          floating[float_parent][#floating[float_parent] + 1] = {
            name = name,
            windows = windows_by_session[name] or {},
          }
        elseif is_float ~= "1" then
          sessions[#sessions + 1] = {
            name = name,
            parent = path:match("([^/]+)/[^/]+$") or "",
            windows = windows_by_session[name] or {},
          }
        end
      end
    end
  end

  table.sort(sessions, function(a, b)
    if a.parent == b.parent then return a.name < b.name end
    return a.parent < b.parent
  end)

  local session_set = {}
  for _, session in ipairs(sessions) do
    session_set[session.name] = true
    session.floating = floating[session.name] or {}
    table.sort(session.floating, function(a, b) return a.name < b.name end)
  end

  for parent_name, floats in pairs(floating) do
    if parent_name ~= current_session and not session_set[parent_name] then
      for _, f in ipairs(floats) do
        sessions[#sessions + 1] = {
          name = f.name,
          parent = "",
          windows = f.windows,
          floating = {},
          is_floating = true,
        }
      end
    end
  end

  return sessions
end

local function build_session_entries(sessions)
  local entries = {}
  local icons = M.config.icons
  local float_icon = icons.floating
  local float_icon_hl = icons.floating_hl and HL_FLOATING_ICON or nil
  local win_icon = icons.window
  local win_icon_hl = icons.window_hl and HL_WINDOW_ICON or nil
  local pane_icon = icons.pane
  local pane_icon_hl = icons.pane_hl and HL_PANE_ICON or win_icon_hl

  for _, session in ipairs(sessions) do
    if session.is_floating then
      local label = float_display_label(session)
      local display_str = string.format("%s %s", float_icon, label)
      entries[#entries + 1] = {
        type = "floating",
        session_name = session.name,
        parent = session.parent,
        display_str = display_str,
        ordinal_str = session.name,
        icon_hl = float_icon_hl,
        icon_start = 0,
        icon_end = #float_icon,
      }
    else
      local is_expanded = expanded_sessions[session.name]
      local is_float_expanded = expanded_floating[session.name]
      local win_count = #session.windows
      local float_count = #(session.floating or {})
      local has_children = win_count > 0 or float_count > 0
      local any_expanded = is_expanded or is_float_expanded

      local session_indicator = has_children and (any_expanded and "─" or "+") or " "
      local window_suffix = win_count == 1 and ": 1 window" or string.format(": %d windows", win_count)
      if float_count > 0 then
        window_suffix = window_suffix .. string.format(", %d floating", float_count)
      end
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
        for _, win in ipairs(session.windows) do
          local win_key = session.name .. ":" .. win.index
          local win_is_expanded = expanded_windows[win_key]
          local pane_count = #win.panes

          local expand_indicator = ""
          if pane_count > 1 then
            expand_indicator = win_is_expanded and "─ " or "+ "
          end

          local pane_suffix = pane_count > 1 and string.format(": %d panes", pane_count) or ""
          local prefix = "   \t"
          local win_display = string.format("%s%s%s %s%s", prefix, expand_indicator, win_icon, win.name, pane_suffix)
          local icon_start = #prefix + #expand_indicator
          local icon_end = icon_start + #win_icon

          entries[#entries + 1] = {
            type = "window",
            session_name = session.name,
            parent = session.parent,
            window_index = win.index,
            window_name = win.name,
            pane_count = pane_count,
            panes = win.panes,
            expanded = win_is_expanded,
            display_str = win_display,
            ordinal_str = session.name .. " " .. session.parent .. " " .. win.name,
            icon_hl = win_icon_hl,
            icon_start = icon_start,
            icon_end = icon_end,
          }

          if win_is_expanded and pane_count > 1 then
            for _, pane in ipairs(win.panes) do
              local pane_prefix = "      \t"
              local pane_display = string.format("%s%s %s", pane_prefix, pane_icon, pane.command)
              local pane_icon_start = #pane_prefix
              local pane_icon_end = pane_icon_start + #pane_icon

              entries[#entries + 1] = {
                type = "pane",
                session_name = session.name,
                parent = session.parent,
                window_index = win.index,
                window_name = win.name,
                pane_index = pane.index,
                pane_command = pane.command,
                display_str = pane_display,
                ordinal_str = session.name .. " " .. session.parent .. " " .. win.name .. " " .. pane.command,
                icon_hl = pane_icon_hl,
                icon_start = pane_icon_start,
                icon_end = pane_icon_end,
              }
            end
          end
        end
      end

      if is_expanded or is_float_expanded then
        for _, float in ipairs(session.floating or {}) do
          local label = float_display_label(float)
          local float_prefix = "   \t"
          local float_display = string.format("%s%s %s", float_prefix, float_icon, label)
          local float_icon_start = #float_prefix
          local float_icon_end = float_icon_start + #float_icon

          entries[#entries + 1] = {
            type = "floating",
            session_name = float.name,
            parent = session.parent,
            parent_session = session.name,
            display_str = float_display,
            ordinal_str = session.name .. " " .. session.parent .. " floating " .. label,
            icon_hl = float_icon_hl,
            icon_start = float_icon_start,
            icon_end = float_icon_end,
          }
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

local function popup_session(session_name)
  local raw = vim.fn.system(
    'tmux display-message -p "#{@popup-width}|#{@popup-height}|#{@popup-border}"'
  ):gsub("%s+$", "")
  local w, h, s = raw:match("^([^|]*)|([^|]*)|(.*)$")
  w = (w and w ~= "") and w or "80%"
  h = (h and h ~= "") and h or "80%"
  s = (s and s ~= "") and s or "fg=#232728"
  vim.fn.jobstart(
    string.format("tmux popup -E -w %s -h %s -S '%s' 'tmux attach -t %s'",
      w, h, s, vim.fn.shellescape(session_name))
  )
end

local function create_session_finder(sessions)
  local entries = build_session_entries(sessions)

  return finders.new_table {
    results = entries,
    entry_maker = function(entry)
      return {
        value = entry,
        display = function(tbl)
          local str = tbl.value.display_str
          local hl = {}
          if tbl.value.icon_hl and tbl.value.icon_start then
            hl[#hl + 1] = { { tbl.value.icon_start, tbl.value.icon_end }, tbl.value.icon_hl }
          end
          return str, hl
        end,
        ordinal = entry.ordinal_str,
      }
    end
  }
end

local function create_preserve_order_sorter()
  return sorters.new {
    scoring_function = function(_, prompt, _, entry)
      if not prompt or prompt == "" then
        return 1
      end

      local ordinal = entry.ordinal:lower()
      local search = prompt:lower()

      if ordinal:find(search, 1, true) then
        return 1
      end

      return -1
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
  load_telescope()
  if not is_tmux_running() then
    vim.notify("Not in a tmux session", vim.log.levels.WARN)
    return
  end

  expanded_sessions = {}
  expanded_windows = {}
  expanded_floating = {}
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
        local sel = action_state.get_selected_entry()
        if not sel then return end
        local entry = sel.value
        actions.close(prompt_bufnr)
        if entry.type == "floating" then
          popup_session(entry.session_name)
        elseif entry.type == "pane" then
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

        local tbl, key, find_type, find_win_idx
        if entry.type == "session" then
          tbl, key = expanded_sessions, entry.session_name
          find_type = "session"
        elseif entry.type == "window" and entry.pane_count > 1 then
          tbl, key = expanded_windows, entry.session_name .. ":" .. entry.window_index
          find_type, find_win_idx = "window", entry.window_index
        else
          return
        end

        local is_expanded = tbl[key]
        if expand and not is_expanded then
          tbl[key] = true
        elseif not expand and is_expanded then
          tbl[key] = nil
        else
          return
        end

        picker:refresh(create_session_finder(state.sessions), { reset_prompt = false })
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(prompt_bufnr) then
            local idx = find_entry_index(picker, find_type, entry.session_name, find_win_idx)
            if idx then picker:set_selection(picker:get_row(idx)) end
          end
        end, 10)
      end

      map("i", "<Right>", function() toggle_expand(true) end)
      map("i", "<Left>", function() toggle_expand(false) end)

      local function toggle_all()
        local picker = action_state.get_current_picker(prompt_bufnr)
        if next(expanded_sessions) ~= nil or next(expanded_windows) ~= nil or next(expanded_floating) ~= nil then
          expanded_sessions = {}
          expanded_windows = {}
          expanded_floating = {}
        else
          for _, session in ipairs(state.sessions) do
            expanded_sessions[session.name] = true
            for _, win in ipairs(session.windows) do
              if #win.panes > 1 then
                expanded_windows[session.name .. ":" .. win.index] = true
              end
            end
          end
        end
        picker:refresh(create_session_finder(state.sessions), { reset_prompt = false })
      end

      local function toggle_panes_for_selected()
        local sel = action_state.get_selected_entry()
        if not sel then return end
        local entry = sel.value

        local session_name, window_index
        if entry.type == "window" and entry.pane_count > 1 then
          session_name = entry.session_name
          window_index = entry.window_index
        elseif entry.type == "pane" then
          session_name = entry.session_name
          window_index = entry.window_index
        else
          return
        end

        local picker = action_state.get_current_picker(prompt_bufnr)
        local key = session_name .. ":" .. window_index
        if expanded_windows[key] then
          expanded_windows[key] = nil
        else
          expanded_windows[key] = true
        end
        picker:refresh(create_session_finder(state.sessions), { reset_prompt = false })
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(prompt_bufnr) then
            local idx = find_entry_index(picker, "window", session_name, window_index)
            if idx then picker:set_selection(picker:get_row(idx)) end
          end
        end, 10)
      end

      local function toggle_floating()
        local picker = action_state.get_current_picker(prompt_bufnr)
        if next(expanded_floating) ~= nil then
          expanded_floating = {}
        else
          for _, session in ipairs(state.sessions) do
            if #(session.floating or {}) > 0 then
              expanded_floating[session.name] = true
            end
          end
        end
        picker:refresh(create_session_finder(state.sessions), { reset_prompt = false })
      end

      map("i", "<C-e>", toggle_all)
      map("i", "<C-g>", toggle_panes_for_selected)
      map("i", "<C-f>", toggle_floating)

      map("i", "<C-d>", function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selections = picker:get_multi_selection()

        local entries = #selections > 0 and vim.tbl_map(function(s) return s.value end, selections)
            or { action_state.get_selected_entry() and action_state.get_selected_entry().value }

        if #entries == 0 or not entries[1] then return end

        local sessions_to_kill, windows_to_kill = {}, {}
        for _, entry in ipairs(entries) do
          if entry.type == "session" or entry.type == "floating" then
            sessions_to_kill[entry.session_name] = true
          elseif not sessions_to_kill[entry.session_name] then
            windows_to_kill[#windows_to_kill + 1] = { session = entry.session_name, index = entry.window_index }
          end
        end

        for _, session in ipairs(state.sessions) do
          if sessions_to_kill[session.name] and session.floating then
            for _, float in ipairs(session.floating) do
              sessions_to_kill[float.name] = true
            end
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

  local icons = M.config.icons
  if icons.window_hl then
    vim.api.nvim_set_hl(0, HL_WINDOW_ICON, icons.window_hl)
  end
  if icons.floating_hl then
    vim.api.nvim_set_hl(0, HL_FLOATING_ICON, icons.floating_hl)
  end
  if icons.pane_hl then
    vim.api.nvim_set_hl(0, HL_PANE_ICON, icons.pane_hl)
  end

  if #M.workspaces > 0 then
    preload_cache(M.workspaces[1].path)
  end

  vim.api.nvim_create_user_command("TmuxCreateSession", function()
    load_telescope()
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
