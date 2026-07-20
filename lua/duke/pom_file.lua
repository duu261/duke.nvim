local bit = require("bit")

local M = {}

local function same_lines(left, right)
  if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
    return false
  end
  for index, line in ipairs(left) do
    if right[index] ~= line then
      return false
    end
  end
  return true
end

local function sibling_path(path)
  local bytes, random_err = vim.uv.random(8)
  if not bytes then
    return nil, random_err
  end
  local encoded = {}
  for index = 1, #bytes do
    encoded[index] = string.format("%02x", bytes:byte(index))
  end
  return path .. ".duke-" .. table.concat(encoded)
end

function M.read(path)
  local buffer = vim.fn.bufnr(path)
  if buffer ~= -1 and vim.api.nvim_buf_is_loaded(buffer) then
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, buffer, 0, -1, false)
    if not ok then
      return nil, nil, nil, "cannot read " .. path .. ": " .. tostring(lines)
    end
    return lines, buffer, vim.bo[buffer].modified
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, nil, nil, "cannot read " .. path .. ": " .. tostring(lines)
  end
  return lines
end

function M.save(path, lines, buffer, was_modified)
  local ok, saved_or_error = pcall(function()
    if buffer then
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
      if was_modified then
        return false
      end
      vim.api.nvim_buf_call(buffer, function()
        -- A plugin edit is not a user save: skip write autocommands so a
        -- format-on-save chain cannot reformat the POM around our one-line
        -- change and bury it in an unreviewable diff.
        vim.cmd("silent noautocmd write")
      end)
      return true
    end
    if vim.fn.writefile(lines, path) ~= 0 then
      error("write failed")
    end
    return true
  end)
  if not ok then
    return nil, "cannot write " .. path .. ": " .. tostring(saved_or_error)
  end
  return saved_or_error
end

function M.snapshot(path)
  local lines, buffer, modified, err = M.read(path)
  if not lines then
    return nil, err
  end
  return {
    path = path,
    lines = lines,
    buffer = buffer,
    modified = modified == true,
  }
end

function M.replace(snapshot, lines)
  if type(snapshot) ~= "table" or type(snapshot.path) ~= "string" or type(lines) ~= "table" then
    return nil, "invalid POM replacement"
  end
  local current, current_err = M.snapshot(snapshot.path)
  if not current then
    return nil, current_err
  end
  if
    not same_lines(current.lines, snapshot.lines)
    or current.buffer ~= snapshot.buffer
    or current.modified ~= snapshot.modified
  then
    return nil, "cannot write " .. snapshot.path .. ": stale POM snapshot"
  end
  if current.buffer then
    local saved, save_err = M.save(snapshot.path, lines, current.buffer, current.modified)
    if saved == nil then
      local buffer_ok, current_lines =
        pcall(vim.api.nvim_buf_get_lines, current.buffer, 0, -1, false)
      if buffer_ok and same_lines(current_lines, lines) then
        pcall(vim.api.nvim_buf_set_lines, current.buffer, 0, -1, false, snapshot.lines)
      end
    end
    return saved, save_err
  end

  local temporary, temporary_err = sibling_path(snapshot.path)
  if not temporary then
    return nil, "cannot create sibling POM temporary: " .. tostring(temporary_err)
  end
  local function cleanup()
    pcall(vim.fn.delete, temporary)
  end
  local ok, write_err = pcall(function()
    local stat, stat_err = vim.uv.fs_stat(snapshot.path)
    if not stat then
      error(stat_err)
    end
    if vim.fn.writefile(lines, temporary) ~= 0 then
      error("temporary write failed")
    end
    local chmod_ok, chmod_err = vim.uv.fs_chmod(temporary, bit.band(stat.mode, 511))
    if not chmod_ok then
      error(chmod_err)
    end
    local latest, latest_err = M.snapshot(snapshot.path)
    if
      not latest
      or not same_lines(latest.lines, current.lines)
      or latest.buffer ~= current.buffer
      or latest.modified ~= current.modified
    then
      error(latest_err or "stale POM snapshot before rename")
    end
    local renamed, rename_err = vim.uv.fs_rename(temporary, snapshot.path)
    if not renamed then
      error(rename_err)
    end
  end)
  cleanup()
  if not ok then
    return nil, "cannot write " .. snapshot.path .. ": " .. tostring(write_err)
  end
  return true
end

return M
