describe("Java runtime selection", function()
  local java

  before_each(function()
    package.loaded["duke.java"] = nil
    java = require("duke.java")
  end)

  it("parses modern Java versions", function()
    assert.equals("23", java.parse_version('openjdk version "23.0.1" 2024-10-15'))
  end)

  it("parses legacy Java 8 versions", function()
    assert.equals("8", java.parse_version('java version "1.8.0_412"'))
  end)

  it("uses configured selection when available", function()
    assert.equals("17", java.default("17", { "8", "17", "23" }, "23"))
  end)

  it("parses Maven runtime versions", function()
    assert.equals("21", java.parse_maven_version("Java version: 21.0.2, vendor: Eclipse Adoptium"))
  end)

  it("detects Maven runtime asynchronously", function()
    package.loaded["duke.process"] = {
      run = function(command, args, _, callback)
        assert.equals("mvn", command)
        assert.same({ "--version" }, args)
        callback({ code = 0, stdout = "Java version: 21.0.2", stderr = "" })
      end,
    }
    local result

    java.maven_runtime_async("mvn", function(version)
      result = version
    end)

    assert.equals("21", result)
    package.loaded["duke.process"] = nil
  end)

  it("bounds synchronous Java version probes", function()
    local home = vim.fn.tempname()
    local java_path = vim.fs.joinpath(home, "bin", "java")
    vim.fn.mkdir(vim.fs.dirname(java_path), "p")
    vim.fn.writefile({ "java" }, java_path)
    vim.uv.fs_chmod(java_path, 493)
    local saved_system = vim.system
    local waited
    vim.system = function(command)
      assert.same({ java_path, "-version" }, command)
      return {
        wait = function(_, timeout)
          waited = timeout
          return { code = 124, stdout = "", stderr = "" }
        end,
      }
    end

    local ok, version = pcall(java.home_version, home)
    vim.system = saved_system
    vim.fn.delete(home, "rf")

    assert.is_true(ok)
    assert.is_nil(version)
    assert.equals(1000, waited)
  end)

  it("deduplicates Java homes by real path", function()
    local first = "/virtual/jdk-17"
    local second = "/virtual/jdk-23"
    local saved_realpath = vim.uv.fs_realpath
    local probes = 0
    local function mock_home_version(path)
      if path == first or path == second then
        probes = probes + 1
        return "23"
      end
      return nil
    end
    vim.uv.fs_realpath = function(path)
      if path == first or path == second then
        return "/physical/jdk-23"
      end
      return path
    end

    local ok, homes =
      pcall(java.discover_homes, { ["17"] = first, ["23"] = second }, mock_home_version)
    vim.uv.fs_realpath = saved_realpath

    assert.is_true(ok)
    assert.equals(1, probes)
    assert.equals(second, homes["23"])
  end)

  it("uses a provided runtime snapshot without probing", function()
    local saved_active = java.active
    local saved_discover_homes = java.discover_homes
    local active_calls = 0
    local discovery_calls = 0
    java.active = function()
      active_calls = active_calls + 1
      return "99"
    end
    java.discover_homes = function()
      discovery_calls = discovery_calls + 1
      return { ["99"] = "/jdk/99" }
    end
    local runtimes = {
      active = "23",
      homes = { ["17"] = "/jdk/17", ["23"] = "/jdk/23" },
    }

    local ok, result = pcall(function()
      local versions = java.installed({ "21" }, {}, runtimes)
      local selected = java.default("auto", versions, runtimes.active)
      return {
        versions = versions,
        selected = selected,
        env = java.runner_env(selected, {}, runtimes.homes),
      }
    end)
    java.active = saved_active
    java.discover_homes = saved_discover_homes

    assert.is_true(ok)
    assert.equals(0, active_calls)
    assert.equals(0, discovery_calls)
    assert.same({ "17", "21", "23" }, result.versions)
    assert.equals("23", result.selected)
    assert.equals("/jdk/23", result.env.JAVA_HOME)
  end)

  it("ignores nonnumeric configured Java versions", function()
    local versions = java.installed({ "latest", "21" })

    assert.is_false(vim.tbl_contains(versions, "latest"))
    assert.is_true(vim.tbl_contains(versions, "21"))
  end)

  it("builds scoped runner environment from configured JDK home", function()
    local home = vim.fn.tempname()
    local java_path = vim.fs.joinpath(home, "bin", "java")
    vim.fn.mkdir(vim.fs.dirname(java_path), "p")
    vim.fn.writefile({ "#!/bin/sh", "echo 'openjdk version \"99.0.1\"' >&2" }, java_path)
    vim.uv.fs_chmod(java_path, 493)

    local env = java.runner_env("99", { ["99"] = home })
    local versions = java.installed({}, { ["99"] = home })

    assert.equals(home, env.JAVA_HOME)
    assert.is_true(vim.tbl_contains(versions, "99"))
    assert.equals(vim.fs.joinpath(home, "bin"), vim.split(env.PATH, ":", { plain = true })[1])
    vim.fn.delete(home, "rf")
  end)

  it("rejects a configured JDK home whose actual version differs", function()
    local home = vim.fn.tempname()
    local java_path = vim.fs.joinpath(home, "bin", "java")
    vim.fn.mkdir(vim.fs.dirname(java_path), "p")
    vim.fn.writefile({ "#!/bin/sh", "echo 'openjdk version \"17.0.12\"' >&2" }, java_path)
    vim.uv.fs_chmod(java_path, 493)

    local homes = java.discover_homes({ ["21"] = home })
    local env = java.runner_env("21", { ["21"] = home })

    assert.equals("17", java.home_version(home))
    assert.not_equals(home, homes["21"])
    assert.is_true(env == nil or env.JAVA_HOME ~= home)
    vim.fn.delete(home, "rf")
  end)
end)
