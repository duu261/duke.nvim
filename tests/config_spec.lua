describe("config", function()
  local config

  before_each(function()
    vim.notify = function() end
    package.loaded["duke.config"] = nil
    config = require("duke.config")
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
    assert.equals("maven-archetype-quickstart", opts.maven.archetypes[1].artifact_id)
    assert.equals("maven-archetype-webapp", opts.maven.archetypes[2].artifact_id)
    assert.equals("https://search.maven.org/solrsearch/select", opts.maven.central_search_url)
    assert.equals(20, opts.maven.central_search_rows)
    assert.equals(15000, opts.maven.central_search_timeout)
    assert.is_false(opts.handoff.enabled)
  end)

  it("deep-merges user options", function()
    config.setup({ java_version = "17", maven = { command = "./mvnw", wrapper = true } })
    local opts = config.get()

    assert.equals("17", opts.java_version)
    assert.equals("./mvnw", opts.maven.command)
    assert.is_true(opts.maven.wrapper)
    assert.equals("maven-archetype-quickstart", opts.maven.archetypes[1].artifact_id)
  end)

  it("wraps a legacy Maven archetype override", function()
    local archetype = {
      name = "Legacy archetype",
      group_id = "com.example",
      artifact_id = "legacy-archetype",
      version = "1.0.0",
    }
    config.setup({ maven = { archetype = archetype } })

    local archetypes = config.get().maven.archetypes
    assert.equals(1, #archetypes)
    assert.same({ archetype }, archetypes)
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

  it("rejects invalid Maven Central search options", function()
    config.setup({
      maven = {
        central_search_url = "",
        central_search_rows = 0,
        central_search_timeout = "slow",
      },
    })

    local opts = config.get().maven
    assert.equals("https://search.maven.org/solrsearch/select", opts.central_search_url)
    assert.equals(20, opts.central_search_rows)
    assert.equals(15000, opts.central_search_timeout)
  end)

  it("rejects malformed Maven archetype lists and keeps defaults", function()
    config.setup({ maven = { archetypes = { { group_id = "broken" } } } })

    local archetypes = config.get().maven.archetypes
    assert.equals(2, #archetypes)
    assert.equals("maven-archetype-quickstart", archetypes[1].artifact_id)
    assert.equals("maven-archetype-webapp", archetypes[2].artifact_id)
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
