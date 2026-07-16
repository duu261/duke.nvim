local M = {}

function M.command(project_dir, prefix, entry_file)
  local command = {}
  local expanded = false
  for _, argument in ipairs(prefix or {}) do
    local value, project_count = argument:gsub("%{project%}", function()
      return project_dir
    end)
    local file_count
    value, file_count = value:gsub("%{file%}", function()
      return entry_file or project_dir
    end)
    expanded = expanded or project_count > 0 or file_count > 0
    command[#command + 1] = value
  end
  if not expanded then
    command[#command + 1] = project_dir
  end
  return command
end

function M.open(project_dir, opts, callback, entry_file)
  if not opts.enabled then
    callback(nil, false)
    return
  end
  if type(opts.command) ~= "table" or #opts.command == 0 then
    callback("handoff command not configured", false)
    return
  end
  if vim.fn.executable(opts.command[1]) ~= 1 then
    callback(opts.command[1] .. " executable not found", false)
    return
  end

  local command = M.command(project_dir, opts.command, entry_file)
  require("duke.process").run(command[1], vim.list_slice(command, 2), {}, function(result)
    if result.code ~= 0 then
      callback("project handoff failed: " .. require("duke.process").detail(result), false)
      return
    end
    callback(nil, true)
  end)
end

return M
