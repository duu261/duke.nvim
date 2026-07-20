describe("creation facade", function()
  local saved_cwd
  local captured

  before_each(function()
    saved_cwd = vim.fn.getcwd()
    captured = nil
    package.loaded["duke.creation"] = nil
    package.loaded["duke.creation.center"] = {
      open = function(opts)
        captured = opts
        return { marker = "session", model = opts.model }
      end,
    }
  end)

  after_each(function()
    vim.cmd.cd(vim.fn.fnameescape(saved_cwd))
    for _, name in ipairs({
      "duke.creation",
      "duke.creation.center",
      "duke.maven",
      "duke.gradle",
      "duke.spring",
      "duke.project",
      "duke.handoff",
      "duke.picker",
      "duke.java",
      "duke.metadata",
      "duke",
    }) do
      package.loaded[name] = nil
    end
  end)

  it("routes public creation functions to one center", function()
    local opened = {}
    package.loaded["duke"] = nil
    package.loaded["duke.creation"] = {
      open = function(opts)
        opened[#opened + 1] = opts
      end,
    }
    package.loaded["duke.picker"] = {
      select_one = function(_, _, callback)
        callback(nil)
      end,
      input = function(_, _, callback)
        callback(nil)
      end,
    }

    local duke = require("duke")
    duke.new()
    duke.new_maven()
    duke.new_gradle()
    duke.new_spring()

    assert.same({
      {},
      { kind = "maven" },
      { kind = "gradle" },
      { kind = "spring" },
    }, opened)
  end)

  it("opens one center with the requested generator preset", function()
    local session = require("duke.creation").open({ kind = "gradle" })

    assert.equals("session", session.marker)
    assert.equals("gradle", captured.model:snapshot().kind)
    assert.is_function(captured.submit)
    assert.is_function(captured.finish)
  end)

  it("passes the configured layout preference to the center", function()
    local config = require("duke.config")
    config.setup({ creation = { layout = "compact" } })

    require("duke.creation").open({ kind = "maven" })

    assert.equals("compact", captured.layout)
    config.setup({})
  end)

  it("contains center startup failures", function()
    local notices = {}
    local saved_notify = vim.notify
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded["duke.creation.center"] = {
      open = function()
        error("window exploded")
      end,
    }

    local ok, result = pcall(require("duke.creation").open, { kind = "maven" })
    vim.notify = saved_notify

    assert.is_true(ok)
    assert.is_nil(result)
    assert.is_truthy(notices[1]:find("could not open Creation Center", 1, true))
  end)

  it("dispatches immutable requests to the selected adapter", function()
    local received
    package.loaded["duke.maven"] = {
      package_name = function()
        return "com.example.demo"
      end,
      validate = function()
        return nil
      end,
      validate_package = function()
        return nil
      end,
      create = function(request, callback)
        received = request
        request.artifact_id = "mutated"
        callback(nil, "/tmp/demo")
      end,
    }
    local callback_result
    require("duke.creation").open({ kind = "maven" })

    captured.submit("maven", { artifact_id = "demo" }, function(err, project_dir)
      callback_result = { err, project_dir }
    end)

    assert.equals("mutated", received.artifact_id)
    assert.same({ nil, "/tmp/demo" }, callback_result)
  end)

  it("discovers target and runner Java state", function()
    package.loaded["duke.java"] = {
      active = function()
        return "23"
      end,
      discover_homes = function()
        return { ["17"] = "/jdk/17", ["23"] = "/jdk/23" }
      end,
      installed = function()
        return { "17", "23" }
      end,
      default = function(configured)
        return configured == "auto" and "17" or configured
      end,
      runner_env = function(version)
        return { JAVA_HOME = "/jdk/" .. version }
      end,
      maven_runtime_async = function(_, callback)
        callback("11")
      end,
    }
    require("duke.creation").open({ kind = "maven" })
    local refreshes = 0
    captured.discover({
      model = captured.model,
      refresh = function()
        refreshes = refreshes + 1
      end,
    }, "all")

    local state = captured.model:snapshot()
    assert.equals("17", state.values.java_version)
    assert.same({ "17", "23" }, state.derived.java_versions)
    assert.equals("17", state.derived.maven_runner_version)
    assert.equals("/jdk/17", state.derived.maven_runner_env.JAVA_HOME)
    assert.equals("11", state.derived.maven_detected_runtime)
    assert.is_truthy(state.errors.java_version:find("runner Java 11", 1, true))
    assert.equals(2, refreshes)
  end)

  it("preserves a selected Java target during later discovery", function()
    package.loaded["duke.java"] = {
      active = function()
        return "23"
      end,
      discover_homes = function()
        return { ["17"] = "/jdk/17", ["21"] = "/jdk/21", ["23"] = "/jdk/23" }
      end,
      installed = function()
        return { "17", "21", "23" }
      end,
      default = function(configured)
        return configured == "auto" and "17" or configured
      end,
      runner_env = function(version)
        return { JAVA_HOME = "/jdk/" .. version }
      end,
      maven_runtime_async = function(_, callback)
        callback("23")
      end,
    }
    require("duke.creation").open({ kind = "maven" })
    local session = { model = captured.model, refresh = function() end }
    captured.discover(session, "all")
    captured.model:set("java_version", "21")

    captured.discover(session, "all")

    assert.equals("21", captured.model:snapshot().values.java_version)
  end)

  it("loads Spring defaults and compatible dependency catalog", function()
    local actual_metadata = require("duke.metadata")
    local client = {
      bootVersion = { default = "4.0.0", values = { { id = "4.0.0" } } },
      javaVersion = { default = "17", values = { { id = "17" }, { id = "21" } } },
      language = { default = "java", values = { { id = "java" } } },
      packaging = { default = "jar", values = { { id = "jar" } } },
      type = {
        default = "maven-project",
        values = {
          {
            id = "gradle-project",
            name = "Gradle",
            tags = { format = "project", build = "gradle" },
          },
          {
            id = "maven-project",
            name = "Maven",
            tags = { format = "project", build = "maven" },
          },
        },
      },
      dependencies = {
        values = {
          {
            name = "Web",
            values = {
              { id = "web", name = "Spring Web", description = "Web applications" },
            },
          },
        },
      },
    }
    local catalog = {
      dependencies = {
        web = { groupId = "org.springframework.boot", artifactId = "spring-boot-starter-web" },
      },
    }
    package.loaded["duke.java"] = {
      active = function()
        return "23"
      end,
      discover_homes = function()
        return { ["17"] = "/jdk/17" }
      end,
      installed = function()
        return { "17" }
      end,
      default = function(_, _, fallback)
        return fallback
      end,
      runner_env = function()
        return nil
      end,
    }
    package.loaded["duke.metadata"] = setmetatable({
      fetch_cached = function(url, _, _, callback)
        if url:find("dependencies", 1, true) then
          callback(nil, catalog, "remote")
        else
          callback(nil, client, "remote")
        end
      end,
      cache_path = function()
        return "/tmp/cache"
      end,
    }, { __index = actual_metadata })

    require("duke.creation").open({ kind = "spring" })
    captured.discover({ model = captured.model, refresh = function() end }, "all")
    local state = captured.model:snapshot()

    assert.equals("4.0.0", state.values.boot_version)
    assert.equals("maven-project", state.values.spring_project_type.id)
    assert.same(
      { "web" },
      vim.tbl_map(function(item)
        return item.id
      end, state.derived.spring_dependency_items)
    )
    assert.same(catalog, state.derived.spring_catalog)
  end)

  it("keeps validated cache fallback visible in the Spring form", function()
    package.loaded["duke.java"] = {
      active = function()
        return "23"
      end,
      discover_homes = function()
        return { ["17"] = "/jdk/17" }
      end,
      installed = function()
        return { "17" }
      end,
      default = function(requested, _, fallback)
        return requested == "auto" and fallback or requested
      end,
      runner_env = function()
        return nil
      end,
    }
    package.loaded["duke.metadata"] = {
      cache_path = function()
        return "/tmp/cache"
      end,
      fetch_cached = function(url, _, _, callback)
        local value = url:find("dependencies", 1, true) and { dependencies = { web = {} } } or {}
        callback(nil, value, "cache", { reason = "fetch", age_seconds = 120 })
      end,
      values = function(_, key)
        return ({
          javaVersion = { "17" },
          bootVersion = { "4.0.0" },
          language = { "java" },
          packaging = { "jar" },
        })[key]
      end,
      project_types = function()
        return { { id = "maven-project", build = "maven", name = "Maven" } }
      end,
      default = function(_, _, fallback)
        return fallback
      end,
      flatten_dependencies = function()
        return { { id = "web", name = "Spring Web" } }
      end,
      format_age = function()
        return "2 minutes ago"
      end,
      is_client = function()
        return true
      end,
      is_catalog = function()
        return true
      end,
    }

    require("duke.creation").open({ kind = "spring" })
    captured.discover({ model = captured.model, refresh = function() end }, "all")
    local state = captured.model:snapshot()

    assert.equals("cache", state.derived.spring_metadata_source)
    assert.equals("cache", state.derived.spring_catalog_source)
    assert.equals(
      "Spring Initializr unreachable; using cached data from 2 minutes ago",
      state.banner
    )
  end)

  it("contains Spring metadata callback failures", function()
    local fetch_callback
    package.loaded["duke.java"] = {
      active = function()
        return "23"
      end,
      discover_homes = function()
        return { ["17"] = "/jdk/17" }
      end,
      installed = function()
        return { "17" }
      end,
      default = function(_, _, fallback)
        return fallback or "17"
      end,
      runner_env = function()
        return nil
      end,
    }
    package.loaded["duke.metadata"] = {
      cache_path = function()
        return "/tmp/cache"
      end,
      fetch_cached = function(_, _, _, callback)
        fetch_callback = callback
      end,
      values = function()
        error("metadata transform exploded")
      end,
      is_client = function()
        return true
      end,
    }
    require("duke.creation").open({ kind = "spring" })
    local refresh_calls = 0
    local session = {
      model = captured.model,
      refresh = function()
        refresh_calls = refresh_calls + 1
        if refresh_calls > 1 then
          error("refresh exploded")
        end
      end,
    }
    captured.discover(session, "all")

    local ok, err = pcall(fetch_callback, nil, {}, "remote")

    assert.is_true(ok, err)
    assert.is_truthy(captured.model:snapshot().banner:find("metadata callback failed", 1, true))
  end)

  it("performs existing successful project handoff", function()
    local project_dir = vim.fn.tempname()
    vim.fn.mkdir(project_dir, "p")
    local entry = vim.fs.joinpath(project_dir, "pom.xml")
    vim.fn.writefile({ "<project/>" }, entry)
    local event
    package.loaded["duke.project"] = {
      entry = function()
        return entry
      end,
    }
    package.loaded["duke.handoff"] = {
      open = function(_, _, callback)
        callback(nil, false)
      end,
    }
    local group = vim.api.nvim_create_augroup("DukeCreationFacadeSpec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "DukeProjectCreated",
      callback = function(args)
        event = args.data
      end,
    })

    local ok, err = pcall(function()
      require("duke.creation").open({ kind = "maven" })
      captured.finish(project_dir)
    end)
    vim.api.nvim_del_augroup_by_id(group)
    assert.is_true(ok, err)
    assert.equals(project_dir, vim.fn.getcwd())
    assert.equals(project_dir, event.project_dir)
    assert.equals(entry, event.entry_file)
    assert.equals(entry, vim.api.nvim_buf_get_name(0))
  end)
end)
