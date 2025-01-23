local M = {}

local pickers = require('telescope.pickers')
local finders = require('telescope.finders')
local conf = require('telescope.config').values
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')

-- Configuration defaults
M.config = {
  nvim_alias = "nvim",
  status_icons = {
    active = "●",
    background = "○"
  },
  colors = {
    active = "\27[38;2;152;190;101m",   -- Green: #98be65
    background = "\27[38;2;127;140;141m" -- Gray: #7f8c8d
  },
  layout_config = {
    height = 15,
    width = 80,
  }
}

-- Helper functions
local function is_tmux_running()
  return vim.fn.exists('$TMUX') == 1
end

local function format_duration(seconds)
  local units = {
    { "y", 31536000 },
    { "mo", 2592000 },
    { "w", 604800 },
    { "d", 86400 },
    { "h", 3600 },
    { "m", 60 },
    { "now", 1 }
  }

  seconds = math.max(seconds, 0)

  for _, unit in ipairs(units) do
    if seconds >= unit[2] then
      local value = math.floor(seconds / unit[2])
      return (unit[1] == "now" and "just now") or string.format("%d%s ago", value, unit[1])
    end
  end
  return "just now"
end

local function get_session_metadata(session_name)
  local metadata = {
    windows = 0,
    last_used = "never",
    status = "background"
  }

  -- Get session status
  local clients = vim.fn.systemlist("tmux list-clients -t "..vim.fn.shellescape(session_name).." 2>/dev/null")
  if #clients > 0 then
    metadata.status = "active"
  end

  -- Get window count
  local windows = vim.fn.systemlist("tmux list-windows -t "..vim.fn.shellescape(session_name).." | wc -l")
  metadata.windows = tonumber(windows[1]) or 0

  -- Get last activity time
  local timestamp = tonumber(vim.fn.system(
    "tmux display-message -p -t "..vim.fn.shellescape(session_name).." '#{session_activity}' 2>/dev/null"
  )) or os.time()

  local diff = os.time() - timestamp
  metadata.last_used = format_duration(diff)

  return metadata
end

-- Tmux session management
local function switch_tmux_session(session_name)
  os.execute("tmux switch-client -t " .. vim.fn.shellescape(session_name))
end

local function create_tmux_session(session_name, project_path, callback)
  vim.fn.jobstart({ "tmux", "new-session", "-ds", session_name, "-c", project_path }, {
    on_exit = function(_, _) if callback then callback() end end
  })
end

local function run_nvim_in_session(session_name, project_path, callback)
  create_tmux_session(session_name, project_path, function()
    vim.fn.jobstart({ "tmux", "send-keys", "-t", session_name, M.config.nvim_alias, "Enter" }, {
      on_exit = function(_, _) if callback then callback() end end
    })
  end)
end

-- Project finding functionality
local function find_git_projects(workspace_path, max_depth)
  local has_fd = vim.fn.executable('fd') == 1
  local cmd = has_fd
    and string.format("fd -H -t d '^.git$' %s -d %d --exclude 'archive' -x echo {//}", workspace_path, max_depth)
    or string.format("find %s -type d -name .git -prune -maxdepth %d ! -path '*/archive/*' -exec dirname {} \\;", workspace_path, max_depth)

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

-- Telescope pickers
function M.open_workspace_popup(workspace, _)
  if not is_tmux_running() then
    print("Not in a tmux session")
    return
  end

  local projects = find_git_projects(workspace.path, 3)

  pickers.new({
    layout_config = M.config.layout_config
  }, {
    prompt_title = "Select a project in " .. workspace.name,
    finder = finders.new_table {
      results = projects,
      entry_maker = function(entry)
        local display_width = vim.o.columns - 4
        local column_width = math.floor((display_width - 20) / 2)
        column_width = math.max(1, math.min(column_width, 50))
        return {
          value = entry,
          display = string.format("%-"..column_width.."s     %-"..column_width.."s", entry.name, entry.parent),
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
  }):find()
end

function M.tmux_sessions()
  if not is_tmux_running() then
    print("Not in a tmux session")
    return
  end

  local sessions = vim.fn.systemlist('tmux list-sessions -F "#{session_name}"')
  table.sort(sessions)

  pickers.new({
    layout_config = M.config.layout_config
  }, {
    prompt_title = "Switch Tmux Session",
    finder = finders.new_table {
      results = sessions,
      entry_maker = function(entry)
        local meta = get_session_metadata(entry)
        local status_icon = meta.status == "active"
          and M.config.colors.active..M.config.status_icons.active.."\27[0m"
          or M.config.colors.background..M.config.status_icons.background.."\27[0m"

        return {
          value = entry,
          display = string.format(
            "%-20s %s %-9s Windows: %-2d Last Used: %s",
            entry,
            status_icon,
            meta.status:gsub("^%l", string.upper),
            meta.windows,
            meta.last_used
          ),
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

        if #selections > 0 then
          for _, sel in ipairs(selections) do
            table.insert(sessions_to_kill, sel.value)
          end
        else
          local selection = action_state.get_selected_entry()
          if not selection then return end
          table.insert(sessions_to_kill, selection.value)
        end

        for _, session in ipairs(sessions_to_kill) do
          os.execute("tmux kill-session -t " .. vim.fn.shellescape(session))
        end

        if vim.api.nvim_buf_is_valid(prompt_bufnr) then
          local new_sessions = vim.fn.systemlist('tmux list-sessions -F "#{session_name}"')
          table.sort(new_sessions)

          if #new_sessions == 0 then
            actions.close(prompt_bufnr)
            return
          end

          local new_finder = finders.new_table({
            results = new_sessions,
            entry_maker = function(entry)
              local meta = get_session_metadata(entry)
              local status_icon = meta.status == "active"
                and M.config.colors.active..M.config.status_icons.active.."\27[0m"
                or M.config.colors.background..M.config.status_icons.background.."\27[0m"

              return {
                value = entry,
                display = string.format(
                  "%-20s %s %-9s Windows: %-2d Last Used: %s",
                  entry,
                  status_icon,
                  meta.status:gsub("^%l", string.upper),
                  meta.windows,
                  meta.last_used
                ),
                ordinal = entry,
              }
            end
          })

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

  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("TmuxerResize", { clear = true }),
    callback = function()
      M.config.layout_config.width = math.floor(vim.o.columns * 0.8)
      M.config.layout_config.height = math.floor(vim.o.lines * 0.6)
    end
  })

  vim.api.nvim_create_user_command("WorkspaceOpen", function()
    if #M.workspaces == 1 then
      M.open_workspace_popup(M.workspaces[1])
    else
      pickers.new({
        layout_config = M.config.layout_config
      }, {
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
--   local projects = find_git_projects(workspace.path, 3)
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
-- function M.tmux_sessions()
--   if not is_tmux_running() then
--     print("Not in a tmux session")
--     return
--   end
--
--   local sessions = vim.fn.systemlist('tmux list-sessions -F "#{session_name}"')
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
--           local new_sessions = vim.fn.systemlist('tmux list-sessions -F "#{session_name}"')
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
