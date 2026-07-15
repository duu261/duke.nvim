describe("plugin surface", function()
  before_each(function()
    vim.g.loaded_java_scaffold = nil
    package.loaded["java_scaffold"] = nil
    vim.cmd("runtime plugin/java-scaffold.lua")
  end)

  after_each(function()
    package.loaded["java_scaffold.config"] = nil
    package.loaded["java_scaffold.java"] = nil
  end)

  it("registers lazy user commands", function()
    assert.equals(2, vim.fn.exists(":JavaScaffoldMaven"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldGradle"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldSpring"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldAddDependency"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldLog"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldHealth"))
  end)

  it("loads public API without setup", function()
    local plugin = require("java_scaffold")
    assert.is_function(plugin.new_maven)
    assert.is_function(plugin.new_gradle)
    assert.is_function(plugin.new_spring)
    assert.is_function(plugin.add_dependency)
    assert.is_function(plugin.java_runtimes)
    assert.is_function(plugin.select_runtime)
  end)

  it("caches public Java runtime discovery", function()
    local discovery_count = 0
    package.loaded["java_scaffold"] = nil
    package.loaded["java_scaffold.config"] = {
      get = function()
        return { java_homes = {} }
      end,
    }
    package.loaded["java_scaffold.java"] = {
      active = function()
        return "23"
      end,
      discover_homes = function()
        discovery_count = discovery_count + 1
        return { ["23"] = "/jdk/23" }
      end,
    }

    local plugin = require("java_scaffold")
    local first = plugin.java_runtimes()
    first.homes["23"] = "/mutated"
    local second = plugin.java_runtimes()

    assert.equals(1, discovery_count)
    assert.equals("23", second.active)
    assert.equals("/jdk/23", second.homes["23"])

    plugin.java_runtimes({ refresh = true })
    assert.equals(2, discovery_count)
  end)

  it("selects an eligible public Java runtime", function()
    local active = "23"
    package.loaded["java_scaffold"] = nil
    package.loaded["java_scaffold.config"] = {
      get = function()
        return { java_homes = {} }
      end,
    }
    package.loaded["java_scaffold.java"] = {
      active = function()
        return active
      end,
      discover_homes = function()
        return {
          ["17"] = "/jdk/17",
          ["21"] = "/jdk/21",
          ["23"] = "/jdk/23",
          ["26"] = "/jdk/26",
        }
      end,
    }

    local plugin = require("java_scaffold")

    assert.same({
      version = "23",
      home = "/jdk/23",
      executable = "/jdk/23/bin/java",
    }, plugin.select_runtime({ min_version = 21, prefer_active = true }))
    assert.same({
      version = "21",
      home = "/jdk/21",
      executable = "/jdk/21/bin/java",
    }, plugin.select_runtime({ min_version = 21, prefer_active = false }))
    active = "17"
    plugin.java_runtimes({ refresh = true })
    assert.same({
      version = "21",
      home = "/jdk/21",
      executable = "/jdk/21/bin/java",
    }, plugin.select_runtime({ min_version = 21, prefer_active = true }))
    assert.is_nil(plugin.select_runtime({ min_version = 27 }))
  end)
end)
