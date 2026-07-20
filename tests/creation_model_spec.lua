describe("creation model", function()
  local config
  local model

  before_each(function()
    package.loaded["duke.creation.model"] = nil
    config = require("duke.config").get()
    config.java_version = "17"
    model = require("duke.creation.model")
  end)

  it("starts with Maven defaults and derived values", function()
    local creation = model.new(config, { cwd = "/work" })
    local state = creation:snapshot()

    assert.equals("maven", state.kind)
    assert.equals("/work", state.values.destination)
    assert.equals(config.group_id, state.values.group_id)
    assert.equals(config.artifact_id, state.values.artifact_id)
    assert.equals("com.example.demo", state.values.package_name)
    assert.equals("17", state.values.java_version)
    assert.equals("/work/demo", state.derived.project_dir)
    assert.is_false(state.dirty)
  end)

  it("updates derived package until package is explicitly edited", function()
    local creation = model.new(config, { cwd = "/work" })

    assert.is_true(creation:set("artifact_id", "order-service"))
    assert.equals("com.example.orderservice", creation:snapshot().values.package_name)
    assert.is_true(creation:set("package_name", "dev.duu.orders"))
    assert.is_true(creation:set("artifact_id", "billing"))
    assert.equals("dev.duu.orders", creation:snapshot().values.package_name)
  end)

  it("restores the derived package when package input is blank", function()
    local creation = model.new(config, { cwd = "/work" })
    creation:set("package_name", "dev.duu.custom")

    creation:set("package_name", "  ")
    creation:set("artifact_id", "orders")

    assert.equals("com.example.orders", creation:snapshot().values.package_name)
  end)

  it("normalizes an existing destination", function()
    local destination = vim.fn.tempname()
    vim.fn.mkdir(destination, "p")
    local creation = model.new(config, { cwd = "/work" })

    creation:set("destination", destination .. "/../" .. vim.fs.basename(destination))
    assert.equals(vim.fs.normalize(destination), creation:snapshot().values.destination)
    vim.fn.delete(destination, "d")
  end)

  it("updates Spring name until name is explicitly edited", function()
    local creation = model.new(config, { kind = "spring", cwd = "/work" })

    creation:set("artifact_id", "orders")
    assert.equals("orders", creation:snapshot().values.name)
    creation:set("name", "Order API")
    creation:set("artifact_id", "billing")
    assert.equals("Order API", creation:snapshot().values.name)
  end)

  it("derives Spring name from a shared artifact after kind switch", function()
    local creation = model.new(config, { kind = "maven", cwd = "/work" })
    creation:set("artifact_id", "orders")

    creation:switch("spring")

    assert.equals("orders", creation:snapshot().values.name)
  end)

  it("preserves shared values and resets kind-specific values", function()
    local creation = model.new(config, { kind = "maven", cwd = "/work" })
    creation:set("artifact_id", "service")
    creation:set("archetype", config.maven.archetypes[2])

    assert.is_true(creation:switch("gradle"))
    local state = creation:snapshot()

    assert.equals("gradle", state.kind)
    assert.equals("service", state.values.artifact_id)
    assert.equals("com.example.service", state.values.package_name)
    assert.is_nil(state.values.archetype)
    assert.equals(config.gradle.default_project_type, state.values.gradle_project_type_id)
    assert.equals(config.gradle.dsl, state.values.dsl)
  end)

  it("rejects unknown kinds and fields", function()
    local creation = model.new(config, { cwd = "/work" })

    local changed, change_error = creation:set("unknown", "value")
    local switched, switch_error = creation:switch("unknown")

    assert.is_nil(changed)
    assert.equals("unknown creation field: unknown", change_error)
    assert.is_nil(switched)
    assert.equals("unknown project generator: unknown", switch_error)
  end)

  it("rejects stale async callbacks", function()
    local creation = model.new(config, { cwd = "/work" })
    local first = creation:begin_async("runtimes")
    local second = creation:begin_async("runtimes")

    assert.is_false(creation:resolve_async(first, { runner_version = "17" }))
    assert.is_true(creation:resolve_async(second, { runner_version = "23" }))
    assert.equals("23", creation:snapshot().derived.runner_version)

    local third = creation:begin_async("metadata")
    creation:switch("spring")
    assert.is_false(creation:reject_async(third, "late failure"))

    local fourth = creation:begin_async("metadata")
    creation:close()
    assert.is_false(creation:resolve_async(fourth, { spring_client = {} }))
  end)

  it("applies structured async value and derived patches", function()
    local creation = model.new(config, { kind = "spring", cwd = "/work" })
    local token = creation:begin_async("metadata")

    assert.is_true(creation:resolve_async(token, {
      values = {
        java_version = "21",
        boot_version = "4.0.0",
        spring_project_type = { id = "maven-project", build = "maven" },
      },
      derived = {
        java_versions = { "17", "21" },
        boot_version_choices = { "4.0.0" },
      },
    }))

    local state = creation:snapshot()
    assert.equals("21", state.values.java_version)
    assert.equals("4.0.0", state.values.boot_version)
    assert.same({ "17", "21" }, state.derived.java_versions)
    assert.is_nil(state.errors.boot_version)
    assert.is_nil(state.errors.spring_project_type)
  end)

  it("returns detached snapshots and requests", function()
    local creation = model.new(config, { cwd = "/work" })
    creation:resolve_async(creation:begin_async("runtimes"), {
      maven_runner_env = { JAVA_HOME = "/jdk/23" },
      maven_runner_version = "23",
    })
    local snapshot = creation:snapshot()
    snapshot.values.artifact_id = "mutated"

    local request = assert(creation:request())
    request.env.JAVA_HOME = "/bad"

    local second = assert(creation:request())
    assert.equals("demo", creation:snapshot().values.artifact_id)
    assert.equals("/jdk/23", second.env.JAVA_HOME)
  end)

  it("blocks edits and requests while busy or closed", function()
    local creation = model.new(config, { cwd = "/work" })
    creation:set_busy(true)

    assert.is_nil(creation:set("artifact_id", "blocked"))
    assert.is_nil(creation:request())

    creation:set_busy(false)
    creation:close()
    assert.is_nil(creation:set("artifact_id", "closed"))
    assert.is_nil(creation:request())
  end)

  it("blocks requests while discovery is loading", function()
    local creation = model.new(config, { cwd = "/work" })
    local token = creation:begin_async("runtimes")

    local request, errors = creation:request()
    assert.is_nil(request)
    assert.equals("discovery is still running", errors.async)

    creation:resolve_async(token, {
      maven_runner_env = { JAVA_HOME = "/jdk/23" },
    })
    assert.is_table(creation:request())
  end)
end)
