local M = {}

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

return M
