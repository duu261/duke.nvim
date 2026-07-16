describe("Gradle scaffolding", function()
  local gradle
  local temporary_directories = {}

  before_each(function()
    package.loaded["java_scaffold.gradle"] = nil
    gradle = require("java_scaffold.gradle")
  end)

  after_each(function()
    package.loaded["java_scaffold.process"] = nil
    for _, path in ipairs(temporary_directories) do
      vim.fn.delete(path, "rf")
    end
    temporary_directories = {}
  end)

  local function options(cwd)
    return {
      command = "gradle",
      cwd = cwd,
      group_id = "com.example",
      artifact_id = "demo-api",
      java_version = "23",
      project_type = "java-application",
      dsl = "kotlin",
      test_framework = "auto",
      env = { JAVA_HOME = "/jdk/23" },
    }
  end

  it("builds a non-interactive Gradle init invocation", function()
    local opts = options("/tmp/projects")
    opts.output_directory = "/tmp/projects/.stage/demo-api"

    assert.same({
      "init",
      "--type",
      "java-application",
      "--dsl",
      "kotlin",
      "--test-framework",
      "junit-jupiter",
      "--package",
      "com.example.demoapi",
      "--into",
      "/tmp/projects/.stage/demo-api",
      "--project-name",
      "demo-api",
      "--no-split-project",
      "--java-version",
      "23",
      "--use-defaults",
      "--no-incubating",
    }, gradle.build_args(opts))
  end)

  it("uses JUnit 4 for Java versions unsupported by current Jupiter", function()
    local opts = options("/tmp/projects")
    opts.java_version = "8"
    opts.output_directory = "/tmp/projects/.stage/demo-api"

    local args = gradle.build_args(opts)
    local framework_index = vim.fn.index(args, "--test-framework") + 1

    assert.equals("junit", args[framework_index + 1])
  end)

  it("maps Kotlin applications to the Gradle init type", function()
    assert.equals("kotlin-application", gradle.project_type("kotlin", "java-application"))
    assert.equals("groovy-library", gradle.project_type("groovy", "java-library"))
    assert.is_nil(gradle.project_type("scala", "java-application"))
  end)

  it("promotes only a generated Gradle project", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local project_dir
    package.loaded["java_scaffold.process"] = {
      run = function(_, args, process_options, callback)
        assert.equals("/jdk/23", process_options.env.JAVA_HOME)
        local into_index = vim.fn.index(args, "--into") + 1
        local generated = args[into_index + 1]
        vim.fn.mkdir(generated, "p")
        vim.fn.writefile({ "plugins {}" }, vim.fs.joinpath(generated, "build.gradle.kts"))
        vim.fn.writefile(
          { "rootProject.name = 'demo-api'" },
          vim.fs.joinpath(generated, "settings.gradle.kts")
        )
        callback({ code = 0, stdout = "", stderr = "" })
      end,
    }

    gradle.create(options(cwd), function(err, path)
      assert.is_nil(err)
      project_dir = path
    end)

    assert.equals(vim.fs.joinpath(cwd, "demo-api"), project_dir)
    assert.equals(1, vim.fn.filereadable(vim.fs.joinpath(project_dir, "build.gradle.kts")))
    assert.same({}, vim.fn.glob(vim.fs.joinpath(cwd, ".java-scaffold-*"), false, true))
  end)

  it("accepts Gradle's generated application subproject layout", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local project_dir
    package.loaded["java_scaffold.process"] = {
      run = function(_, args, _, callback)
        local into_index = vim.fn.index(args, "--into") + 1
        local generated = args[into_index + 1]
        vim.fn.mkdir(vim.fs.joinpath(generated, "app"), "p")
        vim.fn.writefile({ "plugins {}" }, vim.fs.joinpath(generated, "app", "build.gradle.kts"))
        vim.fn.writefile({ "include('app')" }, vim.fs.joinpath(generated, "settings.gradle.kts"))
        callback({ code = 0, stdout = "", stderr = "" })
      end,
    }

    gradle.create(options(cwd), function(err, path)
      assert.is_nil(err)
      project_dir = path
    end)

    assert.equals(1, vim.fn.filereadable(vim.fs.joinpath(project_dir, "app", "build.gradle.kts")))
  end)
end)
