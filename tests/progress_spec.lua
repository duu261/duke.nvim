describe("duke.progress", function()
  local original_notify

  before_each(function()
    original_notify = vim.notify
    package.loaded["duke.progress"] = nil
  end)

  after_each(function()
    vim.notify = original_notify
    package.loaded["duke.progress"] = nil
  end)

  it("finishes only when the async owner reports completion", function()
    local notifications = {}
    vim.notify = function(message, level, opts)
      notifications[#notifications + 1] = { message = message, level = level, opts = opts }
      return #notifications
    end

    local task = require("duke.progress").task("Loading metadata")

    assert.equals(1, #notifications)
    assert.is_truthy(notifications[1].message:find("Loading metadata", 1, true))
    assert.is_falsy(notifications[1].message:find("done", 1, true))

    task:done()

    assert.equals(2, #notifications)
    assert.is_truthy(notifications[2].message:find("Loading metadata done", 1, true))
    assert.equals(1, notifications[2].opts.replace)
  end)

  it("has one terminal state and distinguishes failure", function()
    local notifications = {}
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end

    local task = require("duke.progress").task("Resolving dependencies")
    task:fail("Resolution failed")
    task:done()

    assert.equals(2, #notifications)
    assert.is_truthy(notifications[2].message:find("Resolution failed", 1, true))
    assert.equals(vim.log.levels.WARN, notifications[2].level)
  end)

  it("reports bounded batch counts and terminal completion", function()
    local notifications = {}
    vim.notify = function(message)
      notifications[#notifications + 1] = message
      return #notifications
    end

    local batch = require("duke.progress").batch(2, "Checking Maven Central")
    batch:next()
    batch:next()
    batch:next()
    batch:done()

    assert.equals(4, #notifications)
    assert.is_truthy(notifications[1]:find("0/2", 1, true))
    assert.is_truthy(notifications[2]:find("1/2", 1, true))
    assert.is_truthy(notifications[3]:find("2/2", 1, true))
    assert.is_truthy(notifications[4]:find("done", 1, true))
  end)
end)
