local M = {}

local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')

M.config = {
  nvim_cmd = "nvim"
}

local function is_tmux_running()
  return vim.fn.exists('$TMUX') == 1
end

local function sanitize_session_name(name)
  return string.lower(name):gsub("[^%w_]", "_")
end

local function create_tmux_session(session_name, project_path)
  os.execute(string.format("tmux new-session -ds %s -c %s", session_name, project_path))
end

local function run_nvim_in_session(session_name, project_path)
  create_tmux_session(session_name, project_path)
  os.execute(string.format("tmux send-keys -t %s '%s' Enter", session_name, M.config.nvim_cmd))
end

local function switch_tmux_session(session_name)
  os.execute("tmux switch-client -t " .. session_name)
end

local function get_find_command(base_dir, max_depth, excluded_dirs)
  if vim.fn.executable('fd') == 1 then
    local exclude_patterns = table.concat(
      vim.tbl_map(function(dir)
        return string.format("--exclude '%s'", dir)
      end, excluded_dirs),
      " "
    )
    return string.format(
      "fd -H -t d -d %d '^.git$' %s %s -x echo {//}",
      max_depth,
      vim.fn.expand(base_dir),
      exclude_patterns
    )
  else
    local exclude_patterns = table.concat(
      vim.tbl_map(function(dir)
        return string.format("-not -path '*/%s/*'", dir)
      end, excluded_dirs),
      " "
    )
    return string.format(
      "find %s -type d -name .git -prune -maxdepth %d %s -exec dirname {} \\;",
      vim.fn.expand(base_dir),
      max_depth,
      exclude_patterns
    )
  end
end

local function find_git_projects(base_dir, max_depth, excluded_dirs)
  local cmd = get_find_command(base_dir, max_depth, excluded_dirs)
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

function M.open_workspace_popup(workspace)
  if not is_tmux_running() then
    print("Not in a tmux session")
    return
  end

  local projects = find_git_projects(workspace.path, 3, workspace.excluded_dirs or {})

  pickers.new({}, {
    prompt_title = "Select a project in " .. workspace.name,
    finder = finders.new_table {
      results = projects,
      entry_maker = function(entry)
        return {
          value = entry,
          display = string.format("%-30s %-30s", entry.name, entry.parent),
          ordinal = entry.name .. " " .. entry.parent,
        }
      end,
    },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selection = picker:get_multi_selection()

        if #selection > 0 then
          for _, sel in ipairs(selection) do
            local project = sel.value
            local session_name = sanitize_session_name(project.name)
            create_tmux_session(session_name, project.path)
            print("Created tmux session: " .. session_name)
          end
        else
          local project = action_state.get_selected_entry().value
          local session_name = sanitize_session_name(project.name)
          run_nvim_in_session(session_name, project.path)
          switch_tmux_session(session_name)
          print("Created and switched to session: " .. session_name)
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
      end,
    },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local session_name = action_state.get_selected_entry().value
        switch_tmux_session(session_name)
        print("Switched to session: " .. session_name)
        actions.close(prompt_bufnr)
      end)
      return true
    end,
  }):find()
end

function M.setup(opts)
  if opts.nvim_cmd then
    M.config.nvim_cmd = opts.nvim_cmd
  end

  -- Register commands
  vim.api.nvim_create_user_command(
    "WorkspaceOpen",
    function()
      if not opts.workspaces or #opts.workspaces == 0 then
        print("No workspaces configured")
        return
      end
      M.open_workspace_popup(opts.workspaces[1]) -- Adjust to support multiple workspaces
    end,
    { desc = "Create or switch to a Tmux session for a project" }
  )

  vim.api.nvim_create_user_command(
    "TmuxSessions",
    function()
      M.tmux_sessions()
    end,
    { desc = "Switch to an existing Tmux session" }
  )
end

return M



