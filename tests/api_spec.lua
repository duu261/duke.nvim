describe("programmatic API", function()
  local original_cwd
  local original_buffer
  local temporary_directories = {}

  local function temp_dir()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    temporary_directories[#temporary_directories + 1] = path
    return path
  end

  local function wait_result(invoke)
    local results = {}
    local returned = false
    invoke(function(result)
      assert.is_true(returned)
      results[#results + 1] = result
    end)
    returned = true
    vim.wait(1000, function()
      return #results > 0
    end)
    assert.equals(1, #results)
    return results[1]
  end

  local function pom(lines)
    local directory = temp_dir()
    local path = vim.fs.joinpath(directory, "pom.xml")
    vim.fn.writefile(lines, path)
    return path
  end

  local function base_pom(dependencies)
    local lines = { "<project>", "  <dependencies>" }
    vim.list_extend(lines, dependencies or {})
    vim.list_extend(lines, { "  </dependencies>", "</project>" })
    return lines
  end

  before_each(function()
    original_cwd = vim.fn.getcwd()
    original_buffer = vim.api.nvim_get_current_buf()
    package.loaded["duke"] = nil
    package.loaded["duke.api"] = nil
    package.loaded["duke.pom_file"] = nil
  end)

  after_each(function()
    for _, module in ipairs({
      "duke",
      "duke.api",
      "duke.config",
      "duke.gradle",
      "duke.java",
      "duke.log",
      "duke.maven",
      "duke.maven_central",
      "duke.maven_module",
      "duke.pom",
      "duke.pom_file",
      "duke.project",
      "duke.spring",
    }) do
      package.loaded[module] = nil
    end
    vim.cmd.cd(vim.fn.fnameescape(original_cwd))
    if vim.api.nvim_buf_is_valid(original_buffer) then
      vim.api.nvim_set_current_buf(original_buffer)
    end
    for _, path in ipairs(temporary_directories) do
      vim.fn.delete(path, "rf")
    end
    temporary_directories = {}
  end)

  it("exports all headless operations without setup", function()
    local duke = require("duke")
    assert.is_function(duke.create)
    assert.is_function(duke.add)
    assert.is_function(duke.upgrade)
    assert.is_function(duke.outdated)
    assert.is_function(duke.remove)
  end)

  it("rejects invalid creation requests before adapters start", function()
    local starts = 0
    local adapter = {
      create = function(_, callback)
        starts = starts + 1
        callback("adapter must not start")
      end,
      package_name = function()
        return "com.example.demo"
      end,
      project_type = function(language, project_type)
        if language == "java" and project_type == "java-application" then
          return "java-application"
        end
      end,
    }
    package.loaded["duke.maven"] = adapter
    package.loaded["duke.gradle"] = adapter
    package.loaded["duke.spring"] = adapter
    local duke = require("duke")
    local cwd = temp_dir()
    local valid = {
      cwd = cwd,
      group_id = "com.example",
      artifact_id = "demo",
      java_version = "17",
    }
    local cases = {
      { "unknown", valid },
      { "maven", "bad" },
      { "maven", vim.tbl_extend("force", valid, { group_id = vim.NIL }) },
      { "maven", vim.tbl_extend("force", valid, { java_version = "auto" }) },
      { "gradle", vim.tbl_extend("force", valid, { language = "scala" }) },
      {
        "spring",
        vim.tbl_extend("force", valid, { boot_version = "3.5.4", project_type = "zip" }),
      },
      {
        "spring",
        vim.tbl_extend("force", valid, { boot_version = "3.5.4", url = "http://spring.test" }),
      },
      {
        "spring",
        vim.tbl_extend("force", valid, { boot_version = "3.5.4", dependencies = { web = true } }),
      },
      { "spring", valid },
    }
    for _, case in ipairs(cases) do
      local result = wait_result(function(callback)
        duke.create(case[1], case[2], callback)
      end)
      assert.is_false(result.ok)
      assert.is_string(result.error)
    end
    assert.equals(0, starts)
  end)

  it("normalizes all generator options and runner environments", function()
    local cwd = temp_dir()
    local received = {}
    package.loaded["duke.config"] = {
      get = function()
        return {
          java_versions = { "17", "23" },
          java_homes = { ["17"] = "/jdk17", ["23"] = "/jdk23" },
          maven = {
            command = "mvnx",
            runner_java_version = "23",
            wrapper = true,
            project_version = "2.0",
            timeout = 101,
            archetypes = { { group_id = "a", artifact_id = "b", version = "1" } },
          },
          gradle = {
            command = "gradlex",
            runner_java_version = "23",
            dsl = "groovy",
            test_framework = "auto",
            timeout = 202,
            default_project_type = "java-library",
          },
          spring = {
            starter_url = "https://spring.test/starter.tgz",
            project_type = "gradle-project",
            language = "java",
            packaging = "jar",
            timeout = 303,
          },
        }
      end,
    }
    package.loaded["duke.java"] = {
      active = function()
        return "17"
      end,
      discover_homes = function()
        return { ["17"] = "/jdk17", ["23"] = "/jdk23" }
      end,
      installed = function()
        return { "17", "23" }
      end,
      default = function(configured)
        return configured
      end,
      runner_env = function(version)
        return { JAVA_HOME = "/jdk" .. version, PATH = "/jdk" .. version .. "/bin" }
      end,
    }
    package.loaded["duke.project"] = {
      entry = function(path)
        return path .. "/entry.java"
      end,
    }
    for _, kind in ipairs({ "maven", "gradle", "spring" }) do
      package.loaded["duke." .. kind] = {
        package_name = function()
          return "com.example.demo"
        end,
        project_type = function(language, project_type)
          return language == "java" and project_type == "java-library" and "java-library" or nil
        end,
        create = function(opts, callback)
          received[kind] = opts
          callback(nil, vim.fs.joinpath(cwd, "demo"))
        end,
      }
    end
    local duke = require("duke")
    local common = {
      cwd = cwd,
      group_id = "com.example",
      artifact_id = "demo",
      java_version = "17",
    }
    assert.is_true(wait_result(function(cb)
      duke.create("maven", common, cb)
    end).ok)
    assert.is_true(wait_result(function(cb)
      duke.create("gradle", common, cb)
    end).ok)
    assert.is_true(wait_result(function(cb)
      duke.create(
        "spring",
        vim.tbl_extend("force", common, {
          boot_version = "3.5.4",
          dependencies = { "web" },
        }),
        cb
      )
    end).ok)
    assert.same({ group_id = "a", artifact_id = "b", version = "1" }, received.maven.archetype)
    assert.equals("2.0", received.maven.version)
    assert.is_true(received.maven.wrapper)
    assert.equals("/jdk23", received.maven.env.JAVA_HOME)
    assert.equals("java-library", received.gradle.project_type)
    assert.equals("groovy", received.gradle.dsl)
    assert.equals("/jdk23", received.gradle.env.JAVA_HOME)
    assert.equals("gradle", received.spring.build)
    assert.equals("demo", received.spring.name)
    assert.equals("", received.spring.description)
    assert.same({ "web" }, received.spring.dependencies)
  end)

  it("returns creation data, emits one event, and keeps editor state", function()
    local cwd = temp_dir()
    local caller_cwd = vim.fn.getcwd()
    local caller_buffer = vim.api.nvim_get_current_buf()
    local events = {}
    local original_exec = vim.api.nvim_exec_autocmds
    vim.api.nvim_exec_autocmds = function(event, opts)
      events[#events + 1] = { event = event, opts = opts }
    end
    package.loaded["duke.maven"] = {
      package_name = function()
        return "com.example.demo"
      end,
      create = function(_, callback)
        callback(nil, vim.fs.joinpath(cwd, "demo"))
        callback("late failure")
      end,
    }
    package.loaded["duke.project"] = {
      entry = function(path)
        return path .. "/App.java"
      end,
    }
    package.loaded["duke.java"] = {
      active = function()
        return nil
      end,
      discover_homes = function()
        return {}
      end,
      installed = function()
        return {}
      end,
      default = function()
        return nil
      end,
      runner_env = function()
        return nil
      end,
    }
    local result = wait_result(function(callback)
      require("duke").create("maven", {
        cwd = cwd,
        group_id = "com.example",
        artifact_id = "demo",
        java_version = "17",
      }, callback)
    end)
    vim.api.nvim_exec_autocmds = original_exec
    assert.same({
      ok = true,
      kind = "maven",
      project_dir = vim.fs.joinpath(cwd, "demo"),
      entry_file = vim.fs.joinpath(cwd, "demo", "App.java"),
    }, result)
    assert.equals(caller_cwd, vim.fn.getcwd())
    assert.equals(caller_buffer, vim.api.nvim_get_current_buf())
    assert.equals(1, #events)
    assert.equals("DukeProjectCreated", events[1].opts.pattern)
    assert.equals(result.project_dir, events[1].opts.data.project_dir)
    assert.equals(result.entry_file, events[1].opts.data.entry_file)
  end)

  it("contains adapter, event, and user callback failures", function()
    local cwd = temp_dir()
    local logged = {}
    package.loaded["duke.log"] = {
      add = function(_, message)
        logged[#logged + 1] = message
      end,
    }
    package.loaded["duke.maven"] = {
      package_name = function()
        return "com.example.demo"
      end,
      create = function()
        error("startup exploded")
      end,
    }
    package.loaded["duke.java"] = {
      active = function()
        return nil
      end,
      discover_homes = function()
        return {}
      end,
      installed = function()
        return {}
      end,
      default = function()
        return nil
      end,
      runner_env = function()
        return nil
      end,
    }
    local duke = require("duke")
    local opts = { cwd = cwd, group_id = "com.example", artifact_id = "demo", java_version = "17" }
    local result = wait_result(function(callback)
      duke.create("maven", opts, callback)
    end)
    assert.is_false(result.ok)
    package.loaded["duke.maven"].create = function(_, callback)
      callback(nil, cwd)
    end
    package.loaded["duke.project"] = {
      entry = function()
        return cwd
      end,
    }
    local original_exec = vim.api.nvim_exec_autocmds
    vim.api.nvim_exec_autocmds = function()
      error("event exploded")
    end
    result = wait_result(function(callback)
      duke.create("maven", opts, callback)
    end)
    vim.api.nvim_exec_autocmds = original_exec
    assert.is_true(result.ok)
    duke.create("maven", opts, function()
      error("callback exploded")
    end)
    vim.wait(1000, function()
      return #logged >= 2
    end)
    assert.is_true(#logged >= 2)
  end)

  it("adds dependencies with safe scope and duplicate behavior", function()
    local path = pom(base_pom())
    local duke = require("duke")
    local added = wait_result(function(callback)
      duke.add({
        pom_path = path,
        group_id = "junit",
        artifact_id = "junit",
        version = "4.13.2",
        scope = "test",
      }, callback)
    end)
    assert.same({ ok = true, pom_path = path, changed = true, count = 1, saved = true }, added)
    local contents = table.concat(vim.fn.readfile(path), "\n")
    assert.matches("<scope>test</scope>", contents)
    local duplicate = wait_result(function(callback)
      duke.add(
        { pom_path = path, group_id = "junit", artifact_id = "junit", version = "4.13.2" },
        callback
      )
    end)
    assert.same({ ok = true, pom_path = path, changed = false, count = 0, saved = true }, duplicate)
    assert.equals(contents, table.concat(vim.fn.readfile(path), "\n"))
  end)

  it("rejects invalid add requests without changing bytes", function()
    local path = pom(base_pom())
    local before = table.concat(vim.fn.readfile(path), "\n")
    for _, opts in ipairs({
      { pom_path = path, group_id = "bad group", artifact_id = "x", version = "1" },
      { pom_path = path, group_id = "g", artifact_id = "a", version = "1", scope = "system" },
    }) do
      local result = wait_result(function(callback)
        require("duke").add(opts, callback)
      end)
      assert.is_false(result.ok)
    end
    assert.equals(before, table.concat(vim.fn.readfile(path), "\n"))
  end)

  it("upgrades and removes unique explicit root dependencies", function()
    local dependency = {
      "    <dependency>",
      "      <groupId>junit</groupId>",
      "      <artifactId>junit</artifactId>",
      "      <version>4.12</version>",
      "    </dependency>",
    }
    local path = pom(base_pom(dependency))
    local duke = require("duke")
    local upgraded = wait_result(function(callback)
      duke.upgrade(
        { pom_path = path, group_id = "junit", artifact_id = "junit", version = "4.13.2" },
        callback
      )
    end)
    assert.same({ ok = true, pom_path = path, changed = true, count = 1, saved = true }, upgraded)
    assert.matches("4%.13%.2", table.concat(vim.fn.readfile(path), "\n"))
    local same = wait_result(function(callback)
      duke.upgrade(
        { pom_path = path, group_id = "junit", artifact_id = "junit", version = "4.13.2" },
        callback
      )
    end)
    assert.is_false(same.changed)
    local removed = wait_result(function(callback)
      duke.remove({ pom_path = path, group_id = "junit", artifact_id = "junit" }, callback)
    end)
    assert.same({ ok = true, pom_path = path, changed = true, count = 1, saved = true }, removed)
    local missing = wait_result(function(callback)
      duke.remove({ pom_path = path, group_id = "junit", artifact_id = "junit" }, callback)
    end)
    assert.is_false(missing.changed)
  end)

  it("rejects managed, property-backed, and duplicate upgrades", function()
    local blocks = {
      "    <dependency><groupId>bad</groupId><artifactId>compact</artifactId></dependency>",
      "    <dependency>",
      "      <groupId>g</groupId>",
      "      <artifactId>managed</artifactId>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>g</groupId>",
      "      <artifactId>property</artifactId>",
      "      <version>${x.version}</version>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>g</groupId>",
      "      <artifactId>duplicate</artifactId>",
      "      <version>1</version>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>g</groupId>",
      "      <artifactId>duplicate</artifactId>",
      "      <version>2</version>",
      "    </dependency>",
    }
    local path = pom(base_pom(blocks))
    local before = table.concat(vim.fn.readfile(path), "\n")
    for _, artifact in ipairs({ "managed", "property", "duplicate" }) do
      local result = wait_result(function(callback)
        require("duke").upgrade(
          { pom_path = path, group_id = "g", artifact_id = artifact, version = "3" },
          callback
        )
      end)
      assert.is_false(result.ok)
    end
    assert.equals(before, table.concat(vim.fn.readfile(path), "\n"))
  end)

  it("preserves modified loaded buffers and writes clean loaded buffers", function()
    local path = pom(base_pom())
    vim.cmd.edit(vim.fn.fnameescape(path))
    local clean = wait_result(function(callback)
      require("duke").add(
        { pom_path = path, group_id = "g", artifact_id = "clean", version = "1" },
        callback
      )
    end)
    assert.is_true(clean.saved)
    vim.api.nvim_buf_set_lines(0, 1, 1, false, { "  <!-- unsaved -->" })
    local disk_before = table.concat(vim.fn.readfile(path), "\n")
    local modified = wait_result(function(callback)
      require("duke").add(
        { pom_path = path, group_id = "g", artifact_id = "dirty", version = "1" },
        callback
      )
    end)
    assert.is_false(modified.saved)
    assert.matches("dirty", table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"))
    assert.equals(disk_before, table.concat(vim.fn.readfile(path), "\n"))
    vim.cmd("bwipeout!")
  end)

  it("turns POM write failures into callback failures", function()
    local path = pom(base_pom())
    package.loaded["duke.pom_file"] = {
      read = function()
        return base_pom()
      end,
      save = function()
        return nil, "write denied"
      end,
    }
    local result = wait_result(function(callback)
      require("duke").add(
        { pom_path = path, group_id = "g", artifact_id = "a", version = "1" },
        callback
      )
    end)
    assert.is_false(result.ok)
    assert.matches("write denied", result.error)
  end)

  it("inspects outdated dependencies sequentially with filtering and skips", function()
    local blocks = {
      "    <dependency>",
      "      <groupId>g</groupId>",
      "      <artifactId>old</artifactId>",
      "      <version>1</version>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>g</groupId>",
      "      <artifactId>current</artifactId>",
      "      <version>2</version>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>g</groupId>",
      "      <artifactId>managed</artifactId>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>g</groupId>",
      "      <artifactId>property</artifactId>",
      "      <version>${x}</version>",
      "    </dependency>",
    }
    local path = pom(base_pom(blocks))
    local active = false
    local order = {}
    package.loaded["duke.maven_central"] = {
      versions = function(_, artifact, callback)
        assert.is_false(active)
        active = true
        order[#order + 1] = artifact
        vim.schedule(function()
          active = false
          callback(nil, artifact == "old" and { "3", "1" } or { "2" })
        end)
      end,
    }
    local result = wait_result(function(callback)
      require("duke").outdated({ pom_path = path }, callback)
    end)
    assert.same({ "old", "current" }, order)
    assert.same({ managed = 1, property_backed = 1 }, result.skipped)
    assert.equals(0, result.unchecked)
    assert.is_nil(result.warning)
    assert.same(
      { { group_id = "g", artifact_id = "old", current_version = "1", latest_version = "3" } },
      result.dependencies
    )
    local filtered = wait_result(function(callback)
      require("duke").outdated(
        { pom_path = path, group_id = "g", artifact_id = "current" },
        callback
      )
    end)
    assert.same({}, filtered.dependencies)
  end)

  it("returns exact partial outdated state and fails before first result", function()
    local blocks = {}
    for _, artifact in ipairs({ "one", "two", "three" }) do
      vim.list_extend(blocks, {
        "    <dependency>",
        "      <groupId>g</groupId>",
        "      <artifactId>" .. artifact .. "</artifactId>",
        "      <version>1</version>",
        "    </dependency>",
      })
    end
    local path = pom(base_pom(blocks))
    local calls = 0
    package.loaded["duke.maven_central"] = {
      versions = function(_, _, callback)
        calls = calls + 1
        if calls == 1 then
          callback(nil, { "2" })
        else
          callback("HTTP 429")
        end
      end,
    }
    local partial = wait_result(function(callback)
      require("duke").outdated({ pom_path = path }, callback)
    end)
    assert.is_true(partial.ok)
    assert.equals("HTTP 429", partial.warning)
    assert.equals(2, partial.unchecked)
    assert.equals(1, #partial.dependencies)
    calls = 0
    package.loaded["duke.maven_central"].versions = function(_, _, callback)
      calls = calls + 1
      callback("timeout")
    end
    local failed = wait_result(function(callback)
      require("duke").outdated({ pom_path = path }, callback)
    end)
    assert.is_false(failed.ok)
    assert.equals(1, calls)
  end)

  it("rejects ambiguous outdated coordinates before network access", function()
    local block = {
      "    <dependency>",
      "      <groupId>g</groupId>",
      "      <artifactId>duplicate</artifactId>",
      "      <version>1</version>",
      "    </dependency>",
    }
    local lines = base_pom(vim.list_extend(vim.deepcopy(block), block))
    local path = pom(lines)
    local calls = 0
    package.loaded["duke.maven_central"] = {
      versions = function(_, _, callback)
        calls = calls + 1
        callback(nil, {})
      end,
    }
    local result = wait_result(function(callback)
      require("duke").outdated({ pom_path = path }, callback)
    end)
    assert.is_false(result.ok)
    assert.equals(0, calls)
  end)

  it("rejects add_module with a missing reactor_dir instead of a cwd fallback", function()
    local duke = require("duke")
    local result = wait_result(function(callback)
      duke.add_module({ artifact_id = "child" }, callback)
    end)
    assert.is_false(result.ok)
    assert.is_string(result.error)
  end)

  it("rejects add_module with a missing or empty artifact_id", function()
    local duke = require("duke")
    local reactor = temp_dir()
    local missing = wait_result(function(callback)
      duke.add_module({ reactor_dir = reactor }, callback)
    end)
    assert.is_false(missing.ok)
    assert.is_string(missing.error)
    local empty = wait_result(function(callback)
      duke.add_module({ reactor_dir = reactor, artifact_id = "" }, callback)
    end)
    assert.is_false(empty.ok)
    assert.is_string(empty.error)
  end)

  it("returns ok, module_dir, and parent_pom for a successful add_module", function()
    local reactor = temp_dir()
    package.loaded["duke.maven_module"] = {
      create = function(opts, callback)
        callback(nil, {
          parent_pom = vim.fs.joinpath(opts.reactor_dir, "pom.xml"),
          module_dir = vim.fs.joinpath(opts.reactor_dir, opts.artifact_id),
          saved = true,
          rolled_back = false,
        })
      end,
    }
    local duke = require("duke")
    local result = wait_result(function(callback)
      duke.add_module({ reactor_dir = reactor, artifact_id = "child" }, callback)
    end)
    assert.is_true(result.ok)
    assert.equals(vim.fs.joinpath(reactor, "pom.xml"), result.parent_pom)
    assert.equals(vim.fs.joinpath(reactor, "child"), result.module_dir)
  end)

  it("returns ok=false and a string error when the core fails", function()
    local reactor = temp_dir()
    package.loaded["duke.maven_module"] = {
      create = function(_, callback)
        callback("reactor pom.xml is missing", {
          parent_pom = nil,
          module_dir = nil,
          saved = false,
          rolled_back = false,
        })
      end,
    }
    local duke = require("duke")
    local result = wait_result(function(callback)
      duke.add_module({ reactor_dir = reactor, artifact_id = "child" }, callback)
    end)
    assert.is_false(result.ok)
    assert.equals("reactor pom.xml is missing", result.error)
  end)

  it("propagates rolled_back to the add_module caller", function()
    local reactor = temp_dir()
    package.loaded["duke.maven_module"] = {
      create = function(opts, callback)
        callback("target already exists: " .. opts.reactor_dir, {
          parent_pom = vim.fs.joinpath(opts.reactor_dir, "pom.xml"),
          module_dir = vim.fs.joinpath(opts.reactor_dir, opts.artifact_id),
          saved = true,
          rolled_back = true,
        })
      end,
    }
    local duke = require("duke")
    local result = wait_result(function(callback)
      duke.add_module({ reactor_dir = reactor, artifact_id = "child" }, callback)
    end)
    assert.is_false(result.ok)
    assert.is_true(result.rolled_back)
  end)

  it("fires the add_module callback exactly once and on the main loop", function()
    local reactor = temp_dir()
    package.loaded["duke.maven_module"] = {
      create = function(_, callback)
        callback(nil, { parent_pom = "p", module_dir = "m", saved = true, rolled_back = false })
        callback(
          "late failure",
          { parent_pom = "p", module_dir = "m", saved = true, rolled_back = false }
        )
      end,
    }
    local duke = require("duke")
    local calls = 0
    local returned = false
    duke.add_module({ reactor_dir = reactor, artifact_id = "child" }, function()
      assert.is_true(returned)
      calls = calls + 1
    end)
    returned = true
    vim.wait(1000, function()
      return calls > 0
    end)
    assert.equals(1, calls)
  end)
end)
