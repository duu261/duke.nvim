local pom = require("duke.pom")
local pom_file = require("duke.pom_file")
local spring_config = require("duke.spring_config")

local M = {}

local function absolute(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function real_or_absolute(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or absolute(path))
end

local function contained(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function diagnostic(code, message, severity)
  return {
    code = code,
    message = message,
    severity = severity or "warning",
  }
end

local function first_file(directory, names)
  for _, name in ipairs(names) do
    local path = vim.fs.joinpath(directory, name)
    if vim.uv.fs_stat(path) then
      return path
    end
  end
end

local function read_model(path)
  local lines, buffer, modified, read_err = pom_file.read(path)
  if not lines then
    return nil, read_err
  end
  local model, model_err = pom.model(lines)
  if not model then
    return nil, model_err
  end
  return {
    buffer = buffer,
    lines = lines,
    model = model,
    modified = modified == true,
  }
end

local function parent_reactor(directory)
  local parent_start = vim.fs.dirname(directory)
  if not parent_start or parent_start == directory then
    return nil
  end
  local parent_pom = vim.fs.find("pom.xml", { path = parent_start, upward = true })[1]
  if not parent_pom then
    return nil
  end
  local loaded = read_model(parent_pom)
  if not loaded then
    return nil
  end
  local parent_root = real_or_absolute(vim.fs.dirname(parent_pom))
  for _, module in ipairs(loaded.model.modules) do
    if real_or_absolute(vim.fs.joinpath(parent_root, module.path)) == directory then
      return parent_root
    end
  end
end

local function maven_root(nearest_pom)
  local root = real_or_absolute(vim.fs.dirname(nearest_pom))
  while true do
    local parent = parent_reactor(root)
    if not parent or parent == root then
      return root
    end
    root = parent
  end
end

local function inspect_maven(root, input_path)
  local modules = {}
  local dependencies = {}
  local configuration = {}
  local diagnostics = {}
  local visited = {}

  local function visit(directory)
    directory = real_or_absolute(directory)
    if not contained(directory, root) then
      diagnostics[#diagnostics + 1] = diagnostic(
        "outside_reactor",
        "Maven module outside reactor ignored: " .. directory,
        "error"
      )
      return
    end
    if visited[directory] then
      diagnostics[#diagnostics + 1] = diagnostic(
        "duplicate_module",
        "duplicate or cyclic Maven module path ignored: " .. directory
      )
      return
    end
    visited[directory] = true

    local path = vim.fs.joinpath(directory, "pom.xml")
    if not vim.uv.fs_stat(path) then
      diagnostics[#diagnostics + 1] =
        diagnostic("missing_module", "missing Maven module POM: " .. path)
      return
    end
    local loaded, err = read_model(path)
    if not loaded then
      diagnostics[#diagnostics + 1] = diagnostic("invalid_module", path .. ": " .. err, "error")
      return
    end

    local id = loaded.model.coordinates.group_id .. ":" .. loaded.model.coordinates.artifact_id
    local module = {
      id = id,
      root = directory,
      build_file = path,
      kind = "maven",
      modified = loaded.modified,
      model = loaded.model,
    }
    modules[#modules + 1] = module
    for _, dependency in ipairs(loaded.model.dependencies) do
      dependencies[#dependencies + 1] = {
        coordinate = dependency.coordinate,
        module_id = id,
        scope = dependency.scope,
        version = dependency.version,
      }
    end
    local config = spring_config.inspect(module)
    for _, file in ipairs(config.files) do
      file.module_id = id
      configuration[#configuration + 1] = file
    end
    vim.list_extend(diagnostics, config.diagnostics)

    for _, child in ipairs(loaded.model.modules) do
      visit(vim.fs.joinpath(directory, child.path))
    end
  end

  visit(root)
  table.sort(modules, function(left, right)
    return left.root < right.root
  end)
  table.sort(configuration, function(left, right)
    return left.path < right.path
  end)

  local active
  local best_length = -1
  for _, module in ipairs(modules) do
    if contained(input_path, module.root) and #module.root > best_length then
      active = module.id
      best_length = #module.root
    end
  end
  return {
    root = root,
    kind = "maven",
    active_module = active,
    modules = modules,
    dependencies = dependencies,
    configuration = configuration,
    environment = {
      build_file = vim.fs.joinpath(root, "pom.xml"),
      wrapper = first_file(root, { "mvnw", "mvnw.cmd" }),
    },
    diagnostics = diagnostics,
    state = "local",
  }
end

local function inspect_gradle(root, input_path)
  local build_file = first_file(root, { "build.gradle.kts", "build.gradle" })
  local settings = first_file(root, { "settings.gradle.kts", "settings.gradle" })
  local id = "gradle:" .. vim.fs.basename(root)
  local module = {
    id = id,
    root = root,
    build_file = build_file,
    kind = "gradle",
    modified = false,
  }
  local config = spring_config.inspect(module)
  for _, file in ipairs(config.files) do
    file.module_id = id
  end
  return {
    root = root,
    kind = "gradle",
    active_module = contained(input_path, root) and id or nil,
    modules = { module },
    dependencies = {},
    configuration = config.files,
    environment = {
      build_file = build_file,
      settings_file = settings,
      version_catalog = first_file(root, { "gradle/libs.versions.toml" }),
      wrapper = first_file(root, { "gradlew", "gradlew.bat" }),
    },
    diagnostics = config.diagnostics,
    state = "local",
  }
end

local function input_path(opts)
  local path = opts.path
  if not path or path == "" then
    path = vim.api.nvim_buf_get_name(0)
  end
  if not path or path == "" then
    path = vim.fn.getcwd()
  end
  path = absolute(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil, "workspace path does not exist: " .. path
  end
  return real_or_absolute(path), stat.type
end

local function inspect_local(opts)
  local path, kind_or_err = input_path(opts)
  if not path then
    return kind_or_err
  end
  local start = kind_or_err == "directory" and path or vim.fs.dirname(path)
  local pom_path = vim.fs.find("pom.xml", { path = start, upward = true })[1]
  local gradle_path = vim.fs.find({
    "settings.gradle.kts",
    "settings.gradle",
    "build.gradle.kts",
    "build.gradle",
  }, { path = start, upward = true })[1]

  if
    pom_path and (not gradle_path or #vim.fs.dirname(pom_path) >= #vim.fs.dirname(gradle_path))
  then
    return nil, inspect_maven(maven_root(pom_path), path)
  end
  if gradle_path then
    local gradle_root = real_or_absolute(vim.fs.dirname(gradle_path))
    local settings = vim.fs.find({ "settings.gradle.kts", "settings.gradle" }, {
      path = start,
      upward = true,
    })[1]
    if settings then
      gradle_root = real_or_absolute(vim.fs.dirname(settings))
    end
    return nil, inspect_gradle(gradle_root, path)
  end
  return "no Maven or Gradle workspace found from " .. path
end

function M.inspect(opts, callback)
  opts = opts or {}
  assert(type(callback) == "function", "workspace callback is required")
  vim.schedule(function()
    local ok, err, result = pcall(inspect_local, opts)
    if not ok then
      pcall(callback, "workspace inspection failed: " .. tostring(err))
      return
    end
    pcall(callback, err, result)
  end)
end

return M