-- local M = {}
--
-- local pickers = require('telescope.pickers')
-- local finders = require('telescope.finders')
-- local conf = require('telescope.config').values
-- local actions = require('telescope.actions')
-- local action_state = require('telescope.actions.state')
--
-- M.config = {
--   nvim_cmd = "nvim"
-- }
--
-- local function is_tmux_running()
--   return vim.fn.exists('$TMUX') == 1
-- end
--
-- local function create_tmux_session(session_name, project_path)
--   os.execute("tmux new-session -ds " .. session_name .. " -c " .. project_path)
-- end
--
-- local function run_nvim_in_session(session_name, project_path)
--   local create_cmd = string.format("tmux new-session -ds %s -c %s", session_name, project_path)
--   os.execute(create_cmd)
--
--   local send_cmd = string.format("tmux send-keys -t %s '%s' Enter", session_name, M.config.nvim_cmd)
--   os.execute(send_cmd)
-- end
--
-- local function switch_tmux_session(session_name)
--   os.execute("tmux switch-client -t " .. session_name)
-- end
--
-- local function find_git_projects(workspace_path, max_depth)
--   local cmd = string.format(
--     "find %s -type d -name .git -prune -maxdepth %d ! -path '*/archive/*'",
--     workspace_path,
--     max_depth
--   )
--   local git_dirs = vim.fn.systemlist(cmd)
--   local projects = {}
--   for _, git_dir in ipairs(git_dirs) do
--     local project_path = vim.fn.fnamemodify(git_dir, ":h")
--     local project_name = vim.fn.fnamemodify(project_path, ":t")
--     local parent_dir = vim.fn.fnamemodify(project_path, ":h:t")
--     table.insert(projects, { name = project_name, path = project_path, parent = parent_dir })
--   end
--   table.sort(projects, function(a, b)
--     if a.parent:lower() == b.parent:lower() then
--       return a.name:lower() < b.name:lower()
--     end
--     return a.parent:lower() < b.parent:lower()
--   end)
--   return projects
-- end
--
-- function M.open_workspace_popup(workspace, _)
--   if not is_tmux_running() then
--     print("Not in a tmux session")
--     return
--   end
--
--   local projects = find_git_projects(workspace.path, 3)
--
--   pickers.new({}, {
--     prompt_title = "Select a project in " .. workspace.name,
--     finder = finders.new_table {
--       results = projects,
--       entry_maker = function(entry)
--         local display_width = vim.o.columns - 4
--         local column_width = math.floor((display_width - 20) / 2)
--         column_width = math.max(1, math.min(column_width, 50))
--         local name_format = "%-" .. column_width .. "." .. column_width .. "s"
--         local parent_format = "%-" .. column_width .. "." .. column_width .. "s"
--         return {
--           value = entry,
--           display = string.format(name_format .. "                    " .. parent_format, entry.name, entry.parent),
--           ordinal = entry.parent .. " " .. entry.name,
--         }
--       end
--     },
--     sorter = conf.generic_sorter({}),
--     attach_mappings = function(prompt_bufnr)
--       actions.select_default:replace(function()
--         local picker = action_state.get_current_picker(prompt_bufnr)
--         local selections = picker:get_multi_selection()
--
--         if #selections > 0 then
--           -- Multiple selections: create sessions in background
--           for _, selection in ipairs(selections) do
--             local project = selection.value
--             local session_name = string.lower(project.name):gsub("[^%w_]", "_")
--             create_tmux_session(session_name, project.path)
--             print("Created tmux session: " .. session_name)
--           end
--         else
--           -- Single selection: create session, send nvim command, and switch to it
--           local selection = action_state.get_selected_entry()
--           local project = selection.value
--           local session_name = string.lower(project.name):gsub("[^%w_]", "_")
--           run_nvim_in_session(session_name, project.path)
--           switch_tmux_session(session_name)
--           print("Created and switched to session: " .. session_name .. " with " .. M.config.nvim_cmd)
--         end
--
--         actions.close(prompt_bufnr)
--       end)
--
--       return true
--     end,
--   }):find()
-- end
--
-- function M.tmux_sessions()
--   if not is_tmux_running() then
--     print("Not in a tmux session")
--     return
--   end
--
--   local sessions = vim.fn.systemlist('tmux list-sessions -F "#{session_name}"')
--   table.sort(sessions, function(a, b) return a:lower() < b:lower() end)
--
--   pickers.new({}, {
--     prompt_title = "Switch Tmux Session",
--     finder = finders.new_table {
--       results = sessions,
--       entry_maker = function(entry)
--         return {
--           value = entry,
--           display = entry,
--           ordinal = entry,
--         }
--       end
--     },
--     sorter = conf.generic_sorter({}),
--     attach_mappings = function(prompt_bufnr)
--       actions.select_default:replace(function()
--         actions.close(prompt_bufnr)
--         local selection = action_state.get_selected_entry()
--         switch_tmux_session(selection.value)
--       end)
--       return true
--     end,
--   }):find()
-- end
--
-- function M.setup(opts)
--   if opts.nvim_cmd then
--     M.config.nvim_cmd = opts.nvim_cmd
--   end
--   M.workspaces = opts.workspaces or {}
-- end
--
-- return M
