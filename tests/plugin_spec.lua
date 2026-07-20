describe("plugin surface", function()
  local original_cwd
  local original_notify
  local temporary_directories = {}
  local format_dependency = require("duke.picker").format_dependency

  before_each(function()
    original_cwd = vim.fn.getcwd()
    original_notify = vim.notify
    vim.g.loaded_duke = nil
    package.loaded["duke"] = nil
    vim.cmd("runtime plugin/duke.lua")
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "DukePluginBuildChangedSpec")
    vim.notify = original_notify
    package.loaded["duke.api"] = nil
    package.loaded["duke.build"] = nil
    package.loaded["duke.config"] = nil
    package.loaded["duke.dependency_insight"] = nil
    package.loaded["duke.events"] = nil
    package.loaded["duke.gradle"] = nil
    package.loaded["duke.java"] = nil
    package.loaded["duke.log"] = nil
    package.loaded["duke.managed"] = nil
    package.loaded["duke.maven"] = nil
    package.loaded["duke.maven_central"] = nil
    package.loaded["duke.maven_module"] = nil
    package.loaded["duke.metadata"] = nil
    package.loaded["duke.picker"] = nil
    package.loaded["duke.pom"] = nil
    package.loaded["duke.pom_file"] = nil
    package.loaded["duke.project"] = nil
    package.loaded["duke.progress"] = nil
    package.loaded["duke.project_center"] = nil
    package.loaded["duke.spring"] = nil
    package.loaded["duke.workspace"] = nil
    vim.cmd.cd(vim.fn.fnameescape(original_cwd))
    for _, path in ipairs(temporary_directories) do
      vim.fn.delete(path, "rf")
    end
    temporary_directories = {}
  end)

  local function open_pom(lines)
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local pom_path = vim.fs.joinpath(cwd, "pom.xml")
    vim.fn.writefile(lines, pom_path)
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    vim.opt.runtimepath:prepend(original_cwd)
    vim.cmd("enew!")
    return pom_path
  end

  it("registers lazy user commands", function()
    assert.equals(2, vim.fn.exists(":Duke"))
    assert.equals(2, vim.fn.exists(":DukeNew"))
    assert.equals(2, vim.fn.exists(":DukeMaven"))
    assert.equals(2, vim.fn.exists(":DukeGradle"))
    assert.equals(2, vim.fn.exists(":DukeSpring"))
    assert.equals(2, vim.fn.exists(":DukeAdd"))
    assert.equals(2, vim.fn.exists(":DukeUpgrade"))
    assert.equals(2, vim.fn.exists(":DukeBootUpgrade"))
    assert.equals(2, vim.fn.exists(":DukeRemove"))
    assert.equals(2, vim.fn.exists(":DukeOutdated"))
    assert.equals(2, vim.fn.exists(":DukeTree"))
    assert.equals(2, vim.fn.exists(":DukeWhy"))
    assert.equals(2, vim.fn.exists(":DukeModule"))
    assert.equals(2, vim.fn.exists(":DukeClearCache"))
    assert.equals(2, vim.fn.exists(":DukeLog"))
    assert.equals(2, vim.fn.exists(":DukeHealth"))
  end)

  it("opens Project Center from Duke inside a Java workspace", function()
    local received
    package.loaded["duke.workspace"] = {
      can_inspect = function()
        return true
      end,
    }
    package.loaded["duke"] = {
      project_center = function(opts)
        received = opts.path
      end,
    }

    vim.cmd("Duke")

    assert.equals(vim.fn.getcwd(), received)
  end)

  it("loads public API without setup", function()
    local plugin = require("duke")
    assert.is_function(plugin.new)
    assert.is_function(plugin.new_maven)
    assert.is_function(plugin.new_gradle)
    assert.is_function(plugin.new_spring)
    assert.is_function(plugin.new_module)
    assert.is_function(plugin.add_dependency)
    assert.is_function(plugin.update_dependency)
    assert.is_function(plugin.upgrade_boot_parent)
    assert.is_function(plugin.remove_dependency)
    assert.is_function(plugin.outdated_dependencies)
    assert.is_function(plugin.clear_cache)
    assert.is_function(plugin.java_runtimes)
    assert.is_function(plugin.select_runtime)
    assert.is_function(plugin.create)
    assert.is_function(plugin.add)
    assert.is_function(plugin.add_module)
    assert.is_function(plugin.upgrade)
    assert.is_function(plugin.upgrade_parent)
    assert.is_function(plugin.outdated)
    assert.is_function(plugin.remove)
    assert.is_function(plugin.help)
  end)

  it("routes the unified workflow picker to each generator", function()
    local selected_index = 0
    local routed = {}
    package.loaded["duke.picker"] = {
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

    local plugin = require("duke")
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

  it("uses selected Spring fields and options", function()
    local received = { pickers = {} }
    local destination = "/tmp"
    local client = {
      artifactId = { default = "demo" },
      bootVersion = {
        default = "4.0.0",
        values = { { id = "3.5.4" }, { id = "4.0.0" } },
      },
      javaVersion = { default = "21", values = { { id = "17" }, { id = "21" } } },
      language = {
        default = "java",
        values = { { id = "java" }, { id = "kotlin" }, { id = "groovy" } },
      },
      packaging = { default = "jar", values = { { id = "jar" }, { id = "war" } } },
      type = {
        values = {
          {
            id = "maven-project",
            name = "Maven",
            tags = { build = "maven", format = "project" },
          },
          {
            id = "gradle-project-kotlin",
            name = "Gradle - Kotlin",
            tags = { build = "gradle", format = "project" },
          },
        },
      },
      dependencies = { values = {} },
    }
    package.loaded["duke.config"] = {
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
    package.loaded["duke.java"] = {
      default = function(configured)
        return configured
      end,
    }
    package.loaded["duke.maven"] = {
      validate = function()
        return nil
      end,
      package_name = function()
        return "com.example.demo"
      end,
      validate_package = function()
        return nil
      end,
    }
    package.loaded["duke.metadata"] = {
      cache_path = function(kind)
        return kind
      end,
      default = function(value, key, fallback)
        return value[key] and value[key].default or fallback
      end,
      fetch_cached = function(url, _, _, callback)
        if url:find("dependencies", 1, true) then
          received.catalog_url = url
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
      project_types = function()
        return {
          { id = "maven-project", name = "Maven", build = "maven" },
          { id = "gradle-project-kotlin", name = "Gradle - Kotlin", build = "gradle" },
        }
      end,
    }
    package.loaded["duke.picker"] = {
      input = function(prompt, default, callback)
        local values = {
          ["Destination directory: "] = destination,
          ["Project name: "] = "Custom Demo",
          ["Description: "] = "Custom description",
          ["Package name: "] = "com.acme.demo",
        }
        callback(values[prompt] or default)
      end,
      confirm = function(prompt)
        received.review = prompt
        return true
      end,
      select_one = function(items, opts, callback)
        received.pickers[opts.prompt] = { items = vim.deepcopy(items), default = opts.default }
        local selected = {
          ["Spring language"] = "kotlin",
          ["Spring packaging"] = "war",
          ["Java version"] = "21",
          ["Spring Boot version"] = "3.5.4",
        }
        if opts.prompt == "Spring project type" then
          callback(items[2])
        else
          callback(selected[opts.prompt])
        end
      end,
      select_many = function(_, _, callback)
        callback({})
      end,
    }
    package.loaded["duke.spring"] = {
      create = function(opts)
        received.create = opts
      end,
    }

    require("duke").new_spring()

    assert.same(
      { items = { "java", "kotlin", "groovy" }, default = "java" },
      received.pickers["Spring language"]
    )
    assert.same({ items = { "jar", "war" }, default = "jar" }, received.pickers["Spring packaging"])
    assert.equals("kotlin", received.create.language)
    assert.equals("war", received.create.packaging)
    assert.equals(destination, received.create.cwd)
    assert.equals("Custom Demo", received.create.name)
    assert.equals("Custom description", received.create.description)
    assert.equals("com.acme.demo", received.create.package_name)
    assert.equals("3.5.4", received.create.boot_version)
    assert.equals("gradle-project-kotlin", received.create.project_type)
    assert.equals("gradle", received.create.build)
    assert.is_truthy(received.catalog_url:find("bootVersion=3.5.4", 1, true))
    assert.equals("maven-project", received.pickers["Spring project type"].default)
    assert.is_truthy(received.review:find("Destination: /tmp/demo", 1, true))
    assert.is_truthy(received.review:find("Coordinates: com.example:demo", 1, true))
    assert.is_truthy(received.review:find("Name: Custom Demo", 1, true))
    assert.is_truthy(received.review:find("Description: Custom description", 1, true))
    assert.is_truthy(received.review:find("Package: com.acme.demo", 1, true))
    assert.is_truthy(received.review:find("Build type: gradle", 1, true))
    assert.is_truthy(received.review:find("Spring Boot: 3.5.4", 1, true))
    assert.is_truthy(received.review:find("Dependencies: none", 1, true))
  end)

  it("finishes Spring metadata progress before reporting cache fallback", function()
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded["duke.metadata"] = {
      cache_path = function()
        return "path"
      end,
      format_age = function()
        return "3 days ago"
      end,
      is_client = function()
        return true
      end,
      fetch_cached = function(_, _, _, callback)
        callback(nil, { source = "cache" }, "cache", { reason = "fetch", age_seconds = 259200 })
      end,
    }

    local wizard = require("duke.wizard")
    local step = wizard.spring_metadata_fetch({ spring = { metadata_url = "https://x" } })
    local advanced
    step({}, function(state)
      advanced = state
    end)

    assert.is_not_nil(advanced)
    assert.equals(3, #notices)
    assert.is_truthy(notices[2]:find("done", 1, true))
    assert.is_truthy(notices[3]:find("unreachable", 1, true))
    assert.is_truthy(notices[3]:find("3 days ago", 1, true))
  end)

  it("does not notify about cache when the Spring metadata step resolves from remote", function()
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded["duke.metadata"] = {
      cache_path = function()
        return "path"
      end,
      is_client = function()
        return true
      end,
      fetch_cached = function(_, _, _, callback)
        callback(nil, { source = "remote" }, "remote")
      end,
    }

    local wizard = require("duke.wizard")
    local step = wizard.spring_metadata_fetch({ spring = { metadata_url = "https://x" } })
    local advanced
    step({}, function(state)
      advanced = state
    end)

    assert.is_not_nil(advanced)
    assert.equals(2, #notices)
    assert.is_truthy(notices[1]:find("Loading Spring Initializr metadata", 1, true))
    assert.is_truthy(notices[2]:find("done", 1, true))
  end)

  it("uses schema wording when the Spring metadata step resolves from cache after drift", function()
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded["duke.metadata"] = {
      cache_path = function()
        return "path"
      end,
      format_age = function()
        return "just now"
      end,
      is_client = function()
        return true
      end,
      fetch_cached = function(_, _, _, callback)
        callback(nil, { source = "cache" }, "cache", { reason = "schema", age_seconds = 0 })
      end,
    }

    local wizard = require("duke.wizard")
    local step = wizard.spring_metadata_fetch({ spring = { metadata_url = "https://x" } })
    step({}, function() end)

    assert.equals(3, #notices)
    assert.is_truthy(notices[3]:find("schema not recognized", 1, true))
  end)

  it("uses Maven Central for plain Maven poms and rereads before insertion", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local pom_path = vim.fs.joinpath(cwd, "pom.xml")
    vim.fn.writefile({ "<project>", "  <artifactId>demo</artifactId>", "</project>" }, pom_path)
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    vim.opt.runtimepath:prepend(original_cwd)
    vim.cmd("enew!")
    local received = {}
    local events = {}
    local group = vim.api.nvim_create_augroup("DukePluginBuildChangedSpec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "DukeBuildChanged",
      callback = function(args)
        events[#events + 1] = args.data
      end,
    })
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end

    package.loaded["duke.pom"] = {
      spring_boot_version = function()
        return nil
      end,
      list = function()
        return {}
      end,
      insert = function(lines, dependencies)
        received.lines = lines
        received.dependencies = dependencies
        return lines, #dependencies
      end,
    }
    package.loaded["duke.maven"] = {
      validate = function(group_id, artifact_id)
        received.validated = group_id .. ":" .. artifact_id
      end,
    }
    package.loaded["duke.maven_central"] = {
      search = function(term, callback)
        received.term = term
        callback(nil, {
          {
            group_id = "com.google.guava",
            artifact_id = "guava",
            version = "33.4.8-jre",
            packaging = "jar",
          },
        })
      end,
      versions = function(group_id, artifact_id, callback)
        received.version_coordinates = group_id .. ":" .. artifact_id
        callback(nil, { "33.4.8-jre", "33.4.7-jre" })
      end,
    }
    package.loaded["duke.picker"] = {
      format_dependency = format_dependency,
      input = function(_, _, callback)
        callback("guava")
      end,
      select_many = function(items, opts, callback)
        assert.equals("Add Maven Central dependencies", opts.prompt)
        assert.equals("com.google.guava:guava  33.4.8-jre", opts.format_item(items[1]))
        vim.fn.writefile({
          "<project>",
          "  <artifactId>demo</artifactId>",
          "  <name>changed while picker was open</name>",
          "</project>",
        }, pom_path)
        callback(items)
      end,
      select_one = function(items, opts, callback)
        if opts.prompt:find("Maven Central version", 1, true) == 1 then
          assert.same({
            { name = "33.4.8-jre", value = "33.4.8-jre" },
            { name = "33.4.7-jre", value = "33.4.7-jre" },
          }, items)
          assert.equals("33.4.8-jre", opts.default)
          callback("33.4.7-jre")
          return
        end
        assert.equals("Maven dependency scope for com.google.guava:guava:33.4.7-jre", opts.prompt)
        assert.same({ "compile", "test", "provided", "runtime" }, items)
        assert.equals("compile", opts.default)
        vim.fn.writefile({
          "<project>",
          "  <artifactId>demo</artifactId>",
          "  <name>changed while scope picker was open</name>",
          "</project>",
        }, pom_path)
        callback("test")
      end,
      confirm = function()
        return true
      end,
    }

    require("duke").add_dependency()

    assert.equals("guava", received.term)
    assert.equals("com.google.guava:guava", received.version_coordinates)
    assert.equals("com.google.guava:guava", received.validated)
    assert.same({
      {
        group_id = "com.google.guava",
        artifact_id = "guava",
        version = "33.4.7-jre",
        packaging = "jar",
        scope = "test",
      },
    }, received.dependencies)
    assert.is_truthy(table.concat(received.lines, "\n"):find("changed while scope picker", 1, true))
    assert.is_truthy(
      table.concat(notices, "\n"):find("added com.google.guava:guava:33.4.7-jre [test]", 1, true)
    )
    assert.same({
      {
        kind = "maven",
        root = cwd,
        build_file = pom_path,
        operation = "add_dependency",
        coordinates = { "com.google.guava:guava" },
        saved = true,
      },
    }, events)
  end)

  it("cancels Maven Central insertion when scope selection is cancelled", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local pom_path = vim.fs.joinpath(cwd, "pom.xml")
    local original = { "<project>", "  <artifactId>demo</artifactId>", "</project>" }
    vim.fn.writefile(original, pom_path)
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    vim.opt.runtimepath:prepend(original_cwd)
    vim.cmd("enew!")
    local prompts = {}

    package.loaded["duke.pom"] = {
      spring_boot_version = function()
        return nil
      end,
      list = function()
        return {}
      end,
      insert = function()
        error("pom insert must not run")
      end,
    }
    package.loaded["duke.maven"] = {
      validate = function()
        error("coordinate validation must not run")
      end,
    }
    package.loaded["duke.maven_central"] = {
      search = function(_, callback)
        callback(nil, {
          { group_id = "org.junit.jupiter", artifact_id = "junit-jupiter", version = "5.13.4" },
        })
      end,
      versions = function(_, _, callback)
        callback(nil, { "5.13.4" })
      end,
    }
    package.loaded["duke.picker"] = {
      input = function(_, _, callback)
        callback("junit-jupiter")
      end,
      select_many = function(items, _, callback)
        callback(items)
      end,
      select_one = function(items, opts, callback)
        prompts[#prompts + 1] = opts.prompt
        if opts.prompt:find("Maven Central version", 1, true) == 1 then
          callback(items[1])
        else
          callback(nil)
        end
      end,
    }

    require("duke").add_dependency()

    assert.same({
      "Maven Central version for org.junit.jupiter:junit-jupiter",
      "Maven dependency scope for org.junit.jupiter:junit-jupiter:5.13.4",
    }, prompts)
    assert.same(original, vim.fn.readfile(pom_path))
  end)

  it("requires confirmation before Maven Central insertion", function()
    local pom_path = open_pom({ "<project>", "  <artifactId>demo</artifactId>", "</project>" })
    local original = vim.fn.readfile(pom_path)
    local confirmation

    package.loaded["duke.pom"] = {
      spring_boot_version = function()
        return nil
      end,
      list = function()
        return {}
      end,
      insert = function()
        error("pom insert must not run without confirmation")
      end,
    }
    package.loaded["duke.maven"] = {
      validate = function()
        return nil
      end,
    }
    package.loaded["duke.maven_central"] = {
      search = function(_, callback)
        callback(nil, {
          { group_id = "com.example", artifact_id = "first", version = "1.0" },
          { group_id = "com.example", artifact_id = "second", version = "2.0" },
        })
      end,
    }
    package.loaded["duke.picker"] = {
      input = function(_, _, callback)
        callback("example")
      end,
      select_many = function(items, _, callback)
        callback(items)
      end,
      confirm = function(message, action)
        confirmation = message
        assert.equals("Add", action)
        return false
      end,
    }

    require("duke").add_dependency()

    assert.is_truthy(confirmation:find("com.example:first:1.0", 1, true))
    assert.is_truthy(confirmation:find("com.example:second:2.0", 1, true))
    assert.same(original, vim.fn.readfile(pom_path))
  end)

  it("requires confirmation before Maven dependency upgrade", function()
    local original = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>demo</artifactId>",
      "      <version>1.0</version>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local pom_path = open_pom(original)
    local confirmation
    package.loaded["duke.maven_central"] = {
      versions = function(_, _, callback)
        callback(nil, { "2.0", "1.0" })
      end,
    }
    package.loaded["duke.picker"] = {
      format_dependency = format_dependency,
      select_one = function(items, opts, callback)
        if opts.prompt == "Update Maven dependency" then
          callback(items[1])
        else
          callback("2.0")
        end
      end,
      confirm = function(message, action)
        confirmation = message
        assert.equals("Upgrade", action)
        return false
      end,
    }

    require("duke").update_dependency()

    assert.is_truthy(confirmation:find("com.example:demo", 1, true))
    assert.is_truthy(confirmation:find("1.0 -> 2.0", 1, true))
    assert.same(original, vim.fn.readfile(pom_path))
  end)

  it("updates an explicit Maven dependency and hides managed dependencies", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local pom_path = vim.fs.joinpath(cwd, "pom.xml")
    local original = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.junit.jupiter</groupId>",
      "      <artifactId>junit-jupiter</artifactId>",
      "      <version>5.12.0</version>",
      "      <scope>test</scope>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    vim.fn.writefile(original, pom_path)
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    vim.opt.runtimepath:prepend(original_cwd)
    vim.cmd("enew!")
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded["duke.maven_central"] = {
      versions = function(group_id, artifact_id, callback)
        assert.equals("org.junit.jupiter", group_id)
        assert.equals("junit-jupiter", artifact_id)
        callback(nil, { "5.13.4", "5.12.0" })
      end,
    }
    package.loaded["duke.managed"] = {
      resolve = function(_, _, callback)
        callback("mvn unavailable")
      end,
    }
    package.loaded["duke.picker"] = {
      format_dependency = format_dependency,
      select_one = function(items, opts, callback)
        if opts.prompt == "Update Maven dependency" then
          assert.equals(1, #items)
          assert.equals("org.junit.jupiter:junit-jupiter  5.12.0", opts.format_item(items[1]))
          callback(items[1])
          return
        end
        assert.equals("Maven Central version for org.junit.jupiter:junit-jupiter", opts.prompt)
        assert.same({
          { name = "5.13.4", value = "5.13.4" },
          { name = "5.12.0", value = "5.12.0" },
        }, items)
        assert.equals("5.13.4", opts.default)
        assert.equals("5.13.4  (latest)", opts.format_item({ name = "5.13.4", value = "5.13.4" }))
        callback("5.13.4")
      end,
      confirm = function()
        return true
      end,
    }

    require("duke").update_dependency()

    local expected = vim.deepcopy(original)
    expected[6] = "      <version>5.13.4</version>"
    assert.same(expected, vim.fn.readfile(pom_path))
    assert.is_truthy(table.concat(notices, "\n"):find("1 managed dependency hidden", 1, true))
  end)

  it("leaves Maven dependencies untouched when update selection is cancelled or current", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local pom_path = vim.fs.joinpath(cwd, "pom.xml")
    local original = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>demo</artifactId>",
      "      <version>1.0</version>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    vim.fn.writefile(original, pom_path)
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    vim.opt.runtimepath:prepend(original_cwd)
    vim.cmd("enew!")
    local central_calls = 0
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded["duke.maven_central"] = {
      versions = function(_, _, callback)
        central_calls = central_calls + 1
        callback(nil, { "2.0", "1.0" })
      end,
    }
    package.loaded["duke.picker"] = {
      select_one = function(_, opts, callback)
        assert.equals("Update Maven dependency", opts.prompt)
        callback(nil)
      end,
    }

    require("duke").update_dependency()
    assert.equals(0, central_calls)

    package.loaded["duke.picker"] = {
      format_dependency = format_dependency,
      select_one = function(items, opts, callback)
        if opts.prompt == "Update Maven dependency" then
          callback(items[1])
        else
          callback(nil)
        end
      end,
    }
    require("duke").update_dependency()
    assert.equals(1, central_calls)

    package.loaded["duke.picker"] = {
      select_one = function(items, opts, callback)
        if opts.prompt == "Update Maven dependency" then
          callback(items[1])
        else
          callback("1.0")
        end
      end,
    }
    require("duke").update_dependency()

    assert.equals(2, central_calls)
    assert.same(original, vim.fn.readfile(pom_path))
    assert.is_truthy(table.concat(notices, "\n"):find("already uses version 1.0", 1, true))
  end)

  it("rejects property and stale Maven dependency updates", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local pom_path = vim.fs.joinpath(cwd, "pom.xml")
    local function pom_lines(version)
      return {
        "<project>",
        "  <dependencies>",
        "    <dependency>",
        "      <groupId>com.example</groupId>",
        "      <artifactId>demo</artifactId>",
        "      <version>" .. version .. "</version>",
        "    </dependency>",
        "  </dependencies>",
        "</project>",
      }
    end
    vim.fn.writefile(pom_lines("${demo.version}"), pom_path)
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    vim.opt.runtimepath:prepend(original_cwd)
    vim.cmd("enew!")
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded["duke.maven_central"] = {
      versions = function(_, _, callback)
        callback(nil, { "2.0", "1.0" })
      end,
    }
    package.loaded["duke.picker"] = {
      select_one = function(items, _, callback)
        callback(items[1])
      end,
    }

    require("duke").update_dependency()
    assert.is_truthy(table.concat(notices, "\n"):find("demo.version", 1, true))
    assert.same(pom_lines("${demo.version}"), vim.fn.readfile(pom_path))

    notices = {}
    vim.fn.writefile(pom_lines("1.0"), pom_path)
    package.loaded["duke.picker"] = {
      select_one = function(items, opts, callback)
        if opts.prompt == "Update Maven dependency" then
          callback(items[1])
        else
          vim.fn.writefile(pom_lines("1.1"), pom_path)
          callback("2.0")
        end
      end,
      confirm = function()
        return true
      end,
    }
    require("duke").update_dependency()

    assert.same(pom_lines("1.1"), vim.fn.readfile(pom_path))
    assert.is_truthy(table.concat(notices, "\n"):find("changed", 1, true))
  end)

  it("lists outdated dependencies sequentially and enters the upgrade flow", function()
    local original = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>junit</groupId>",
      "      <artifactId>junit</artifactId>",
      "      <version>3.8.1</version>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>current</artifactId>",
      "      <version>1.0</version>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>property</artifactId>",
      "      <version>${property.version}</version>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local pom_path = open_pom(original)
    local lookups = {}
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded["duke.maven_central"] = {
      versions = function(group_id, artifact_id, callback)
        lookups[#lookups + 1] = group_id .. ":" .. artifact_id
        if artifact_id == "junit" then
          callback(nil, { "4.13.2", "3.8.1" })
        else
          callback(nil, { "1.0" })
        end
      end,
    }
    package.loaded["duke.managed"] = {
      resolve = function(_, _, callback)
        callback("mvn unavailable")
      end,
    }
    package.loaded["duke.picker"] = {
      format_dependency = format_dependency,
      select_one = function(items, opts, callback)
        if opts.prompt == "Outdated Maven dependencies" then
          assert.equals(1, #items)
          assert.equals("junit:junit  3.8.1 -> 4.13.2", opts.format_item(items[1]))
          callback(items[1])
          return
        end
        assert.equals("Maven Central version for junit:junit", opts.prompt)
        assert.same({
          { name = "4.13.2", value = "4.13.2" },
          { name = "3.8.1", value = "3.8.1" },
        }, items)
        assert.equals("4.13.2", opts.default)
        callback(nil)
      end,
    }

    require("duke").outdated_dependencies()

    assert.same({ "junit:junit", "com.example:current" }, lookups)
    assert.is_truthy(table.concat(notices, "\n"):find("1 managed dependency", 1, true))
    assert.is_truthy(table.concat(notices, "\n"):find("1 property-backed dependency", 1, true))
    assert.same(original, vim.fn.readfile(pom_path))
  end)

  it("shows partial outdated results and stops after a rate limit", function()
    local original = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>first</artifactId>",
      "      <version>1.0</version>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>limited</artifactId>",
      "      <version>1.0</version>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>unchecked</artifactId>",
      "      <version>1.0</version>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local pom_path = open_pom(original)
    local lookups = {}
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded["duke.maven_central"] = {
      versions = function(_, artifact_id, callback)
        lookups[#lookups + 1] = artifact_id
        if artifact_id == "limited" then
          callback("Maven Central HTTP 429: rate limited")
        else
          callback(nil, { "2.0", "1.0" })
        end
      end,
    }
    package.loaded["duke.picker"] = {
      format_dependency = format_dependency,
      select_one = function(items, opts, callback)
        assert.equals("Outdated Maven dependencies", opts.prompt)
        assert.equals(1, #items)
        assert.equals("com.example:first  1.0 -> 2.0", opts.format_item(items[1]))
        callback(nil)
      end,
    }

    require("duke").outdated_dependencies()

    assert.same({ "first", "limited" }, lookups)
    assert.is_truthy(table.concat(notices, "\n"):find("2 dependencies not checked", 1, true))
    assert.same(original, vim.fn.readfile(pom_path))
  end)

  it("reports managed-only and up-to-date dependency sets without a picker", function()
    local managed = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local pom_path = open_pom(managed)
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded["duke.maven_central"] = {
      versions = function()
        error("managed dependency must not be looked up")
      end,
    }
    package.loaded["duke.managed"] = {
      resolve = function(_, _, callback)
        callback("mvn unavailable")
      end,
    }
    package.loaded["duke.picker"] = {
      select_one = function()
        error("managed-only result must not open a picker")
      end,
    }

    require("duke").outdated_dependencies()

    assert.equals(4, #notices)
    assert.is_truthy(notices[2]:find("failed", 1, true))
    assert.is_truthy(notices[4]:find("1 managed dependency skipped", 1, true))
    assert.same(managed, vim.fn.readfile(pom_path))

    local current = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>current</artifactId>",
      "      <version>1.0</version>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    vim.fn.writefile(current, pom_path)
    notices = {}
    package.loaded["duke.maven_central"] = {
      versions = function(_, _, callback)
        callback(nil, { "1.0" })
      end,
    }

    require("duke").outdated_dependencies()

    assert.equals(4, #notices)
    assert.is_truthy(notices[1]:find("0/1", 1, true))
    assert.is_truthy(notices[2]:find("1/1", 1, true))
    assert.is_truthy(notices[4]:find("1 dependencies checked, all up to date", 1, true))
    assert.same(current, vim.fn.readfile(pom_path))
  end)

  it(
    "shows managed dependencies in the outdated view with resolved version and managing parent",
    function()
      local original = {
        "<project>",
        "  <parent>",
        "    <groupId>org.springframework.boot</groupId>",
        "    <artifactId>spring-boot-starter-parent</artifactId>",
        "    <version>3.5.3</version>",
        "  </parent>",
        "  <dependencies>",
        "    <dependency>",
        "      <groupId>org.springframework.boot</groupId>",
        "      <artifactId>spring-boot-starter-web</artifactId>",
        "    </dependency>",
        "  </dependencies>",
        "</project>",
      }
      local pom_path = open_pom(original)
      local notices = {}
      vim.notify = function(message)
        notices[#notices + 1] = message
      end
      package.loaded["duke.maven_central"] = {
        versions = function(_, _, callback)
          callback(nil, { "3.6.0" })
        end,
      }
      package.loaded["duke.managed"] = {
        resolve = function(_, deps, callback)
          assert.equals(1, #deps)
          callback(nil, { ["org.springframework.boot:spring-boot-starter-web"] = "3.5.3" })
        end,
      }
      local picker_items
      package.loaded["duke.picker"] = {
        select_one = function(items, opts, callback)
          picker_items = items
          assert.equals("Outdated Maven dependencies", opts.prompt)
          callback(nil) -- Cancel, no upgrade.
        end,
      }

      require("duke").outdated_dependencies()

      assert.equals(1, #picker_items)
      local item = picker_items[1]
      assert.equals("org.springframework.boot", item.dependency.group_id)
      assert.equals("spring-boot-starter-web", item.dependency.artifact_id)
      assert.equals("3.5.3", item.dependency.version)
      assert.equals("3.6.0", item.latest)
      assert.is_true(item.dependency.managed)
      assert.same(original, vim.fn.readfile(pom_path))
    end
  )

  it("selecting a managed outdated row notifies and writes nothing", function()
    local original = {
      "<project>",
      "  <parent>",
      "    <groupId>org.springframework.boot</groupId>",
      "    <artifactId>spring-boot-starter-parent</artifactId>",
      "    <version>3.5.3</version>",
      "  </parent>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local pom_path = open_pom(original)
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded["duke.maven_central"] = {
      versions = function(_, _, callback)
        callback(nil, { "3.6.0" })
      end,
    }
    package.loaded["duke.managed"] = {
      resolve = function(_, _, callback)
        callback(nil, { ["org.springframework.boot:spring-boot-starter-web"] = "3.5.3" })
      end,
    }
    package.loaded["duke.picker"] = {
      select_one = function(items, _, callback)
        callback(items[1]) -- Select the managed dep.
      end,
    }

    require("duke").outdated_dependencies()

    assert.same(original, vim.fn.readfile(pom_path))
    local combined = table.concat(notices, "\n")
    assert.is_truthy(combined:find(":DukeBootUpgrade", 1, true))
  end)

  it("shows managed dependencies as unselectable rows in :DukeUpgrade", function()
    local original = {
      "<project>",
      "  <parent>",
      "    <groupId>org.springframework.boot</groupId>",
      "    <artifactId>spring-boot-starter-parent</artifactId>",
      "    <version>3.5.3</version>",
      "  </parent>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local pom_path = open_pom(original)
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded["duke.managed"] = {
      resolve = function(_, _, callback)
        callback(nil, { ["org.springframework.boot:spring-boot-starter-web"] = "3.5.3" })
      end,
    }
    local picker_items, format_fn
    package.loaded["duke.picker"] = {
      format_dependency = format_dependency,
      select_one = function(items, opts, callback)
        picker_items = items
        format_fn = opts.format_item
        local managed_item = items[1]
        callback(managed_item) -- Select the managed dep.
      end,
    }

    require("duke").update_dependency()

    assert.equals(1, #picker_items)
    assert.is_true(picker_items[1].managed)
    assert.equals("3.5.3", picker_items[1].version)
    -- Format shows managed marker (may or may not include parent name depending on POM parsing).
    local formatted = format_fn(picker_items[1])
    assert.is_truthy(formatted:find("managed by", 1, true))
    -- POM unchanged.
    assert.same(original, vim.fn.readfile(pom_path))
    -- Notice names :DukeBootUpgrade.
    local combined = table.concat(notices, "\n")
    assert.is_truthy(combined:find(":DukeBootUpgrade", 1, true))
  end)

  it("marks installed Maven Central results from a fresh pom read", function()
    local pom_path = open_pom({ "<project>", "  <state>initial</state>", "</project>" })
    package.loaded["duke.pom"] = {
      spring_boot_version = function()
        return nil
      end,
      list = function(lines)
        assert.is_truthy(table.concat(lines, "\n"):find("fresh", 1, true))
        return { { group_id = "com.google.guava", artifact_id = "guava" } }
      end,
    }
    package.loaded["duke.maven_central"] = {
      search = function(_, callback)
        vim.fn.writefile({ "<project>", "  <state>fresh</state>", "</project>" }, pom_path)
        callback(nil, {
          { group_id = "com.google.guava", artifact_id = "guava", version = "33.4.8-jre" },
          { group_id = "org.junit.jupiter", artifact_id = "junit-jupiter", version = "5.13.4" },
        })
      end,
      versions = function()
        error("cancelled result picker must not fetch versions")
      end,
    }
    package.loaded["duke.picker"] = {
      format_dependency = format_dependency,
      input = function(_, _, callback)
        callback("test")
      end,
      select_many = function(items, opts, callback)
        assert.equals("com.google.guava:guava  33.4.8-jre  [installed]", opts.format_item(items[1]))
        assert.equals("org.junit.jupiter:junit-jupiter  5.13.4", opts.format_item(items[2]))
        callback(nil)
      end,
    }

    require("duke").add_dependency()
  end)

  it("removes multiple Maven dependencies only after confirmation", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local pom_path = vim.fs.joinpath(cwd, "pom.xml")
    local original = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>first</artifactId>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>middle</artifactId>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>last</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    vim.fn.writefile(original, pom_path)
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    vim.opt.runtimepath:prepend(original_cwd)
    vim.cmd("enew!")
    local confirmation
    package.loaded["duke.picker"] = {
      format_dependency = format_dependency,
      select_many = function(items, opts, callback)
        assert.equals("Remove Maven dependencies", opts.prompt)
        assert.equals("com.example:first", opts.format_item(items[1]))
        assert.equals(3, #items)
        callback({ items[1], items[3] })
      end,
      confirm = function(message, action)
        confirmation = message
        assert.equals("Remove", action)
        return true
      end,
    }

    require("duke").remove_dependency()

    assert.is_truthy(confirmation:find("com.example:first", 1, true))
    assert.is_truthy(confirmation:find("com.example:last", 1, true))
    assert.same({
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>middle</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }, vim.fn.readfile(pom_path))
  end)

  it("cancels or atomically aborts stale Maven dependency removal", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local pom_path = vim.fs.joinpath(cwd, "pom.xml")
    local original = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>demo</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    vim.fn.writefile(original, pom_path)
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    vim.opt.runtimepath:prepend(original_cwd)
    vim.cmd("enew!")
    local confirm_calls = 0
    package.loaded["duke.picker"] = {
      select_many = function(_, _, callback)
        callback(nil)
      end,
      confirm = function()
        confirm_calls = confirm_calls + 1
        return true
      end,
    }
    require("duke").remove_dependency()
    assert.equals(0, confirm_calls)

    package.loaded["duke.picker"] = {
      select_many = function(items, _, callback)
        callback(items)
      end,
      confirm = function()
        confirm_calls = confirm_calls + 1
        return false
      end,
    }
    require("duke").remove_dependency()
    assert.equals(1, confirm_calls)
    assert.same(original, vim.fn.readfile(pom_path))

    local stale = { "<project>", "  <dependencies>", "  </dependencies>", "</project>" }
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded["duke.picker"] = {
      select_many = function(items, _, callback)
        callback(items)
      end,
      confirm = function()
        vim.fn.writefile(stale, pom_path)
        return true
      end,
    }
    require("duke").remove_dependency()

    assert.same(stale, vim.fn.readfile(pom_path))
    assert.is_truthy(table.concat(notices, "\n"):find("changed", 1, true))
  end)

  it("keeps Spring catalog insertion for Boot poms", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local pom_path = vim.fs.joinpath(cwd, "pom.xml")
    vim.fn.writefile({ "<project>", "  <state>initial</state>", "</project>" }, pom_path)
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    vim.opt.runtimepath:prepend(original_cwd)
    vim.cmd("enew!")
    local received = {}
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end

    package.loaded["duke.config"] = {
      get = function()
        return {
          spring = {
            metadata_url = "https://initializr.test",
            dependencies_url = "https://initializr.test/dependencies",
          },
        }
      end,
    }
    package.loaded["duke.pom"] = {
      spring_boot_version = function()
        return "3.5.4"
      end,
      list = function(lines)
        assert.is_truthy(table.concat(lines, "\n"):find("fresh", 1, true))
        return {
          { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-web" },
        }
      end,
      insert = function(lines, dependencies)
        received.dependencies = dependencies
        return lines, #dependencies
      end,
    }
    package.loaded["duke.metadata"] = {
      cache_path = function(kind)
        return kind
      end,
      fetch_cached = function(url, _, _, callback)
        if url:find("dependencies", 1, true) then
          vim.fn.writefile({ "<project>", "  <state>fresh</state>", "</project>" }, pom_path)
          callback(nil, {
            dependencies = {
              web = {
                groupId = "org.springframework.boot",
                artifactId = "spring-boot-starter-web",
              },
              data = {
                groupId = "org.springframework.boot",
                artifactId = "spring-boot-starter-data-jpa",
              },
            },
          })
        else
          callback(nil, { dependencies = {} })
        end
      end,
      flatten_dependencies = function()
        return {
          { id = "web", name = "Spring Web", group = "Web" },
          { id = "data", name = "Spring Data JPA", group = "Data" },
        }
      end,
      is_catalog = function()
        return true
      end,
      is_client = function()
        return true
      end,
      is_direct = function()
        return true
      end,
      resolve = function(_, ids)
        assert.same({ "data" }, ids)
        return {
          { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-data-jpa" },
        }, {}
      end,
    }
    package.loaded["duke.maven_central"] = {
      search = function()
        error("Maven Central path must not run")
      end,
    }
    package.loaded["duke.picker"] = {
      format_dependency = format_dependency,
      input = function()
        error("search prompt must not run")
      end,
      select_many = function(items, opts, callback)
        assert.equals("Add Spring dependencies", opts.prompt)
        assert.equals(
          "org.springframework.boot:spring-boot-starter-web  Spring Web [Web]  [installed]",
          opts.format_item(items[1])
        )
        assert.equals(
          "org.springframework.boot:spring-boot-starter-data-jpa  Spring Data JPA [Data]",
          opts.format_item(items[2])
        )
        callback({ items[2] })
      end,
      confirm = function()
        return true
      end,
    }

    require("duke").add_dependency()

    assert.same({
      { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-data-jpa" },
    }, received.dependencies)
    assert.is_truthy(
      table
        .concat(notices, "\n")
        :find("added org.springframework.boot:spring-boot-starter-data-jpa", 1, true)
    )
  end)

  it("requires confirmation before Spring catalog insertion", function()
    local pom_path = open_pom({ "<project>", "  <state>initial</state>", "</project>" })
    local original = vim.fn.readfile(pom_path)
    local confirmation
    package.loaded["duke.config"] = {
      get = function()
        return {
          spring = {
            metadata_url = "https://initializr.test",
            dependencies_url = "https://initializr.test/dependencies",
          },
        }
      end,
    }
    package.loaded["duke.pom"] = {
      spring_boot_version = function()
        return "3.5.4"
      end,
      list = function()
        return {}
      end,
      insert = function()
        error("Spring dependency insert must not run without confirmation")
      end,
    }
    package.loaded["duke.metadata"] = {
      cache_path = function(kind)
        return kind
      end,
      fetch_cached = function(url, _, _, callback)
        if url:find("dependencies", 1, true) then
          callback(nil, {
            dependencies = {
              web = {
                groupId = "org.springframework.boot",
                artifactId = "spring-boot-starter-web",
              },
            },
          })
        else
          callback(nil, { dependencies = {} })
        end
      end,
      flatten_dependencies = function()
        return { { id = "web", name = "Spring Web", group = "Web" } }
      end,
      is_catalog = function()
        return true
      end,
      is_client = function()
        return true
      end,
      is_direct = function()
        return true
      end,
      resolve = function()
        return {
          { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-web" },
        }, {}
      end,
    }
    package.loaded["duke.picker"] = {
      select_many = function(items, _, callback)
        callback(items)
      end,
      confirm = function(message, action)
        confirmation = message
        assert.equals("Add", action)
        return false
      end,
    }

    require("duke").add_dependency()

    assert.is_truthy(confirmation:find("org.springframework.boot:spring-boot-starter-web", 1, true))
    assert.same(original, vim.fn.readfile(pom_path))
  end)

  it("caches public Java runtime discovery", function()
    local discovery_count = 0
    package.loaded["duke"] = nil
    package.loaded["duke.config"] = {
      get = function()
        return { java_homes = {} }
      end,
    }
    package.loaded["duke.java"] = {
      active = function()
        return "23"
      end,
      discover_homes = function()
        discovery_count = discovery_count + 1
        return { ["23"] = "/jdk/23" }
      end,
    }

    local plugin = require("duke")
    local first = plugin.java_runtimes()
    first.homes["23"] = "/mutated"
    local second = plugin.java_runtimes()

    assert.equals(1, discovery_count)
    assert.equals("23", second.active)
    assert.equals("/jdk/23", second.homes["23"])

    plugin.java_runtimes({ refresh = true })
    assert.equals(2, discovery_count)
  end)

  it("uses refreshed public Java runtime cache for wizard creation", function()
    local active = "17"
    local created = {}
    package.loaded["duke"] = nil
    package.loaded["duke.config"] = {
      get = function()
        return {
          group_id = "com.example",
          artifact_id = "demo",
          java_versions = {},
          java_homes = {},
          java_version = "auto",
          maven = {
            command = "mvn",
            runner_java_version = "auto",
            project_version = "1.0-SNAPSHOT",
            wrapper = false,
            archetypes = {
              {
                group_id = "org.apache.maven.archetypes",
                artifact_id = "maven-archetype-quickstart",
                version = "1.5",
              },
            },
            timeout = 1000,
          },
        }
      end,
    }
    package.loaded["duke.java"] = {
      active = function()
        return active
      end,
      discover_homes = function()
        return {
          ["17"] = "/jdk/17",
          ["23"] = "/jdk/23",
        }
      end,
      installed = function(_, _, runtimes)
        return { runtimes.active }
      end,
      default = function(configured, _, fallback)
        return configured ~= "auto" and configured or fallback
      end,
      runner_env = function(version, _, homes)
        return { JAVA_HOME = homes[version] }
      end,
      maven_runtime_async = function(_, callback)
        callback(active)
      end,
    }
    package.loaded["duke.maven"] = {
      validate = function()
        return nil
      end,
      package_name = function()
        return "com.example.demo"
      end,
      validate_package = function()
        return nil
      end,
      create = function(opts)
        created[#created + 1] = opts
      end,
    }
    package.loaded["duke.picker"] = {
      input = function(prompt, default, callback)
        if prompt == "Destination directory: " then
          callback("/tmp")
        else
          callback(default)
        end
      end,
      confirm = function()
        return true
      end,
      select_one = function(items, _, callback)
        callback(items[1])
      end,
    }

    local plugin = require("duke")
    plugin.new_maven()
    active = "23"
    plugin.java_runtimes({ refresh = true })
    plugin.new_maven()

    assert.equals("/jdk/17", created[1].env.JAVA_HOME)
    assert.equals("/jdk/23", created[2].env.JAVA_HOME)
  end)

  it("selects an eligible public Java runtime", function()
    local active = "23"
    package.loaded["duke"] = nil
    package.loaded["duke.config"] = {
      get = function()
        return { java_homes = {} }
      end,
    }
    package.loaded["duke.java"] = {
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

    local plugin = require("duke")

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
    local confirm = true
    local runtime_calls = 0
    local creation_calls = 0
    package.loaded["duke"] = nil
    package.loaded["duke.config"] = {
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
            archetypes = {
              {
                group_id = "org.apache.maven.archetypes",
                artifact_id = "maven-archetype-quickstart",
                version = "1.5",
              },
            },
            timeout = 1000,
          },
        }
      end,
    }
    package.loaded["duke.java"] = {
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
        runtime_calls = runtime_calls + 1
        assert.is_truthy(received.review)
        callback("23")
      end,
    }
    package.loaded["duke.picker"] = {
      input = function(prompt, default, callback)
        if prompt == "Destination directory: " then
          callback("/tmp")
        elseif prompt == "Package name: " then
          callback("com.acme.maven")
        else
          callback(default)
        end
      end,
      confirm = function(prompt)
        received.review = prompt
        return confirm
      end,
      select_one = function(items, _, callback)
        callback(items[1])
      end,
    }
    package.loaded["duke.maven"] = {
      validate = function()
        return nil
      end,
      package_name = function()
        return "com.example.demo"
      end,
      validate_package = function()
        return nil
      end,
      create = function(opts)
        creation_calls = creation_calls + 1
        received.create = opts
      end,
    }

    require("duke").new_maven()

    assert.equals(1, active_calls)
    assert.equals(1, discovery_calls)
    assert.same({ active = "23", homes = { ["23"] = "/jdk/23" } }, received.installed)
    assert.equals("23", received.fallback)
    assert.same({ ["23"] = "/jdk/23" }, received.runner_homes)
    assert.equals("/jdk/23", received.create.env.JAVA_HOME)
    assert.equals("/tmp", received.create.cwd)
    assert.equals("com.acme.maven", received.create.package_name)
    assert.equals("maven-archetype-quickstart", received.create.archetype.artifact_id)
    assert.is_truthy(received.review:find("Destination: /tmp/demo", 1, true))
    assert.is_truthy(received.review:find("Coordinates: com.example:demo", 1, true))
    assert.is_truthy(received.review:find("Build system: Maven", 1, true))
    assert.is_truthy(received.review:find("Package: com.acme.maven", 1, true))
    assert.is_truthy(received.review:find("Java target: 23", 1, true))
    assert.is_truthy(received.review:find("Runner JVM: 23", 1, true))

    confirm = false
    require("duke").new_maven()

    assert.equals(1, runtime_calls)
    assert.equals(1, creation_calls)
  end)

  it("rejects blank destination instead of defaulting to cwd", function()
    local creation_calls = 0
    package.loaded["duke"] = nil
    package.loaded["duke.config"] = {
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
            project_version = "1.0-SNAPSHOT",
            wrapper = false,
            archetypes = {
              {
                group_id = "org.apache.maven.archetypes",
                artifact_id = "maven-archetype-quickstart",
                version = "1.5",
              },
            },
            timeout = 1000,
          },
        }
      end,
    }
    package.loaded["duke.java"] = {
      active = function()
        return "23"
      end,
      discover_homes = function()
        return { ["23"] = "/jdk/23" }
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
      maven_runtime_async = function(_, callback)
        callback("23")
      end,
    }
    package.loaded["duke.maven"] = {
      validate = function()
        return nil
      end,
      package_name = function()
        return "com.example.demo"
      end,
      validate_package = function()
        return nil
      end,
      create = function()
        creation_calls = creation_calls + 1
      end,
    }
    package.loaded["duke.picker"] = {
      input = function(prompt, default, callback)
        if prompt == "Destination directory: " then
          callback("")
        else
          callback(default)
        end
      end,
      confirm = function()
        return true
      end,
      select_one = function(items, _, callback)
        callback(items[1])
      end,
    }

    require("duke").new_maven()

    assert.equals(0, creation_calls)
  end)

  it("uses explicit destination and review for Gradle creation", function()
    local received = {}
    package.loaded["duke"] = nil
    package.loaded["duke.config"] = {
      get = function()
        return {
          group_id = "com.example",
          artifact_id = "demo",
          java_versions = {},
          java_homes = {},
          java_version = "23",
          gradle = {
            command = "gradle",
            runner_java_version = "auto",
            dsl = "kotlin",
            test_framework = "auto",
            timeout = 1000,
            default_project_type = "java-application",
            project_types = { { id = "java-application", name = "Java application" } },
            languages = { "java", "kotlin", "groovy" },
            dsls = { "kotlin", "groovy" },
          },
        }
      end,
    }
    package.loaded["duke.java"] = {
      active = function()
        return "23"
      end,
      discover_homes = function()
        return { ["23"] = "/jdk/23" }
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
      gradle_runtime_async = function(_, callback)
        assert.is_truthy(received.review)
        callback("23")
      end,
    }
    package.loaded["duke.maven"] = {
      validate = function()
        return nil
      end,
      package_name = function()
        return "com.example.demo"
      end,
      validate_package = function()
        return nil
      end,
    }
    package.loaded["duke.picker"] = {
      input = function(prompt, default, callback)
        if prompt == "Destination directory: " then
          callback("/tmp")
        elseif prompt == "Package name: " then
          callback("com.acme.gradle")
        else
          callback(default)
        end
      end,
      confirm = function(prompt)
        received.review = prompt
        return true
      end,
      select_one = function(items, opts, callback)
        local selected = {
          ["Gradle source language"] = "kotlin",
          ["Gradle DSL"] = "groovy",
        }
        if opts.prompt == "Gradle DSL" then
          received.dsl_default = opts.default
        end
        callback(selected[opts.prompt] or items[1])
      end,
    }
    package.loaded["duke.gradle"] = {
      project_type = function(language, project_type)
        return project_type:gsub("^java", language)
      end,
      create = function(opts)
        received.create = opts
      end,
    }

    require("duke").new_gradle()

    assert.equals("/tmp", received.create.cwd)
    assert.equals("com.acme.gradle", received.create.package_name)
    assert.equals("kotlin-application", received.create.project_type)
    assert.equals("groovy", received.create.dsl)
    assert.equals("kotlin", received.dsl_default)
    assert.is_truthy(received.review:find("Destination: /tmp/demo", 1, true))
    assert.is_truthy(received.review:find("Coordinates: com.example:demo", 1, true))
    assert.is_truthy(received.review:find("Build system: Gradle - Java application", 1, true))
    assert.is_truthy(received.review:find("Package: com.acme.gradle", 1, true))
    assert.is_truthy(received.review:find("Source language: kotlin", 1, true))
    assert.is_truthy(received.review:find("Build DSL: groovy", 1, true))
    assert.is_truthy(received.review:find("Java target: 23", 1, true))
    assert.is_truthy(received.review:find("Runner JVM: 23", 1, true))
  end)

  it("keeps derived packages for blank input and rejects reserved packages", function()
    local created = { maven = {}, gradle = {} }
    local package_input = ""
    local active_kind
    package.loaded["duke"] = nil
    package.loaded["duke.config"] = {
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
            project_version = "1.0-SNAPSHOT",
            wrapper = false,
            timeout = 1000,
            archetypes = {
              {
                group_id = "org.apache.maven.archetypes",
                artifact_id = "maven-archetype-quickstart",
                version = "1.5",
              },
            },
          },
          gradle = {
            command = "gradle",
            runner_java_version = "auto",
            dsl = "kotlin",
            dsls = { "kotlin", "groovy" },
            languages = { "java", "kotlin", "groovy" },
            test_framework = "auto",
            timeout = 1000,
            default_project_type = "java-application",
            project_types = { { id = "java-application", name = "Java application" } },
          },
        }
      end,
    }
    package.loaded["duke.java"] = {
      active = function()
        return "23"
      end,
      discover_homes = function()
        return { ["23"] = "/jdk/23" }
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
      maven_runtime_async = function(_, callback)
        callback("23")
      end,
      gradle_runtime_async = function(_, callback)
        callback("23")
      end,
    }
    package.loaded["duke.maven"] = {
      validate = function()
        return nil
      end,
      package_name = function()
        return "com.example.demo"
      end,
      validate_package = function(value)
        return value == "com.class.demo" and "package name contains invalid segments" or nil
      end,
      create = function(opts)
        created.maven[#created.maven + 1] = opts
      end,
    }
    package.loaded["duke.gradle"] = {
      project_type = function(language, project_type)
        return project_type:gsub("^java", language)
      end,
      create = function(opts)
        created.gradle[#created.gradle + 1] = opts
      end,
    }
    package.loaded["duke.picker"] = {
      input = function(prompt, default, callback)
        if prompt == "Destination directory: " then
          callback("/tmp")
        elseif prompt == "Package name: " then
          callback(package_input)
        else
          callback(default)
        end
      end,
      confirm = function()
        return true
      end,
      select_one = function(items, opts, callback)
        if opts.prompt == "Gradle source language" or opts.prompt == "Gradle DSL" then
          callback(opts.default)
        else
          callback(items[1])
        end
      end,
    }

    local plugin = require("duke")
    for _, kind in ipairs({ "maven", "gradle" }) do
      active_kind = kind
      plugin["new_" .. active_kind]()
      assert.equals("com.example.demo", created[kind][1].package_name)
    end

    package_input = "com.class.demo"
    plugin.new_maven()
    plugin.new_gradle()
    assert.equals(1, #created.maven)
    assert.equals(1, #created.gradle)
  end)

  local function write_reactor_pom(cwd)
    vim.fn.writefile({
      "<project>",
      "  <groupId>com.example</groupId>",
      "  <artifactId>parent</artifactId>",
      "  <version>1.0.0</version>",
      "  <packaging>pom</packaging>",
      "</project>",
    }, vim.fs.joinpath(cwd, "pom.xml"))
  end

  it("drives :DukeModule through artifact id, package name, and confirmation", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    write_reactor_pom(cwd)
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    vim.cmd("enew!")

    local prompts = {}
    local received = {}
    package.loaded["duke.picker"] = {
      input = function(prompt, default, callback)
        prompts[#prompts + 1] = { prompt = prompt, default = default }
        if prompt == "Artifact ID: " then
          callback("child")
        else
          callback(default)
        end
      end,
      confirm = function(message)
        received.confirm = message
        return true
      end,
    }
    package.loaded["duke.api"] = {
      add_module = function(opts, callback)
        received.opts = opts
        callback({
          ok = true,
          parent_pom = vim.fs.joinpath(cwd, "pom.xml"),
          module_dir = vim.fs.joinpath(cwd, "child"),
          rolled_back = false,
        })
      end,
    }
    package.loaded["duke.project"] = {
      entry = function(path)
        return vim.fs.joinpath(path, "src/main/java/com/example/child/Child.java")
      end,
    }
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end

    vim.cmd("filetype off")
    require("duke").new_module()
    vim.cmd("filetype on")

    assert.same(
      { "Artifact ID: ", "Package name: " },
      vim.tbl_map(function(entry)
        return entry.prompt
      end, prompts)
    )
    assert.equals("com.example.child", prompts[2].default)
    assert.equals(cwd, received.opts.reactor_dir)
    assert.equals("child", received.opts.artifact_id)
    assert.equals("com.example.child", received.opts.package_name)
    assert.is_truthy(received.confirm:find("child", 1, true))
    assert.matches("Child%.java$", vim.api.nvim_buf_get_name(0))
    assert.is_truthy(
      table.concat(notices, "\n"):find("module ready", 1, true),
      "notifications: " .. vim.inspect(notices)
    )
    vim.cmd("bwipeout!")
  end)

  it("cancels each :DukeModule step and the confirmation without any write", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    write_reactor_pom(cwd)
    vim.cmd.cd(vim.fn.fnameescape(cwd))

    package.loaded["duke.api"] = {
      add_module = function()
        error("add_module must not run when a wizard step is cancelled")
      end,
    }

    package.loaded["duke.picker"] = {
      input = function(_, _, callback)
        callback(nil)
      end,
      confirm = function()
        error("confirm must not run when artifact id is cancelled")
      end,
    }
    require("duke").new_module()

    package.loaded["duke.picker"] = {
      input = function(prompt, _, callback)
        if prompt == "Artifact ID: " then
          callback("child")
        else
          callback(nil)
        end
      end,
      confirm = function()
        error("confirm must not run when package name is cancelled")
      end,
    }
    require("duke").new_module()

    package.loaded["duke.picker"] = {
      input = function(prompt, default, callback)
        if prompt == "Artifact ID: " then
          callback("child")
        else
          callback(default)
        end
      end,
      confirm = function()
        return false
      end,
    }
    require("duke").new_module()
  end)

  it("reactor_dir defaults to cwd for :DukeModule", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    write_reactor_pom(cwd)
    vim.cmd.cd(vim.fn.fnameescape(cwd))

    local received = {}
    package.loaded["duke.picker"] = {
      input = function(prompt, default, callback)
        callback(prompt == "Artifact ID: " and "child" or default)
      end,
      confirm = function()
        return true
      end,
    }
    package.loaded["duke.api"] = {
      add_module = function(opts, callback)
        received.opts = opts
        callback({ ok = true, parent_pom = "p", module_dir = "m", rolled_back = false })
      end,
    }
    package.loaded["duke.project"] = {
      entry = function()
        return vim.fs.joinpath(cwd, "pom.xml")
      end,
    }

    require("duke").new_module()

    assert.equals(cwd, received.opts.reactor_dir)
    vim.cmd("bwipeout!")
  end)

  it("notifies and logs a concise message when :DukeModule fails", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    write_reactor_pom(cwd)
    vim.cmd.cd(vim.fn.fnameescape(cwd))

    local logged = {}
    package.loaded["duke.log"] = {
      add = function(_, message)
        logged[#logged + 1] = message
      end,
    }
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    package.loaded["duke.picker"] = {
      input = function(prompt, default, callback)
        callback(prompt == "Artifact ID: " and "child" or default)
      end,
      confirm = function()
        return true
      end,
    }
    package.loaded["duke.api"] = {
      add_module = function(_, callback)
        callback({ ok = false, error = "reactor packaging must be pom" })
      end,
    }

    require("duke").new_module()

    assert.is_truthy(table.concat(notices, "\n"):find("reactor packaging must be pom", 1, true))
    assert.is_true(#logged >= 1)
  end)

  local function boot_pom(version)
    return {
      "<project>",
      "  <parent>",
      "    <groupId>org.springframework.boot</groupId>",
      "    <artifactId>spring-boot-starter-parent</artifactId>",
      "    <version>" .. version .. "</version>",
      "  </parent>",
      "  <artifactId>demo</artifactId>",
      "</project>",
    }
  end

  it("lists Boot versions, confirms, and writes exactly the parent version", function()
    local original = boot_pom("3.3.0")
    local pom_path = open_pom(original)
    local lookups = {}
    local confirmed
    package.loaded["duke.maven_central"] = {
      versions = function(group_id, artifact_id, callback)
        lookups[#lookups + 1] = group_id .. ":" .. artifact_id
        callback(nil, { "3.3.5", "3.3.0" })
      end,
    }
    package.loaded["duke.picker"] = {
      select_one = function(items, opts, callback)
        assert.equals("Spring Boot parent version", opts.prompt)
        assert.same({ "3.3.5", "3.3.0" }, items)
        assert.equals("3.3.5", opts.default)
        assert.equals("3.3.0  (current)", opts.format_item("3.3.0"))
        callback("3.3.5")
      end,
      confirm = function(message)
        confirmed = message
        return true
      end,
    }

    require("duke").upgrade_boot_parent()

    assert.same({ "org.springframework.boot:spring-boot-starter-parent" }, lookups)
    assert.matches("3%.3%.0", confirmed)
    assert.matches("3%.3%.5", confirmed)
    assert.same(boot_pom("3.3.5"), vim.fn.readfile(pom_path))
  end)

  it("writes nothing when the Boot parent confirmation is declined", function()
    local original = boot_pom("3.3.0")
    local pom_path = open_pom(original)
    package.loaded["duke.maven_central"] = {
      versions = function(_, _, callback)
        callback(nil, { "3.3.5", "3.3.0" })
      end,
    }
    package.loaded["duke.picker"] = {
      select_one = function(_, _, callback)
        callback("3.3.5")
      end,
      confirm = function()
        return false
      end,
    }

    require("duke").upgrade_boot_parent()

    assert.same(original, vim.fn.readfile(pom_path))
  end)

  it("writes nothing when the Boot version picker is cancelled", function()
    local original = boot_pom("3.3.0")
    local pom_path = open_pom(original)
    local confirm_calls = 0
    package.loaded["duke.maven_central"] = {
      versions = function(_, _, callback)
        callback(nil, { "3.3.5", "3.3.0" })
      end,
    }
    package.loaded["duke.picker"] = {
      select_one = function(_, _, callback)
        callback(nil)
      end,
      confirm = function()
        confirm_calls = confirm_calls + 1
        return true
      end,
    }

    require("duke").upgrade_boot_parent()

    assert.equals(0, confirm_calls)
    assert.same(original, vim.fn.readfile(pom_path))
  end)

  it("re-reads the pom after the version picker before writing the Boot parent", function()
    local original = boot_pom("3.3.0")
    local pom_path = open_pom(original)
    package.loaded["duke.maven_central"] = {
      versions = function(_, _, callback)
        callback(nil, { "3.3.5", "3.3.0" })
      end,
    }
    package.loaded["duke.picker"] = {
      select_one = function(_, _, callback)
        vim.fn.writefile(boot_pom("3.4.0"), pom_path)
        callback("3.3.5")
      end,
      confirm = function()
        return true
      end,
    }
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end

    require("duke").upgrade_boot_parent()

    assert.same(boot_pom("3.4.0"), vim.fn.readfile(pom_path))
    assert.is_truthy(table.concat(notices, "\n"):find("changed; run command again", 1, true))
  end)

  it("refuses a non-Boot or property-backed parent without a version lookup", function()
    local central_calls = 0
    package.loaded["duke.maven_central"] = {
      versions = function()
        central_calls = central_calls + 1
      end,
    }
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end

    local plain_pom = open_pom({
      "<project>",
      "  <parent>",
      "    <groupId>com.example</groupId>",
      "    <artifactId>company-parent</artifactId>",
      "    <version>1.0.0</version>",
      "  </parent>",
      "</project>",
    })
    require("duke").upgrade_boot_parent()
    assert.same({
      "<project>",
      "  <parent>",
      "    <groupId>com.example</groupId>",
      "    <artifactId>company-parent</artifactId>",
      "    <version>1.0.0</version>",
      "  </parent>",
      "</project>",
    }, vim.fn.readfile(plain_pom))

    assert.equals(0, central_calls)
    assert.is_truthy(table.concat(notices, "\n"):find("Spring Boot", 1, true))
  end)

  it("refuses a property-backed parent version without a version lookup", function()
    local central_calls = 0
    package.loaded["duke.maven_central"] = {
      versions = function()
        central_calls = central_calls + 1
      end,
    }
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end

    local property_pom = open_pom({
      "<project>",
      "  <properties><boot.version>3.3.0</boot.version></properties>",
      "  <parent>",
      "    <groupId>org.springframework.boot</groupId>",
      "    <artifactId>spring-boot-starter-parent</artifactId>",
      "    <version>${boot.version}</version>",
      "  </parent>",
      "</project>",
    })
    local before = vim.fn.readfile(property_pom)

    require("duke").upgrade_boot_parent()

    assert.same(before, vim.fn.readfile(property_pom))
    assert.equals(0, central_calls)
    assert.is_truthy(table.concat(notices, "\n"):find("boot.version", 1, true))
  end)

  it("shows coordinate info in a scratch buffer via :DukeInfo", function()
    package.loaded["duke.pom_file"] = {
      read = function()
        return {
          "<project>",
          "  <artifactId>demo</artifactId>",
          "</project>",
        }
      end,
    }
    package.loaded["duke.maven_central"] = {
      versions_display = function(_, _, callback)
        callback(nil, {
          { name = "33.4.8-jre  (2026-07)", value = "33.4.8-jre" },
          { name = "33.4.7-jre  (2026-06)", value = "33.4.7-jre" },
        })
      end,
    }
    package.loaded["duke.picker"] = {
      input = function(_, _, callback)
        callback("com.google.guava:guava")
      end,
    }
    local created_bufs = {}
    local original_create = vim.api.nvim_create_buf
    vim.api.nvim_create_buf = function(listed, scratch)
      local buf = original_create(listed, scratch)
      table.insert(created_bufs, buf)
      return buf
    end
    local notices = {}
    vim.notify = function(message)
      notices[#notices + 1] = message
    end

    require("duke").info()

    assert.equals(1, #notices)
    assert.is_truthy(notices[1]:find("looking up", 1, true))
    assert.equals(1, #created_bufs)
    local lines = vim.api.nvim_buf_get_lines(created_bufs[1], 0, -1, false)
    assert.is_truthy(lines[1]:find("com.google.guava:guava", 1, true))
    assert.is_truthy(lines[2]:find("33.4.8-jre", 1, true))
    vim.api.nvim_create_buf = original_create
  end)

  it("shows grouped command help in a closable scratch buffer", function()
    require("duke").help()

    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.equals("Duke commands", lines[1])
    assert.is_truthy(table.concat(lines, "\n"):find(":DukeAdd", 1, true))
    assert.is_truthy(table.concat(lines, "\n"):find(":DukeHealth", 1, true))
    assert.equals("duke", vim.bo[buf].filetype)
    assert.is_false(vim.bo[buf].modifiable)
    vim.api.nvim_win_close(0, true)
  end)

  it("rejects invalid coordinates in :DukeInfo", function()
    local notices = {}
    vim.notify = function(message, level)
      if level == vim.log.levels.ERROR then
        notices[#notices + 1] = message
      end
    end

    require("duke").info("bad-coordinate")

    assert.equals(1, #notices)
    assert.is_truthy(notices[1]:find("invalid coordinate", 1, true))
  end)

  it("renders Maven dependency insight without changing the POM", function()
    local pom_path = open_pom({
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.test</groupId>",
      "      <artifactId>direct</artifactId>",
      "      <version>1.0</version>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    })
    local original = vim.fn.readfile(pom_path)
    local calls = {}
    package.loaded["duke.dependency_insight"] = {
      coordinate_error = function()
        return nil
      end,
      inspect = function(received_pom, coordinate, opts, callback)
        assert.equals("mvn", opts.command)
        assert.equals(180000, opts.timeout)
        calls[#calls + 1] = { received_pom, coordinate }
        callback(nil, {
          "com.example:demo:jar:1.0",
          "\\- org.test:direct:jar:1.0:compile",
        })
      end,
    }

    require("duke").dependency_tree()
    local tree_buf = vim.api.nvim_get_current_buf()
    assert.is_false(vim.bo[tree_buf].modifiable)
    assert.equals("duke", vim.bo[tree_buf].filetype)
    assert.is_truthy(
      table
        .concat(vim.api.nvim_buf_get_lines(tree_buf, 0, -1, false), "\n")
        :find("org.test:direct", 1, true)
    )
    vim.api.nvim_win_close(0, true)

    require("duke").dependency_why("org.test:direct")
    local why_buf = vim.api.nvim_get_current_buf()
    assert.is_false(vim.bo[why_buf].modifiable)
    vim.api.nvim_win_close(0, true)

    assert.same({ { pom_path, nil }, { pom_path, "org.test:direct" } }, calls)
    assert.same(original, vim.fn.readfile(pom_path))
  end)

  it("lets DukeWhy choose a root dependency or enter another coordinate", function()
    local pom_path = open_pom({
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.test</groupId>",
      "      <artifactId>direct</artifactId>",
      "      <version>1.0</version>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    })
    local received
    package.loaded["duke.dependency_insight"] = {
      coordinate_error = function()
        return nil
      end,
      inspect = function(received_pom, coordinate, opts, callback)
        assert.equals(pom_path, received_pom)
        assert.equals("mvn", opts.command)
        received = coordinate
        callback(nil, { "com.example:demo:jar:1.0", "\\- " .. coordinate .. ":jar:2.0" })
      end,
    }
    package.loaded["duke.picker"] = {
      select_one = function(items, opts, callback)
        assert.equals("Why is this dependency present?", opts.prompt)
        assert.equals("Enter another coordinate...", opts.format_item(items[1]))
        assert.equals("org.test:direct", opts.format_item(items[2]))
        callback(items[1])
      end,
      input = function(_, _, callback)
        callback("org.transitive:item")
      end,
    }

    require("duke").dependency_why()

    assert.equals("org.transitive:item", received)
    vim.api.nvim_win_close(0, true)
  end)
end)
