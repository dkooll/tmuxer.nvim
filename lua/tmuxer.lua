local M = {}

local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')

local function is_tmux_running()
  return vim.fn.exists('$TMUX') == 1
end

local function create_tmux_session(session_name, project_path, command)
  local expanded_project_path = vim.fn.expand(project_path)
  local session_name_escaped = vim.fn.shellescape(session_name)
  local project_path_escaped = vim.fn.shellescape(expanded_project_path)
  local cmd = "tmux new-session -d -s " .. session_name_escaped .. " -c " .. project_path_escaped
  if command and command ~= '' then
    local command_escaped = vim.fn.shellescape(command)
    cmd = cmd .. " " .. command_escaped
  end
  print("Executing command: " .. cmd)
  local result = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error
  if exit_code ~= 0 then
    print("Error creating tmux session: " .. session_name)
    print("Command output: " .. result)
  end
end

local function switch_tmux_session(session_name)
  local session_name_escaped = vim.fn.shellescape(session_name)
  local cmd = "tmux switch-client -t " .. session_name_escaped
  print("Executing command: " .. cmd)
  local result = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error
  if exit_code ~= 0 then
    print("Error switching to tmux session: " .. session_name)
    print("Command output: " .. result)
  end
end

local function find_git_projects(workspace_path, max_depth)
  local expanded_workspace_path = vim.fn.expand(workspace_path)
  local cmd = string.format(
    "find %s -type d -name .git -prune -maxdepth %d ! -path '*/archive/*'",
    vim.fn.shellescape(expanded_workspace_path),
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
          -- Multiple selections: create sessions in background
          for _, selection in ipairs(selections) do
            local project = selection.value
            local session_name = string.lower(project.name):gsub("[^%w_]", "_")
            create_tmux_session(session_name, project.path)
            print("Created tmux session: " .. session_name)
          end
        else
          -- Single selection: create and switch to session with nvim-dev
          local selection = action_state.get_selected_entry()
          local project = selection.value
          local session_name = string.lower(project.name):gsub("[^%w_]", "_")
          create_tmux_session(session_name, project.path, 'nvim-dev')
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
  -- Expand workspace paths
  for _, workspace in ipairs(M.workspaces) do
    workspace.path = vim.fn.expand(workspace.path)
  end
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
