describe("plugin surface", function()
  local original_cwd
  local temporary_directories = {}

  before_each(function()
    original_cwd = vim.fn.getcwd()
    vim.g.loaded_java_scaffold = nil
    package.loaded["java_scaffold"] = nil
    vim.cmd("runtime plugin/java-scaffold.lua")
  end)

  after_each(function()
    package.loaded["java_scaffold.config"] = nil
    package.loaded["java_scaffold.gradle"] = nil
    package.loaded["java_scaffold.java"] = nil
    package.loaded["java_scaffold.maven"] = nil
    package.loaded["java_scaffold.maven_central"] = nil
    package.loaded["java_scaffold.metadata"] = nil
    package.loaded["java_scaffold.picker"] = nil
    package.loaded["java_scaffold.pom"] = nil
    package.loaded["java_scaffold.spring"] = nil
    vim.cmd.cd(vim.fn.fnameescape(original_cwd))
    for _, path in ipairs(temporary_directories) do
      vim.fn.delete(path, "rf")
    end
    temporary_directories = {}
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
      package_name = function()
        return "com.example.demo"
      end,
      validate_package = function()
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
    package.loaded["java_scaffold.picker"] = {
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

    package.loaded["java_scaffold.pom"] = {
      spring_boot_version = function()
        return nil
      end,
      insert = function(lines, dependencies)
        received.lines = lines
        received.dependencies = dependencies
        return lines, #dependencies
      end,
    }
    package.loaded["java_scaffold.maven"] = {
      validate = function(group_id, artifact_id)
        received.validated = group_id .. ":" .. artifact_id
      end,
    }
    package.loaded["java_scaffold.maven_central"] = {
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
    package.loaded["java_scaffold.picker"] = {
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
        assert.same({ "33.4.8-jre", "33.4.7-jre" }, items)
        assert.equals("33.4.8-jre", opts.default)
        callback("33.4.7-jre")
      end,
    }

    require("java_scaffold").add_dependency()

    assert.equals("guava", received.term)
    assert.equals("com.google.guava:guava", received.version_coordinates)
    assert.equals("com.google.guava:guava", received.validated)
    assert.same({
      {
        group_id = "com.google.guava",
        artifact_id = "guava",
        version = "33.4.7-jre",
        packaging = "jar",
      },
    }, received.dependencies)
    assert.is_truthy(table.concat(received.lines, "\n"):find("changed while picker", 1, true))
  end)

  it("keeps Spring catalog insertion for Boot poms", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    vim.fn.writefile({ "<project>", "</project>" }, vim.fs.joinpath(cwd, "pom.xml"))
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    vim.opt.runtimepath:prepend(original_cwd)
    vim.cmd("enew!")
    local received = {}

    package.loaded["java_scaffold.config"] = {
      get = function()
        return {
          spring = {
            metadata_url = "https://initializr.test",
            dependencies_url = "https://initializr.test/dependencies",
          },
        }
      end,
    }
    package.loaded["java_scaffold.pom"] = {
      spring_boot_version = function()
        return "3.5.4"
      end,
      insert = function(lines, dependencies)
        received.dependencies = dependencies
        return lines, #dependencies
      end,
    }
    package.loaded["java_scaffold.metadata"] = {
      cache_path = function(kind)
        return kind
      end,
      fetch_cached = function(url, _, _, callback)
        if url:find("dependencies", 1, true) then
          callback(nil, { dependencies = { web = {} } })
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
    package.loaded["java_scaffold.maven_central"] = {
      search = function()
        error("Maven Central path must not run")
      end,
    }
    package.loaded["java_scaffold.picker"] = {
      input = function()
        error("search prompt must not run")
      end,
      select_many = function(items, opts, callback)
        assert.equals("Add Spring dependencies", opts.prompt)
        callback(items)
      end,
    }

    require("java_scaffold").add_dependency()

    assert.same({
      { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-web" },
    }, received.dependencies)
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

  it("uses refreshed public Java runtime cache for wizard creation", function()
    local active = "17"
    local created = {}
    package.loaded["java_scaffold"] = nil
    package.loaded["java_scaffold.config"] = {
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
    package.loaded["java_scaffold.java"] = {
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
    package.loaded["java_scaffold.maven"] = {
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
    package.loaded["java_scaffold.picker"] = {
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

    local plugin = require("java_scaffold")
    plugin.new_maven()
    active = "23"
    plugin.java_runtimes({ refresh = true })
    plugin.new_maven()

    assert.equals("/jdk/17", created[1].env.JAVA_HOME)
    assert.equals("/jdk/23", created[2].env.JAVA_HOME)
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
    local confirm = true
    local runtime_calls = 0
    local creation_calls = 0
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
        runtime_calls = runtime_calls + 1
        assert.is_truthy(received.review)
        callback("23")
      end,
    }
    package.loaded["java_scaffold.picker"] = {
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
    package.loaded["java_scaffold.maven"] = {
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

    require("java_scaffold").new_maven()

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
    require("java_scaffold").new_maven()

    assert.equals(1, runtime_calls)
    assert.equals(1, creation_calls)
  end)

  it("rejects blank destination instead of defaulting to cwd", function()
    local creation_calls = 0
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
    package.loaded["java_scaffold.java"] = {
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
    package.loaded["java_scaffold.maven"] = {
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
    package.loaded["java_scaffold.picker"] = {
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

    require("java_scaffold").new_maven()

    assert.equals(0, creation_calls)
  end)

  it("uses explicit destination and review for Gradle creation", function()
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
    package.loaded["java_scaffold.java"] = {
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
    package.loaded["java_scaffold.maven"] = {
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
    package.loaded["java_scaffold.picker"] = {
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
    package.loaded["java_scaffold.gradle"] = {
      project_type = function(language, project_type)
        return project_type:gsub("^java", language)
      end,
      create = function(opts)
        received.create = opts
      end,
    }

    require("java_scaffold").new_gradle()

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
    package.loaded["java_scaffold.java"] = {
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
    package.loaded["java_scaffold.maven"] = {
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
    package.loaded["java_scaffold.gradle"] = {
      project_type = function(language, project_type)
        return project_type:gsub("^java", language)
      end,
      create = function(opts)
        created.gradle[#created.gradle + 1] = opts
      end,
    }
    package.loaded["java_scaffold.picker"] = {
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

    local plugin = require("java_scaffold")
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
end)
