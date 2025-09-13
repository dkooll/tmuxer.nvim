local M = {}

local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local entry_display = require('telescope.pickers.entry_display')

-- Column width cache for performance
local cached_column_width

-- Default configuration
M.config = {
  nvim_alias = "nvim",
  layout_config = {
    height = 15,
    width = 80,
  },
  theme = nil,
  previewer = true,
  border = true,
  max_depth = 2,
  parent_highlight = { fg = "#9E8069", bold = false },
}

-- Helper function to apply telescope theme if available
local function apply_theme(opts)
  opts = opts or {}
  if not opts.theme and not M.config.theme then
    return {
      layout_config = vim.tbl_deep_extend("force", M.config.layout_config, (opts.layout_config or {})),
      border = opts.border ~= nil and opts.border or M.config.border,
    }
  end

  local status, themes = pcall(require, 'telescope.themes')
  if not status then
    return {
      layout_config = vim.tbl_deep_extend("force", M.config.layout_config, (opts.layout_config or {})),
      border = opts.border ~= nil and opts.border or M.config.border,
    }
  end

  local theme_name = opts.theme or M.config.theme
  local theme_opts = {
    layout_config = vim.tbl_deep_extend("force", M.config.layout_config, (opts.layout_config or {})),
    previewer = opts.previewer ~= nil and opts.previewer or M.config.previewer,
    border = opts.border ~= nil and opts.border or M.config.border,
  }

  if theme_name == "dropdown" then
    return themes.get_dropdown(theme_opts)
  elseif theme_name == "cursor" then
    return themes.get_cursor(theme_opts)
  elseif theme_name == "ivy" then
    return themes.get_ivy(theme_opts)
  else
    return theme_opts
  end
end

local function update_column_width()
  local display_width = vim.o.columns - 4
  cached_column_width = math.max(1, math.min(math.floor((display_width - 20) / 2), 50))
  return cached_column_width
end

local function is_tmux_running()
  return vim.fn.exists('$TMUX') == 1
end

local function session_exists(session_name)
  local result = vim.fn.system("tmux has-session -t=" .. vim.fn.shellescape(session_name) .. " 2>/dev/null && echo 1 || echo 0")
  return vim.trim(result) == "1"
end

local function create_tmux_session_with_nvim(session_name, project_path, callback)
  if session_exists(session_name) then
    vim.fn.jobstart({ "tmux", "switch-client", "-t", session_name }, {
      on_exit = function(_, _) if callback then callback() end end
    })
  else
    vim.fn.jobstart({
      "tmux", "new-session", "-ds", session_name,
      "-c", project_path, M.config.nvim_alias
    }, {
      on_exit = function(_, _) if callback then callback() end end
    })
  end
end

local function switch_tmux_session(session_name, callback)
  vim.fn.jobstart({ "tmux", "switch-client", "-t", session_name }, {
    on_exit = function(_, _) if callback then callback() end end
  })
end

local function find_git_projects(workspace_path, max_depth)
  local has_fd = vim.fn.executable('fd') == 1
  local cmd = has_fd and string.format(
    "fd -H -t d '^.git$' %s -d %d --exclude 'archive' -x echo {//}",
    workspace_path,
    max_depth + 1
  ) or string.format(
    "find %s -maxdepth %d -type d -name .git -prune ! -path '*/archive/*' -exec dirname {} \\;",
    workspace_path,
    max_depth + 1
  )

  local found_paths = vim.fn.systemlist(cmd)
  local results = {}
  local path_sep = package.config:sub(1, 1)
  local parent_pattern = "([^" .. path_sep .. "]+)" .. path_sep .. "[^" .. path_sep .. "]+$"
  local name_pattern = "[^" .. path_sep .. "]+$"

  for _, project_path in ipairs(found_paths) do
    local project_name = project_path:match(name_pattern)
    local parent_dir = project_path:match(parent_pattern)
    if project_name and parent_dir then
      table.insert(results, {
        name = project_name,
        path = project_path,
        parent = parent_dir,
        lower_name = project_name:lower(),
        lower_parent = parent_dir:lower()
      })
    end
  end

  table.sort(results, function(a, b)
    return a.lower_parent == b.lower_parent and a.lower_name < b.lower_name or a.lower_parent < b.lower_parent
  end)

  return results
end

function M.open_workspace_popup(workspace, opts)
  if not is_tmux_running() then
    print("Not in a tmux session")
    return
  end

  local projects = find_git_projects(workspace.path, M.config.max_depth)
  local picker_opts = apply_theme(opts)

  local displayer = entry_display.create {
    separator = "/",
    items = {
      { width = nil }, -- Project name
      { width = nil }, -- Parent directory
    },
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
              entry.name,                         -- Default highlight
              { entry.parent, "TmuxerParentDir" } -- Custom highlight
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
          local completed = 0
          local total = #selections
          for _, selection in ipairs(selections) do
            local project = selection.value
            local session_name = string.lower(project.name):gsub("[^%w_]", "_")
            create_tmux_session_with_nvim(session_name, project.path, function()
              completed = completed + 1
              print(string.format("Created tmux session with nvim (%d/%d): %s", completed, total, session_name))
            end)
          end
        else
          local selection = action_state.get_selected_entry()
          local project = selection.value
          local session_name = string.lower(project.name):gsub("[^%w_]", "_")
          create_tmux_session_with_nvim(session_name, project.path, function()
            switch_tmux_session(session_name, function()
              print("Created and switched to session: " .. session_name .. " with " .. M.config.nvim_alias)
            end)
          end)
        end
      end)
      return true
    end,
  }):find()
