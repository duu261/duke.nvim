local M = {}

local function absolute(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function contained(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function scan(directory, files)
  local handle = vim.uv.fs_scandir(directory)
  if not handle then
    return
  end
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local path = vim.fs.joinpath(directory, name)
    if kind == "directory" then
      scan(path, files)
    elseif kind == "file" or kind == "link" then
      files[#files + 1] = path
    end
  end
end

local function metadata(path, scope)
  local name = vim.fs.basename(path)
  local stem, extension = name:match("^(application[^.]*)%.([^.]+)$")
  if not stem or (extension ~= "properties" and extension ~= "yml" and extension ~= "yaml") then
    return nil
  end
  local profile = stem:match("^application%-(.+)$")
  return {
    path = path,
    scope = scope,
    format = extension == "properties" and "properties" or "yaml",
    profile = profile,
  }
end

function M.inspect(module)
  local root = absolute(assert(module.root, "module root is required"))
  local files = {}
  local diagnostics = {}
  local formats = {}

  for _, source in ipairs({
    { relative = "src/main/resources", scope = "main" },
    { relative = "src/test/resources", scope = "test" },
  }) do
    local resources = vim.fs.joinpath(root, source.relative)
    local candidates = {}
    scan(resources, candidates)
    for _, candidate in ipairs(candidates) do
      local real = vim.uv.fs_realpath(candidate)
      if real then
        real = vim.fs.normalize(real)
        if contained(real, resources) then
          local entry = metadata(real, source.scope)
          if entry then
            files[#files + 1] = entry
            formats[entry.format] = true
          end
        else
          diagnostics[#diagnostics + 1] = {
            code = "outside_resources",
            severity = "warning",
            message = "ignored Spring configuration outside module resources: " .. candidate,
          }
        end
      end
    end
  end

  table.sort(files, function(left, right)
    if left.scope ~= right.scope then
      return left.scope < right.scope
    end
    if (left.profile == nil) ~= (right.profile == nil) then
      return left.profile == nil
    end
    return left.path < right.path
  end)
  if formats.properties and formats.yaml then
    diagnostics[#diagnostics + 1] = {
      code = "mixed_formats",
      severity = "warning",
      message = "mixed Spring properties and YAML configuration may obscure precedence",
    }
  end

  return {
    files = files,
    diagnostics = diagnostics,
  }
end

return M
