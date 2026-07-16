describe("process runner", function()
  local process

  before_each(function()
    package.loaded["duke.process"] = nil
    process = require("duke.process")
  end)

  it("reports startup failures through callback", function()
    local result

    assert.has_no.errors(function()
      process.run("true", {}, { cwd = "/path/that/does/not/exist" }, function(value)
        result = value
      end)
    end)

    assert(vim.wait(1000, function()
      return result ~= nil
    end))
    assert.not_equals(0, result.code)
    assert.is_truthy(result.stderr:match("ENOENT") or result.stderr:match("exist"))
  end)

  it("provides nonblank process failure detail", function()
    assert.equals("stdout failure", process.detail({ stderr = "", stdout = "  stdout failure\n" }))
    assert.equals("unknown error", process.detail({ stderr = "", stdout = "" }))
  end)
end)
