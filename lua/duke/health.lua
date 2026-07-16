local M = {}

local function executable(name, required)
  if vim.fn.executable(name) == 1 then
    vim.health.ok(name .. " found: " .. vim.fn.exepath(name))
  elseif required then
    vim.health.error(name .. " not found")
  else
    vim.health.warn(name .. " not found")
  end
end

function M.check()
  vim.health.start("duke.nvim")

  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim >= 0.11")
  else
    vim.health.error("Neovim >= 0.11 required")
  end

  local config = require("duke.config").get()
  executable("java", true)
  executable(config.maven.command, true)
  executable(config.gradle.command, false)
  executable("curl", true)
  executable("tar", true)

  local java = require("duke.java")
  local java_version = java.active()
  if java_version then
    vim.health.ok("active Java: " .. java_version)
  else
    vim.health.error("active Java version could not be detected")
  end
  local configured_versions = vim.tbl_keys(config.java_homes)
  table.sort(configured_versions, function(left, right)
    return tonumber(left) < tonumber(right)
  end)
  for _, declared in ipairs(configured_versions) do
    local home = config.java_homes[declared]
    local actual = java.home_version(home)
    if not actual then
      vim.health.error("configured java_homes[" .. declared .. "] is not a usable JDK: " .. home)
    elseif actual ~= declared then
      vim.health.error(
        "configured java_homes[" .. declared .. "] points to Java " .. actual .. ": " .. home
      )
    else
      vim.health.ok("configured Java " .. declared .. " home verified: " .. home)
    end
  end
  local versions = java.installed(config.java_versions, config.java_homes)
  if #versions > 0 then
    vim.health.ok("available project Java versions: " .. table.concat(versions, ", "))
  end
  local selected = java.default(config.java_version, versions, java_version)
  if selected then
    vim.health.ok("default project Java: " .. selected)
  end
  local maven_runner = java.default(config.maven.runner_java_version, versions, java_version)
  local maven_env = maven_runner and java.runner_env(maven_runner, config.java_homes) or nil
  if maven_env then
    vim.health.ok("Maven runner JDK home: " .. maven_env.JAVA_HOME)
  else
    vim.health.warn("Maven runner Java has no discovered JDK home; inheriting user environment")
  end
  local maven_java = java.maven_runtime(config.maven.command, maven_env)
  if maven_java then
    vim.health.ok("Maven runtime Java: " .. maven_java)
  else
    vim.health.warn("Maven runtime Java version could not be detected")
  end
  if selected and maven_java and tonumber(selected) > tonumber(maven_java) then
    vim.health.warn("selected Java is newer than Maven runtime; runner may override JAVA_HOME")
  end
  if vim.fn.executable(config.gradle.command) == 1 then
    local gradle_runner = java.default(config.gradle.runner_java_version, versions, java_version)
    local gradle_env = gradle_runner and java.runner_env(gradle_runner, config.java_homes) or nil
    if gradle_env then
      vim.health.ok("Gradle runner JDK home: " .. gradle_env.JAVA_HOME)
    end
    local gradle_java = java.gradle_runtime(config.gradle.command, gradle_env)
    if gradle_java then
      vim.health.ok("Gradle runtime Java: " .. gradle_java)
    else
      vim.health.warn("Gradle runtime Java version could not be detected")
    end
  end

  local cache_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "duke.nvim")
  vim.fn.mkdir(cache_dir, "p")
  if vim.fn.filewritable(cache_dir) == 2 then
    vim.health.ok("metadata cache writable: " .. cache_dir)
  else
    vim.health.warn("metadata cache not writable: " .. cache_dir)
  end

  if config.handoff.enabled then
    if type(config.handoff.command) == "table" and #config.handoff.command > 0 then
      executable(config.handoff.command[1], false)
    else
      vim.health.error("handoff enabled but handoff.command is not configured")
    end
    for _, name in ipairs(config.handoff.required_executables) do
      executable(name, false)
    end
  else
    vim.health.ok("project handoff disabled")
  end

  local telescope_ok = pcall(require, "telescope")
  if telescope_ok then
    vim.health.ok("Telescope available")
  else
    vim.health.ok("Telescope absent; using vim.ui fallback")
  end

  local jdtls_ok = pcall(require, "jdtls")
  if jdtls_ok then
    vim.health.ok("nvim-jdtls module available")
  else
    vim.health.warn("nvim-jdtls module absent; scaffolding works without it")
  end
end

return M
