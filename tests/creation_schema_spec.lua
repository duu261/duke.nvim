describe("creation schema", function()
  local config
  local schema

  before_each(function()
    package.loaded["duke.creation.schema"] = nil
    config = require("duke.config").get()
    config.java_version = "17"
    schema = require("duke.creation.schema")
  end)

  local function base_values()
    return {
      destination = "/tmp",
      group_id = "com.acme",
      artifact_id = "service",
      package_name = "com.acme.service",
      java_version = "17",
    }
  end

  it("defines ordered Maven fields and exact request", function()
    local defaults = schema.defaults("maven", config, { cwd = "/work" })
    local fields = schema.fields("maven", config, { values = defaults, derived = {} })
    assert.same(
      {
        "destination",
        "group_id",
        "artifact_id",
        "package_name",
        "archetype",
        "java_version",
      },
      vim.tbl_map(function(field)
        return field.id
      end, fields)
    )

    local values = base_values()
    values.archetype = config.maven.archetypes[1]
    local request = assert(schema.request("maven", config, {
      values = values,
      derived = { maven_runner_env = { JAVA_HOME = "/jdk/23" } },
    }))

    assert.same({
      command = config.maven.command,
      cwd = "/tmp",
      group_id = "com.acme",
      artifact_id = "service",
      package_name = "com.acme.service",
      version = config.maven.project_version,
      wrapper = config.maven.wrapper,
      java_version = "17",
      archetype = config.maven.archetypes[1],
      timeout = config.maven.timeout,
      env = { JAVA_HOME = "/jdk/23" },
    }, request)
  end)

  it("projects Gradle language and project type", function()
    local values = base_values()
    values.gradle_project_type_id = "java-application"
    values.language = "kotlin"
    values.dsl = "groovy"

    local request = assert(schema.request("gradle", config, {
      values = values,
      derived = { gradle_runner_env = { JAVA_HOME = "/jdk/23" } },
    }))

    assert.equals("kotlin-application", request.project_type)
    assert.equals("groovy", request.dsl)
    assert.equals("auto", request.test_framework)
    assert.same({ JAVA_HOME = "/jdk/23" }, request.env)
  end)

  it("projects validated Spring selections", function()
    local values = base_values()
    values.name = "Service"
    values.description = "API"
    values.boot_version = "4.1.0"
    values.dependency_ids = { "web", "data-jpa" }
    values.spring_project_type = { id = "maven-project", build = "maven", name = "Maven" }
    values.spring_language = "java"
    values.spring_packaging = "jar"

    local request = assert(schema.request("spring", config, {
      values = values,
      derived = {
        spring_catalog = { dependencies = { web = {}, ["data-jpa"] = {} } },
      },
    }))

    assert.same({
      url = config.spring.starter_url,
      cwd = "/tmp",
      group_id = "com.acme",
      artifact_id = "service",
      name = "Service",
      description = "API",
      package_name = "com.acme.service",
      java_version = "17",
      boot_version = "4.1.0",
      dependencies = { "web", "data-jpa" },
      project_type = "maven-project",
      build = "maven",
      language = "java",
      packaging = "jar",
      timeout = config.spring.timeout,
    }, request)
  end)

  it("blocks Spring requests without a compatible catalog", function()
    local values = base_values()
    values.name = "Service"
    values.description = "API"
    values.boot_version = "4.1.0"
    values.dependency_ids = { "web", "missing" }
    values.spring_project_type = { id = "maven-project", build = "maven" }
    values.spring_language = "java"
    values.spring_packaging = "jar"

    local errors = schema.validate("spring", config, {
      values = values,
      derived = { spring_catalog = { dependencies = { web = {} } } },
    })
    assert.is_truthy(errors.dependency_ids:find("missing", 1, true))

    errors = schema.validate("spring", config, { values = values, derived = {} })
    assert.equals("Spring dependency catalog is not ready", errors.dependency_ids)
  end)

  it("keeps but rejects a Java target unsupported by Spring metadata", function()
    local values = base_values()
    values.java_version = "23"
    values.name = "Service"
    values.boot_version = "4.1.0"
    values.dependency_ids = {}
    values.spring_project_type = { id = "maven-project", build = "maven" }
    values.spring_language = "java"
    values.spring_packaging = "jar"

    local errors = schema.validate("spring", config, {
      values = values,
      derived = {
        java_versions = { "17", "21" },
        spring_catalog = { dependencies = {} },
      },
    })

    assert.equals(
      "Java target is unavailable for selected Spring Boot version",
      errors.java_version
    )
    assert.equals("23", values.java_version)
  end)

  it("reports field validation errors before request projection", function()
    local values = base_values()
    values.destination = ""
    values.group_id = ""
    values.package_name = "com.class.bad"
    values.archetype = config.maven.archetypes[1]

    local errors = schema.validate("maven", config, { values = values, derived = {} })
    local request, request_errors = schema.request("maven", config, {
      values = values,
      derived = {},
    })

    assert.is_truthy(errors.destination)
    assert.is_truthy(errors.group_id)
    assert.is_truthy(errors.package_name)
    assert.is_nil(request)
    assert.same(errors, request_errors)
  end)
end)
