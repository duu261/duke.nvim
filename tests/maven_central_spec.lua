describe("Maven Central search", function()
  local search

  before_each(function()
    package.loaded["duke.maven_central"] = nil
    package.loaded["duke.config"] = {
      get = function()
        return {
          maven = {
            central_search_url = "https://search.maven.org/solrsearch/select",
            central_search_rows = 20,
            central_search_timeout = 15000,
          },
        }
      end,
    }
    search = require("duke.maven_central")
  end)

  after_each(function()
    package.loaded["duke.config"] = nil
    package.loaded["duke.maven_central"] = nil
  end)

  it("builds encoded HTTPS curl search args", function()
    assert.same({
      "--fail-with-body",
      "--location",
      "--proto",
      "=https",
      "--silent",
      "--show-error",
      "--get",
      "--data-urlencode",
      "q=guava core",
      "--data-urlencode",
      "rows=20",
      "--data-urlencode",
      "wt=json",
      "--user-agent",
      "duke.nvim",
      "https://search.maven.org/solrsearch/select",
    }, search.build_search_args("https://search.maven.org/solrsearch/select", "guava core", 20))
  end)

  it("validates Maven Central response schemas", function()
    assert.is_true(search.is_search_result({
      response = {
        docs = { { g = "com.google.guava", a = "guava", latestVersion = "33.4.8-jre" } },
      },
    }))
    assert.is_true(search.is_search_result({ response = { docs = {} } }))
    assert.is_true(search.is_search_result({ response = { docs = { { g = "g", a = "a" } } } }))
    assert.is_false(search.is_search_result({ response = "broken" }))
    assert.is_false(search.is_search_result({ response = { docs = "broken" } }))
  end)

  it("maps search results and filters pom packaging", function()
    local received
    local runner = function(command, args, opts, callback)
      assert.equals("curl", command)
      assert.equals(15000, opts.timeout)
      assert.equals("q=guava", args[9])
      callback({
        code = 0,
        stdout = vim.json.encode({
          response = {
            numFound = 2,
            docs = {
              {
                g = "com.google.guava",
                a = "guava",
                latestVersion = "33.4.8-jre",
                p = "jar",
              },
              { g = "example", a = "bom", latestVersion = "1.0.0", p = "pom" },
            },
          },
        }),
        stderr = "",
      })
    end

    search.search("guava", function(err, results)
      assert.is_nil(err)
      received = results
    end, runner)

    assert.same({
      {
        group_id = "com.google.guava",
        artifact_id = "guava",
        version = "33.4.8-jre",
        packaging = "jar",
      },
    }, received)
  end)

  it("keeps valid docs when neighboring docs are malformed", function()
    local received
    search.search("guava", function(err, results)
      assert.is_nil(err)
      received = results
    end, function(_, _, _, callback)
      callback({
        code = 0,
        stdout = vim.json.encode({
          response = {
            docs = {
              { g = "com.google.guava", a = "guava", latestVersion = "33.4.8-jre", p = "jar" },
              { g = "broken", a = "missing-version" },
            },
          },
        }),
        stderr = "",
      })
    end)

    assert.equals(1, #received)
    assert.equals("guava", received[1].artifact_id)
  end)

  it("returns an empty list when every result doc is malformed", function()
    local received
    search.search("broken", function(err, results)
      assert.is_nil(err)
      received = results
    end, function(_, _, _, callback)
      callback({
        code = 0,
        stdout = vim.json.encode({ response = { docs = { {}, { g = "g", a = "a", p = 42 } } } }),
        stderr = "",
      })
    end)

    assert.same({}, received)
  end)

  it("reports invalid envelopes", function()
    local received
    search.search("guava", function(err)
      received = err
    end, function(_, _, _, callback)
      callback({ code = 0, stdout = vim.json.encode({ response = "broken" }), stderr = "" })
    end)

    assert.matches("unexpected structure", received)
  end)

  it("reports actionable process errors", function()
    local function error_for(result)
      local received
      search.search("guava", function(err)
        received = err
      end, function(_, _, _, callback)
        callback(result)
      end)
      return received
    end

    assert.matches("timed out", error_for({ code = 28, stdout = "", stderr = "timeout" }))
    local limited = error_for({ code = 22, stdout = "", stderr = "curl: HTTP 429" })
    assert.matches("rate%-limited", limited)
    assert.matches("429", limited)
    assert.equals(
      "Maven Central search failed: connection refused",
      error_for({ code = 7, stdout = "fallback", stderr = "connection refused" })
    )
  end)

  it("builds a gav query and returns versions newest first", function()
    local received
    search.versions("com.google.guava", "guava", function(err, versions)
      assert.is_nil(err)
      received = versions
    end, function(command, args, opts, callback)
      assert.equals("curl", command)
      assert.equals(15000, opts.timeout)
      assert.equals('q=g:"com.google.guava" AND a:"guava"', args[9])
      assert.equals("core=gav", args[11])
      assert.equals("sort=timestamp desc", args[15])
      callback({
        code = 0,
        stdout = vim.json.encode({
          response = {
            docs = {
              { v = "33.4.8-jre", timestamp = 2 },
              { v = "33.4.7-jre", timestamp = 1 },
            },
          },
        }),
        stderr = "",
      })
    end)

    assert.same({ "33.4.8-jre", "33.4.7-jre" }, received)
  end)
end)
