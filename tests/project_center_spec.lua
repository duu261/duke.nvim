describe("Java Project Center", function()
  local project_center
  local root
  local original_window
  local original_buffer
  local original_cwd

  local function rendered_line(buf, needle)
    for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line:find(needle, 1, true) then
        return index
      end
    end
  end

  local function press(state, line, key)
    vim.api.nvim_set_current_win(state.win)
    vim.api.nvim_win_set_cursor(state.win, { line, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
  end

  before_each(function()
    vim.cmd("silent! only")
    vim.cmd("silent! enew!")
    package.loaded["duke.project_center"] = nil
    package.loaded["duke.workspace"] = nil
    project_center = require("duke.project_center")
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({
      "<project>",
      "  <groupId>com.acme</groupId>",
      "  <artifactId>app</artifactId>",
      "  <version>1.0.0</version>",
      "</project>",
    }, vim.fs.joinpath(root, "pom.xml"))
    original_window = vim.api.nvim_get_current_win()
    original_buffer = vim.api.nvim_get_current_buf()
    original_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    project_center.close()
    if vim.api.nvim_buf_is_valid(original_buffer) then
      vim.bo[original_buffer].modified = false
    end
    vim.cmd.cd(vim.fn.fnameescape(original_cwd))
    vim.fn.delete(root, "rf")
    package.loaded["duke.project_center"] = nil
    package.loaded["duke.workspace"] = nil
  end)

  it("opens local data without stealing focus or changing editor state", function()
    vim.api.nvim_buf_set_lines(original_buffer, 0, -1, false, { "unsaved work" })
    vim.bo[original_buffer].modified = true

    project_center.toggle({ path = root })
    assert.is_true(vim.wait(1000, function()
      local state = project_center.state()
      return state and state.snapshot ~= nil
    end))

    local state = project_center.state()
    assert.equals(original_window, vim.api.nvim_get_current_win())
    assert.equals(original_buffer, vim.api.nvim_get_current_buf())
    assert.equals(original_cwd, vim.fn.getcwd())
    assert.is_true(vim.bo[original_buffer].modified)
    assert.equals("duke-project-center", vim.bo[state.buf].filetype)
    assert.matches(
      "Modules %(1%)",
      table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
    )
    assert.is_table(vim.b[state.buf].duke_project_center_nodes)
    local refresh_mapping = vim.tbl_filter(function(mapping)
      return mapping.lhs == "r" or mapping.lhs == "u"
    end, vim.api.nvim_buf_get_keymap(state.buf, "n"))
    assert.equals(2, #refresh_mapping)

    local module_line = assert(rendered_line(state.buf, "com.acme:app"))
    press(state, module_line, "<CR>")
    assert.equals(vim.fs.joinpath(root, "pom.xml"), vim.api.nvim_buf_get_name(0))
    assert.is_true(vim.bo[original_buffer].modified)

    project_center.toggle({ path = root })
    assert.is_nil(project_center.state())
  end)

  it("ignores completion after the sidebar closes", function()
    local pending
    package.loaded["duke.workspace"] = {
      inspect = function(_, callback)
        pending = callback
      end,
    }
    package.loaded["duke.project_center"] = nil
    project_center = require("duke.project_center")

    project_center.toggle({ path = root })
    project_center.close()
    pending(nil, { root = root, state = "local", modules = {}, diagnostics = {} })

    assert.is_nil(project_center.state())
  end)

  it("renders resolved versions and analysis counts", function()
    package.loaded["duke.workspace"] = {
      inspect = function(_, callback)
        callback(nil, {
          root = root,
          state = "resolved",
          kind = "maven",
          modules = {
            { id = "com.acme:app", build_file = vim.fs.joinpath(root, "pom.xml") },
          },
          dependencies = {
            {
              coordinate = "com.acme:managed",
              module_id = "com.acme:app",
              line = 4,
            },
            {
              coordinate = "com.acme:property",
              module_id = "com.acme:app",
              version = "${lib.version}",
              line = 8,
            },
          },
          configuration = {},
          diagnostics = {},
          analysis = {
            dependencies = {
              {
                coordinate = "com.acme:managed",
                module_id = "com.acme:app",
                version = "2.0.0",
                direct = true,
              },
              {
                coordinate = "com.acme:property",
                module_id = "com.acme:app",
                version = "3.0.0",
                direct = true,
              },
              {
                coordinate = "com.acme:transitive",
                module_id = "com.acme:app",
                version = "4.0.0",
                direct = false,
              },
            },
            findings = { conflicts = {}, drift = {}, duplicates = {}, unknown = {} },
          },
        })
      end,
    }
    package.loaded["duke.project_center"] = nil
    project_center = require("duke.project_center")

    project_center.toggle({ path = root })
    assert.is_true(vim.wait(1000, function()
      local state = project_center.state()
      return state and state.snapshot ~= nil
    end))

    local state = project_center.state()
    local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
    assert.matches("com.acme:managed  2.0.0 %(managed%)", rendered)
    assert.is_truthy(rendered:find("com.acme:property  ${lib.version} -> 3.0.0", 1, true))
    assert.matches("Resolved nodes %(3%)", rendered)
    assert.matches("Transitive dependencies  1", rendered)
    assert.matches("Conflicts  0", rendered)
    assert.matches("Version drift  0", rendered)
    assert.matches("Duplicate declarations  0", rendered)
  end)

  it("renders partial Gradle diagnostics as single lines", function()
    package.loaded["duke.workspace"] = {
      inspect = function(_, callback)
        callback(nil, {
          root = root,
          state = "partial",
          kind = "gradle",
          modules = {},
          dependencies = {},
          configuration = {},
          diagnostics = {
            {
              severity = "warning",
              message = "dependencies: FAILURE\nconfiguration missing",
            },
          },
          analysis = {
            projects = { { id = ":app", name = "app" } },
            dependencies = {
              {
                coordinate = "com.acme:library",
                project_id = ":app",
                version = "1.0.0",
                direct = true,
              },
            },
          },
        })
      end,
    }
    package.loaded["duke.project_center"] = nil
    project_center = require("duke.project_center")

    assert.has_no.errors(function()
      project_center.toggle({ path = root })
    end)

    local state = project_center.state()
    local rendered = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
    assert.equals("partial", rendered[2])
    assert.is_truthy(
      table
        .concat(rendered, "\n")
        :find("warning  dependencies: FAILURE configuration missing", 1, true)
    )
  end)

  it("renders workspace environment and resolved Gradle dependencies", function()
    package.loaded["duke.workspace"] = {
      inspect = function(_, callback)
        callback(nil, {
          root = root,
          state = "resolved",
          kind = "gradle",
          active_module = "gradle:sample",
          modules = {
            {
              id = "gradle:sample",
              root = root,
              build_file = vim.fs.joinpath(root, "build.gradle.kts"),
            },
          },
          dependencies = {},
          configuration = {},
          diagnostics = {},
          environment = {
            wrapper = vim.fs.joinpath(root, "gradlew"),
            settings_file = vim.fs.joinpath(root, "settings.gradle.kts"),
            version_catalog = vim.fs.joinpath(root, "gradle", "libs.versions.toml"),
            gradle_version = "9.6.1",
          },
          analysis = {
            projects = { { id = ":", name = "sample" }, { id = ":app", name = "app" } },
            java = {
              {
                project_id = ":app",
                language_version = "17",
                source_compatibility = "17",
                target_compatibility = "17",
              },
            },
            toolchains = { "17", "21" },
            dependencies = {
              {
                coordinate = "com.acme:library",
                project_id = ":app",
                requested_version = "1.0.0",
                version = "2.0.0",
                configuration = "runtimeClasspath",
                direct = true,
                path = { "com.acme:parent", "com.acme:library" },
              },
            },
          },
        })
      end,
    }
    package.loaded["duke.project_center"] = nil
    project_center = require("duke.project_center")

    project_center.toggle({ path = root })

    local state = project_center.state()
    local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
    assert.is_truthy(rendered:find("Workspace", 1, true))
    assert.is_truthy(rendered:find("active  gradle:sample", 1, true))
    assert.is_truthy(rendered:find("Environment", 1, true))
    assert.is_truthy(rendered:find("Gradle projects (2)", 1, true))
    assert.is_truthy(rendered:find(":app  app", 1, true))
    assert.is_truthy(rendered:find("Gradle  9.6.1", 1, true))
    assert.is_truthy(rendered:find("Java target  :app  17", 1, true))
    assert.is_truthy(rendered:find("Toolchains  17, 21", 1, true))
    assert.is_truthy(
      rendered:find("com.acme:library  1.0.0 -> 2.0.0  [:app runtimeClasspath]", 1, true)
    )
  end)

  it("opens Maven details, paths, and exact owning declarations", function()
    local module_id = "com.acme:app"
    local coordinate = "com.acme:library"
    package.loaded["duke.workspace"] = {
      inspect = function(_, callback)
        callback(nil, {
          root = root,
          state = "resolved",
          kind = "maven",
          active_module = module_id,
          modules = {
            {
              id = module_id,
              build_file = vim.fs.joinpath(root, "pom.xml"),
              model = {
                spring_boot_version = "3.5.3",
                properties = {
                  ["maven.compiler.release"] = { value = "21" },
                },
              },
            },
          },
          dependencies = {
            {
              coordinate = coordinate,
              module_id = module_id,
              version = "${lib.version}",
              line = 3,
            },
          },
          configuration = {},
          diagnostics = {},
          environment = {
            build_file = vim.fs.joinpath(root, "pom.xml"),
            runner_java_version = "23",
            runner_java_home = "/opt/jdk-23",
          },
          analysis = {
            dependencies = {
              {
                coordinate = coordinate,
                module_id = module_id,
                version = "2.0.0",
                effective_version = "2.0.0",
                direct = true,
                raw_owner = { start_line = 3, version = "${lib.version}" },
                property = "lib.version",
                property_consumers = {
                  { coordinate = coordinate, line = 3 },
                  { coordinate = "com.acme:second", line = 4 },
                },
              },
            },
            findings = { conflicts = {}, drift = {}, duplicates = {}, unknown = {} },
            paths = {
              [module_id .. "\0" .. coordinate] = {
                { module_id, "com.acme:parent", coordinate },
                { module_id, coordinate },
              },
            },
          },
        })
      end,
    }
    package.loaded["duke.project_center"] = nil
    project_center = require("duke.project_center")
    project_center.toggle({ path = root })

    local state = project_center.state()
    local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
    assert.is_truthy(rendered:find("Java target  com.acme:app  21", 1, true))
    assert.is_truthy(rendered:find("Runner JVM  23", 1, true))
    assert.is_truthy(rendered:find("Runner JAVA_HOME  /opt/jdk-23", 1, true))
    assert.is_truthy(rendered:find("Spring Boot  com.acme:app  3.5.3", 1, true))
    assert.is_truthy(rendered:find("JDTLS", 1, true))
    local dependency_line = assert(rendered_line(state.buf, coordinate))
    press(state, dependency_line, "<CR>")
    local detail_buf = vim.api.nvim_get_current_buf()
    local detail = table.concat(vim.api.nvim_buf_get_lines(detail_buf, 0, -1, false), "\n")
    assert.equals("nofile", vim.bo[detail_buf].buftype)
    assert.is_false(vim.bo[detail_buf].modifiable)
    assert.is_truthy(detail:find("Selected version: 2.0.0", 1, true))
    assert.is_truthy(detail:find("Property: lib.version", 1, true))
    assert.is_truthy(detail:find("com.acme:second", 1, true))

    press(state, dependency_line, "p")
    local paths = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(paths:find("com.acme:app -> com.acme:parent -> com.acme:library", 1, true))
    assert.is_truthy(paths:find("com.acme:app -> com.acme:library", 1, true))

    press(state, dependency_line, "g")
    assert.equals(vim.fs.joinpath(root, "pom.xml"), vim.api.nvim_buf_get_name(0))
    assert.equals(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("dispatches contextual add remove and why actions through Duke workflows", function()
    local calls = {}
    local picker_called = false
    local saved_duke = package.loaded["duke"]
    local saved_api = package.loaded["duke.api"]
    local saved_picker = package.loaded["duke.picker"]
    package.loaded["duke"] = {
      add_dependency = function()
        calls[#calls + 1] = { action = "add", path = vim.api.nvim_buf_get_name(0) }
      end,
      remove_dependency = function()
        calls[#calls + 1] = { action = "remove", path = vim.api.nvim_buf_get_name(0) }
      end,
      dependency_why = function(coordinate)
        calls[#calls + 1] = { action = "why", coordinate = coordinate }
      end,
    }
    package.loaded["duke.api"] = {
      plan_upgrades = function(opts, callback)
        calls[#calls + 1] = { action = "upgrade", opts = opts }
        callback(nil, { preview = { before = {}, after = {} }, changes = { {} } })
      end,
    }
    package.loaded["duke.picker"] = {
      select_many = function(items, _, callback)
        picker_called = true
        callback(items)
      end,
      confirm = function()
        return false
      end,
    }
    package.loaded["duke.workspace"] = {
      inspect = function(_, callback)
        callback(nil, {
          root = root,
          state = "local",
          kind = "maven",
          active_module = "com.acme:app",
          modules = {
            { id = "com.acme:app", build_file = vim.fs.joinpath(root, "pom.xml") },
          },
          dependencies = {
            {
              coordinate = "com.acme:library",
              module_id = "com.acme:app",
              version = "1.0.0",
              line = 3,
            },
          },
          configuration = {},
          diagnostics = {},
          environment = {},
        })
      end,
    }
    package.loaded["duke.project_center"] = nil
    project_center = require("duke.project_center")
    project_center.toggle({ path = root })

    local state = project_center.state()
    local module_line = assert(rendered_line(state.buf, "com.acme:app"))
    local dependency_line = assert(rendered_line(state.buf, "com.acme:library"))
    press(state, module_line, "a")
    press(state, dependency_line, "x")
    press(state, dependency_line, "p")
    press(state, dependency_line, "u")

    assert.same("add", calls[1].action)
    assert.same(vim.fs.joinpath(root, "pom.xml"), calls[1].path)
    assert.same("remove", calls[2].action)
    assert.same(vim.fs.joinpath(root, "pom.xml"), calls[2].path)
    assert.same("why", calls[3].action)
    assert.same("com.acme:library", calls[3].coordinate)
    assert.same("upgrade", calls[4].action)
    assert.same(vim.fs.joinpath(root, "pom.xml"), calls[4].opts.pom_path)
    assert.same({ { coordinate = "com.acme:library" } }, calls[4].opts.changes)
    assert.is_false(picker_called)
    package.loaded["duke"] = saved_duke
    package.loaded["duke.api"] = saved_api
    package.loaded["duke.picker"] = saved_picker
  end)

  it("keeps the newest refresh result and preserves the latest snapshot across reopen", function()
    local pending = {}
    package.loaded["duke.workspace"] = {
      inspect = function(_, callback)
        pending[#pending + 1] = callback
      end,
    }
    package.loaded["duke.project_center"] = nil
    project_center = require("duke.project_center")
    project_center.toggle({ path = root })
    local state = project_center.state()
    press(state, 1, "r")

    pending[2](nil, {
      root = root,
      state = "resolved",
      kind = "maven",
      modules = {},
      dependencies = {},
      configuration = {},
      diagnostics = {},
      environment = {},
    })
    pending[1](nil, {
      root = "/stale",
      state = "local",
      kind = "maven",
      modules = {},
      dependencies = {},
      configuration = {},
      diagnostics = {},
      environment = {},
    })
    assert.equals(root, project_center.state().snapshot.root)
    assert.equals("resolved", project_center.state().snapshot.state)

    project_center.close()
    project_center.toggle({ path = root })
    assert.equals(root, project_center.state().snapshot.root)
    assert.equals("resolved", project_center.state().snapshot.state)
  end)

  it("invalidates a cached resolved snapshot after its build file is written", function()
    local inspections = 0
    package.loaded["duke.workspace"] = {
      inspect = function(_, callback)
        inspections = inspections + 1
        callback(nil, {
          root = root,
          state = inspections == 1 and "resolved" or "local",
          kind = "maven",
          modules = {
            { id = "com.acme:app", build_file = vim.fs.joinpath(root, "pom.xml") },
          },
          dependencies = {},
          configuration = {},
          diagnostics = {},
          environment = { build_file = vim.fs.joinpath(root, "pom.xml") },
          analysis = inspections == 1 and { dependencies = {}, findings = {} } or nil,
        })
      end,
    }
    package.loaded["duke.project_center"] = nil
    project_center = require("duke.project_center")
    project_center.toggle({ path = root })
    project_center.close()

    local pom_buf = vim.fn.bufadd(vim.fs.joinpath(root, "pom.xml"))
    vim.fn.bufload(pom_buf)
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = pom_buf })
    project_center.toggle({ path = root })

    assert.equals(2, inspections)
    assert.equals("local", project_center.state().snapshot.state)
  end)

  it("lists every sidebar action in help", function()
    project_center.toggle({ path = root })
    assert.is_true(vim.wait(1000, function()
      local state = project_center.state()
      return state and state.snapshot ~= nil
    end))

    local state = project_center.state()
    vim.api.nvim_set_current_win(state.win)
    vim.api.nvim_feedkeys("?", "x", false)

    local help = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.matches("a     Add a dependency", help)
    assert.matches("u     Plan upgrades for the active Maven module", help)
    assert.matches("x     Remove dependencies", help)
    assert.matches("p     Show dependency paths", help)
    assert.matches("g     Jump to the owning declaration", help)
    vim.cmd.close()
  end)
end)
