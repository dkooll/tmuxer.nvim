local M = {}

local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')

local cached_column_width

M.config = {
  nvim_cmd = "nvim"
}

local function update_column_width()
  local display_width = vim.o.columns - 4
  cached_column_width = math.max(1, math.min(math.floor((display_width - 20) / 2), 50))
  return cached_column_width
end

local function is_tmux_running()
  return vim.fn.exists('$TMUX') == 1
end

local function create_tmux_session(session_name, project_path, callback)
  vim.fn.jobstart({"tmux", "new-session", "-ds", session_name, "-c", project_path}, {
    on_exit = function(_, _)
      if callback then callback() end
    end
  })
end

local function run_nvim_in_session(session_name, project_path, callback)
  create_tmux_session(session_name, project_path, function()
    vim.fn.jobstart({"tmux", "send-keys", "-t", session_name, M.config.nvim_cmd, "Enter"}, {
      on_exit = function(_, _)
        if callback then callback() end
      end
    })
  end)
end

local function switch_tmux_session(session_name)
  os.execute("tmux switch-client -t " .. session_name)
end

-- Optimized session merging function that uses a single tmux command
local function merge_sessions_fast(sessions)
  if #sessions == 0 then return end

  -- Create the merged session name
  local merged_name = "merged_" .. os.time()

  -- Build a single command that creates the session and joins all panes
  local cmd = {"tmux"}

  -- Start with creating the new session
  table.insert(cmd, "new-session")
  table.insert(cmd, "-d")
  table.insert(cmd, "-s")
  table.insert(cmd, merged_name)
  table.insert(cmd, ";")

  -- Calculate layout based on number of sessions
  local layout
  if #sessions <= 2 then
    layout = "even-vertical"
  elseif #sessions <= 4 then
    layout = "tiled"
  else
    layout = "tiled"  -- for more than 4, tiled works best
  end

  -- For each additional session, split and join in one go
  for i, session in ipairs(sessions) do
    if i > 1 then
      -- Split window with optimal layout
      table.insert(cmd, "split-window")
      table.insert(cmd, "-t")
      table.insert(cmd, merged_name)
      table.insert(cmd, "-f")  -- Full width/height split
      table.insert(cmd, ";")

      -- Move content from original session
      table.insert(cmd, "join-pane")
      table.insert(cmd, "-s")
      table.insert(cmd, session .. ":0.0")
      table.insert(cmd, "-t")
      table.insert(cmd, merged_name)
      table.insert(cmd, ";")
    else
      -- For first session, just join its content
      table.insert(cmd, "join-pane")
      table.insert(cmd, "-s")
      table.insert(cmd, session .. ":0.0")
      table.insert(cmd, "-t")
      table.insert(cmd, merged_name)
      table.insert(cmd, ";")
    end
  end

  -- Select the layout at the end
  table.insert(cmd, "select-layout")
  table.insert(cmd, "-t")
  table.insert(cmd, merged_name)
  table.insert(cmd, layout)

  -- Execute the combined command
  vim.fn.jobstart(cmd, {
    on_exit = function()
      -- Switch to the merged session
      switch_tmux_session(merged_name)
      print("Created merged session: " .. merged_name)
    end
  })
end

