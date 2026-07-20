describe("Java workspace discovery", function()
  local workspace
  local roots = {}

  local function temp_dir()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    roots[#roots + 1] = path
    return path
  end

  local function write(path, lines)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
  end

  local function pom(group, artifact, packaging, modules)
    local lines = {
      "<project>",
      "  <groupId>" .. group .. "</groupId>",
      "  <artifactId>" .. artifact .. "</artifactId>",
      "  <version>1.0.0</version>",
    }
    if packaging then
      lines[#lines + 1] = "  <packaging>" .. packaging .. "</packaging>"
    end
    if modules then
      lines[#lines + 1] = "  <modules>"
      for _, module_path in ipairs(modules) do
        lines[#lines + 1] = "    <module>" .. module_path .. "</module>"
      end
      lines[#lines + 1] = "  </modules>"
    end
    lines[#lines + 1] = "</project>"
    return lines
  end

  local function inspect(opts)
    local calls = {}
    workspace.inspect(opts, function(err, result)
      calls[#calls + 1] = { err = err, result = result }
    end)
    assert.is_true(vim.wait(1000, function()
      return #calls == 1
    end))
    vim.wait(20)
    assert.equals(1, #calls)
    return calls[1].err, calls[1].result
  end

  before_each(function()
    package.loaded["duke.workspace"] = nil
    package.loaded["duke.spring_config"] = nil
    package.loaded["duke.maven_model"] = nil
    package.loaded["duke.dependency_analyzer"] = nil
    package.loaded["duke.gradle_model"] = nil
    workspace = require("duke.workspace")
  end)

  after_each(function()
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buffer)
      if name ~= "" and vim.tbl_contains(roots, vim.fs.dirname(name)) then
        pcall(vim.api.nvim_buf_delete, buffer, { force = true })
      end
    end
    for _, path in ipairs(roots) do
      vim.fn.delete(path, "rf")
    end
    roots = {}
    package.loaded["duke.workspace"] = nil
    package.loaded["duke.spring_config"] = nil
    package.loaded["duke.maven_model"] = nil
    package.loaded["duke.dependency_analyzer"] = nil
    package.loaded["duke.gradle_model"] = nil
  end)

  it("discovers a Maven reactor and active module from a Java file", function()
    local root = temp_dir()
    write(vim.fs.joinpath(root, "pom.xml"), pom("com.acme", "root", "pom", { "app", "missing" }))
    write(vim.fs.joinpath(root, "app", "pom.xml"), pom("com.acme", "app"))
    local java = vim.fs.joinpath(root, "app", "src", "main", "java", "App.java")
    write(java, { "class App {}" })
    write(vim.fs.joinpath(root, "app", "src", "main", "resources", "application-dev.properties"), {
      "server.port=0",
    })
    write(vim.fs.joinpath(root, "mvnw"), { "#!/bin/sh" })

    local err, result = inspect({ path = java, resolve = false })

    assert.is_nil(err)
    assert.equals("local", result.state)
    assert.equals("maven", result.kind)
    assert.equals(root, result.root)
    assert.equals("com.acme:app", result.active_module)
    assert.equals(2, #result.modules)
    assert.equals(vim.fs.joinpath(root, "mvnw"), result.environment.wrapper)
    assert.equals("dev", result.configuration[1].profile)
    assert.matches("missing", result.diagnostics[1].message)
  end)

  it("uses modified loaded POM contents", function()
    local root = temp_dir()
    local path = vim.fs.joinpath(root, "pom.xml")
    write(path, pom("com.acme", "disk"))
    local buffer = vim.fn.bufadd(path)
    vim.fn.bufload(buffer)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, pom("com.acme", "buffer"))

    local err, result = inspect({ path = path, resolve = false })

    assert.is_nil(err)
    assert.equals("com.acme:buffer", result.modules[1].id)
    assert.is_true(result.modules[1].modified)
    pcall(vim.api.nvim_buf_delete, buffer, { force = true })
  end)

  it("never follows Maven modules outside the reactor", function()
    local parent = temp_dir()
    local root = vim.fs.joinpath(parent, "reactor")
    vim.fn.mkdir(root, "p")
    write(vim.fs.joinpath(root, "pom.xml"), pom("com.acme", "root", "pom", { "../outside" }))
    write(vim.fs.joinpath(parent, "outside", "pom.xml"), pom("com.acme", "outside"))

    local err, result = inspect({ path = root, resolve = false })

    assert.is_nil(err)
    assert.equals(1, #result.modules)
    assert.equals("outside_reactor", result.diagnostics[1].code)
  end)

  it("inventories a local Gradle workspace without running Gradle", function()
    local root = temp_dir()
    write(vim.fs.joinpath(root, "settings.gradle.kts"), { 'rootProject.name = "demo"' })
    write(vim.fs.joinpath(root, "build.gradle.kts"), { "plugins { java }" })
    write(vim.fs.joinpath(root, "gradle", "libs.versions.toml"), { "[versions]" })
    write(vim.fs.joinpath(root, "gradlew"), { "#!/bin/sh" })

    local err, result = inspect({ path = root, resolve = false })

    assert.is_nil(err)
    assert.equals("gradle", result.kind)
    assert.equals(root, result.root)
    assert.equals(vim.fs.joinpath(root, "gradlew"), result.environment.wrapper)
    assert.equals(
      vim.fs.joinpath(root, "gradle", "libs.versions.toml"),
      result.environment.version_catalog
    )
  end)

  it("enriches Maven only when resolve is explicit", function()
    local root = temp_dir()
    write(vim.fs.joinpath(root, "pom.xml"), pom("com.acme", "app"))
    local enrich_calls = 0
    package.loaded["duke.maven_model"] = {
      enrich = function(snapshot, _, callback)
        enrich_calls = enrich_calls + 1
        snapshot.state = "resolved"
        callback(nil, snapshot)
      end,
    }
    package.loaded["duke.dependency_analyzer"] = {
      analyze = function()
        return { findings = {} }
      end,
    }

    local err, result = inspect({ path = root, resolve = true, env = {} })

    assert.is_nil(err)
    assert.equals(1, enrich_calls)
    assert.equals("resolved", result.state)
    assert.same({ findings = {} }, result.analysis)
  end)

  it("records the scoped runner selected for resolved inspection", function()
    local root = temp_dir()
    write(vim.fs.joinpath(root, "pom.xml"), pom("com.acme", "app"))
    package.loaded["duke.java"] = {
      active = function()
        return "21"
      end,
      discover_homes = function()
        return { { version = "23", home = "/opt/jdk-23" } }
      end,
      installed = function()
        return { "23" }
      end,
      default = function()
        return "23"
      end,
      runner_env = function()
        return { JAVA_HOME = "/opt/jdk-23" }
      end,
    }
    package.loaded["duke.maven_model"] = {
      enrich = function(snapshot, _, callback)
        snapshot.state = "resolved"
        callback(nil, snapshot)
      end,
    }
    package.loaded["duke.dependency_analyzer"] = {
      analyze = function()
        return { findings = {} }
      end,
    }

    local err, result = inspect({ path = root, resolve = true })

    assert.is_nil(err)
    assert.equals("23", result.environment.runner_java_version)
    assert.equals("/opt/jdk-23", result.environment.runner_java_home)
    package.loaded["duke.java"] = nil
  end)

  it("enriches Gradle only when resolve is explicit", function()
    local root = temp_dir()
    write(vim.fs.joinpath(root, "settings.gradle.kts"), { 'rootProject.name = "demo"' })
    local enrich_calls = 0
    package.loaded["duke.gradle_model"] = {
      enrich = function(snapshot, _, callback)
        enrich_calls = enrich_calls + 1
        snapshot.state = "resolved"
        snapshot.analysis = { projects = { ":" } }
        callback(nil, snapshot)
      end,
    }

    local err, result = inspect({ path = root, resolve = true, env = {} })

    assert.is_nil(err)
    assert.equals(1, enrich_calls)
    assert.equals("resolved", result.state)
    assert.same({ projects = { ":" } }, result.analysis)
  end)
end)
