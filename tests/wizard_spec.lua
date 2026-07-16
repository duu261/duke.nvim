describe("Wizard engine", function()
  local wizard

  before_each(function()
    package.loaded["java_scaffold.wizard"] = nil
    package.loaded["java_scaffold.picker"] = nil
    package.loaded["java_scaffold.config"] = nil
    package.loaded["java_scaffold.java"] = nil
    package.loaded["java_scaffold.maven"] = nil
    package.loaded["java_scaffold.log"] = nil
    package.loaded["java_scaffold.metadata"] = nil
    wizard = require("java_scaffold.wizard")
  end)

  describe("sequence", function()
    it("completes when all steps succeed", function()
      local received
      wizard.sequence({
        function(state, callback)
          state.a = 1
          callback(state)
        end,
        function(state, callback)
          state.b = 2
          callback(state)
        end,
      }, function(state)
        received = state
      end)

      assert.is_table(received)
      assert.equals(1, received.a)
      assert.equals(2, received.b)
    end)

    it("aborts when a step cancels with nil", function()
      local completed = false
      wizard.sequence({
        function(state, callback)
          state.a = 1
          callback(state)
        end,
        function(_, callback)
          callback(nil)
        end,
        function(state, callback)
          state.c = 3
          callback(state)
        end,
      }, function()
        completed = true
      end)

      assert.is_false(completed)
    end)

    it("aborts when first step cancels", function()
      local completed = false
      wizard.sequence({
        function(_, callback)
          callback(nil)
        end,
      }, function()
        completed = true
      end)

      assert.is_false(completed)
    end)

    it("catches step errors and aborts", function()
      local completed = false
      wizard.sequence({
        function()
          error("step exploded")
        end,
        function(state, callback)
          callback(state)
        end,
      }, function()
        completed = true
      end)

      assert.is_false(completed)
    end)
  end)

  describe("select_one step", function()
    it("stores selected item in state", function()
      package.loaded["java_scaffold.picker"] = {
        select_one = function(items, _opts, callback)
          callback(items[2]) -- pick second item
        end,
      }
      wizard = require("java_scaffold.wizard")

      local received
      wizard.sequence({
        wizard.select_one({ "a", "b", "c" }, { prompt = "Pick" }, "choice"),
      }, function(state)
        received = state
      end)

      assert.equals("b", received.choice)
    end)

    it("aborts when user cancels selection", function()
      package.loaded["java_scaffold.picker"] = {
        select_one = function(_, _, callback)
          callback(nil) -- user cancelled
        end,
      }
      wizard = require("java_scaffold.wizard")

      local completed = false
      wizard.sequence({
        wizard.select_one({ "a", "b" }, { prompt = "Pick" }, "choice"),
      }, function()
        completed = true
      end)

      assert.is_false(completed)
    end)
  end)

  describe("select_many step", function()
    it("stores selected items in state", function()
      package.loaded["java_scaffold.picker"] = {
        select_many = function(items, _opts, callback)
          callback({ items[1], items[3] })
        end,
      }
      wizard = require("java_scaffold.wizard")

      local received
      wizard.sequence({
        wizard.select_many({ "x", "y", "z" }, { prompt = "Pick" }, "choices"),
      }, function(state)
        received = state
      end)

      assert.same({ "x", "z" }, received.choices)
    end)

    it("aborts when user cancels multi-select", function()
      package.loaded["java_scaffold.picker"] = {
        select_many = function(_, _, callback)
          callback(nil)
        end,
      }
      wizard = require("java_scaffold.wizard")

      local completed = false
      wizard.sequence({
        wizard.select_many({ "x", "y" }, { prompt = "Pick" }, "choices"),
      }, function()
        completed = true
      end)

      assert.is_false(completed)
    end)
  end)

  describe("input step", function()
    it("stores trimmed value in state", function()
      package.loaded["java_scaffold.picker"] = {
        input = function(_prompt, _default, callback)
          callback("  hello  ")
        end,
      }
      wizard = require("java_scaffold.wizard")

      local received
      wizard.sequence({
        wizard.input("Name: ", "default", "name"),
      }, function(state)
        received = state
      end)

      assert.equals("hello", received.name)
    end)

    it("uses default when empty and allow_empty is false", function()
      package.loaded["java_scaffold.picker"] = {
        input = function(_prompt, _default, callback)
          callback("")
        end,
      }
      wizard = require("java_scaffold.wizard")

      local received
      wizard.sequence({
        wizard.input("Name: ", "fallback", "name"),
      }, function(state)
        received = state
      end)

      assert.equals("fallback", received.name)
    end)

    it("aborts when user cancels input", function()
      package.loaded["java_scaffold.picker"] = {
        input = function(_, _, callback)
          callback(nil)
        end,
      }
      wizard = require("java_scaffold.wizard")

      local completed = false
      wizard.sequence({
        wizard.input("Name: ", "default", "name"),
      }, function()
        completed = true
      end)

      assert.is_false(completed)
    end)
  end)

  describe("confirm step", function()
    it("continues when user confirms", function()
      package.loaded["java_scaffold.picker"] = {
        confirm = function(_)
          return true
        end,
      }
      wizard = require("java_scaffold.wizard")

      local received
      wizard.sequence({
        function(state, callback)
          state.java_version = "21"
          callback(state)
        end,
        wizard.confirm("Review", function(state)
          return { { "Java", state.java_version } }
        end),
      }, function(state)
        received = state
      end)

      assert.equals("21", received.java_version)
    end)

    it("aborts when user declines", function()
      package.loaded["java_scaffold.picker"] = {
        confirm = function(_)
          return false
        end,
      }
      wizard = require("java_scaffold.wizard")

      local completed = false
      wizard.sequence({
        wizard.confirm("Review", function()
          return {}
        end),
      }, function()
        completed = true
      end)

      assert.is_false(completed)
    end)
  end)
end)
