describe("health", function()
  local original_health = {}
  local original_jdtls_loaded
  local original_jdtls_preload
  local messages

  before_each(function()
    messages = { ok = {}, warn = {}, error = {} }
    for _, level in ipairs({ "start", "ok", "warn", "error" }) do
      original_health[level] = vim.health[level]
    end
    vim.health.start = function() end
    for _, level in ipairs({ "ok", "warn", "error" }) do
      vim.health[level] = function(message)
        messages[level][#messages[level] + 1] = message
      end
    end

    package.loaded["java_scaffold.health"] = nil
    package.loaded["java_scaffold.config"] = {
      get = function()
        return {
          java_version = "auto",
          java_versions = {},
          java_homes = { ["21"] = "/jdk/17" },
          maven = { command = "java", runner_java_version = "auto" },
          gradle = { command = "missing-gradle", runner_java_version = "auto" },
          handoff = { enabled = false, required_executables = {} },
        }
      end,
    }
    package.loaded["java_scaffold.java"] = {
      active = function()
        return "23"
      end,
      installed = function()
        return { "23" }
      end,
      default = function()
        return "23"
      end,
      runner_env = function()
        return { JAVA_HOME = "/jdk/23" }
      end,
      maven_runtime = function()
        return "23"
      end,
      home_version = function()
        return "17"
      end,
    }
    original_jdtls_loaded = package.loaded.jdtls
    original_jdtls_preload = package.preload.jdtls
    package.loaded.jdtls = nil
    package.preload.jdtls = function()
      return {}
    end
  end)

  after_each(function()
    for level, callback in pairs(original_health) do
      vim.health[level] = callback
    end
    package.loaded["java_scaffold.health"] = nil
    package.loaded["java_scaffold.config"] = nil
    package.loaded["java_scaffold.java"] = nil
    package.loaded.jdtls = original_jdtls_loaded
    package.preload.jdtls = original_jdtls_preload
  end)

  it("reports only verified JDK homes and nvim-jdtls module availability", function()
    require("java_scaffold.health").check()

    assert.is_true(vim.tbl_contains(messages.ok, "nvim-jdtls module available"))
    assert.is_true(
      vim.tbl_contains(messages.error, "configured java_homes[21] points to Java 17: /jdk/17")
    )
  end)
end)
