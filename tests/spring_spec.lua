describe("Spring Initializr scaffolding", function()
  local spring
  local temporary_directories = {}

  before_each(function()
    package.loaded["duke.spring"] = nil
    spring = require("duke.spring")
  end)

  after_each(function()
    package.loaded["duke.process"] = nil
    for _, path in ipairs(temporary_directories) do
      vim.fn.delete(path, "rf")
    end
    temporary_directories = {}
  end)

  it("builds curl args without shell interpolation", function()
    local args = spring.build_curl_args({
      url = "https://start.spring.io/starter.tgz",
      output = "/tmp/demo.tgz",
      group_id = "com.example",
      artifact_id = "demo api",
      name = "Demo API",
      description = "Custom Spring project",
      package_name = "com.example.custom",
      java_version = "21",
      boot_version = "4.0.0",
      dependencies = { "web", "data-jpa" },
      project_type = "maven-project",
      language = "java",
      packaging = "jar",
    })

    assert.same({
      "--fail-with-body",
      "--location",
      "--proto",
      "=https",
      "--silent",
      "--show-error",
      "--get",
      "https://start.spring.io/starter.tgz",
      "--data-urlencode",
      "type=maven-project",
      "--data-urlencode",
      "language=java",
      "--data-urlencode",
      "packaging=jar",
      "--data-urlencode",
      "groupId=com.example",
      "--data-urlencode",
      "artifactId=demo api",
      "--data-urlencode",
      "name=Demo API",
      "--data-urlencode",
      "description=Custom Spring project",
      "--data-urlencode",
      "packageName=com.example.custom",
      "--data-urlencode",
      "javaVersion=21",
      "--data-urlencode",
      "bootVersion=4.0.0",
      "--data-urlencode",
      "dependencies=web,data-jpa",
      "--data-urlencode",
      "baseDir=demo api",
      "--output",
      "/tmp/demo.tgz",
    }, args)
  end)

  it("normalizes a Java package from coordinates", function()
    assert.equals("com.example.demoapi", spring.package_name("com.example", "demo-api"))
  end)

  it("rejects reserved package segments before any request", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local callback_error
    package.loaded["duke.process"] = {
      run = function()
        error("request must not start")
      end,
    }

    spring.create({
      cwd = cwd,
      group_id = "com.example",
      artifact_id = "demo",
      package_name = "com.class.demo",
      build = "maven",
    }, function(err)
      callback_error = err
    end)

    assert.matches("package", callback_error)
    assert.same({}, vim.fn.glob(vim.fs.joinpath(cwd, ".duke-*"), false, true))
  end)

  it("contains archive contents inside staging", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local project_dir
    package.loaded["duke.process"] = {
      run = function(command, args, _, callback)
        if command == "curl" then
          callback({ code = 0, stdout = "", stderr = "" })
          return
        end
        assert.equals("tar", command)
        if args[1] == "-tzf" then
          callback({ code = 0, stdout = "demo-api/\ndemo-api/pom.xml\n", stderr = "" })
          return
        end
        if args[1] == "-tvzf" then
          callback({
            code = 0,
            stdout = "drwxr-xr-x user/group 0 Jul 16 07:30 demo-api/\n"
              .. "-rw-r--r-- user/group 0 Jul 16 07:30 demo-api/pom.xml\n",
            stderr = "",
          })
          return
        end
        local staging = args[4]
        local generated = vim.fs.joinpath(staging, "demo-api")
        vim.fn.mkdir(generated, "p")
        vim.fn.writefile({ "<project/>" }, vim.fs.joinpath(generated, "pom.xml"))
        vim.fn.writefile({ "junk" }, vim.fs.joinpath(staging, "unexpected"))
        callback({ code = 0, stdout = "", stderr = "" })
      end,
    }

    spring.create({
      url = "https://start.spring.io/starter.tgz",
      cwd = cwd,
      group_id = "com.example",
      artifact_id = "demo-api",
      java_version = "21",
      dependencies = {},
      project_type = "maven-project",
      build = "maven",
      language = "java",
      packaging = "jar",
    }, function(err, path)
      assert.is_nil(err)
      project_dir = path
    end)

    assert.equals(vim.fs.joinpath(cwd, "demo-api"), project_dir)
    assert.equals(0, vim.fn.filereadable(vim.fs.joinpath(cwd, "unexpected")))
    assert.same({}, vim.fn.glob(vim.fs.joinpath(cwd, ".duke-*"), false, true))
  end)

  it("rejects unsafe archive members before extraction", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local extracted = false
    local received_error
    package.loaded["duke.process"] = {
      run = function(command, args, _, callback)
        if command == "curl" then
          callback({ code = 0, stdout = "", stderr = "" })
        elseif args[1] == "-tzf" then
          callback({ code = 0, stdout = "demo-api/\n../escaped\n", stderr = "" })
        else
          extracted = true
          callback({ code = 0, stdout = "", stderr = "" })
        end
      end,
    }

    spring.create({
      url = "https://start.spring.io/starter.tgz",
      cwd = cwd,
      group_id = "com.example",
      artifact_id = "demo-api",
      java_version = "21",
      dependencies = {},
      project_type = "maven-project",
      build = "maven",
      language = "java",
      packaging = "jar",
    }, function(err)
      received_error = err
    end)

    assert.is_false(extracted)
    assert.equals("Spring archive contains unsafe path: ../escaped", received_error)
    assert.equals(0, vim.fn.isdirectory(vim.fs.joinpath(cwd, "demo-api")))
    assert.same({}, vim.fn.glob(vim.fs.joinpath(cwd, ".duke-*"), false, true))
  end)

  local function assert_rejects_archive_link(listing)
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local extracted = false
    local received_error
    package.loaded["duke.process"] = {
      run = function(command, args, _, callback)
        if command == "curl" then
          callback({ code = 0, stdout = "", stderr = "" })
        elseif args[1] == "-tzf" then
          callback({ code = 0, stdout = "demo-api/\ndemo-api/link\n", stderr = "" })
        elseif args[1] == "-tvzf" then
          callback({
            code = 0,
            stdout = "drwxr-xr-x  0 user group 0 Jul 16 07:30 demo-api/\n" .. listing,
            stderr = "",
          })
        else
          extracted = true
          callback({ code = 0, stdout = "", stderr = "" })
        end
      end,
    }

    spring.create({
      url = "https://start.spring.io/starter.tgz",
      cwd = cwd,
      group_id = "com.example",
      artifact_id = "demo-api",
      java_version = "21",
      dependencies = {},
      project_type = "maven-project",
      build = "maven",
      language = "java",
      packaging = "jar",
    }, function(err)
      received_error = err
    end)

    assert.is_false(extracted)
    assert.equals("Spring archive contains unsupported link: demo-api/link", received_error)
    assert.equals(0, vim.fn.isdirectory(vim.fs.joinpath(cwd, "demo-api")))
    assert.same({}, vim.fn.glob(vim.fs.joinpath(cwd, ".duke-*"), false, true))
  end

  it("rejects archive symlinks before extraction", function()
    assert_rejects_archive_link(
      "lrwxrwxrwx  0 user group 0 Jul 16 07:30 demo-api/link -> ../../escape\n"
    )
  end)

  it("rejects archive hardlinks before extraction", function()
    assert_rejects_archive_link(
      "hrw-r--r--  0 user group 0 Jul 16 07:30 demo-api/link link to demo-api/pom.xml\n"
    )
  end)

  it("promotes Gradle Spring projects with Kotlin build files", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local project_dir
    package.loaded["duke.process"] = {
      run = function(command, args, _, callback)
        if command == "curl" then
          callback({ code = 0, stdout = "", stderr = "" })
        elseif args[1] == "-tzf" then
          callback({ code = 0, stdout = "demo-api/\ndemo-api/build.gradle.kts\n", stderr = "" })
        elseif args[1] == "-tvzf" then
          callback({
            code = 0,
            stdout = "drwxr-xr-x user/group 0 Jul 16 07:30 demo-api/\n"
              .. "-rw-r--r-- user/group 0 Jul 16 07:30 demo-api/build.gradle.kts\n",
            stderr = "",
          })
        else
          local generated = vim.fs.joinpath(args[4], "demo-api")
          vim.fn.mkdir(generated, "p")
          vim.fn.writefile({ "plugins {}" }, vim.fs.joinpath(generated, "build.gradle.kts"))
          callback({ code = 0, stdout = "", stderr = "" })
        end
      end,
    }

    spring.create({
      url = "https://start.spring.io/starter.tgz",
      cwd = cwd,
      group_id = "com.example",
      artifact_id = "demo-api",
      java_version = "21",
      dependencies = {},
      project_type = "gradle-project-kotlin",
      build = "gradle",
      language = "java",
      packaging = "jar",
    }, function(err, path)
      assert.is_nil(err)
      project_dir = path
    end)

    assert.equals(vim.fs.joinpath(cwd, "demo-api"), project_dir)
    assert.equals(1, vim.fn.filereadable(vim.fs.joinpath(project_dir, "build.gradle.kts")))
  end)

  it("rejects responses missing the selected build file", function()
    for _, case in ipairs({
      { build = "maven", expected = "pom.xml" },
      { build = "gradle", expected = "build.gradle or build.gradle.kts" },
    }) do
      local cwd = vim.fn.tempname()
      vim.fn.mkdir(cwd, "p")
      temporary_directories[#temporary_directories + 1] = cwd
      local received_error
      package.loaded["duke.process"] = {
        run = function(command, args, _, callback)
          if command == "curl" then
            callback({ code = 0, stdout = "", stderr = "" })
          elseif args[1] == "-tzf" then
            callback({ code = 0, stdout = "demo-api/\n", stderr = "" })
          elseif args[1] == "-tvzf" then
            callback({ code = 0, stdout = "drwxr-xr-x user/group 0 demo-api/\n", stderr = "" })
          else
            vim.fn.mkdir(vim.fs.joinpath(args[4], "demo-api"), "p")
            callback({ code = 0, stdout = "", stderr = "" })
          end
        end,
      }

      spring.create({
        url = "https://start.spring.io/starter.tgz",
        cwd = cwd,
        group_id = "com.example",
        artifact_id = "demo-api",
        java_version = "21",
        dependencies = {},
        project_type = case.build .. "-project",
        build = case.build,
        language = "java",
        packaging = "jar",
      }, function(err)
        received_error = err
      end)

      assert.equals("Spring Initializr response contained no " .. case.expected, received_error)
    end
  end)
end)
