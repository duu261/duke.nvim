describe("Maven workspace enrichment", function()
  local calls
  local maven_model

  local function snapshot()
    return {
      kind = "maven",
      state = "local",
      modules = {
        {
          id = "com.acme:app",
          root = "/workspace/app",
          build_file = "/workspace/app/pom.xml",
          model = { dependencies = {} },
        },
      },
      diagnostics = {},
    }
  end

  before_each(function()
    calls = {}
    package.loaded["duke.maven_model"] = nil
    package.loaded["duke.build"] = {
      maven = function()
        return { command = "/workspace/mvnw", cwd = "/workspace/app" }
      end,
    }
    package.loaded["duke.process"] = {
      detail = function(result)
        return result.stderr
      end,
      run = function(command, args, opts, callback)
        calls[#calls + 1] = { command = command, args = args, opts = opts }
        local output = table.concat(args, " "):match("%-DoutputFile=([^ ]+)")
          or table.concat(args, " "):match("%-Doutput=([^ ]+)")
        if #calls == 1 then
          vim.fn.writefile({
            "<project>",
            "  <groupId>com.acme</groupId>  <!-- com.acme:app:1.0.0, line 2 -->",
            "  <artifactId>app</artifactId>",
            "  <version>1.0.0</version>",
            "  <modules>",
            "    <module>child</module>  <!-- com.acme:app:1.0.0, line 8 -->",
            "  </modules>",
            "  <properties>",
            "    <slf4j.version>2.0.17</slf4j.version>  <!-- com.acme:app:1.0.0, line 12 -->",
            "  </properties>",
            "</project>",
          }, output)
        else
          vim.fn.writefile({
            vim.json.encode({
              groupId = "com.acme",
              artifactId = "app",
              version = "1.0.0",
              children = {
                {
                  groupId = "org.slf4j",
                  artifactId = "slf4j-api",
                  version = "2.0.17",
                  scope = "compile",
                },
              },
            }),
          }, output)
        end
        callback({ code = 0, stdout = "", stderr = "" })
      end,
    }
    maven_model = require("duke.maven_model")
  end)

  after_each(function()
    package.loaded["duke.maven_model"] = nil
    package.loaded["duke.build"] = nil
    package.loaded["duke.process"] = nil
  end)

  it("uses versioned read-only goals through the wrapper and cleans output", function()
    local results = {}
    maven_model.enrich(snapshot(), { timeout = 5000 }, function(err, result)
      results[#results + 1] = { err = err, result = result }
    end)

    assert.equals(1, #results)
    assert.is_nil(results[1].err)
    assert.equals("resolved", results[1].result.state)
    assert.equals("/workspace/mvnw", calls[1].command)
    assert.same({
      "-q",
      "-N",
      "-f",
      "/workspace/app/pom.xml",
      "org.apache.maven.plugins:maven-help-plugin:3.5.2:effective-pom",
      "-Dverbose",
      calls[1].args[7],
    }, calls[1].args)
    assert.matches("^%-Doutput=", calls[1].args[7])
    assert.same({
      "-q",
      "-N",
      "-f",
      "/workspace/app/pom.xml",
      "org.apache.maven.plugins:maven-dependency-plugin:3.11.0:tree",
      "-DoutputType=json",
      "-Dverbose",
      calls[2].args[8],
    }, calls[2].args)
    assert.matches("^%-DoutputFile=", calls[2].args[8])
    assert.equals(5000, calls[1].opts.timeout)
    assert.equals(1, #results[1].result.modules[1].resolved.tree.children)
    assert.same({
      { source = "com.acme:app:1.0.0", line = 2, effective_line = 2 },
      { source = "com.acme:app:1.0.0", line = 8, effective_line = 6 },
      { source = "com.acme:app:1.0.0", line = 12, effective_line = 9 },
    }, results[1].result.modules[1].resolved.effective.sources)
    assert.is_nil(vim.uv.fs_stat(calls[1].args[7]:sub(10)))
    assert.is_nil(vim.uv.fs_stat(calls[2].args[8]:sub(14)))
  end)

  it("returns a partial snapshot after a non-zero goal", function()
    package.loaded["duke.process"].run = function(_, _, _, callback)
      callback({ code = 1, stdout = "", stderr = "offline" })
    end
    package.loaded["duke.maven_model"] = nil
    maven_model = require("duke.maven_model")
    local result

    maven_model.enrich(snapshot(), {}, function(_, value)
      result = value
    end)

    assert.equals("partial", result.state)
    assert.equals("maven_goal_failed", result.diagnostics[1].code)
  end)

  it("parses the proven text dependency-tree fallback", function()
    package.loaded["duke.process"].run = function(_, args, _, callback)
      local output = table.concat(args, " "):match("%-DoutputFile=([^ ]+)")
        or table.concat(args, " "):match("%-Doutput=([^ ]+)")
      if output:find("effective", 1, true) then
        error("unexpected output path")
      end
      if table.concat(args, " "):find("effective%-pom") then
        vim.fn.writefile({
          "<project>",
          "  <groupId>com.acme</groupId>",
          "  <artifactId>app</artifactId>",
          "  <version>1.0.0</version>",
          "</project>",
        }, output)
      else
        vim.fn.writefile({
          "com.acme:app:jar:1.0.0",
          "+- org.slf4j:slf4j-api:jar:2.0.17:compile",
          "|  \\- com.acme:legacy:jar:1.0.0:compile",
          "\\- (com.acme:old:jar:1.0.0:compile - omitted for conflict with 2.0.0)",
        }, output)
      end
      callback({ code = 0, stdout = "", stderr = "" })
    end
    package.loaded["duke.maven_model"] = nil
    maven_model = require("duke.maven_model")
    local result

    maven_model.enrich(snapshot(), {}, function(_, value)
      result = value
    end)

    local tree = result.modules[1].resolved.tree
    assert.equals("com.acme:app", tree.coordinate)
    assert.equals("com.acme:legacy", tree.children[1].children[1].coordinate)
    assert.equals("2.0.0", tree.children[2].omitted_for_conflict)
  end)

  it("rejects oversized Maven output and cleans it", function()
    local oversized_path
    package.loaded["duke.process"].run = function(_, args, _, callback)
      local output = table.concat(args, " "):match("%-Doutput=([^ ]+)")
      oversized_path = output
      vim.fn.writefile({ string.rep("x", 8 * 1024 * 1024 + 1) }, output)
      callback({ code = 0, stdout = "", stderr = "" })
    end
    package.loaded["duke.maven_model"] = nil
    maven_model = require("duke.maven_model")
    local result

    maven_model.enrich(snapshot(), {}, function(_, value)
      result = value
    end)

    assert.equals("partial", result.state)
    assert.matches("exceeds size limit", result.diagnostics[1].message)
    assert.is_nil(vim.uv.fs_stat(oversized_path))
  end)

  it("contains malformed process callbacks and finishes once", function()
    package.loaded["duke.process"].run = function(_, _, _, callback)
      callback(nil)
      callback(nil)
    end
    package.loaded["duke.maven_model"] = nil
    maven_model = require("duke.maven_model")
    local count = 0
    local result

    assert.has_no.errors(function()
      maven_model.enrich(snapshot(), {}, function(_, value)
        count = count + 1
        result = value
      end)
    end)

    assert.equals(1, count)
    assert.equals("partial", result.state)
  end)
end)
