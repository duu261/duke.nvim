describe("Creation Center renderer", function()
  local render

  before_each(function()
    package.loaded["duke.creation.render"] = nil
    render = require("duke.creation.render")
  end)

  local function snapshot(overrides)
    return vim.tbl_deep_extend("force", {
      kind = "maven",
      values = {
        destination = "/tmp",
        group_id = "com.example",
        artifact_id = "demo",
        package_name = "com.example.demo",
        archetype = { name = "Maven quickstart" },
        java_version = "17",
      },
      derived = { project_dir = "/tmp/demo", maven_runner_version = "23" },
      fields = {
        { id = "destination", label = "Destination" },
        { id = "group_id", label = "Group ID" },
        { id = "artifact_id", label = "Artifact ID" },
        { id = "package_name", label = "Package" },
        { id = "archetype", label = "Archetype" },
        { id = "java_version", label = "Java target" },
      },
      errors = {},
      async = { runtimes = { state = "ready" } },
      dirty = false,
      busy = false,
      help = false,
    }, overrides or {})
  end

  local function joined(view)
    return table.concat(view.lines, "\n")
  end

  it("renders wide generator and field actions", function()
    local view = render.settings(snapshot(), { layout = "wide", width = 120, height = 40 })

    assert.is_truthy(joined(view):find("Duke Creation Center", 1, true))
    assert.is_truthy(joined(view):find("Maven", 1, true))
    assert.is_truthy(joined(view):find("/tmp/demo", 1, true))
    assert.is_truthy(joined(view):find("Runner JVM", 1, true))
    assert.is_truthy(vim.iter(view.lines):any(function(line)
      return line:find("Generator", 1, true) and line:find("Project settings", 1, true)
    end))
    assert.equals("generator:maven", view.actions[1].id)
    assert.equals("generators", view.actions[1].pane)
    assert.is_truthy(vim.iter(view.actions):any(function(action)
      return action.id == "field:artifact_id" and action.pane == "fields"
    end))
    assert.is_truthy(vim.iter(view.actions):any(function(action)
      return action.id == "create" and action.enabled
    end))
  end)

  it("renders validation and disables Create", function()
    local view = render.settings(
      snapshot({
        errors = { artifact_id = "artifact ID contains invalid characters" },
        banner = "Fix 1 field",
      }),
      { layout = "wide", width = 120, height = 40 }
    )

    assert.is_truthy(joined(view):find("artifact ID contains invalid characters", 1, true))
    assert.is_truthy(joined(view):find("Fix 1 field", 1, true))
    assert.is_truthy(vim.iter(view.actions):any(function(action)
      return action.id == "create" and not action.enabled
    end))
  end)

  it("renders narrow layout in one ordered column", function()
    local view = render.settings(snapshot(), { layout = "narrow", width = 80, height = 24 })
    local text = joined(view)

    assert.equals("narrow", view.layout)
    assert.is_true(text:find("Generator", 1, true) < text:find("Project settings", 1, true))
    assert.is_true(text:find("Project settings", 1, true) < text:find("Create", 1, true))
    for _, action in ipairs(view.actions) do
      assert.equals("main", action.pane)
    end
  end)

  it("renders loading, busy, and help state", function()
    local view = render.settings(
      snapshot({
        busy = true,
        help = true,
        async = { runtimes = { state = "loading" } },
      }),
      { layout = "wide", width = 120, height = 40 }
    )
    local text = joined(view)

    assert.is_truthy(text:find("Discovering Java runtimes", 1, true))
    assert.is_truthy(text:find("Creating project", 1, true))
    assert.is_truthy(text:find("Enter edit", 1, true))
    assert.is_truthy(vim.iter(view.actions):any(function(action)
      return action.id == "create" and not action.enabled
    end))
  end)

  it("disables Create while discovery is loading", function()
    local view = render.settings(
      snapshot({
        async = { runtimes = { state = "loading" } },
      }),
      { layout = "wide", width = 120, height = 40 }
    )

    assert.is_truthy(vim.iter(view.actions):any(function(action)
      return action.id == "create" and not action.enabled
    end))
  end)

  it("renders Spring dependency panes and actions", function()
    local view = render.dependencies(snapshot({ kind = "spring" }), {
      categories = { "Web", "SQL" },
      active_category = "Web",
      category_index = 1,
      results = {
        { id = "web", name = "Spring Web", description = "Web applications" },
      },
      result_index = 1,
      selected_ids = { "web" },
      selected_count = 1,
      pane = "results",
      query = "",
    }, { layout = "wide", width = 120, height = 40 })
    local text = joined(view)

    assert.is_truthy(text:find("Categories", 1, true))
    assert.is_truthy(text:find("Spring Web", 1, true))
    assert.is_truthy(text:find("Selected (1)", 1, true))
    assert.is_truthy(vim.iter(view.actions):any(function(action)
      return action.id == "dependency:item:web"
    end))
  end)
end)
