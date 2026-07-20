describe("Creation Center", function()
  local center
  local config
  local model
  local sessions

  before_each(function()
    package.loaded["duke.creation.center"] = nil
    package.loaded["duke.picker"] = nil
    center = require("duke.creation.center")
    config = require("duke.config").get()
    config.java_version = "17"
    model = require("duke.creation.model")
    sessions = {}
    vim.cmd("enew!")
  end)

  after_each(function()
    for _, session in ipairs(sessions) do
      pcall(function()
        session:cancel(true)
      end)
    end
    package.loaded["duke.picker"] = nil
    vim.cmd("silent! only!")
    vim.cmd("enew!")
  end)

  local function open(opts)
    opts = opts or {}
    opts.model = opts.model or model.new(config, { cwd = "/tmp" })
    opts.config = config
    if opts.confirm == nil then
      opts.confirm = false
    end
    opts.submit = opts.submit or function() end
    opts.finish = opts.finish or function() end
    local session = center.open(opts)
    sessions[#sessions + 1] = session
    return session
  end

  it("chooses responsive layout from editor size", function()
    assert.equals("wide", center.choose_layout(120, 40))
    assert.equals("narrow", center.choose_layout(99, 40))
    assert.equals("narrow", center.choose_layout(120, 27))
    assert.equals("narrow", center.choose_layout(120, 40, "compact"))
    assert.equals("wide", center.choose_layout(99, 40, "wide"))
  end)

  it("opens a centered scratch float with local keymaps", function()
    local session = open({ layout = "wide" })
    local state = session:snapshot()
    local window = vim.api.nvim_win_get_config(state.win)

    assert.equals("wide", state.layout)
    assert.equals("editor", window.relative)
    assert.is_true(window.width >= math.floor(vim.o.columns * 0.8))
    assert.equals("nofile", vim.bo[state.buf].buftype)
    assert.equals(false, vim.bo[state.buf].modifiable)
    local maps = vim.api.nvim_buf_get_keymap(state.buf, "n")
    for _, lhs in ipairs({ "j", "k", "<CR>", "c", "q", "?" }) do
      assert.is_truthy(
        vim.iter(maps):any(function(map)
          return map.lhs == lhs
        end),
        lhs
      )
    end
  end)

  it("restores original narrow-window editor state on cancel", function()
    local origin_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(origin_buf, 0, -1, false, { "one", "two", "three" })
    vim.api.nvim_win_set_cursor(0, { 2, 1 })
    vim.bo[origin_buf].modified = true
    local origin_cwd = vim.fn.getcwd()
    local changed_cwd = "/tmp"

    local session = open({ layout = "narrow" })
    assert.not_equals(origin_buf, vim.api.nvim_get_current_buf())
    vim.cmd.cd(vim.fn.fnameescape(changed_cwd))
    assert.is_true(session:cancel(true))

    assert.equals(origin_buf, vim.api.nvim_get_current_buf())
    assert.same({ 2, 1 }, vim.api.nvim_win_get_cursor(0))
    assert.is_true(vim.bo[origin_buf].modified)
    assert.equals(origin_cwd, vim.fn.getcwd())
  end)

  it("never clears concurrent changes in the original buffer", function()
    local origin_buf = vim.api.nvim_get_current_buf()
    vim.bo[origin_buf].modified = false
    local session = open({ layout = "narrow" })

    vim.api.nvim_buf_set_lines(origin_buf, 0, -1, false, { "changed while open" })
    assert.is_true(vim.bo[origin_buf].modified)
    session:cancel(true)

    assert.is_true(vim.bo[origin_buf].modified)
  end)

  it("routes field edits through picker and switches generators", function()
    package.loaded["duke.picker"] = {
      input = function(_, _, callback)
        callback("orders")
      end,
      select_one = function(items, _, callback)
        callback(items[1])
      end,
      confirm = function()
        return true
      end,
    }
    local discoveries = {}
    local session = open({
      layout = "wide",
      discover = function(_, scope)
        discoveries[#discoveries + 1] = scope or "all"
      end,
    })

    assert.same({ "all" }, discoveries)
    assert.is_true(session:activate("field:artifact_id"))
    assert.equals("orders", session:snapshot().model.values.artifact_id)
    assert.is_true(session:activate("generator:gradle"))
    assert.equals("gradle", session:snapshot().model.kind)
    assert.same({ "all", "all" }, discoveries)
  end)

  it("keeps a missing destination out of the model", function()
    local missing = vim.fn.tempname()
    package.loaded["duke.picker"] = {
      input = function(_, _, callback)
        callback(missing)
      end,
    }
    local session = open({ layout = "wide" })
    local original = session:snapshot().model.values.destination

    assert.is_true(session:activate("field:destination"))

    assert.equals(original, session:snapshot().model.values.destination)
    assert.is_truthy(session:snapshot().model.banner:find("does not exist", 1, true))
  end)

  it("keeps state after failure and accepts only one success callback", function()
    local callbacks = {}
    local finished = {}
    local session = open({
      layout = "wide",
      submit = function(_, _, callback)
        callbacks[#callbacks + 1] = callback
      end,
      finish = function(project_dir)
        finished[#finished + 1] = project_dir
      end,
    })

    assert.is_true(session:submit())
    assert.is_true(session:snapshot().model.busy)
    callbacks[1]("generation failed")
    assert.is_true(session:is_open())
    assert.is_false(session:snapshot().model.busy)
    assert.equals("generation failed", session:snapshot().model.banner)

    assert.is_true(session:submit())
    callbacks[2](nil, "/tmp/demo")
    callbacks[2](nil, "/tmp/duplicate")
    callbacks[2]("late error")

    assert.same({ "/tmp/demo" }, finished)
    assert.is_false(session:is_open())
  end)

  it("shows an observable target collision before confirmation", function()
    local destination = vim.fn.tempname()
    local target = vim.fs.joinpath(destination, "demo")
    vim.fn.mkdir(target, "p")
    local submitted = false
    local session = open({
      layout = "wide",
      submit = function()
        submitted = true
      end,
    })
    session.model:set("destination", destination)

    assert.is_false(session:submit())
    assert.is_false(submitted)
    assert.is_truthy(session:snapshot().model.banner:find("target already exists", 1, true))
    vim.fn.delete(destination, "rf")
  end)

  it("edits Spring dependencies inside the same window", function()
    local creation = model.new(config, { kind = "spring", cwd = "/tmp" })
    creation:resolve_async(creation:begin_async("metadata"), {
      values = {
        java_version = "17",
        boot_version = "4.0.0",
        spring_project_type = { id = "maven-project", build = "maven" },
      },
      derived = {
        spring_dependency_items = {
          { id = "web", name = "Spring Web", description = "Web", group = "Web" },
          { id = "data-jpa", name = "Spring Data JPA", description = "SQL", group = "SQL" },
        },
      },
    })
    local session = open({ model = creation, layout = "wide" })

    assert.is_true(session:activate("field:dependency_ids"))
    assert.equals("dependencies", session:snapshot().view)
    assert.is_true(session:dependency_focus("results"))
    assert.is_true(session:dependency_toggle())
    assert.is_true(session:dependency_accept())
    assert.equals("settings", session:snapshot().view)
    assert.same({ "web" }, session:snapshot().model.values.dependency_ids)
  end)

  it("accepts dependency selections with Enter from the focused result", function()
    local creation = model.new(config, { kind = "spring", cwd = "/tmp" })
    creation:resolve_async(creation:begin_async("metadata"), {
      values = {
        java_version = "17",
        boot_version = "4.0.0",
        spring_project_type = { id = "maven-project", build = "maven" },
      },
      derived = {
        spring_dependency_items = {
          { id = "web", name = "Spring Web", group = "Web" },
        },
      },
    })
    local session = open({ model = creation, layout = "wide" })
    session:activate("field:dependency_ids")
    session:dependency_focus("results")
    session:dependency_toggle()

    assert.is_true(session:activate())
    assert.equals("settings", session:snapshot().view)
    assert.same({ "web" }, session:snapshot().model.values.dependency_ids)
  end)

  it("confirms before discarding dependency subview changes", function()
    local confirmations = 0
    package.loaded["duke.picker"] = {
      confirm = function()
        confirmations = confirmations + 1
        return false
      end,
    }
    local creation = model.new(config, { kind = "spring", cwd = "/tmp" })
    creation:resolve_async(creation:begin_async("metadata"), {
      values = {
        java_version = "17",
        boot_version = "4.0.0",
        spring_project_type = { id = "maven-project", build = "maven" },
      },
      derived = {
        spring_dependency_items = {
          { id = "web", name = "Spring Web", group = "Web" },
        },
      },
    })
    local session = open({ model = creation, layout = "wide" })
    session:activate("field:dependency_ids")
    session:dependency_focus("results")
    session:dependency_toggle()

    assert.is_false(session:cancel())
    assert.equals(1, confirmations)
    assert.is_true(session:is_open())
  end)

  it("treats external narrow-buffer closure as safe cancellation", function()
    local creation = model.new(config, { cwd = "/tmp" })
    local session = open({ model = creation, layout = "narrow" })
    local token = creation:begin_async("runtimes")

    local ok, err = pcall(vim.api.nvim_buf_delete, session:snapshot().buf, { force = true })

    assert.is_true(ok, err)
    assert.is_false(session:is_open())
    assert.is_false(creation:resolve_async(token, { runner_version = "late" }))
  end)

  it("closes an existing center before opening another", function()
    local first = open({ layout = "narrow" })
    local ok, second = pcall(function()
      return open({ layout = "narrow" })
    end)

    assert.is_true(ok, second)
    assert.is_false(first:is_open())
    assert.is_true(second:is_open())
  end)

  it("focuses an existing busy center instead of opening a second", function()
    local first = open({ layout = "wide" })
    first.model:set_busy(true)

    local second = open({ layout = "wide" })

    assert.equals(first, second)
    assert.is_true(first:is_open())
    first.model:set_busy(false)
  end)

  it("moves wide focus between panes with a visible cursor column", function()
    local session = open({ layout = "wide" })
    local initial_cursor = vim.api.nvim_win_get_cursor(session:snapshot().win)

    assert.is_true(session:cycle_pane(1))
    local field_cursor = vim.api.nvim_win_get_cursor(session:snapshot().win)

    assert.equals(0, initial_cursor[2])
    assert.is_true(field_cursor[2] > 0)
    assert.is_true(session:move(1))
    assert.is_true(vim.api.nvim_win_get_cursor(session:snapshot().win)[1] > field_cursor[1])
  end)

  it("restores narrow editor state after partial startup failure", function()
    local origin_buf = vim.api.nvim_get_current_buf()
    local saved_set = vim.keymap.set
    vim.keymap.set = function()
      error("keymap setup exploded")
    end

    local ok = pcall(open, { layout = "narrow" })
    vim.keymap.set = saved_set

    assert.is_false(ok)
    assert.equals(origin_buf, vim.api.nvim_get_current_buf())
  end)

  it("contains picker failures without closing the center", function()
    package.loaded["duke.picker"] = {
      input = function()
        error("picker exploded")
      end,
    }
    local session = open({ layout = "wide" })

    local ok, result = pcall(session.activate, session, "field:artifact_id")

    assert.is_true(ok)
    assert.is_false(result)
    assert.is_true(session:is_open())
    assert.is_truthy(session:snapshot().model.banner:find("picker exploded", 1, true))
  end)

  it("contains failures inside callback recovery", function()
    package.loaded["duke.picker"] = {
      input = function()
        error("picker exploded")
      end,
    }
    local session = open({ layout = "wide" })
    local original_set_banner = session.model.set_banner
    session.model.set_banner = function()
      error("recovery exploded")
    end

    local ok = pcall(session.activate, session, "field:artifact_id")
    session.model.set_banner = original_set_banner

    assert.is_true(ok)
    assert.is_true(session:is_open())
  end)

  it("stores Gradle project picker values as IDs", function()
    package.loaded["duke.picker"] = {
      select_one = function(items, _, callback)
        callback(items[2])
      end,
    }
    local creation = model.new(config, { kind = "gradle", cwd = "/tmp" })
    local session = open({ model = creation, layout = "wide" })

    assert.is_true(session:activate("field:gradle_project_type_id"))
    assert.equals(
      config.gradle.project_types[2].id,
      session:snapshot().model.values.gradle_project_type_id
    )
    assert.is_nil(session:snapshot().model.errors.gradle_project_type_id)
  end)

  it("keeps Java LTS labels in the focused picker", function()
    local picker_opts
    package.loaded["duke.picker"] = {
      select_one = function(_, opts, callback)
        picker_opts = opts
        callback(nil)
      end,
    }
    local creation = model.new(config, { kind = "maven", cwd = "/tmp" })
    creation:resolve_async(creation:begin_async("runtimes"), {
      java_versions = { "17", "23", "25" },
    })
    local session = open({ model = creation, layout = "wide" })

    session:activate("field:java_version")

    assert.equals("17  (LTS)", picker_opts.format_item("17"))
    assert.equals("23", picker_opts.format_item("23"))
    assert.equals("25  (LTS)", picker_opts.format_item("25"))
  end)
end)
