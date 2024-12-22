local M = {}

local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')

-- Cache frequently used functions
local execute = os.execute
local systemlist = vim.fn.systemlist
local fnamemodify = vim.fn.fnamemodify

M.config = {
  nvim_cmd = "nvim",
  max_column_width = 50,
  min_column_width = 1,
}

local function is_tmux_running()
  return vim.fn.exists('$TMUX') == 1
end

local function sanitize_session_name(name)
  return string.lower(name):gsub("[^%w_]", "_")
end

local function create_tmux_session(session_name, project_path)
  local cmd = string.format("tmux new-session -ds %s -c %s", session_name, project_path)
  if execute(cmd) ~= 0 then
    error(string.format("Failed to create tmux session: %s", session_name))
  end
end

local function run_nvim_in_session(session_name, project_path)
  create_tmux_session(session_name, project_path)

  local send_cmd = string.format("tmux send-keys -t %s '%s' Enter", session_name, M.config.nvim_cmd)
  if execute(send_cmd) ~= 0 then
    error(string.format("Failed to send nvim command to session: %s", session_name))
  end
end

local function switch_tmux_session(session_name)
  local cmd = string.format("tmux switch-client -t %s", session_name)
  if execute(cmd) ~= 0 then
    error(string.format("Failed to switch to tmux session: %s", session_name))
  end
end

local function kill_tmux_session(session_name)
  local cmd = string.format("tmux kill-session -t %s", session_name)
  if execute(cmd) ~= 0 then
    error(string.format("Failed to kill tmux session: %s", session_name))
  end
end

local function find_git_projects(workspace_path, max_depth)
  -- Escape spaces in workspace path
  local escaped_path = workspace_path:gsub(" ", "\\ ")
  local cmd = string.format(
    "find %s -type d -name .git -prune -maxdepth %d ! -path '*/archive/*'",
    escaped_path,
    max_depth
  )

  local git_dirs = systemlist(cmd)
  if not git_dirs then return {} end

  local projects = {}
  for _, git_dir in ipairs(git_dirs) do
    local project_path = fnamemodify(git_dir, ":h")
    local project_name = fnamemodify(project_path, ":t")
    local parent_dir = fnamemodify(project_path, ":h:t")

    -- Pre-compute lowercase values for sorting
    local lower_parent = parent_dir:lower()
    local lower_name = project_name:lower()

    projects[#projects + 1] = {
      name = project_name,
      path = project_path,
      parent = parent_dir,
      lower_parent = lower_parent,
      lower_name = lower_name
    }
  end

  table.sort(projects, function(a, b)
    if a.lower_parent == b.lower_parent then
      return a.lower_name < b.lower_name
    end
    return a.lower_parent < b.lower_parent
  end)

  return projects
end

function M.open_workspace_popup(workspace, _)
  if not is_tmux_running() then
    vim.notify("Not in a tmux session", vim.log.levels.WARN)
    return
  end

  if not workspace or not workspace.path then
    vim.notify("Invalid workspace configuration", vim.log.levels.ERROR)
    return
  end

  local projects = find_git_projects(workspace.path, 3)
  if #projects == 0 then
    vim.notify("No git projects found in " .. workspace.path, vim.log.levels.INFO)
    return
  end

  pickers.new({}, {
    prompt_title = "Select a project in " .. workspace.name,
    finder = finders.new_table {
      results = projects,
      entry_maker = function(entry)
        local display_width = vim.o.columns - 4
        local column_width = math.floor((display_width - 20) / 2)
        column_width = math.max(1, math.min(column_width, 50))
        local name_format = "%-" .. column_width .. "." .. column_width .. "s"
        local parent_format = "%-" .. column_width .. "." .. column_width .. "s"
        return {
          value = entry,
          display = string.format(name_format .. "                    " .. parent_format, entry.name, entry.parent),
          ordinal = entry.parent .. " " .. entry.name,
        }
      end
    },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selections = picker:get_multi_selection()

        if #selections > 0 then
          -- Multiple selections: create sessions in background
          for _, selection in ipairs(selections) do
            local project = selection.value
            local session_name = sanitize_session_name(project.name)
            create_tmux_session(session_name, project.path)
            print("Created tmux session: " .. session_name)
          end
        else
          -- Single selection: create session, send nvim command, and switch to it
          local selection = action_state.get_selected_entry()
          local project = selection.value
          local session_name = sanitize_session_name(project.name)
          run_nvim_in_session(session_name, project.path)
          switch_tmux_session(session_name)
          print("Created and switched to session: " .. session_name .. " with " .. M.config.nvim_cmd)
        end

        actions.close(prompt_bufnr)
      end)

      return true
    end,
  }):find()
end

function M.tmux_sessions()
  if not is_tmux_running() then
    vim.notify("Not in a tmux session", vim.log.levels.WARN)
    return
  end

  local tmux_sessions = vim.fn.systemlist('tmux list-sessions -F "#{session_name}"')
  if not tmux_sessions or #tmux_sessions == 0 then
    vim.notify("No tmux sessions found", vim.log.levels.INFO)
    return
  end

  table.sort(tmux_sessions, function(a, b) return a:lower() < b:lower() end)

  pickers.new({}, {
    prompt_title = "Switch Tmux Session (Ctrl-D to delete)",
    finder = finders.new_table {
      results = tmux_sessions,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry,
          ordinal = entry,
        }
      end
    },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        switch_tmux_session(selection.value)
      end)

      map("n", "<C-d>", function()
        local current_picker = action_state.get_current_picker(prompt_bufnr)
        local selection = action_state.get_selected_entry()

        if not selection then return end

        local current_session = vim.fn.systemlist("tmux display-message -p '#S'")[1]

        if selection.value == current_session then
          vim.notify("Cannot delete current session", vim.log.levels.WARN)
          return
        end

        -- Kill the session
        local success, err = pcall(kill_tmux_session, selection.value)
        if success then
          -- Get updated session list
          local updated_sessions = vim.fn.systemlist('tmux list-sessions -F "#{session_name}"') or {}
          table.sort(updated_sessions, function(a, b) return a:lower() < b:lower() end)

          -- Update the picker with new results
          current_picker:refresh(finders.new_table({
            results = updated_sessions,
            entry_maker = function(entry)
              return {
                value = entry,
                display = entry,
                ordinal = entry,
              }
            end,
          }), { reset_prompt = true })

          vim.notify("Deleted session: " .. selection.value, vim.log.levels.INFO)
        else
          vim.notify("Failed to delete session: " .. err, vim.log.levels.ERROR)
        end
      end)

      return true
    end,
  }):find()
end

function M.setup(opts)
  if opts.nvim_cmd then
    M.config.nvim_cmd = opts.nvim_cmd
  end
  M.workspaces = opts.workspaces or {}
end

return M
