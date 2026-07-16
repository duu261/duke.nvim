local M = {}

local function random_hex(bytes)
  local value, err = vim.uv.random(bytes)
  if not value then
    return nil, err
  end
  return (value:gsub(".", function(char)
    return string.format("%02x", string.byte(char))
  end))
end

function M.make_staging(parent)
  for _ = 1, 8 do
    local suffix, random_error = random_hex(8)
    if not suffix then
      return nil, "cannot create random staging name: " .. tostring(random_error)
    end
    local path = vim.fs.joinpath(parent, ".duke-" .. suffix)
    local created, mkdir_error = vim.uv.fs_mkdir(path, 448)
    if created then
      return path
    end
    if not tostring(mkdir_error):match("EEXIST") then
      return nil, "cannot create staging directory: " .. tostring(mkdir_error)
    end
  end
  return nil, "cannot allocate unique staging directory"
end

function M.cleanup(path)
  if path then
    pcall(vim.fn.delete, path, "rf")
  end
end

function M.promote(staged, target)
  if vim.uv.fs_stat(target) then
    return nil, "target already exists: " .. target
  end
  local renamed, rename_error = vim.uv.fs_rename(staged, target)
  if not renamed then
    return nil, "cannot finalize project: " .. tostring(rename_error)
  end
  return true
end

return M
