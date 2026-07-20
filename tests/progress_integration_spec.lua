describe("progress integration", function()
  local original_cwd
  local temporary_directories

  before_each(function()
    original_cwd = vim.fn.getcwd()
    temporary_directories = {}
  end)

  after_each(function()
    package.loaded["duke"] = nil
    package.loaded["duke.config"] = nil
    package.loaded["duke.managed"] = nil
    package.loaded["duke.metadata"] = nil
    package.loaded["duke.maven_central"] = nil
    package.loaded["duke.picker"] = nil
    package.loaded["duke.pom"] = nil
    package.loaded["duke.pom_file"] = nil
    package.loaded["duke.process"] = nil
    package.loaded["duke.progress"] = nil
    package.loaded["duke.wizard"] = nil
    vim.cmd.cd(vim.fn.fnameescape(original_cwd))
    for _, path in ipairs(temporary_directories) do
      vim.fn.delete(path, "rf")
    end
  end)

  local function open_pom(lines)
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    temporary_directories[#temporary_directories + 1] = directory
    vim.fn.writefile(lines, vim.fs.joinpath(directory, "pom.xml"))
    vim.cmd.cd(vim.fn.fnameescape(directory))
  end

  it("keeps managed resolution UI-free for headless callers", function()
    local process_callback
    package.loaded["duke.process"] = {
      run = function(_, _, _, callback)
        process_callback = callback
      end,
    }
    package.loaded["duke.progress"] = {
      task = function()
        error("headless managed resolution must not start UI progress")
      end,
    }

    local result
    require("duke.managed").resolve("/tmp/pom.xml", {
      { group_id = "com.example", artifact_id = "demo" },
    }, function(err, resolved)
      result = { err = err, resolved = resolved }
    end)

    assert.is_nil(result)

    process_callback({
      code = 0,
      stdout = "[INFO] com.example:demo:jar:1.0:compile",
      stderr = "",
    })

    assert.equals("1.0", result.resolved["com.example:demo"])
  end)

  it("owns managed-resolution progress in the interactive layer", function()
    open_pom({
      "<project>",
      "  <parent>",
      "    <groupId>org.springframework.boot</groupId>",
      "    <artifactId>spring-boot-starter-parent</artifactId>",
      "    <version>3.5.4</version>",
      "  </parent>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    })
    local resolution_callback
    local label
    local terminal
    package.loaded["duke.managed"] = {
      resolve = function(_, _, callback)
        resolution_callback = callback
      end,
    }
    package.loaded["duke.progress"] = {
      task = function(value)
        label = value
        return {
          done = function()
            terminal = "done"
          end,
          fail = function()
            terminal = "failed"
          end,
        }
      end,
    }
    local formatter = require("duke.picker").format_dependency
    package.loaded["duke.picker"] = {
      format_dependency = formatter,
      select_one = function(_, _, callback)
        callback(nil)
      end,
    }

    require("duke").update_dependency()

    assert.equals("Resolving managed dependencies", label)
    assert.is_nil(terminal)
    resolution_callback(nil, {
      ["org.springframework.boot:spring-boot-starter-web"] = "3.5.4",
    })
    assert.equals("done", terminal)
  end)

  it("finishes Spring metadata progress from the fetch callback", function()
    local fetch_callback
    local label
    local terminal
    package.loaded["duke.metadata"] = {
      cache_path = function()
        return "/tmp/cache"
      end,
      fetch_cached = function(_, _, _, callback)
        fetch_callback = callback
      end,
      is_client = function()
        return true
      end,
    }
    package.loaded["duke.progress"] = {
      task = function(value)
        label = value
        return {
          done = function()
            terminal = "done"
          end,
          fail = function()
            terminal = "failed"
          end,
        }
      end,
    }

    local advanced
    local step = require("duke.wizard").spring_metadata_fetch({
      spring = { metadata_url = "https://initializr.test" },
    })
    step({}, function(state)
      advanced = state
    end)

    assert.equals("Loading Spring Initializr metadata", label)
    assert.is_nil(terminal)
    assert.is_nil(advanced)

    fetch_callback(nil, { bootVersion = {} }, "remote")

    assert.equals("done", terminal)
    assert.is_not_nil(advanced)
  end)

  it("counts completed Maven Central checks and stops on completion", function()
    open_pom({
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>first</artifactId>",
      "      <version>1.0</version>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>second</artifactId>",
      "      <version>1.0</version>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    })
    local total
    local label
    local completed = 0
    local terminal
    package.loaded["duke.progress"] = {
      batch = function(value, text)
        total = value
        label = text
        return {
          next = function()
            completed = completed + 1
          end,
          done = function()
            terminal = "done"
          end,
          fail = function()
            terminal = "failed"
          end,
        }
      end,
    }
    package.loaded["duke.maven_central"] = {
      versions = function(_, _, callback)
        callback(nil, { "1.0" })
      end,
    }
    package.loaded["duke.picker"] = {
      select_one = function()
        error("up-to-date dependencies must not open picker")
      end,
    }

    require("duke").outdated_dependencies()

    assert.equals(2, total)
    assert.equals("Checking Maven Central", label)
    assert.equals(2, completed)
    assert.equals("done", terminal)
  end)

  it("keeps Spring dependency loading active until both fetches finish", function()
    open_pom({ "<project>", "</project>" })
    local callbacks = {}
    local label
    local terminal
    local picker_opened = false
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
    }
    package.loaded["duke.metadata"] = {
      cache_path = function(kind)
        return kind
      end,
      fetch_cached = function(_, _, _, callback)
        callbacks[#callbacks + 1] = callback
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
    }
    package.loaded["duke.progress"] = {
      task = function(value)
        label = value
        return {
          done = function()
            terminal = "done"
          end,
          fail = function()
            terminal = "failed"
          end,
        }
      end,
    }
    package.loaded["duke.picker"] = {
      select_many = function(_, _, callback)
        picker_opened = true
        callback(nil)
      end,
    }

    require("duke").add_dependency()

    assert.equals("Loading dependencies for Spring Boot 3.5.4", label)
    assert.is_nil(terminal)
    callbacks[1](nil, { dependencies = {} }, "remote")
    assert.equals(2, #callbacks)
    assert.is_nil(terminal)
    callbacks[2](nil, { dependencies = {} }, "remote")

    assert.equals("done", terminal)
    assert.is_true(picker_opened)
  end)
end)
