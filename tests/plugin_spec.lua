describe("plugin surface", function()
  before_each(function()
    vim.g.loaded_java_scaffold = nil
    package.loaded["java_scaffold"] = nil
    vim.cmd("runtime plugin/java-scaffold.lua")
  end)

  after_each(function()
    package.loaded["java_scaffold.config"] = nil
    package.loaded["java_scaffold.java"] = nil
    package.loaded["java_scaffold.maven"] = nil
    package.loaded["java_scaffold.metadata"] = nil
    package.loaded["java_scaffold.picker"] = nil
    package.loaded["java_scaffold.spring"] = nil
  end)

  it("registers lazy user commands", function()
    assert.equals(2, vim.fn.exists(":JavaScaffoldNew"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldMaven"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldGradle"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldSpring"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldAddDependency"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldClearCache"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldLog"))
    assert.equals(2, vim.fn.exists(":JavaScaffoldHealth"))
  end)

  it("loads public API without setup", function()
    local plugin = require("java_scaffold")
    assert.is_function(plugin.new)
    assert.is_function(plugin.new_maven)
    assert.is_function(plugin.new_gradle)
    assert.is_function(plugin.new_spring)
    assert.is_function(plugin.add_dependency)
    assert.is_function(plugin.clear_cache)
    assert.is_function(plugin.java_runtimes)
    assert.is_function(plugin.select_runtime)
  end)

  it("routes the unified workflow picker to each generator", function()
    local selected_index = 0
    local routed = {}
    package.loaded["java_scaffold.picker"] = {
      select_one = function(items, opts, callback)
        selected_index = selected_index + 1
        assert.equals("Project generator", opts.prompt)
        assert.equals("maven", opts.default)
        assert.same(
          { "maven", "gradle", "spring" },
          vim.tbl_map(function(item)
            return item.id
          end, items)
        )
        callback(items[selected_index])
      end,
    }

    local plugin = require("java_scaffold")
    plugin.new_maven = function()
      routed[#routed + 1] = "maven"
    end
    plugin.new_gradle = function()
      routed[#routed + 1] = "gradle"
    end
    plugin.new_spring = function()
      routed[#routed + 1] = "spring"
    end

    plugin.new()
    plugin.new()
    plugin.new()

    assert.same({ "maven", "gradle", "spring" }, routed)
  end)

  it("uses selected Spring language and packaging", function()
    local received = { pickers = {} }
    local client = {
      artifactId = { default = "demo" },
      bootVersion = { default = "4.0.0" },
      javaVersion = { default = "21", values = { { id = "17" }, { id = "21" } } },
      language = {
        default = "java",
        values = { { id = "java" }, { id = "kotlin" }, { id = "groovy" } },
      },
      packaging = { default = "jar", values = { { id = "jar" }, { id = "war" } } },
      dependencies = { values = {} },
    }
    package.loaded["java_scaffold.config"] = {
      get = function()
        return {
          group_id = "com.example",
          java_version = "21",
          spring = {
            metadata_url = "https://initializr.test/metadata",
            dependencies_url = "https://initializr.test/dependencies",
            starter_url = "https://initializr.test/starter.tgz",
            project_type = "maven-project",
            language = "java",
            packaging = "jar",
            metadata_timeout = 1000,
            timeout = 1000,
          },
        }
      end,
    }
    package.loaded["java_scaffold.java"] = {
      default = function(configured)
        return configured
      end,
    }
    package.loaded["java_scaffold.maven"] = {
      validate = function()
        return nil
      end,
    }
    package.loaded["java_scaffold.metadata"] = {
      cache_path = function(kind)
        return kind
      end,
      default = function(value, key, fallback)
        return value[key] and value[key].default or fallback
      end,
      fetch_cached = function(url, _, _, callback)
        if url:find("dependencies", 1, true) then
          callback(nil, { dependencies = {} })
        else
          callback(nil, client)
        end
      end,
      flatten_dependencies = function()
        return {}
      end,
      is_catalog = function()
        return true
      end,
      is_client = function()
        return true
      end,
      values = function(value, key)
        return vim.tbl_map(function(item)
          return item.id
        end, value[key].values)
      end,
    }
    package.loaded["java_scaffold.picker"] = {
      input = function(_, default, callback)
        callback(default)
      end,
      select_one = function(items, opts, callback)
        received.pickers[opts.prompt] = { items = vim.deepcopy(items), default = opts.default }
        local selected = {
          ["Spring language"] = "kotlin",
          ["Spring packaging"] = "war",
          ["Java version"] = "21",
        }
        callback(selected[opts.prompt])
      end,
      select_many = function(_, _, callback)
        callback({})
      end,
    }
    package.loaded["java_scaffold.spring"] = {
      create = function(opts)
        received.create = opts
      end,
    }

    require("java_scaffold").new_spring()

    assert.same(
      { items = { "java", "kotlin", "groovy" }, default = "java" },
      received.pickers["Spring language"]
    )
    assert.same({ items = { "jar", "war" }, default = "jar" }, received.pickers["Spring packaging"])
    assert.equals("kotlin", received.create.language)
    assert.equals("war", received.create.packaging)
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

  it("threads one Java runtime snapshot through Maven creation", function()
    local active_calls = 0
    local discovery_calls = 0
    local received = {}
    package.loaded["java_scaffold"] = nil
    package.loaded["java_scaffold.config"] = {
      get = function()
        return {
          group_id = "com.example",
          artifact_id = "demo",
          java_versions = {},
          java_homes = {},
          java_version = "23",
          maven = {
            command = "mvn",
            runner_java_version = "auto",
            project_version = "0.1.0-SNAPSHOT",
            wrapper = false,
            archetype = {},
            timeout = 1000,
          },
        }
      end,
    }
    package.loaded["java_scaffold.java"] = {
      active = function()
        active_calls = active_calls + 1
        return "23"
      end,
      discover_homes = function()
        discovery_calls = discovery_calls + 1
        return { ["23"] = "/jdk/23" }
      end,
      installed = function(_, _, runtimes)
        received.installed = runtimes
        return { "23" }
      end,
      default = function(_, _, fallback)
        received.fallback = fallback
        return "23"
      end,
      runner_env = function(_, _, homes)
        received.runner_homes = homes
        return { JAVA_HOME = "/jdk/23", PATH = "/jdk/23/bin" }
      end,
      maven_runtime_async = function(_, callback)
        callback("23")
      end,
    }
    package.loaded["java_scaffold.picker"] = {
      input = function(_, default, callback)
        callback(default)
      end,
      select_one = function(items, _, callback)
        callback(items[1])
      end,
    }
    package.loaded["java_scaffold.maven"] = {
      validate = function()
        return nil
      end,
      create = function(opts)
        received.create = opts
      end,
    }

    require("java_scaffold").new_maven()

    assert.equals(1, active_calls)
    assert.equals(1, discovery_calls)
    assert.same({ active = "23", homes = { ["23"] = "/jdk/23" } }, received.installed)
    assert.equals("23", received.fallback)
    assert.same({ ["23"] = "/jdk/23" }, received.runner_homes)
    assert.equals("/jdk/23", received.create.env.JAVA_HOME)
  end)
end)
