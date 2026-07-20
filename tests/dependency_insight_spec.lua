describe("Maven dependency insight", function()
  local insight

  before_each(function()
    package.loaded["duke.dependency_insight"] = nil
    insight = require("duke.dependency_insight")
  end)

  after_each(function()
    package.loaded["duke.dependency_insight"] = nil
    package.loaded["duke.process"] = nil
    package.loaded["duke.log"] = nil
  end)

  it("extracts resolved tree lines and preserves Maven annotations", function()
    local lines = insight.parse([[
[INFO] Scanning for projects...
[INFO] --- maven-dependency-plugin:3.8.1:tree (default-cli) @ demo ---
[INFO] com.example:demo:jar:1.0.0
[INFO] +- org.springframework:spring-core:jar:6.2.8:compile
[INFO] |  \- commons-logging:commons-logging:jar:1.3.5:compile
[INFO]    \- org.example:space-indented:jar:1.0:compile
[INFO] \- example:legacy:jar:1.0:compile (omitted for conflict with 2.0)
[INFO] BUILD SUCCESS
]])

    assert.same({
      "com.example:demo:jar:1.0.0",
      "+- org.springframework:spring-core:jar:6.2.8:compile",
      "|  \\- commons-logging:commons-logging:jar:1.3.5:compile",
      "   \\- org.example:space-indented:jar:1.0:compile",
      "\\- example:legacy:jar:1.0:compile (omitted for conflict with 2.0)",
    }, lines)
  end)

  it("accepts only groupId:artifactId coordinates", function()
    assert.is_nil(insight.coordinate_error("com.google.guava:guava"))
    assert.equals("use groupId:artifactId", insight.coordinate_error("guava"))
    assert.equals("use groupId:artifactId", insight.coordinate_error("com.acme:lib:1.0"))
    assert.equals("use groupId:artifactId", insight.coordinate_error("com.acme:bad value"))
  end)

  it("runs Maven once with argument lists and the nearest POM directory", function()
    local call
    package.loaded["duke.process"] = {
      run = function(command, args, opts, callback)
        call = { command = command, args = args, opts = opts }
        callback({
          code = 0,
          stdout = "[INFO] com.example:demo:jar:1.0\n[INFO] \\- org.test:item:jar:2.0:test\n",
          stderr = "",
        })
      end,
    }

    local err, lines
    insight.inspect(
      "/tmp/demo/pom.xml",
      "org.test:item",
      { command = "mvnd", timeout = 42000, env = { JAVA_HOME = "/jdk/21" } },
      function(result_error, result_lines)
        err = result_error
        lines = result_lines
      end
    )

    assert.is_nil(err)
    assert.same({ "com.example:demo:jar:1.0", "\\- org.test:item:jar:2.0:test" }, lines)
    assert.equals("mvnd", call.command)
    assert.same({
      "dependency:tree",
      "-Dverbose",
      "-Dstyle.color=never",
      "-Dincludes=org.test:item",
      "--batch-mode",
      "-f",
      "/tmp/demo/pom.xml",
    }, call.args)
    assert.equals("/tmp/demo", call.opts.cwd)
    assert.equals(42000, call.opts.timeout)
    assert.same({ JAVA_HOME = "/jdk/21" }, call.opts.env)
  end)

  it("reports a missing coordinate plainly", function()
    package.loaded["duke.process"] = {
      run = function(_, _, _, callback)
        callback({ code = 0, stdout = "[INFO] com.example:demo:jar:1.0\n", stderr = "" })
      end,
    }

    local err
    insight.inspect("/tmp/demo/pom.xml", "org.missing:item", {}, function(result_error)
      err = result_error
    end)

    assert.equals("org.missing:item is not on the dependency tree", err)
  end)

  it("keeps Maven failure detail in the log", function()
    local logged
    package.loaded["duke.process"] = {
      run = function(_, _, _, callback)
        callback({ code = 1, stdout = "", stderr = "resolver exploded" })
      end,
    }
    package.loaded["duke.log"] = {
      add = function(level, message)
        logged = { level, message }
      end,
    }

    local err
    insight.inspect("/tmp/demo/pom.xml", nil, {}, function(result_error)
      err = result_error
    end)

    assert.equals("Maven dependency tree failed; see :DukeLog", err)
    assert.same({ "ERROR", "mvn dependency:tree failed: resolver exploded" }, logged)
  end)
end)
