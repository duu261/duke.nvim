---JDK discovery, version probing, and runtime environment setup.
---I/O-heavy: subprocess calls, filesystem scanning, environment variables.

local M = {}
local VERSION_PROBE_TIMEOUT = 1000

local version = require("java_scaffold.java_version")

local function version_from(command)
  local started, process = pcall(vim.system, { command, "-version" }, { text = true })
  if not started then
    return nil
  end
  local result = process:wait(VERSION_PROBE_TIMEOUT)
  if result.code ~= 0 then
    return nil
  end
  return version.parse_version((result.stdout or "") .. "\n" .. (result.stderr or ""))
end

function M.active()
  if vim.fn.executable("java") ~= 1 then
    return nil
  end
  return version_from("java")
end

function M.maven_runtime(command, env)
  local started, process = pcall(vim.system, { command, "--version" }, { text = true, env = env })
  if not started then
    return nil
  end
  local result = process:wait()
  if result.code ~= 0 then
    return nil
  end
  return version.parse_maven_version((result.stdout or "") .. "\n" .. (result.stderr or ""))
end

function M.gradle_runtime(command, env)
  local started, process = pcall(vim.system, { command, "--version" }, { text = true, env = env })
  if not started then
    return nil
  end
  local result = process:wait()
  if result.code ~= 0 then
    return nil
  end
  return version.parse_gradle_version((result.stdout or "") .. "\n" .. (result.stderr or ""))
end

local function runtime_async(command, parse_fn, callback, timeout, env)
  require("java_scaffold.process").run(command, { "--version" }, {
    timeout = timeout,
    env = env,
  }, function(result)
    if result.code ~= 0 then
      callback(nil)
      return
    end
    callback(parse_fn((result.stdout or "") .. "\n" .. (result.stderr or "")))
  end)
end

function M.maven_runtime_async(command, callback, timeout, env)
  runtime_async(command, version.parse_maven_version, callback, timeout, env)
end

function M.gradle_runtime_async(command, callback, timeout, env)
  runtime_async(command, version.parse_gradle_version, callback, timeout, env)
end

local function usable_home(path)
  return type(path) == "string"
    and path ~= ""
    and vim.fn.isdirectory(path) == 1
    and vim.fn.executable(vim.fs.joinpath(path, "bin", "java")) == 1
end

function M.home_version(path)
  if not usable_home(path) then
    return nil
  end
  return version_from(vim.fs.joinpath(path, "bin", "java"))
end

function M.discover_homes(configured_homes, home_version_fn)
  local probe = home_version_fn or M.home_version
  local homes = {}
  local probed = {}
  local function add(path, declared_version)
    local realpath = type(path) == "string" and vim.uv.fs_realpath(path) or nil
    local key = realpath or path
    if type(key) ~= "string" or key == "" then
      return
    end
    local hv = probed[key]
    if hv == nil then
      hv = probe(path) or false
      probed[key] = hv
    end
    if not hv then
      return
    end
    hv = tostring(hv)
    if declared_version and tostring(declared_version) ~= hv then
      return
    end
    if hv and hv:match("^%d+$") and not homes[hv] then
      homes[hv] = path
    end
  end

  for declared_version, path in pairs(configured_homes or {}) do
    add(path, tostring(declared_version))
  end
  for name, path in pairs(vim.fn.environ()) do
    if name:match("^JDK%d+$") then
      add(path)
    end
  end
  add(vim.env.JAVA_HOME)

  local patterns = {
    vim.fn.expand("~/.m2/jdks/*"),
    vim.fn.expand("~/.sdkman/candidates/java/*"),
    vim.fn.expand("~/.asdf/installs/java/*"),
  }
  local system = vim.uv.os_uname().sysname
  if system == "Linux" then
    patterns[#patterns + 1] = "/usr/lib/jvm/*"
  elseif system == "Darwin" then
    patterns[#patterns + 1] = "/Library/Java/JavaVirtualMachines/*/Contents/Home"
  end
  for _, pattern in ipairs(patterns) do
    for _, path in ipairs(vim.fn.glob(pattern, false, true)) do
      add(path)
    end
  end
  return homes
end

function M.installed(extra, configured_homes, runtimes)
  local seen = {}
  local versions = {}
  local function add(v)
    v = v and tostring(v) or nil
    if v and v:match("^%d+$") and not seen[v] then
      seen[v] = true
      versions[#versions + 1] = v
    end
  end

  local active
  local homes
  if type(runtimes) == "table" then
    active = runtimes.active
    homes = runtimes.homes or {}
  else
    active = M.active()
    homes = M.discover_homes(configured_homes)
  end
  add(active)
  for home_version in pairs(homes) do
    add(home_version)
  end
  for _, extra_version in ipairs(extra or {}) do
    add(tostring(extra_version))
  end
  table.sort(versions, function(left, right)
    return tonumber(left) < tonumber(right)
  end)
  return versions
end

function M.home(version_str, configured_homes, homes)
  return (homes or M.discover_homes(configured_homes))[tostring(version_str)]
end

function M.runner_env(version_str, configured_homes, homes)
  local home_path = M.home(version_str, configured_homes, homes)
  if not home_path then
    return nil
  end
  local path = vim.fs.joinpath(home_path, "bin")
  if vim.env.PATH and vim.env.PATH ~= "" then
    path = path .. ":" .. vim.env.PATH
  end
  return { JAVA_HOME = home_path, PATH = path }
end

function M.default(configured, available, fallback)
  if configured and configured ~= "auto" and vim.tbl_contains(available, configured) then
    return configured
  end
  local active = fallback
  if active == nil then
    active = M.active()
  end
  if active and vim.tbl_contains(available, active) then
    return active
  end
  return fallback or available[#available]
end

return M
