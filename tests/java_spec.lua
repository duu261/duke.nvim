describe("Java runtime selection", function()
  local java

  before_each(function()
    package.loaded["java_scaffold.java"] = nil
    java = require("java_scaffold.java")
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
    package.loaded["java_scaffold.process"] = {
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
    package.loaded["java_scaffold.process"] = nil
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
