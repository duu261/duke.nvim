local M = {}

function M.log(level, message)
  local ok, logger = pcall(require, "duke.log")
  if ok and type(logger.add) == "function" then
    pcall(logger.add, level, message)
  end
end

function M.once(callback, context)
  local called = false
  return function(err, result)
    if called then
      return
    end
    called = true
    local invoke = function()
      local ok, callback_err = pcall(callback, err, result)
      if not ok then
        M.log("ERROR", context .. " callback failed: " .. tostring(callback_err))
      end
    end
    local scheduled, schedule_err = pcall(vim.schedule, invoke)
    if not scheduled then
      M.log("ERROR", context .. " scheduling failed: " .. tostring(schedule_err))
      invoke()
    end
  end
end

function M.guard_once(handler, on_error, context)
  local called = false
  return function(...)
    if called then
      return
    end
    called = true
    local ok, err = pcall(handler, ...)
    if ok then
      return
    end
    local recovered, recovery_err = pcall(on_error, err)
    if not recovered then
      M.log("ERROR", context .. " recovery failed: " .. tostring(recovery_err))
    end
  end
end

return M
