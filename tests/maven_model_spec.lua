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
            "  <groupId>com.acme</groupId>",
            "  <artifactId>app</artifactId>",
            "  <version>1.0.0</version>",
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
      calls[1].args[6],
    }, calls[1].args)
    assert.matches("^%-Doutput=", calls[1].args[6])
    assert.same({
      "-q",
      "-f",
      "/workspace/app/pom.xml",
      "org.apache.maven.plugins:maven-dependency-plugin:3.11.0:tree",
      "-DoutputType=json",
      "-Dverbose",
      calls[2].args[7],
    }, calls[2].args)
    assert.matches("^%-DoutputFile=", calls[2].args[7])
    assert.equals(5000, calls[1].opts.timeout)
    assert.equals(1, #results[1].result.modules[1].resolved.tree.children)
    assert.is_nil(vim.uv.fs_stat(calls[1].args[6]:sub(10)))
    assert.is_nil(vim.uv.fs_stat(calls[2].args[7]:sub(14)))
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
end)
