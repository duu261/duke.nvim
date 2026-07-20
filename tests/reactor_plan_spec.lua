describe("reactor repair plans", function()
  local directories = {}

  local function fixture()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    directories[#directories + 1] = root
    local pom_path = vim.fs.joinpath(root, "pom.xml")
    local lines = {
      "<project>",
      "  <modelVersion>4.0.0</modelVersion>",
      "  <groupId>com.acme</groupId>",
      "  <artifactId>app</artifactId>",
      "  <version>1.0.0</version>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.acme</groupId>",
      "      <artifactId>library</artifactId>",
      "      <version>1.0.0</version>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    vim.fn.writefile(lines, pom_path)
    local model = assert(require("duke.pom").model(lines))
    local finding = {
      id = "version_drift:com.acme:library",
      kind = "version_drift",
      severity = "warning",
      coordinate = "com.acme:library",
      module_id = "com.acme:app",
      requested_versions = { "1.0.0", "2.0.0" },
      selected_version = "2.0.0",
      repairable = true,
      consumers = { "com.acme:library" },
      ownership = {
        kind = "dependency",
        coordinate = "com.acme:library",
        owner_coordinate = "com.acme:library",
        requested_version = "1.0.0",
        pom_path = pom_path,
        line = 10,
        writable = true,
      },
    }
    return root,
      pom_path,
      lines,
      {
        root = root,
        kind = "maven",
        state = "resolved",
        modules = {
          {
            id = "com.acme:app",
            root = root,
            build_file = pom_path,
            model = model,
          },
        },
        analysis = {
          doctor = { warnings = {}, deep = false },
          findings = { finding },
        },
      }
  end

  local function wait_call(invoke)
    local calls = {}
    invoke(function(err, result)
      calls[#calls + 1] = { err = err, result = result }
    end)
    assert.is_true(vim.wait(500, function()
      return #calls > 0
    end))
    assert.equals(1, #calls)
    return calls[1].err, calls[1].result
  end

  local function contains_private_path(value, path)
    if type(value) == "string" then
      return value:find(path, 1, true) ~= nil
    end
    if type(value) ~= "table" then
      return false
    end
    for key, child in pairs(value) do
      if contains_private_path(key, path) or contains_private_path(child, path) then
        return true
      end
    end
    return false
  end

  before_each(function()
    for _, name in ipairs({
      "duke.reactor_plan",
      "duke.events",
      "duke.pom_file",
      "duke.pom_repair",
      "duke.pom_transaction",
    }) do
      package.loaded[name] = nil
    end
  end)

  after_each(function()
    for _, root in ipairs(directories) do
      vim.fn.delete(root, "rf")
    end
    directories = {}
  end)

  it("publishes redacted diagnosis and sorted plan previews", function()
    local root, pom_path, _, snapshot = fixture()
    local plans = require("duke.reactor_plan")
    local diagnosis = assert(plans.capture(snapshot))

    assert.is_string(diagnosis.id)
    assert.equals("pom.xml", diagnosis.findings[1].ownership.pom_label)
    assert.is_false(contains_private_path(diagnosis, root))

    local err, descriptor = wait_call(function(callback)
      plans.build({
        diagnosis_id = diagnosis.id,
        repairs = {
          { finding_id = diagnosis.findings[1].id, new_version = "2.0.0" },
        },
      }, callback)
    end)
    assert.is_nil(err)
    assert.is_string(descriptor.id)
    assert.equals("pom.xml", descriptor.preview.files[1].pom_label)
    assert.same({
      {
        kind = "upgrade",
        coordinate = "com.acme:library",
        consumers = { "com.acme:library" },
        before = "1.0.0",
        after = "2.0.0",
      },
    }, descriptor.preview.files[1].changes)
    assert.is_false(contains_private_path(descriptor, pom_path))
  end)

  it("ignores descriptor tampering, applies once, and emits one aggregate event", function()
    local root, pom_path, _, snapshot = fixture()
    local events = {}
    package.loaded["duke.events"] = {
      build_changed = function(path, operation, details)
        events[#events + 1] = { path = path, operation = operation, details = details }
      end,
    }
    local plans = require("duke.reactor_plan")
    local diagnosis = assert(plans.capture(snapshot))
    local _, descriptor = wait_call(function(callback)
      plans.build({
        diagnosis_id = diagnosis.id,
        repairs = { { finding_id = diagnosis.findings[1].id, new_version = "2.0.0" } },
      }, callback)
    end)
    descriptor.preview.files[1].pom_label = "../../attacker.xml"

    local err, result = wait_call(function(callback)
      plans.apply(descriptor, callback)
    end)
    assert.is_nil(err)
    assert.is_true(result.ok)
    assert.same({ pom_path }, result.changed_files)
    assert.matches("<version>2.0.0</version>", table.concat(vim.fn.readfile(pom_path), "\n"))
    assert.equals(1, #events)
    assert.equals("repair_reactor", events[1].operation)
    assert.equals(root, events[1].details.root)

    local second_err = wait_call(function(callback)
      plans.apply(descriptor, callback)
    end)
    assert.matches("unknown or expired", second_err)
  end)

  it("rejects stale files without an event", function()
    local _, pom_path, _, snapshot = fixture()
    local event_count = 0
    package.loaded["duke.events"] = {
      build_changed = function()
        event_count = event_count + 1
      end,
    }
    local plans = require("duke.reactor_plan")
    local diagnosis = assert(plans.capture(snapshot))
    local _, descriptor = wait_call(function(callback)
      plans.build({
        diagnosis_id = diagnosis.id,
        repairs = { { finding_id = diagnosis.findings[1].id, new_version = "2.0.0" } },
      }, callback)
    end)
    vim.fn.writefile({ "<project><!-- changed --></project>" }, pom_path)

    local err, result = wait_call(function(callback)
      plans.apply(descriptor, callback)
    end)
    assert.is_nil(err)
    assert.is_false(result.ok)
    assert.equals("preflight", result.phase)
    assert.equals(0, event_count)
  end)

  it("expires and discards opaque diagnoses", function()
    local _, _, _, snapshot = fixture()
    local plans = require("duke.reactor_plan")
    local diagnosis = assert(plans.capture(snapshot, { ttl_ms = 1 }))
    vim.wait(5)
    local expired = wait_call(function(callback)
      plans.build({ diagnosis_id = diagnosis.id, repairs = {} }, callback)
    end)
    assert.matches("unknown or expired", expired)

    diagnosis = assert(plans.capture(snapshot))
    assert.is_true(plans.discard(diagnosis))
    local discarded = wait_call(function(callback)
      plans.build({ diagnosis_id = diagnosis.id, repairs = {} }, callback)
    end)
    assert.matches("unknown or expired", discarded)
  end)
end)
