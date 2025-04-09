local M = {}

local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')

-- Column width cache for performance
local cached_column_width

M.config = {
  nvim_alias = "nvim", -- default
  layout_config = {
    height = 15,
    width = 80,
  },
  theme = nil,      -- Default theme (nil means no theme)
  previewer = true, -- Default previewer setting
}

-- Helper function to apply telescope theme if available
local function apply_theme(opts)
  opts = opts or {}

  -- If no theme specified, just return the basic config
  if not opts.theme and not M.config.theme then
    return {
      layout_config = vim.tbl_deep_extend("force", M.config.layout_config, (opts.layout_config or {}))
    }
  end

  -- Try to load telescope themes
  local status, themes = pcall(require, 'telescope.themes')
  if not status then
    -- Fallback if telescope.themes not available
    return {
      layout_config = vim.tbl_deep_extend("force", M.config.layout_config, (opts.layout_config or {}))
    }
  end

  -- Get theme name from options or config
  local theme_name = opts.theme or M.config.theme

  -- Build theme options
  local theme_opts = {
    layout_config = vim.tbl_deep_extend("force", M.config.layout_config, (opts.layout_config or {})),
    previewer = opts.previewer ~= nil and opts.previewer or M.config.previewer
  }

  -- Apply the appropriate theme
  if theme_name == "dropdown" then
    return themes.get_dropdown(theme_opts)
  elseif theme_name == "cursor" then
    return themes.get_cursor(theme_opts)
  elseif theme_name == "ivy" then
    return themes.get_ivy(theme_opts)
  else
    -- Default to no theme transformation
    return theme_opts
  end
end

-- Update column width based on current window size
local function update_column_width()
  local display_width = vim.o.columns - 4
  cached_column_width = math.max(1, math.min(math.floor((display_width - 20) / 2), 50))
  return cached_column_width
end

local function is_tmux_running()
  return vim.fn.exists('$TMUX') == 1
end
M.is_tmux_running = is_tmux_running

-- Async version of create_tmux_session
local function create_tmux_session(session_name, project_path, callback)
  vim.fn.jobstart({ "tmux", "new-session", "-ds", session_name, "-c", project_path }, {
    on_exit = function(_, _)
      if callback then
        callback()
      end
    end
  })
end

-- Async version of run_nvim_in_session
local function run_nvim_in_session(session_name, project_path, callback)
  create_tmux_session(session_name, project_path, function()
    vim.fn.jobstart({ "tmux", "send-keys", "-t", session_name, M.config.nvim_alias, "Enter" }, {
      on_exit = function(_, _)
        if callback then
          callback()
        end
      end
    })
  end)
end
M.run_nvim_in_session = run_nvim_in_session

local function switch_tmux_session(session_name)
  os.execute("tmux switch-client -t " .. session_name)
end
M.switch_tmux_session = switch_tmux_session

local function find_git_projects(workspace_path, max_depth)
  -- Use fd if available for faster searching
  local has_fd = vim.fn.executable('fd') == 1
  local cmd
  if has_fd then
    cmd = string.format(
      "fd -H -t d '^.git$' %s -d %d --exclude 'archive' -x echo {//}",
      workspace_path,
      max_depth + 1
    )
  else
    cmd = string.format(
    -- Else use find
      "find %s -maxdepth %d -type d -name .git -prune ! -path '*/archive/*' -exec dirname {} \\;",
      workspace_path,
      max_depth + 1
    )
  end

  local found_paths = vim.fn.systemlist(cmd)
  local results = {}

  -- Pre-compile patterns for better performance
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

  -- Sort with pre-computed lowercase values
  table.sort(results, function(a, b)
    if a.lower_parent == b.lower_parent then
      return a.lower_name < b.lower_name
    end
    return a.lower_parent < b.lower_parent
  end)

  return results
end
M.find_git_projects = find_git_projects