end

-- Updated to include directory information
local function get_non_current_tmux_sessions()
  -- Get session name and working directory path
  local sessions_output = vim.fn.systemlist(
    'tmux list-sessions -F "#{?session_attached,1,0} #{session_name} #{session_path}"')
  local sessions = {}

  for _, line in ipairs(sessions_output) do
    local is_current, name, path = line:match("^(%d)%s+(.+)%s+(.+)$")
    if name and path and is_current == "0" then
      local path_sep = package.config:sub(1, 1)
      local parent_pattern = "([^" .. path_sep .. "]+)" .. path_sep .. "[^" .. path_sep .. "]+$"
      local name_pattern = "[^" .. path_sep .. "]+$"

      -- Extract project name and parent directory from path
      local project_name = path:match(name_pattern) or ""
      local parent_dir = path:match(parent_pattern) or ""

      table.insert(sessions, {
        name = name,
        path = path,
        project_name = project_name,
        parent = parent_dir,
      })
    end
  end

  -- Sort sessions by parent directory then name
  table.sort(sessions, function(a, b)
    return a.parent == b.parent and a.name < b.name or a.parent < b.parent
  end)

  return sessions
end

function M.tmux_sessions(opts)
  if not is_tmux_running() then
    print("Not in a tmux session")
    return
  end

  local sessions = get_non_current_tmux_sessions()
  local picker_opts = apply_theme(opts)

  local displayer = entry_display.create {
    separator = "/",
    items = {
      { width = nil }, -- Session name
      { width = nil }, -- Parent directory
    },
  }

  pickers.new(picker_opts, {
    prompt_title = "Switch Tmux Session",
    finder = finders.new_table {
      results = sessions,
      entry_maker = function(entry)
        return {
          value = entry,
          display = function()
            return displayer {
              entry.name,                         -- Session name (default highlight)
              { entry.parent, "TmuxerParentDir" } -- Parent directory (custom highlight)
            }
          end,
          ordinal = entry.name .. " " .. entry.parent,
        }
      end
    },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        switch_tmux_session(selection.value.name)
      end)

      map("i", "<C-d>", function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selections = picker:get_multi_selection()
        local sessions_to_kill = {}

        if #selections > 0 then
          for _, sel in ipairs(selections) do
            table.insert(sessions_to_kill, sel.value.name)
          end
        else
          local selection = action_state.get_selected_entry()
          if not selection then return end
          table.insert(sessions_to_kill, selection.value.name)
        end

        for _, session in ipairs(sessions_to_kill) do
          vim.fn.jobstart({ "tmux", "kill-session", "-t", session }, {
            on_exit = function()
              if vim.api.nvim_buf_is_valid(prompt_bufnr) then
                local new_sessions = get_non_current_tmux_sessions()
                if #new_sessions == 0 then
                  vim.schedule(function() actions.close(prompt_bufnr) end)
                  return
                end
                local new_finder = finders.new_table({
                  results = new_sessions,
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
                })
                vim.schedule(function()
                  if vim.api.nvim_buf_is_valid(prompt_bufnr) then
                    picker:refresh(new_finder, { reset_prompt = true, new_prefix = picker.prompt_prefix })
                  end
                end)
              end
            end
          })
        end
      end)
      return true
    end,
  }):find()
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  M.workspaces = opts.workspaces or {}

  -- Set up parent directory highlight
  vim.api.nvim_set_hl(0, "TmuxerParentDir", M.config.parent_highlight)

  update_column_width()
  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("TmuxerResize", { clear = true }),
    callback = update_column_width,
  })

  vim.api.nvim_create_user_command("WorkspaceOpen", function()
    if #M.workspaces == 1 then
      M.open_workspace_popup(M.workspaces[1])
    else
      local picker_opts = apply_theme()
      pickers.new(picker_opts, {
        prompt_title = "Select Workspace",
        finder = finders.new_table {
          results = M.workspaces,
          entry_maker = function(entry) return { value = entry, display = entry.name, ordinal = entry.name } end
        },
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            actions.close(prompt_bufnr)
            local selection = action_state.get_selected_entry()
            M.open_workspace_popup(selection.value)
          end)
          return true
        end,
      }):find()
    end
  end, {})

  vim.api.nvim_create_user_command("TmuxSessions", M.tmux_sessions, {})
end

return M