local function find_git_projects(workspace_path, max_depth)
  local has_fd = vim.fn.executable('fd') == 1
  local cmd
  if has_fd then
    cmd = string.format(
      "fd -H -t d '^.git$' %s -d %d --exclude 'archive' -x echo {//}",
      workspace_path,
      max_depth
    )
  else
    cmd = string.format(
      "find %s -type d -name .git -prune -maxdepth %d ! -path '*/archive/*' -exec dirname {} \\;",
      workspace_path,
      max_depth
    )
  end

  local found_paths = vim.fn.systemlist(cmd)
  local results = {}
  local path_sep = package.config:sub(1,1)
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
    if a.lower_parent == b.lower_parent then
      return a.lower_name < b.lower_name
    end
    return a.lower_parent < b.lower_parent
  end)

  return results
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

        actions.close(prompt_bufnr)

        if #selections > 0 then
          local completed = 0
          local total = #selections

          for _, selection in ipairs(selections) do
            local project = selection.value
            local session_name = string.lower(project.name):gsub("[^%w_]", "_")
            create_tmux_session(session_name, project.path, function()
              completed = completed + 1
              print(string.format("Created tmux session (%d/%d): %s", completed, total, session_name))
            end)
          end
        else
          local selection = action_state.get_selected_entry()
          local project = selection.value
          local session_name = string.lower(project.name):gsub("[^%w_]", "_")
          run_nvim_in_session(session_name, project.path, function()
            switch_tmux_session(session_name)
            print("Created and switched to session: " .. session_name .. " with " .. M.config.nvim_cmd)
          end)
        end
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
  table.sort(sessions)

  pickers.new({}, {
    prompt_title = "Select Sessions to Merge (Tab for multi-select)",
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
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selections = picker:get_multi_selection()
        actions.close(prompt_bufnr)

        if #selections > 0 then
          local selected_sessions = vim.tbl_map(function(selection)
            return selection.value
          end, selections)
          merge_sessions_fast(selected_sessions)
        else
          local selection = action_state.get_selected_entry()
          switch_tmux_session(selection.value)
        end
      end)
      return true
    end,
  }):find()
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  M.workspaces = opts.workspaces or {}

  update_column_width()

  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("TmuxerResize", { clear = true }),
    callback = update_column_width,
  })

  vim.api.nvim_create_user_command("WorkspaceOpen", function()
    if #M.workspaces == 1 then
      M.open_workspace_popup(M.workspaces[1])
    else
      pickers.new({}, {
        prompt_title = "Select Workspace",
        finder = finders.new_table {
          results = M.workspaces,
          entry_maker = function(entry)
            return {
              value = entry,
              display = entry.name,
              ordinal = entry.name,
            }
          end
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

-- local M = {}
--
-- local pickers = require('telescope.pickers')
-- local finders = require('telescope.finders')
-- local conf = require('telescope.config').values
-- local actions = require('telescope.actions')
-- local action_state = require('telescope.actions.state')
--
-- -- Column width cache for performance
-- local cached_column_width
--
-- M.config = {
--   nvim_cmd = "nvim"
-- }
--
-- -- Update column width based on current window size
-- local function update_column_width()
--   local display_width = vim.o.columns - 4
--   cached_column_width = math.max(1, math.min(math.floor((display_width - 20) / 2), 50))
--   return cached_column_width
-- end
--
-- local function is_tmux_running()
--   return vim.fn.exists('$TMUX') == 1
-- end
--
-- -- Async version of create_tmux_session
-- local function create_tmux_session(session_name, project_path, callback)
--   vim.fn.jobstart({"tmux", "new-session", "-ds", session_name, "-c", project_path}, {
--     on_exit = function(_, _)
--       if callback then
--         callback()
--       end
--     end
--   })
-- end
--
-- -- Async version of run_nvim_in_session
-- local function run_nvim_in_session(session_name, project_path, callback)
--   create_tmux_session(session_name, project_path, function()
--     vim.fn.jobstart({"tmux", "send-keys", "-t", session_name, M.config.nvim_cmd, "Enter"}, {
--       on_exit = function(_, _)
--         if callback then
--           callback()
--         end
--       end
--     })
--   end)
-- end
--
-- local function switch_tmux_session(session_name)
--   os.execute("tmux switch-client -t " .. session_name)
-- end
--
-- local function find_git_projects(workspace_path, max_depth)
--   -- Use fd if available for faster searching
--   local has_fd = vim.fn.executable('fd') == 1
--   local cmd
--   if has_fd then
--     cmd = string.format(
--       "fd -H -t d '^.git$' %s -d %d --exclude 'archive' -x echo {//}",
--       workspace_path,
--       max_depth
--     )
--   else
--     cmd = string.format(
--       "find %s -type d -name .git -prune -maxdepth %d ! -path '*/archive/*' -exec dirname {} \\;",
--       workspace_path,
--       max_depth
--     )
--   end
--
--   local found_paths = vim.fn.systemlist(cmd)
--   local results = {}
--
--   -- Pre-compile patterns for better performance
--   local path_sep = package.config:sub(1,1)
--   local parent_pattern = "([^" .. path_sep .. "]+)" .. path_sep .. "[^" .. path_sep .. "]+$"
--   local name_pattern = "[^" .. path_sep .. "]+$"
--
--   for _, project_path in ipairs(found_paths) do
--     local project_name = project_path:match(name_pattern)
--     local parent_dir = project_path:match(parent_pattern)
--     if project_name and parent_dir then
--       table.insert(results, {
--         name = project_name,
--         path = project_path,
--         parent = parent_dir,
--         lower_name = project_name:lower(),
--         lower_parent = parent_dir:lower()
--       })
--     end
--   end
--
--   -- Sort with pre-computed lowercase values
--   table.sort(results, function(a, b)
--     if a.lower_parent == b.lower_parent then
--       return a.lower_name < b.lower_name
--     end
--     return a.lower_parent < b.lower_parent
--   end)
--
--   return results
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
--         actions.close(prompt_bufnr)
--
--         if #selections > 0 then
--           -- Multiple selections: create sessions in background asynchronously
--           local completed = 0
--           local total = #selections
--
--           for _, selection in ipairs(selections) do
--             local project = selection.value
--             local session_name = string.lower(project.name):gsub("[^%w_]", "_")
--             create_tmux_session(session_name, project.path, function()
--               completed = completed + 1
--               print(string.format("Created tmux session (%d/%d): %s", completed, total, session_name))
--             end)
--           end
--         else
--           -- Single selection: create session, send nvim command, and switch to it
--           local selection = action_state.get_selected_entry()
--           local project = selection.value
--           local session_name = string.lower(project.name):gsub("[^%w_]", "_")
--           run_nvim_in_session(session_name, project.path, function()
--             switch_tmux_session(session_name)
--             print("Created and switched to session: " .. session_name .. " with " .. M.config.nvim_cmd)
--           end)
--         end
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
--   table.sort(sessions)
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
--   M.config = vim.tbl_deep_extend("force", M.config, opts or {})
--   M.workspaces = opts.workspaces or {}
--
--   -- Initial column width calculation
--   update_column_width()
--
--   -- Set up autocommand for window resize
--   vim.api.nvim_create_autocmd("VimResized", {
--     group = vim.api.nvim_create_augroup("TmuxerResize", { clear = true }),
--     callback = update_column_width,
--   })
--
--   -- Create commands
--   vim.api.nvim_create_user_command("WorkspaceOpen", function()
--     if #M.workspaces == 1 then
--       M.open_workspace_popup(M.workspaces[1])
--     else
--       -- Show workspace picker if multiple workspaces
--       pickers.new({}, {
--         prompt_title = "Select Workspace",
--         finder = finders.new_table {
--           results = M.workspaces,
--           entry_maker = function(entry)
--             return {
--               value = entry,
--               display = entry.name,
--               ordinal = entry.name,
--             }
--           end
--         },
--         sorter = conf.generic_sorter({}),
--         attach_mappings = function(prompt_bufnr)
--           actions.select_default:replace(function()
--             actions.close(prompt_bufnr)
--             local selection = action_state.get_selected_entry()
--             M.open_workspace_popup(selection.value)
--           end)
--           return true
--         end,
--       }):find()
--     end
--   end, {})
--
--   vim.api.nvim_create_user_command("TmuxSessions", M.tmux_sessions, {})
-- end
--
-- return M