-- function M.open_workspace_popup(workspace, opts)
--   if not is_tmux_running() then
--     print("Not in a tmux session")
--     return
--   end
--
--   local projects = find_git_projects(workspace.path, M.config.max_depth)
--
--   -- Apply theme to picker
--   local picker_opts = apply_theme(opts)
--
--   pickers.new(picker_opts, {
--     prompt_title = "Select a project in " .. workspace.name,
--     finder = finders.new_table {
--       results = projects,
--       entry_maker = function(entry)
--         local display_width = vim.o.columns - 4
--         local column_width = math.floor((display_width - 20) / 2)
--         column_width = math.max(1, math.min(column_width, 50))
--         local name_format = "%-" .. column_width .. "." .. column_width .. "s"
--         local parent_format = "%-" .. column_width .. "." .. column_width .. "s"
--
--         -- Increase the spacing between columns (from 5 spaces to 15 spaces)
--         return {
--           value = entry,
--           display = string.format(name_format .. "               " .. parent_format, entry.name, entry.parent),
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
--           local completed = 0
--           local total = #selections
--
--           for _, selection in ipairs(selections) do
--             local project = selection.value
--             local session_name = string.lower(project.name):gsub("[^%w_]", "_")
--
--             run_nvim_in_session(session_name, project.path, function()
--               completed = completed + 1
--               print(string.format("Created tmux session with nvim (%d/%d): %s", completed, total, session_name))
--             end)
--           end
--         else
--           local selection = action_state.get_selected_entry()
--           local project = selection.value
--           local session_name = string.lower(project.name):gsub("[^%w_]", "_")
--           run_nvim_in_session(session_name, project.path, function()
--             switch_tmux_session(session_name)
--             print("Created and switched to session: " .. session_name .. " with " .. M.config.nvim_alias)
--           end)
--         end
--       end)
--
--       return true
--     end,
--   }):find()
-- end

function M.open_workspace_popup(workspace, opts)
  if not is_tmux_running() then
    print("Not in a tmux session")
    return
  end

  local projects = find_git_projects(workspace.path, M.config.max_depth)

  -- Apply theme to picker
  local picker_opts = apply_theme(opts)

  pickers.new(picker_opts, {
    prompt_title = "Select a project in " .. workspace.name,
    finder = finders.new_table {
      results = projects,
      entry_maker = function(entry)
        -- Create a single string with a separator
        local display_string = entry.name .. "/" .. entry.parent

        return {
          value = entry,
          display = display_string,
          ordinal = entry.parent .. " " .. entry.name,
          -- Store the name length for highlighting
          name_length = #entry.name,
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

            run_nvim_in_session(session_name, project.path, function()
              completed = completed + 1
              print(string.format("Created tmux session with nvim (%d/%d): %s", completed, total, session_name))
            end)
          end
        else
          local selection = action_state.get_selected_entry()
          local project = selection.value
          local session_name = string.lower(project.name):gsub("[^%w_]", "_")
          run_nvim_in_session(session_name, project.path, function()
            switch_tmux_session(session_name)
            print("Created and switched to session: " .. session_name .. " with " .. M.config.nvim_alias)
          end)
        end
      end)

      return true
    end,
    -- Add custom highlighting for the project name
    make_entry = {
      display = function(entry)
        -- Apply custom highlighting to the project name (first part)
        -- The #9E8069 color is approximated using a named highlight group
        return entry.display, {
          {{{ 0, entry.name_length }, "Special"}}, -- This will be close to your desired color or can be customized
        }
      end,
    },
  }):find()
end

local function get_non_current_tmux_sessions()
  local sessions_output = vim.fn.systemlist(
    'tmux list-sessions -F "#{?session_attached,1,0} #{session_name}"'
  )
  local sessions = {}

  for _, line in ipairs(sessions_output) do
    local is_current, name = line:match("^(%d)%s+(.+)$")
    if name and is_current == "0" then
      table.insert(sessions, name)
    end
  end

  return sessions
end
M.get_non_current_tmux_sessions = get_non_current_tmux_sessions

function M.tmux_sessions(opts)
  if not is_tmux_running() then
    print("Not in a tmux session")
    return
  end

  local sessions = get_non_current_tmux_sessions()
  table.sort(sessions)

  -- Apply theme to picker
  local picker_opts = apply_theme(opts)

  pickers.new(picker_opts, {
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
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        switch_tmux_session(selection.value)
      end)

      map("i", "<C-d>", function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selections = picker:get_multi_selection()
        local sessions_to_kill = {}

        -- Collect sessions to delete
        if #selections > 0 then
          for _, sel in ipairs(selections) do
            table.insert(sessions_to_kill, sel.value)
          end
        else
          local selection = action_state.get_selected_entry()
          if not selection then return end
          table.insert(sessions_to_kill, selection.value)
        end

        -- Kill sessions
        for _, session in ipairs(sessions_to_kill) do
          os.execute("tmux kill-session -t " .. vim.fn.shellescape(session))
        end

        -- Only refresh if buffer is still valid
        if vim.api.nvim_buf_is_valid(prompt_bufnr) then
          local new_sessions = get_non_current_tmux_sessions()
          table.sort(new_sessions)

          if #new_sessions == 0 then
            actions.close(prompt_bufnr)
            return
          end

          local new_finder = finders.new_table({
            results = new_sessions,
            entry_maker = function(entry)
              return {
                value = entry,
                display = entry,
                ordinal = entry,
              }
            end
          })

          -- Schedule refresh to avoid race conditions
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(prompt_bufnr) then
              picker:refresh(new_finder, {
                reset_prompt = true,
                new_prefix = picker.prompt_prefix
              })
            end
          end)
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
      -- Apply theme to the workspace picker too
      local picker_opts = apply_theme()

      pickers.new(picker_opts, {
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
--   nvim_alias = "nvim", -- default
--   layout_config = {
--     height = 15,
--     width = 80,
--   }
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
--   vim.fn.jobstart({ "tmux", "new-session", "-ds", session_name, "-c", project_path }, {
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
--     vim.fn.jobstart({ "tmux", "send-keys", "-t", session_name, M.config.nvim_alias, "Enter" }, {
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
--       max_depth + 1
--     )
--   else
--     cmd = string.format(
--     -- Else use find
--       "find %s -maxdepth %d -type d -name .git -prune ! -path '*/archive/*' -exec dirname {} \\;",
--       workspace_path,
--       max_depth + 1
--     )
--   end
--
--   local found_paths = vim.fn.systemlist(cmd)
--   local results = {}
--
--   -- Pre-compile patterns for better performance
--   local path_sep = package.config:sub(1, 1)
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
--   local projects = find_git_projects(workspace.path, M.config.max_depth)
--
--   pickers.new({
--     layout_config = M.config.layout_config
--   }, {
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
--           display = string.format(name_format .. "     " .. parent_format, entry.name, entry.parent),
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
--           local completed = 0
--           local total = #selections
--
--           for _, selection in ipairs(selections) do
--             local project = selection.value
--             local session_name = string.lower(project.name):gsub("[^%w_]", "_")
--
--             run_nvim_in_session(session_name, project.path, function()
--               completed = completed + 1
--               print(string.format("Created tmux session with nvim (%d/%d): %s", completed, total, session_name))
--             end)
--           end
--         else
--           local selection = action_state.get_selected_entry()
--           local project = selection.value
--           local session_name = string.lower(project.name):gsub("[^%w_]", "_")
--           run_nvim_in_session(session_name, project.path, function()
--             switch_tmux_session(session_name)
--             print("Created and switched to session: " .. session_name .. " with " .. M.config.nvim_alias)
--           end)
--         end
--       end)
--
--       return true
--     end,
--   }):find()
-- end
--
-- local function get_non_current_tmux_sessions()
--   local sessions_output = vim.fn.systemlist(
--     'tmux list-sessions -F "#{?session_attached,1,0} #{session_name}"'
--   )
--   local sessions = {}
--
--   for _, line in ipairs(sessions_output) do
--     local is_current, name = line:match("^(%d)%s+(.+)$")
--     if name and is_current == "0" then
--       table.insert(sessions, name)
--     end
--   end
--
--   return sessions
-- end
--
-- function M.tmux_sessions()
--   if not is_tmux_running() then
--     print("Not in a tmux session")
--     return
--   end
--
--   local sessions = get_non_current_tmux_sessions()
--   table.sort(sessions)
--
--   pickers.new({
--     layout_config = M.config.layout_config
--   }, {
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
--     attach_mappings = function(prompt_bufnr, map)
--       actions.select_default:replace(function()
--         actions.close(prompt_bufnr)
--         local selection = action_state.get_selected_entry()
--         switch_tmux_session(selection.value)
--       end)
--
--       map("i", "<C-d>", function()
--         local picker = action_state.get_current_picker(prompt_bufnr)
--         local selections = picker:get_multi_selection()
--         local sessions_to_kill = {}
--
--         -- Collect sessions to delete
--         if #selections > 0 then
--           for _, sel in ipairs(selections) do
--             table.insert(sessions_to_kill, sel.value)
--           end
--         else
--           local selection = action_state.get_selected_entry()
--           if not selection then return end
--           table.insert(sessions_to_kill, selection.value)
--         end
--
--         -- Kill sessions
--         for _, session in ipairs(sessions_to_kill) do
--           os.execute("tmux kill-session -t " .. vim.fn.shellescape(session))
--         end
--
--         -- Only refresh if buffer is still valid
--         if vim.api.nvim_buf_is_valid(prompt_bufnr) then
--           local new_sessions = get_non_current_tmux_sessions()
--           table.sort(new_sessions)
--
--           if #new_sessions == 0 then
--             actions.close(prompt_bufnr)
--             return
--           end
--
--           local new_finder = finders.new_table({
--             results = new_sessions,
--             entry_maker = function(entry)
--               return {
--                 value = entry,
--                 display = entry,
--                 ordinal = entry,
--               }
--             end
--           })
--
--           -- Schedule refresh to avoid race conditions
--           vim.schedule(function()
--             if vim.api.nvim_buf_is_valid(prompt_bufnr) then
--               picker:refresh(new_finder, {
--                 reset_prompt = true,
--                 new_prefix = picker.prompt_prefix
--               })
--             end
--           end)
--         end
--       end)
--
--       return true
--     end,
--   }):find()
-- end
--
-- function M.setup(opts)
--   M.config = vim.tbl_deep_extend("force", M.config, opts or {})
--   M.workspaces = opts.workspaces or {}
--
--   update_column_width()
--
--   vim.api.nvim_create_autocmd("VimResized", {
--     group = vim.api.nvim_create_augroup("TmuxerResize", { clear = true }),
--     callback = update_column_width,
--   })
--
--   vim.api.nvim_create_user_command("WorkspaceOpen", function()
--     if #M.workspaces == 1 then
--       M.open_workspace_popup(M.workspaces[1])
--     else
--       pickers.new({
--         layout_config = M.config.layout_config
--       }, {
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
