describe("Maven Doctor reports", function()
  local calls
  local doctor
  local logs

  local function snapshot()
    return {
      kind = "maven",
      state = "local",
      root = "/workspace",
      modules = {
        {
          id = "com.acme:app",
          root = "/workspace",
          build_file = "/workspace/pom.xml",
          model = { dependencies = {} },
        },
      },
      diagnostics = {},
      analysis = { existing = true },
    }
  end

  local function output_path(args)
    return table.concat(args, " "):match("%-Doutput=([^ ]+)")
  end

  before_each(function()
    calls = {}
    logs = {}
    package.loaded["duke.maven_doctor"] = nil
    package.loaded["duke.maven_model"] = {
      enrich = function(input, _, callback)
        callback(nil, vim.deepcopy(input))
      end,
      read_output = function(path)
        local ok, lines = pcall(vim.fn.readfile, path)
        return ok and lines or nil, ok and nil or lines
      end,
    }
    package.loaded["duke.build"] = {
      maven = function()
        return { command = "/workspace/mvnw", cwd = "/workspace" }
      end,
    }
    package.loaded["duke.maven_ownership"] = {
      resolve = function()
        return { proof = true }
      end,
    }
    package.loaded["duke.dependency_analyzer"] = {
      analyze = function()
        return { findings = {}, dependencies = {}, paths = {} }
      end,
      repairable = function(_, rows, usage)
        assert.is_true(rows.proof)
        assert.same({}, usage.used_undeclared)
        return { { id = "doctor-proof", kind = "proof" } }
      end,
    }
    package.loaded["duke.log"] = {
      add = function(level, message)
        logs[#logs + 1] = { level = level, message = message }
      end,
    }
    package.loaded["duke.process"] = {
      detail = function(result)
        return result.stderr
      end,
      run = function(command, args, opts, callback)
        calls[#calls + 1] = { command = command, args = args, opts = opts }
        local path = output_path(args)
        if path then
          vim.fn.writefile({
            "The following profiles are active:",
            " - local-dev (source: com.acme:app)",
            " - jdk-21 (source: com.acme:app)",
          }, path)
        end
        callback({ code = 0, stdout = "", stderr = "" })
      end,
    }
    doctor = require("duke.maven_doctor")
  end)

  after_each(function()
    package.loaded["duke.maven_doctor"] = nil
    package.loaded["duke.maven_model"] = nil
    package.loaded["duke.build"] = nil
    package.loaded["duke.log"] = nil
    package.loaded["duke.process"] = nil
    package.loaded["duke.maven_ownership"] = nil
    package.loaded["duke.dependency_analyzer"] = nil
  end)

  it("reports active profiles through the wrapper and cleans output", function()
    local result
    doctor.inspect(snapshot(), {
      maven_command = "mvn",
      env = { JAVA_HOME = "/jdk" },
      timeout = 5000,
    }, function(err, value)
      assert.is_nil(err)
      result = value
    end)

    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.equals("/workspace/mvnw", calls[1].command)
    assert.same({
      "-q",
      "-f",
      "/workspace/pom.xml",
      "org.apache.maven.plugins:maven-help-plugin:3.5.2:active-profiles",
      calls[1].args[5],
    }, calls[1].args)
    assert.matches("^%-Doutput=", calls[1].args[5])
    assert.same({ JAVA_HOME = "/jdk" }, calls[1].opts.env)
    assert.equals("/workspace", calls[1].opts.cwd)
    assert.equals(5000, calls[1].opts.timeout)
    assert.same({ "local-dev", "jdk-21" }, result.analysis.doctor.active_profiles)
    assert.same({}, result.analysis.doctor.usage.used_undeclared)
    assert.same({}, result.analysis.doctor.usage.unused_declared)
    assert.same({}, result.analysis.doctor.warnings)
    assert.is_false(result.analysis.doctor.deep)
    assert.is_true(result.analysis.existing)
    assert.is_true(result.analysis.ownership.proof)
    assert.equals("doctor-proof", result.analysis.findings[1].id)
    assert.is_nil(vim.uv.fs_stat(calls[1].args[5]:sub(10)))
  end)

  it("preserves enrichment after active-profile failure", function()
    package.loaded["duke.process"].run = function(_, _, _, callback)
      callback({ code = 1, stdout = "", stderr = "offline" })
    end
    package.loaded["duke.maven_doctor"] = nil
    doctor = require("duke.maven_doctor")
    local result

    doctor.inspect(snapshot(), {}, function(err, value)
      assert.is_nil(err)
      result = value
    end)

    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.equals("partial", result.state)
    assert.same({}, result.analysis.doctor.active_profiles)
    assert.same({ "active profiles unavailable" }, result.analysis.doctor.warnings)
    assert.matches("offline", logs[1].message)
  end)

  it("rejects oversized active-profile output before reading it", function()
    package.loaded["duke.maven_model"].read_output = function()
      return nil, "Maven inspection output exceeds size limit"
    end
    package.loaded["duke.maven_doctor"] = nil
    doctor = require("duke.maven_doctor")
    local result

    doctor.inspect(snapshot(), {}, function(err, value)
      assert.is_nil(err)
      result = value
    end)

    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.equals("partial", result.state)
    assert.same({ "active profiles output unavailable" }, result.analysis.doctor.warnings)
    assert.matches("exceeds size limit", logs[1].message)
    assert.is_nil(vim.uv.fs_stat(calls[1].args[5]:sub(10)))
  end)

  it("runs dependency analysis only when deep is requested", function()
    package.loaded["duke.process"].run = function(command, args, opts, callback)
      calls[#calls + 1] = { command = command, args = args, opts = opts }
      local path = output_path(args)
      if path then
        vim.fn.writefile({ " - local-dev (source: com.acme:app)" }, path)
      end
      callback({
        code = 0,
        stdout = table.concat({
          "[WARNING] Used undeclared dependencies found:",
          "[WARNING]   com.acme:missing:jar:1.0:compile",
          "[WARNING] Unused declared dependencies found:",
          "[WARNING]   com.acme:unused:jar:1.0:compile",
          "[WARNING]   com.acme:unused:jar:1.0:compile",
        }, "\n"),
        stderr = "",
      })
    end
    package.loaded["duke.maven_doctor"] = nil
    doctor = require("duke.maven_doctor")
    local result

    doctor.inspect(snapshot(), { deep = true }, function(err, value)
      assert.is_nil(err)
      result = value
    end)

    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.same(
      "org.apache.maven.plugins:maven-dependency-plugin:3.11.0:analyze",
      calls[#calls].args[4]
    )
    assert.same({ "com.acme:missing" }, result.analysis.doctor.usage.used_undeclared)
    assert.same({ "com.acme:unused" }, result.analysis.doctor.usage.unused_declared)
    assert.is_true(result.analysis.doctor.deep)
  end)

  it("keeps deep-analysis output out of public warnings", function()
    local invocation = 0
    package.loaded["duke.process"].run = function(_, args, _, callback)
      invocation = invocation + 1
      local path = output_path(args)
      if path then
        vim.fn.writefile({ " - local-dev (source: com.acme:app)" }, path)
      end
      if invocation == 1 then
        callback({ code = 0, stdout = "", stderr = "" })
      else
        callback({ code = 1, stdout = "sensitive stdout", stderr = "sensitive stderr" })
      end
    end
    package.loaded["duke.maven_doctor"] = nil
    doctor = require("duke.maven_doctor")
    local result

    doctor.inspect(snapshot(), { deep = true }, function(err, value)
      assert.is_nil(err)
      result = value
    end)

    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.same({ "dependency analysis unavailable" }, result.analysis.doctor.warnings)
    assert.matches("sensitive stderr", logs[1].message)
  end)

  it("contains repeated process callbacks and callback errors", function()
    package.loaded["duke.process"].run = function(_, args, _, callback)
      local path = output_path(args)
      vim.fn.writefile({ " - local-dev (source: com.acme:app)" }, path)
      callback({ code = 0, stdout = "", stderr = "" })
      callback({ code = 0, stdout = "", stderr = "" })
    end
    package.loaded["duke.maven_doctor"] = nil
    doctor = require("duke.maven_doctor")
    local count = 0

    assert.has_no.errors(function()
      doctor.inspect(snapshot(), {}, function()
        count = count + 1
        error("callback failure")
      end)
    end)

    assert.is_true(vim.wait(100, function()
      return count == 1
    end))
    assert.equals(1, count)
  end)

  it("schedules one terminal callback", function()
    local count = 0

    doctor.inspect(snapshot(), {}, function()
      count = count + 1
    end)

    assert.equals(0, count)
    assert.is_true(vim.wait(100, function()
      return count == 1
    end))
  end)

  it("contains enrichment callback failures and still finishes once", function()
    package.loaded["duke.maven_model"].enrich = function(input, _, callback)
      local malformed = vim.deepcopy(input)
      malformed.analysis = "invalid"
      pcall(callback, nil, malformed)
    end
    package.loaded["duke.maven_doctor"] = nil
    doctor = require("duke.maven_doctor")
    local count = 0
    local received_err

    assert.has_no.errors(function()
      doctor.inspect(snapshot(), {}, function(err)
        count = count + 1
        received_err = err
      end)
    end)

    assert.is_true(vim.wait(100, function()
      return count == 1
    end))
    assert.equals(1, count)
    assert.equals("Maven Doctor inspection failed", received_err)
    assert.matches("invalid Maven analysis state", logs[1].message)
  end)

  it("preserves analyzed evidence when ownership synthesis fails", function()
    package.loaded["duke.maven_ownership"].resolve = function()
      error("ownership failure detail")
    end
    package.loaded["duke.dependency_analyzer"].repairable = function(_, rows)
      assert.same({}, rows)
      return { { id = "blocked-proof", repairable = false } }
    end
    package.loaded["duke.maven_doctor"] = nil
    doctor = require("duke.maven_doctor")
    local result

    doctor.inspect(snapshot(), {}, function(err, value)
      assert.is_nil(err)
      result = value
    end)

    assert.is_true(vim.wait(100, function()
      return result ~= nil
    end))
    assert.equals("partial", result.state)
    assert.equals("blocked-proof", result.analysis.findings[1].id)
    assert.is_false(result.analysis.findings[1].repairable)
    assert.same({ "ownership analysis unavailable" }, result.analysis.doctor.warnings)
    assert.matches("ownership failure detail", logs[1].message)
  end)
end)
