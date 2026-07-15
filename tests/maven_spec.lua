describe("Maven scaffolding", function()
  local maven
  local temporary_directories = {}

  before_each(function()
    package.loaded["java_scaffold.maven"] = nil
    maven = require("java_scaffold.maven")
  end)

  after_each(function()
    package.loaded["java_scaffold.process"] = nil
    for _, path in ipairs(temporary_directories) do
      vim.fn.delete(path, "rf")
    end
    temporary_directories = {}
  end)

  local function temporary_directory()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    temporary_directories[#temporary_directories + 1] = path
    return path
  end

  local function create_options(cwd)
    return {
      command = "mvn",
      cwd = cwd,
      group_id = "com.example",
      artifact_id = "demo-api",
      java_version = "21",
      env = { JAVA_HOME = "/jdk/21" },
      version = "1.0-SNAPSHOT",
      wrapper = false,
      archetype = {
        group_id = "org.apache.maven.archetypes",
        artifact_id = "maven-archetype-quickstart",
        version = "1.5",
      },
    }
  end

  it("builds a non-interactive quickstart invocation", function()
    local args = maven.build_args({
      group_id = "com.example",
      artifact_id = "demo-api",
      java_version = "21",
      cwd = "/tmp/projects",
      version = "1.0-SNAPSHOT",
      archetype = {
        group_id = "org.apache.maven.archetypes",
        artifact_id = "maven-archetype-quickstart",
        version = "1.5",
      },
    })

    assert.same({
      "-B",
      "archetype:generate",
      "-DarchetypeGroupId=org.apache.maven.archetypes",
      "-DarchetypeArtifactId=maven-archetype-quickstart",
      "-DarchetypeVersion=1.5",
      "-DgroupId=com.example",
      "-DartifactId=demo-api",
      "-Dversion=1.0-SNAPSHOT",
      "-Dpackage=com.example.demoapi",
      "-DjavaCompilerVersion=21",
      "-DoutputDirectory=/tmp/projects",
      "-DinteractiveMode=false",
    }, args)
  end)

  it("validates Maven coordinates", function()
    assert.is_nil(maven.validate("com.example", "demo-api"))
    assert.matches("groupId", maven.validate("bad group", "demo-api"))
    assert.matches("artifactId", maven.validate("com.example", "../demo"))
  end)

  it("creates in staging before promoting the project", function()
    local cwd = temporary_directory()
    local callback_error
    local project_dir
    package.loaded["java_scaffold.process"] = {
      run = function(_, args, process_options, callback)
        assert.equals("/jdk/21", process_options.env.JAVA_HOME)
        local output = vim.iter(args):find(function(arg)
          return arg:match("^-DoutputDirectory=")
        end)
        local staging = output:match("^%-DoutputDirectory=(.+)$")
        assert.not_equals(cwd, staging)
        local generated = vim.fs.joinpath(staging, "demo-api")
        vim.fn.mkdir(generated, "p")
        vim.fn.writefile({ "<project/>" }, vim.fs.joinpath(generated, "pom.xml"))
        callback({ code = 0, stdout = "", stderr = "" })
      end,
    }

    maven.create(create_options(cwd), function(err, path)
      callback_error = err
      project_dir = path
    end)

    assert.is_nil(callback_error)
    assert.equals(vim.fs.joinpath(cwd, "demo-api"), project_dir)
    assert.equals(1, vim.fn.filereadable(vim.fs.joinpath(project_dir, "pom.xml")))
    assert.same({}, vim.fn.glob(vim.fs.joinpath(cwd, ".java-scaffold-*"), false, true))
  end)

  it("preserves a target created while Maven runs", function()
    local cwd = temporary_directory()
    local callback_error
    package.loaded["java_scaffold.process"] = {
      run = function(_, args, _, callback)
        local output = vim.iter(args):find(function(arg)
          return arg:match("^-DoutputDirectory=")
        end)
        local staging = output:match("^%-DoutputDirectory=(.+)$")
        local generated = vim.fs.joinpath(staging, "demo-api")
        vim.fn.mkdir(generated, "p")
        vim.fn.writefile({ "<project/>" }, vim.fs.joinpath(generated, "pom.xml"))
        local target = vim.fs.joinpath(cwd, "demo-api")
        vim.fn.mkdir(target, "p")
        vim.fn.writefile({ "keep" }, vim.fs.joinpath(target, "sentinel"))
        callback({ code = 0, stdout = "", stderr = "" })
      end,
    }

    maven.create(create_options(cwd), function(err)
      callback_error = err
    end)

    assert.matches("target already exists", callback_error)
    assert.equals("keep", vim.fn.readfile(vim.fs.joinpath(cwd, "demo-api", "sentinel"))[1])
  end)

  it("generates an optional Maven Wrapper before promotion", function()
    local cwd = temporary_directory()
    local runs = 0
    local project_dir
    local staged_project
    package.loaded["java_scaffold.process"] = {
      run = function(command, args, process_options, callback)
        runs = runs + 1
        if runs == 1 then
          local output = vim.iter(args):find(function(arg)
            return arg:match("^-DoutputDirectory=")
          end)
          local staging = output:match("^%-DoutputDirectory=(.+)$")
          local generated = vim.fs.joinpath(staging, "demo-api")
          staged_project = generated
          vim.fn.mkdir(generated, "p")
          vim.fn.writefile({ "<project/>" }, vim.fs.joinpath(generated, "pom.xml"))
          callback({ code = 0, stdout = "", stderr = "" })
          return
        end

        assert.equals("mvn", command)
        assert.same({ "-B", "wrapper:wrapper", "-Dtype=only-script" }, args)
        assert.equals(staged_project, process_options.cwd)
        assert.equals("/jdk/21", process_options.env.JAVA_HOME)
        vim.fn.writefile({ "#!/bin/sh" }, vim.fs.joinpath(process_options.cwd, "mvnw"))
        vim.fn.writefile({ "@echo off" }, vim.fs.joinpath(process_options.cwd, "mvnw.cmd"))
        local wrapper_dir = vim.fs.joinpath(process_options.cwd, ".mvn", "wrapper")
        vim.fn.mkdir(wrapper_dir, "p")
        vim.fn.writefile(
          { "distributionUrl=https://example.invalid/maven.zip" },
          vim.fs.joinpath(wrapper_dir, "maven-wrapper.properties")
        )
        callback({ code = 0, stdout = "", stderr = "" })
      end,
    }
    local opts = create_options(cwd)
    opts.wrapper = true

    maven.create(opts, function(err, path)
      assert.is_nil(err)
      project_dir = path
    end)

    assert.equals(2, runs)
    assert.equals(1, vim.fn.filereadable(vim.fs.joinpath(project_dir, "mvnw")))
    assert.equals(1, vim.fn.filereadable(vim.fs.joinpath(project_dir, "mvnw.cmd")))
    assert.equals(
      1,
      vim.fn.filereadable(
        vim.fs.joinpath(project_dir, ".mvn", "wrapper", "maven-wrapper.properties")
      )
    )
  end)

  it("aborts promotion when Maven Wrapper generation fails", function()
    local cwd = temporary_directory()
    local runs = 0
    local callback_error
    package.loaded["java_scaffold.process"] = {
      run = function(_, args, _, callback)
        runs = runs + 1
        if runs == 1 then
          local output = vim.iter(args):find(function(arg)
            return arg:match("^-DoutputDirectory=")
          end)
          local staging = output:match("^%-DoutputDirectory=(.+)$")
          local generated = vim.fs.joinpath(staging, "demo-api")
          vim.fn.mkdir(generated, "p")
          vim.fn.writefile({ "<project/>" }, vim.fs.joinpath(generated, "pom.xml"))
          callback({ code = 0, stdout = "", stderr = "" })
          return
        end
        callback({ code = 1, stdout = "", stderr = "wrapper failed" })
      end,
      detail = function(result)
        return result.stderr
      end,
    }
    local opts = create_options(cwd)
    opts.wrapper = true

    maven.create(opts, function(err)
      callback_error = err
    end)

    assert.equals(2, runs)
    assert.matches("Maven Wrapper generation failed: wrapper failed", callback_error)
    assert.is_nil(vim.uv.fs_stat(vim.fs.joinpath(cwd, "demo-api")))
    assert.same({}, vim.fn.glob(vim.fs.joinpath(cwd, ".java-scaffold-*"), false, true))
  end)

  it("rejects incomplete Maven Wrapper output", function()
    local cwd = temporary_directory()
    local runs = 0
    local callback_error
    package.loaded["java_scaffold.process"] = {
      run = function(_, args, process_options, callback)
        runs = runs + 1
        if runs == 1 then
          local output = vim.iter(args):find(function(arg)
            return arg:match("^-DoutputDirectory=")
          end)
          local staging = output:match("^%-DoutputDirectory=(.+)$")
          local generated = vim.fs.joinpath(staging, "demo-api")
          vim.fn.mkdir(generated, "p")
          vim.fn.writefile({ "<project/>" }, vim.fs.joinpath(generated, "pom.xml"))
          callback({ code = 0, stdout = "", stderr = "" })
          return
        end
        vim.fn.writefile({ "#!/bin/sh" }, vim.fs.joinpath(process_options.cwd, "mvnw"))
        vim.fn.writefile({ "@echo off" }, vim.fs.joinpath(process_options.cwd, "mvnw.cmd"))
        callback({ code = 0, stdout = "", stderr = "" })
      end,
    }
    local opts = create_options(cwd)
    opts.wrapper = true

    maven.create(opts, function(err)
      callback_error = err
    end)

    assert.equals(2, runs)
    assert.matches("Maven Wrapper output missing", callback_error)
    assert.is_nil(vim.uv.fs_stat(vim.fs.joinpath(cwd, "demo-api")))
  end)
end)
