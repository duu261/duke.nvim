describe("Initializr metadata", function()
  local metadata

  before_each(function()
    package.loaded["duke.metadata"] = nil
    metadata = require("duke.metadata")
  end)

  it("flattens grouped dependencies", function()
    local entries = metadata.flatten_dependencies({
      dependencies = {
        values = {
          {
            name = "Web",
            values = {
              { id = "web", name = "Spring Web", description = "Build web applications" },
            },
          },
          {
            name = "SQL",
            values = {
              { id = "data-jpa", name = "Spring Data JPA" },
            },
          },
        },
      },
    })

    assert.same({
      { id = "web", name = "Spring Web", description = "Build web applications", group = "Web" },
      { id = "data-jpa", name = "Spring Data JPA", description = "", group = "SQL" },
    }, entries)
  end)

  it("returns only full Spring project types", function()
    assert.same(
      {
        { id = "maven-project", name = "Maven - Groovy", build = "maven" },
        { id = "gradle-project-kotlin", name = "Gradle - Kotlin", build = "gradle" },
      },
      metadata.project_types({
        type = {
          values = {
            {
              id = "maven-project",
              name = "Maven - Groovy",
              tags = { build = "maven", format = "project" },
            },
            {
              id = "maven-build",
              name = "Maven POM",
              tags = { build = "maven", format = "build" },
            },
            {
              id = "gradle-project-kotlin",
              name = "Gradle - Kotlin",
              tags = { build = "gradle", format = "project" },
            },
            { id = "broken", name = "Broken", tags = { format = "project" } },
            "malformed",
          },
        },
      })
    )
    assert.same({}, metadata.project_types({}))
  end)

  it("uses remote JSON and refreshes cache", function()
    local cache = vim.fn.tempname()
    local result

    metadata.fetch_cached("https://example.test/metadata", cache, function(_, callback)
      callback(nil, '{"source":"remote"}')
    end, function(err, value, source)
      assert.is_nil(err)
      result = { value = value, source = source }
    end)

    assert(vim.wait(1000, function()
      return result ~= nil
    end))
    assert.equals("remote", result.value.source)
    assert.equals("remote", result.source)
    assert.equals('{"source":"remote"}', table.concat(vim.fn.readfile(cache), "\n"))
    vim.fn.delete(cache)
  end)

  it("falls back to cached JSON after fetch failure", function()
    local cache = vim.fn.tempname()
    vim.fn.writefile({ '{"source":"cache"}' }, cache)
    local result

    metadata.fetch_cached("https://example.test/metadata", cache, function(_, callback)
      callback("offline")
    end, function(err, value, source)
      assert.is_nil(err)
      result = { value = value, source = source }
    end)

    assert(vim.wait(1000, function()
      return result ~= nil
    end))
    assert.equals("cache", result.value.source)
    assert.equals("cache", result.source)
    vim.fn.delete(cache)
  end)

  it("reports Initializr JSON error messages", function()
    local saved_process = package.loaded["duke.process"]
    local received_error
    local expected_error = "Invalid Spring Boot version '3.3.4', "
      .. "Spring Boot compatibility range is >=4.0.0"
    package.loaded["duke.process"] = {
      run = function(_, _, _, callback)
        callback({
          code = 22,
          stderr = "curl: (22) The requested URL returned error: 400",
          stdout = vim.json.encode({
            status = 400,
            error = "Bad Request",
            message = expected_error,
          }),
        })
      end,
    }

    metadata.http_get("https://start.spring.io/dependencies?bootVersion=3.3.4", function(err)
      received_error = err
    end)
    package.loaded["duke.process"] = saved_process

    assert.equals(expected_error, received_error)
  end)

  it("pins Initializr requests to HTTPS", function()
    local saved_process = package.loaded["duke.process"]
    local received_args
    package.loaded["duke.process"] = {
      run = function(command, args, _, callback)
        assert.equals("curl", command)
        received_args = args
        callback({ code = 0, stdout = "{}", stderr = "" })
      end,
    }

    metadata.http_get("https://start.spring.io/metadata/client", function() end)
    package.loaded["duke.process"] = saved_process

    assert.equals("--proto", received_args[3])
    assert.equals("=https", received_args[4])
  end)

  it("reports fetch-failure reason and cache age when falling back after a fetch error", function()
    local cache = vim.fn.tempname()
    vim.fn.writefile({ '{"source":"cache"}' }, cache)
    vim.uv.fs_utime(cache, os.time() - 200, os.time() - 200)
    local result

    metadata.fetch_cached("https://example.test/metadata", cache, function(_, callback)
      callback("offline")
    end, function(err, value, source, fallback)
      assert.is_nil(err)
      result = { value = value, source = source, fallback = fallback }
    end)

    assert(vim.wait(1000, function()
      return result ~= nil
    end))
    assert.equals("cache", result.source)
    assert.equals("fetch", result.fallback.reason)
    assert.equals("offline", result.fallback.detail)
    assert.is_true(result.fallback.age_seconds >= 200)
    vim.fn.delete(cache)
  end)

  it("reports schema reason when falling back after validator rejection", function()
    local cache = vim.fn.tempname()
    vim.fn.writefile({ '{"source":"cache"}' }, cache)
    local result

    metadata.fetch_cached("https://example.test/metadata", cache, function(_, callback)
      callback(nil, "not json")
    end, function(err, value, source, fallback)
      assert.is_nil(err)
      result = { value = value, source = source, fallback = fallback }
    end, function()
      return true
    end)

    assert(vim.wait(1000, function()
      return result ~= nil
    end))
    assert.equals("cache", result.source)
    assert.equals("schema", result.fallback.reason)
    vim.fn.delete(cache)
  end)

  it("reports no fallback table when resolved from remote", function()
    local cache = vim.fn.tempname()
    local result

    metadata.fetch_cached("https://example.test/metadata", cache, function(_, callback)
      callback(nil, '{"source":"remote"}')
    end, function(err, _value, source, fallback)
      assert.is_nil(err)
      result = { source = source, fallback = fallback }
    end)

    assert(vim.wait(1000, function()
      return result ~= nil
    end))
    assert.equals("remote", result.source)
    assert.is_nil(result.fallback)
    vim.fn.delete(cache)
  end)

  it("still calls back with the fetch error when there is no cache", function()
    local cache = vim.fn.tempname()
    local received_error

    metadata.fetch_cached("https://example.test/metadata", cache, function(_, callback)
      callback("offline")
    end, function(err, value, source)
      received_error = err
      assert.is_nil(value)
      assert.is_nil(source)
    end)

    assert(vim.wait(1000, function()
      return received_error ~= nil
    end))
    assert.equals("offline", received_error)
  end)

  it("formats cache age boundaries", function()
    assert.equals("just now", metadata.format_age(0))
    assert.equals("just now", metadata.format_age(-5))
    assert.equals("just now", metadata.format_age(59))
    assert.equals("1 minute ago", metadata.format_age(60))
    assert.equals("2 minutes ago", metadata.format_age(120))
    assert.equals("1 hour ago", metadata.format_age(3600))
    assert.equals("2 hours ago", metadata.format_age(7200))
    assert.equals("1 day ago", metadata.format_age(86400))
    assert.equals("3 days ago", metadata.format_age(3 * 86400))
  end)

  it("rejects invalid remote structure without replacing valid cache", function()
    local cache = vim.fn.tempname()
    local cached_json = vim.json.encode({
      dependencies = {
        web = {
          groupId = "org.springframework.boot",
          artifactId = "spring-boot-starter-webmvc",
        },
      },
    })
    vim.fn.writefile({ cached_json }, cache)
    local result

    metadata.fetch_cached("https://example.test/dependencies", cache, function(_, callback)
      callback(nil, "{}")
    end, function(err, value, source)
      assert.is_nil(err)
      result = { value = value, source = source }
    end, metadata.is_catalog)

    assert(vim.wait(1000, function()
      return result ~= nil
    end))
    assert.equals("cache", result.source)
    assert.is_table(result.value.dependencies)
    assert.equals(cached_json, table.concat(vim.fn.readfile(cache), "\n"))
    vim.fn.delete(cache)
  end)

  it("rejects deeply malformed client metadata", function()
    local valid_client = {
      bootVersion = { default = "4.0.0", values = { { id = "4.0.0" } } },
      javaVersion = { default = "17", values = { { id = "17" } } },
      language = { default = "java", values = { { id = "java" } } },
      packaging = { default = "jar", values = { { id = "jar" }, { id = "war" } } },
      dependencies = {
        values = {
          {
            name = "Web",
            values = { { id = "web", name = "Spring Web", description = "Web applications" } },
          },
        },
      },
    }
    assert.is_true(metadata.is_client(valid_client))

    local malformed_group = vim.deepcopy(valid_client)
    malformed_group.dependencies.values[1] = "Web"
    assert.is_false(metadata.is_client(malformed_group))

    local malformed_dependency = vim.deepcopy(valid_client)
    malformed_dependency.dependencies.values[1].values[1] = "web"
    assert.is_false(metadata.is_client(malformed_dependency))

    local malformed_version = vim.deepcopy(valid_client)
    malformed_version.bootVersion.values[1].id = 4
    assert.is_false(metadata.is_client(malformed_version))

    local malformed_language = vim.deepcopy(valid_client)
    malformed_language.language.values[1].id = 4
    assert.is_false(metadata.is_client(malformed_language))
  end)

  it("rejects deeply malformed dependency catalogs", function()
    assert.is_true(metadata.is_catalog({
      dependencies = {
        web = {
          groupId = "org.springframework.boot",
          artifactId = "spring-boot-starter-webmvc",
        },
      },
    }))
    assert.is_false(metadata.is_catalog({ dependencies = { web = "spring-boot-starter-webmvc" } }))
    assert.is_false(metadata.is_catalog({
      dependencies = {
        web = {
          groupId = "org.springframework.boot",
          artifactId = 42,
        },
      },
    }))
  end)

  it("namespaces cache paths by Initializr URL", function()
    local standard = metadata.cache_path("metadata", nil, "https://start.spring.io")
    local custom = metadata.cache_path("metadata", nil, "https://initializr.example.test")

    assert.not_equals(standard, custom)
    assert.is_truthy(standard:find(vim.fn.sha256("https://start.spring.io"), 1, true))
    assert.is_truthy(custom:find(vim.fn.sha256("https://initializr.example.test"), 1, true))
  end)

  it("clears the complete Initializr cache directory", function()
    local cache = vim.fn.tempname()
    local nested = vim.fs.joinpath(cache, "server")
    vim.fn.mkdir(nested, "p")
    vim.fn.writefile({ "cached" }, vim.fs.joinpath(nested, "metadata.json"))

    local ok, err = metadata.clear_cache(cache)

    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals(0, vim.fn.isdirectory(cache))
  end)

  it("resolves selected dependency IDs through the version catalog", function()
    local dependencies, missing = metadata.resolve({
      dependencies = {
        web = {
          groupId = "org.springframework.boot",
          artifactId = "spring-boot-starter-webmvc",
          scope = "compile",
        },
        test = {
          groupId = "org.springframework.boot",
          artifactId = "spring-boot-starter-test",
          scope = "test",
        },
      },
    }, { "web", "missing", "test" })

    assert.same({
      {
        group_id = "org.springframework.boot",
        artifact_id = "spring-boot-starter-webmvc",
        scope = "compile",
      },
      {
        group_id = "org.springframework.boot",
        artifact_id = "spring-boot-starter-test",
        scope = "test",
      },
    }, dependencies)
    assert.same({ "missing" }, missing)
  end)

  it("accepts only dependencies representable by one Maven dependency block", function()
    assert.is_true(metadata.is_direct({ groupId = "g", artifactId = "a", scope = "runtime" }))
    assert.is_false(metadata.is_direct({ groupId = "g", artifactId = "a", bom = "cloud" }))
    assert.is_false(
      metadata.is_direct({ groupId = "g", artifactId = "a", repository = "milestones" })
    )
    assert.is_false(metadata.is_direct({
      groupId = "g",
      artifactId = "a",
      scope = "annotationProcessor",
    }))
  end)
end)
