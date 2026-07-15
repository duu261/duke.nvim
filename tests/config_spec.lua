describe("config", function()
  local config

  before_each(function()
    vim.notify = function() end
    package.loaded["java_scaffold.config"] = nil
    config = require("java_scaffold.config")
  end)

  it("uses workflow defaults without setup", function()
    local opts = config.get()

    assert.equals("com.example", opts.group_id)
    assert.equals("auto", opts.java_version)
    assert.same({}, opts.java_homes)
    assert.equals("mvn", opts.maven.command)
    assert.equals("auto", opts.maven.runner_java_version)
    assert.is_false(opts.maven.wrapper)
    assert.equals("auto", opts.gradle.runner_java_version)
    assert.equals("java-application", opts.gradle.default_project_type)
    assert.equals("maven-archetype-quickstart", opts.maven.archetype.artifact_id)
    assert.is_false(opts.handoff.enabled)
  end)

  it("deep-merges user options", function()
    config.setup({ java_version = "17", maven = { command = "./mvnw", wrapper = true } })
    local opts = config.get()

    assert.equals("17", opts.java_version)
    assert.equals("./mvnw", opts.maven.command)
    assert.is_true(opts.maven.wrapper)
    assert.equals("maven-archetype-quickstart", opts.maven.archetype.artifact_id)
  end)

  it("rejects invalid scalar options and keeps defaults", function()
    config.setup({
      group_id = "",
      java_version = 21,
      maven = { wrapper = "yes" },
      handoff = { enabled = "yes" },
    })
    local opts = config.get()

    assert.equals("com.example", opts.group_id)
    assert.equals("auto", opts.java_version)
    assert.is_false(opts.maven.wrapper)
    assert.is_false(opts.handoff.enabled)
  end)

  it("recovers from malformed nested options", function()
    assert.has_no.errors(function()
      config.setup({
        maven = "broken",
        gradle = { project_types = "broken" },
        spring = false,
        handoff = { command = { "tmux", 42 } },
      })
    end)

    local opts = config.get()
    assert.equals("mvn", opts.maven.command)
    assert.equals("java-application", opts.gradle.project_types[1].id)
    assert.equals("https://start.spring.io", opts.spring.metadata_url)
    assert.is_nil(opts.handoff.command)
  end)

  it("normalizes numeric Java home keys", function()
    config.setup({ java_homes = { [21] = "/jdk/21" } })

    assert.equals("/jdk/21", config.get().java_homes["21"])
  end)
end)
