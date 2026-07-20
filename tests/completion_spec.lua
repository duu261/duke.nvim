describe("callback completion boundary", function()
  local original_schedule

  before_each(function()
    original_schedule = vim.schedule
    package.loaded["duke.completion"] = nil
    package.loaded["duke.log"] = nil
  end)

  after_each(function()
    vim.schedule = original_schedule
    package.loaded["duke.completion"] = nil
    package.loaded["duke.log"] = nil
  end)

  it("falls back once when scheduling and logging fail", function()
    package.loaded["duke.log"] = {
      add = function()
        error("logger failed")
      end,
    }
    vim.schedule = function()
      error("scheduler failed")
    end
    local completion = require("duke.completion")
    local count = 0
    local finish = completion.once(function()
      count = count + 1
    end, "test completion")

    assert.has_no.errors(function()
      finish(nil, { ok = true })
      finish(nil, { ok = true })
    end)
    assert.equals(1, count)
  end)

  it("contains handler and recovery failures", function()
    package.loaded["duke.log"] = {
      add = function()
        error("logger failed")
      end,
    }
    local completion = require("duke.completion")
    local guarded = completion.guard_once(function()
      error("handler failed")
    end, function()
      error("recovery failed")
    end, "test guard")

    assert.has_no.errors(function()
      guarded()
      guarded()
    end)
  end)
end)
