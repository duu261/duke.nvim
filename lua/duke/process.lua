local M = {}

local function report_callback_error(err)
  require("duke.log").add("ERROR", "process callback failed: " .. tostring(err))
  vim.notify("duke.nvim: internal callback failed; run :DukeLog", vim.log.levels.ERROR)
end

function M.detail(result, fallback)
  for _, value in ipairs({ result.stderr or "", result.stdout or "" }) do
    local detail = vim.trim(value)
    if detail ~= "" then
      return detail
    end
  end
  return fallback or "unknown error"
end

function M.run(command, args, opts, callback)
  opts = opts or {}
  local command_args = { command }
  vim.list_extend(command_args, args or {})

  require("duke.log").add("DEBUG", "run: " .. table.concat(command_args, " "))

  local started, handle = pcall(vim.system, command_args, {
    cwd = opts.cwd,
    env = opts.env,
    stdin = opts.stdin,
    text = true,
    timeout = opts.timeout,
  }, function(result)
    vim.schedule(function()
      local ok, err = pcall(callback or function() end, result)
      if not ok then
        report_callback_error(err)
      end
    end)
  end)
  if not started then
    vim.schedule(function()
      local ok, err = pcall(callback or function() end, {
        code = -1,
        signal = 0,
        stdout = "",
        stderr = tostring(handle),
      })
      if not ok then
        report_callback_error(err)
      end
    end)
    return nil
  end
  return handle
end

return M
