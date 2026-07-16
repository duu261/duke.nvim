describe("Spring Initializr scaffolding", function()
  local spring
  local temporary_directories = {}

  before_each(function()
    package.loaded["java_scaffold.spring"] = nil
    spring = require("java_scaffold.spring")
  end)

  after_each(function()
    package.loaded["java_scaffold.process"] = nil
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
      "name=demo api",
      "--data-urlencode",
      "packageName=com.example.demoapi",
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

  it("contains archive contents inside staging", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local project_dir
    package.loaded["java_scaffold.process"] = {
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
      language = "java",
      packaging = "jar",
    }, function(err, path)
      assert.is_nil(err)
      project_dir = path
    end)

    assert.equals(vim.fs.joinpath(cwd, "demo-api"), project_dir)
    assert.equals(0, vim.fn.filereadable(vim.fs.joinpath(cwd, "unexpected")))
    assert.same({}, vim.fn.glob(vim.fs.joinpath(cwd, ".java-scaffold-*"), false, true))
  end)

  it("rejects unsafe archive members before extraction", function()
    local cwd = vim.fn.tempname()
    vim.fn.mkdir(cwd, "p")
    temporary_directories[#temporary_directories + 1] = cwd
    local extracted = false
    local received_error
    package.loaded["java_scaffold.process"] = {
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
      language = "java",
      packaging = "jar",
    }, function(err)
      received_error = err
    end)

    assert.is_false(extracted)
    assert.equals("Spring archive contains unsafe path: ../escaped", received_error)
    assert.equals(0, vim.fn.isdirectory(vim.fs.joinpath(cwd, "demo-api")))
    assert.same({}, vim.fn.glob(vim.fs.joinpath(cwd, ".java-scaffold-*"), false, true))
  end)
end)
