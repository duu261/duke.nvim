local M = {}

local function emit(message, level, replace)
  local ok, notification = pcall(vim.notify, "duke.nvim: " .. message, level, {
    title = "duke.nvim",
    replace = replace,
  })
  if ok and notification ~= nil then
    return notification
  end
  return replace
end

local function new_handle(label, initial)
  local notification = emit(initial, vim.log.levels.INFO)
  local finished = false
  local handle = {}

  function handle.update(_, message)
    if finished then
      return
    end
    notification = emit(message, vim.log.levels.INFO, notification)
  end

  function handle.done(_, message)
    if finished then
      return
    end
    finished = true
    emit(message or (label .. " done"), vim.log.levels.INFO, notification)
  end

  function handle.fail(_, message)
    if finished then
      return
    end
    finished = true
    emit(message or (label .. " failed"), vim.log.levels.WARN, notification)
  end

  return handle
end

function M.task(label)
  return new_handle(label, label .. "...")
end

function M.batch(total, label)
  local count = 0
  local handle = new_handle(label, string.format("%s... 0/%d", label, total))

  function handle:next()
    if count >= total then
      return
    end
    count = count + 1
    self:update(string.format("%s... %d/%d", label, count, total))
  end

  return handle
end

return M
