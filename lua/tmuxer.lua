local M = {}

local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')

local function is_tmux_running()
  return vim.fn.exists('$TMUX') == 1
end

local function create_tmux_session(session_name, project_path)
  os.execute("tmux new-session -ds " .. session_name .. " -c " .. project_path)
end

local function create_and_run_dev_session(session_name, project_path)
  -- Create new session and run nvim-dev command
  os.execute("tmux new-session -ds " .. session_name .. " -c " .. project_path .. " 'nvim-dev'")
end

local function switch_tmux_session(session_name)
  os.execute("tmux switch-client -t " .. session_name)
end

local function find_git_projects(workspace_path, max_depth)
  local cmd = string.format(
    "find %s -type d -name .git -prune -maxdepth %d ! -path '*/archive/*'",
    workspace_path,
    max_depth
  )
  local git_dirs = vim.fn.systemlist(cmd)
  local projects = {}
  for _, git_dir in ipairs(git_dirs) do
    local project_path = vim.fn.fnamemodify(git_dir, ":h")
    local project_name = vim.fn.fnamemodify(project_path, ":t")
    local parent_dir = vim.fn.fnamemodify(project_path, ":h:t")
    table.insert(projects, { name = project_name, path = project_path, parent = parent_dir })
  end
  table.sort(projects, function(a, b)
    if a.parent:lower() == b.parent:lower() then
      return a.name:lower() < b.name:lower()
    end
    return a.parent:lower() < b.parent:lower()
  end)
  return projects
end

function M.open_workspace_popup(workspace, _)
  if not is_tmux_running() then
    print("Not in a tmux session")
    return
  end

  local projects = find_git_projects(workspace.path, 3)

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
          -- Multiple selections: create sessions in background (keeping original functionality)
          for _, selection in ipairs(selections) do
            local project = selection.value
            local session_name = string.lower(project.name):gsub("[^%w_]", "_")
            create_tmux_session(session_name, project.path)
            print("Created tmux session: " .. session_name)
          end
        else
          -- Single selection: create session with nvim-dev command and switch to it
          local selection = action_state.get_selected_entry()
          local project = selection.value
          local session_name = string.lower(project.name):gsub("[^%w_]", "_")
          create_and_run_dev_session(session_name, project.path)
          switch_tmux_session(session_name)
        end

        actions.close(prompt_bufnr)
      end)

      return true
    end,
  }):find()
end

function M.tmux_sessions()
  if not is_tmux_running() then
    print("Not in a tmux session")
    return
  end

  local sessions = vim.fn.systemlist('tmux list-sessions -F "#{session_name}"')
  table.sort(sessions, function(a, b) return a:lower() < b:lower() end)

  pickers.new({}, {
    prompt_title = "Switch Tmux Session",
    finder = finders.new_table {
      results = sessions,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry,
          ordinal = entry,
        }
      end
    },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        switch_tmux_session(selection.value)
      end)
      return true
    end,
  }):find()
end

function M.setup(opts)
  M.workspaces = opts.workspaces or {}
end

return M

--local M = {}

--local pickers = require('telescope.pickers')
--local finders = require('telescope.finders')
--local conf = require('telescope.config').values
--local actions = require('telescope.actions')
--local action_state = require('telescope.actions.state')

--local function is_tmux_running()
--return vim.fn.exists('$TMUX') == 1
--end

--local function create_tmux_session(session_name, project_path)
--os.execute("tmux new-session -ds " .. session_name .. " -c " .. project_path)
--end

--local function switch_tmux_session(session_name)
--os.execute("tmux switch-client -t " .. session_name)
--end

--local function find_git_projects(workspace_path, max_depth)
--local cmd = string.format(
--"find %s -type d -name .git -prune -maxdepth %d ! -path '*/archive/*'",
--workspace_path,
--max_depth
--)
--local git_dirs = vim.fn.systemlist(cmd)
--local projects = {}
--for _, git_dir in ipairs(git_dirs) do
--local project_path = vim.fn.fnamemodify(git_dir, ":h")
--local project_name = vim.fn.fnamemodify(project_path, ":t")
--local parent_dir = vim.fn.fnamemodify(project_path, ":h:t")
--table.insert(projects, { name = project_name, path = project_path, parent = parent_dir })
--end
--table.sort(projects, function(a, b)
--if a.parent:lower() == b.parent:lower() then
--return a.name:lower() < b.name:lower()
--end
--return a.parent:lower() < b.parent:lower()
--end)
--return projects
--end

--function M.open_workspace_popup(workspace, _)
--if not is_tmux_running() then
--print("Not in a tmux session")
--return
--end

--local projects = find_git_projects(workspace.path, 3)

--pickers.new({}, {
--prompt_title = "Select a project in " .. workspace.name,
--finder = finders.new_table {
--results = projects,
--entry_maker = function(entry)
--local display_width = vim.o.columns - 4
--local column_width = math.floor((display_width - 20) / 2)
--column_width = math.max(1, math.min(column_width, 50))
--local name_format = "%-" .. column_width .. "." .. column_width .. "s"
--local parent_format = "%-" .. column_width .. "." .. column_width .. "s"
--return {
--value = entry,
--display = string.format(name_format .. "                    " .. parent_format, entry.name, entry.parent),
--ordinal = entry.parent .. " " .. entry.name,
--}
--end
--},
--sorter = conf.generic_sorter({}),
--attach_mappings = function(prompt_bufnr)
--actions.select_default:replace(function()
--local picker = action_state.get_current_picker(prompt_bufnr)
--local selections = picker:get_multi_selection()

--if #selections > 0 then
---- Multiple selections: create sessions in background
--for _, selection in ipairs(selections) do
--local project = selection.value
--local session_name = string.lower(project.name):gsub("[^%w_]", "_")
--create_tmux_session(session_name, project.path)
--print("Created tmux session: " .. session_name)
--end
--else
---- Single selection: create and switch to session
--local selection = action_state.get_selected_entry()
--local project = selection.value
--local session_name = string.lower(project.name):gsub("[^%w_]", "_")
--create_tmux_session(session_name, project.path)
--switch_tmux_session(session_name)
--end

--actions.close(prompt_bufnr)
--end)

--return true
--end,
--}):find()
--end

--function M.tmux_sessions()
--if not is_tmux_running() then
--print("Not in a tmux session")
--return
--end

--local sessions = vim.fn.systemlist('tmux list-sessions -F "#{session_name}"')
--table.sort(sessions, function(a, b) return a:lower() < b:lower() end)

--pickers.new({}, {
--prompt_title = "Switch Tmux Session",
--finder = finders.new_table {
--results = sessions,
--entry_maker = function(entry)
--return {
--value = entry,
--display = entry,
--ordinal = entry,
--}
--end
--},
--sorter = conf.generic_sorter({}),
--attach_mappings = function(prompt_bufnr)
--actions.select_default:replace(function()
--actions.close(prompt_bufnr)
--local selection = action_state.get_selected_entry()
--switch_tmux_session(selection.value)
--end)
--return true
--end,
--}):find()
--end

--function M.setup(opts)
--M.workspaces = opts.workspaces or {}
--end

--return M
