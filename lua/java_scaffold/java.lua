local M = {}

function M.parse_version(output)
  if type(output) ~= "string" then
    return nil
  end
  local quoted = output:match('version%s+"([^"]+)"') or output:match("openjdk%s+([%d._]+)")
  if not quoted then
    return nil
  end
  local legacy = quoted:match("^1%.(%d+)")
  return legacy or quoted:match("^(%d+)")
end

function M.parse_maven_version(output)
  if type(output) ~= "string" then
    return nil
  end
  return output:match("Java version:%s*(%d+)")
end

function M.parse_gradle_version(output)
  if type(output) ~= "string" then
    return nil
  end
  return output:match("Launcher JVM:%s*(%d+)") or output:match("JVM:%s*(%d+)")
end

local function version_from(command)
  local started, process = pcall(vim.system, { command, "-version" }, { text = true })
  if not started then
    return nil
  end
  local result = process:wait()
  if result.code ~= 0 then
    return nil
  end
  return M.parse_version((result.stdout or "") .. "\n" .. (result.stderr or ""))
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
  return M.parse_maven_version((result.stdout or "") .. "\n" .. (result.stderr or ""))
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
  return M.parse_gradle_version((result.stdout or "") .. "\n" .. (result.stderr or ""))
end

function M.maven_runtime_async(command, callback, timeout, env)
  require("java_scaffold.process").run(
    command,
    { "--version" },
    { timeout = timeout, env = env },
    function(result)
      if result.code ~= 0 then
        callback(nil)
        return
      end
      callback(M.parse_maven_version((result.stdout or "") .. "\n" .. (result.stderr or "")))
    end
  )
end

function M.gradle_runtime_async(command, callback, timeout, env)
  require("java_scaffold.process").run(command, { "--version" }, {
    timeout = timeout,
    env = env,
  }, function(result)
    if result.code ~= 0 then
      callback(nil)
      return
    end
    callback(M.parse_gradle_version((result.stdout or "") .. "\n" .. (result.stderr or "")))
  end)
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

function M.discover_homes(configured_homes)
  local homes = {}
  local function add(path, declared_version)
    local version = M.home_version(path)
    if not version then
      return
    end
    version = tostring(version)
    if declared_version and tostring(declared_version) ~= version then
      return
    end
    if version and version:match("^%d+$") and not homes[version] then
      homes[version] = path
    end
  end

  for version, path in pairs(configured_homes or {}) do
    add(path, tostring(version))
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

function M.installed(extra, configured_homes)
  local seen = {}
  local versions = {}
  local function add(version)
    version = version and tostring(version) or nil
    if version and version:match("^%d+$") and not seen[version] then
      seen[version] = true
      versions[#versions + 1] = version
    end
  end

  add(M.active())
  for version in pairs(M.discover_homes(configured_homes)) do
    add(version)
  end
  for _, version in ipairs(extra or {}) do
    add(tostring(version))
  end
  table.sort(versions, function(left, right)
    return tonumber(left) < tonumber(right)
  end)
  return versions
end

function M.home(version, configured_homes)
  return M.discover_homes(configured_homes)[tostring(version)]
end

function M.runner_env(version, configured_homes)
  local home = M.home(version, configured_homes)
  if not home then
    return nil
  end
  local path = vim.fs.joinpath(home, "bin")
  if vim.env.PATH and vim.env.PATH ~= "" then
    path = path .. ":" .. vim.env.PATH
  end
  return { JAVA_HOME = home, PATH = path }
end

function M.default(configured, available, fallback)
  if configured and configured ~= "auto" and vim.tbl_contains(available, configured) then
    return configured
  end
  local active = M.active()
  if active and vim.tbl_contains(available, active) then
    return active
  end
  return fallback or available[#available]
end

return M
