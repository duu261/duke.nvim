describe("Generator pipeline", function()
  local generator
  local temporary_directories = {}

  before_each(function()
    package.loaded["duke.generator"] = nil
    generator = require("duke.generator")
  end)

  after_each(function()
    for _, path in ipairs(temporary_directories) do
      vim.fn.delete(path, "rf")
    end
    temporary_directories = {}
  end)

  local function temp_dir()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    temporary_directories[#temporary_directories + 1] = path
    return path
  end

  local function passing_adapter()
    return {
      validate = function()
        return nil
      end,
      execute = function(_, staging, callback)
        local project = vim.fs.joinpath(staging, "demo")
        vim.fn.mkdir(project, "p")
        vim.fn.writefile({ "content" }, vim.fs.joinpath(project, "build.file"))
        callback(nil)
      end,
    }
  end

  it("rejects invalid coordinates before touching the filesystem", function()
    local cwd = temp_dir()
    local adapter = {
      validate = function()
        return "invalid groupId"
      end,
      execute = function()
        error("execute must not be called")
      end,
    }

    local received_error
    generator.run({ cwd = cwd, artifact_id = "demo" }, adapter, function(err)
      received_error = err
    end)

    assert.equals("invalid groupId", received_error)
  end)

  it("rejects a target that already exists", function()
    local cwd = temp_dir()
    local target = vim.fs.joinpath(cwd, "demo")
    vim.fn.mkdir(target, "p")

    local adapter = {
      validate = function()
        return nil
      end,
      execute = function()
        error("execute must not be called")
      end,
    }

    local received_error
    generator.run({ cwd = cwd, artifact_id = "demo" }, adapter, function(err)
      received_error = err
    end)

    assert.matches("target already exists", received_error)
  end)

  it("promotes a generated project to the target", function()
    local cwd = temp_dir()
    local project_dir

    generator.run({ cwd = cwd, artifact_id = "demo" }, passing_adapter(), function(err, path)
      assert.is_nil(err)
      project_dir = path
    end)

    assert.equals(vim.fs.joinpath(cwd, "demo"), project_dir)
    assert.equals(1, vim.fn.filereadable(vim.fs.joinpath(project_dir, "build.file")))
    assert.same({}, vim.fn.glob(vim.fs.joinpath(cwd, ".duke-*"), false, true))
  end)

  it("cleans up staging and does not promote on execute error", function()
    local cwd = temp_dir()
    local adapter = {
      validate = function()
        return nil
      end,
      execute = function(_, _, callback)
        callback("build tool crashed")
      end,
    }

    local received_error
    generator.run({ cwd = cwd, artifact_id = "demo" }, adapter, function(err)
      received_error = err
    end)

    assert.equals("build tool crashed", received_error)
    assert.is_nil(vim.uv.fs_stat(vim.fs.joinpath(cwd, "demo")))
    assert.same({}, vim.fn.glob(vim.fs.joinpath(cwd, ".duke-*"), false, true))
  end)

  it("preserves a target that appears during generation", function()
    local cwd = temp_dir()
    local adapter = {
      validate = function()
        return nil
      end,
      execute = function(_, staging, callback)
        local project = vim.fs.joinpath(staging, "demo")
        vim.fn.mkdir(project, "p")
        vim.fn.writefile({ "generated" }, vim.fs.joinpath(project, "build.file"))
        -- Simulate target appearing concurrently
        local target = vim.fs.joinpath(cwd, "demo")
        vim.fn.mkdir(target, "p")
        vim.fn.writefile({ "keep" }, vim.fs.joinpath(target, "sentinel"))
        callback(nil)
      end,
    }

    local received_error
    generator.run({ cwd = cwd, artifact_id = "demo" }, adapter, function(err)
      received_error = err
    end)

    assert.matches("target already exists", received_error)
    assert.equals("keep", vim.fn.readfile(vim.fs.joinpath(cwd, "demo", "sentinel"))[1])
    assert.same({}, vim.fn.glob(vim.fs.joinpath(cwd, ".duke-*"), false, true))
  end)

  it("passes full opts through to the adapter", function()
    local cwd = temp_dir()
    local received_opts
    local adapter = {
      validate = function(opts)
        received_opts = opts
        return nil
      end,
      execute = function(opts, staging, callback)
        assert.equals(received_opts, opts)
        local project = vim.fs.joinpath(staging, opts.artifact_id)
        vim.fn.mkdir(project, "p")
        vim.fn.writefile({ "ok" }, vim.fs.joinpath(project, "pom.xml"))
        callback(nil)
      end,
    }

    local opts = {
      cwd = cwd,
      artifact_id = "demo",
      group_id = "com.example",
      java_version = "21",
      extra_field = "preserved",
    }

    local project_dir
    generator.run(opts, adapter, function(err, path)
      assert.is_nil(err)
      project_dir = path
    end)

    assert.equals("com.example", received_opts.group_id)
    assert.equals("21", received_opts.java_version)
    assert.equals("preserved", received_opts.extra_field)
    assert.equals(vim.fs.joinpath(cwd, "demo"), project_dir)
  end)
end)
