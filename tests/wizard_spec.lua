describe("Wizard engine", function()
  local wizard

  before_each(function()
    package.loaded["duke.wizard"] = nil
    package.loaded["duke.picker"] = nil
    package.loaded["duke.config"] = nil
    package.loaded["duke"] = nil
    package.loaded["duke.gradle"] = nil
    package.loaded["duke.java"] = nil
    package.loaded["duke.maven"] = nil
    package.loaded["duke.log"] = nil
    package.loaded["duke.metadata"] = nil
    wizard = require("duke.wizard")
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

  describe("domain steps", function()
    it("rejects a missing destination before later prompts", function()
      local prompts = {}
      local missing = vim.fn.tempname()
      package.loaded["duke.picker"] = {
        input = function(prompt, _, callback)
          prompts[#prompts + 1] = prompt
          callback(missing)
        end,
      }
      wizard = require("duke.wizard")

      local completed = false
      wizard.sequence({ wizard.project_dir({}) }, function()
        completed = true
      end)

      assert.is_false(completed)
      assert.same({ "Destination directory: " }, prompts)
    end)

    it("keeps Gradle project validation before the DSL prompt", function()
      local events = {}
      package.loaded["duke"] = {
        java_runtimes = function()
          return { active = "23", homes = { ["23"] = "/jdk/23" } }
        end,
      }
      package.loaded["duke.gradle"] = {
        project_type = function()
          events[#events + 1] = "validate project type"
          return nil
        end,
      }
      package.loaded["duke.java"] = {
        installed = function()
          return { "23" }
        end,
        default = function()
          return "23"
        end,
        runner_env = function()
          return nil
        end,
        gradle_runtime_async = function(_, callback)
          callback("23")
        end,
      }
      package.loaded["duke.maven"] = {
        validate = function()
          return nil
        end,
        package_name = function()
          return "com.example.demo"
        end,
        validate_package = function()
          return nil
        end,
      }
      package.loaded["duke.picker"] = {
        input = function(prompt, default, callback)
          events[#events + 1] = prompt
          callback(prompt == "Destination directory: " and "/tmp" or default)
        end,
        select_one = function(items, opts, callback)
          events[#events + 1] = opts.prompt
          callback(items[1])
        end,
        confirm = function()
          return true
        end,
      }
      wizard = require("duke.wizard")
      local config = {
        group_id = "com.example",
        artifact_id = "demo",
        java_version = "23",
        java_versions = {},
        java_homes = {},
        gradle = {
          project_types = { { id = "unsupported", name = "Unsupported" } },
          default_project_type = "unsupported",
          languages = { "java" },
          dsls = { "kotlin" },
          dsl = "kotlin",
          runner_java_version = "auto",
          command = "gradle",
          timeout = 1000,
        },
      }

      local completed = false
      wizard.sequence(wizard.gradle_steps(config), function()
        completed = true
      end)

      assert.is_false(completed)
      assert.same({
        "Destination directory: ",
        "Group ID: ",
        "Artifact ID: ",
        "Package name: ",
        "Gradle project type",
        "Gradle source language",
        "validate project type",
      }, events)
    end)

    it("keeps Maven active runtime fallback warning", function()
      package.loaded["duke.java"] = {
        default = function()
          return "23"
        end,
        runner_env = function()
          return nil
        end,
        maven_runtime_async = function(_, callback)
          callback(nil)
        end,
      }
      wizard = require("duke.wizard")
      local config = {
        java_homes = {},
        maven = {
          command = "mvn",
          runner_java_version = "auto",
          timeout = 1000,
        },
      }
      local notifications = {}
      local saved_notify = vim.notify
      vim.notify = function(message)
        notifications[#notifications + 1] = message
      end

      local completed = false
      local ok, err = pcall(function()
        wizard.sequence({
          function(state, callback)
            state.java_version = "23"
            state._versions = { "23" }
            state._runtimes = { active = "17", homes = {} }
            callback(state)
          end,
          wizard.runner_check(config, "maven"),
        }, function()
          completed = true
        end)
      end)
      vim.notify = saved_notify

      assert.is_true(ok, err)
      assert.is_true(completed)
      assert.is_true(vim.tbl_contains(
        notifications,
        table.concat({
          "duke.nvim: Java 23 exceeds Maven runner Java 17;",
          "configure Maven runner JDK or toolchain",
        }, " ")
      ))
    end)
  end)

  describe("select_one step", function()
    it("stores selected item in state", function()
      package.loaded["duke.picker"] = {
        select_one = function(items, _opts, callback)
          callback(items[2]) -- pick second item
        end,
      }
      wizard = require("duke.wizard")

      local received
      wizard.sequence({
        wizard.select_one({ "a", "b", "c" }, { prompt = "Pick" }, "choice"),
      }, function(state)
        received = state
      end)

      assert.equals("b", received.choice)
    end)

    it("aborts when user cancels selection", function()
      package.loaded["duke.picker"] = {
        select_one = function(_, _, callback)
          callback(nil) -- user cancelled
        end,
      }
      wizard = require("duke.wizard")

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
      package.loaded["duke.picker"] = {
        select_many = function(items, _opts, callback)
          callback({ items[1], items[3] })
        end,
      }
      wizard = require("duke.wizard")

      local received
      wizard.sequence({
        wizard.select_many({ "x", "y", "z" }, { prompt = "Pick" }, "choices"),
      }, function(state)
        received = state
      end)

      assert.same({ "x", "z" }, received.choices)
    end)

    it("aborts when user cancels multi-select", function()
      package.loaded["duke.picker"] = {
        select_many = function(_, _, callback)
          callback(nil)
        end,
      }
      wizard = require("duke.wizard")

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
      package.loaded["duke.picker"] = {
        input = function(_prompt, _default, callback)
          callback("  hello  ")
        end,
      }
      wizard = require("duke.wizard")

      local received
      wizard.sequence({
        wizard.input("Name: ", "default", "name"),
      }, function(state)
        received = state
      end)

      assert.equals("hello", received.name)
    end)

    it("uses default when empty and allow_empty is false", function()
      package.loaded["duke.picker"] = {
        input = function(_prompt, _default, callback)
          callback("")
        end,
      }
      wizard = require("duke.wizard")

      local received
      wizard.sequence({
        wizard.input("Name: ", "fallback", "name"),
      }, function(state)
        received = state
      end)

      assert.equals("fallback", received.name)
    end)

    it("aborts when user cancels input", function()
      package.loaded["duke.picker"] = {
        input = function(_, _, callback)
          callback(nil)
        end,
      }
      wizard = require("duke.wizard")

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
      package.loaded["duke.picker"] = {
        confirm = function(_)
          return true
        end,
      }
      wizard = require("duke.wizard")

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
      package.loaded["duke.picker"] = {
        confirm = function(_)
          return false
        end,
      }
      wizard = require("duke.wizard")

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
