describe("Dependency analyzer", function()
  local analyzer

  before_each(function()
    package.loaded["duke.dependency_analyzer"] = nil
    analyzer = require("duke.dependency_analyzer")
  end)

  after_each(function()
    package.loaded["duke.dependency_analyzer"] = nil
  end)

  local function module(id, declared_version, resolved_version)
    return {
      id = id,
      model = {
        dependencies = {
          { coordinate = "org.slf4j:slf4j-api", version = declared_version, start_line = 10 },
          { coordinate = "org.slf4j:slf4j-api", version = declared_version, start_line = 20 },
        },
        properties = {},
      },
      resolved = {
        effective = { dependencies = {} },
        tree = {
          coordinate = id,
          children = {
            {
              coordinate = "org.slf4j:slf4j-api",
              version = resolved_version,
              scope = "compile",
              children = {
                {
                  coordinate = "org.example:leaf",
                  version = "1.0",
                  scope = "runtime",
                  children = {},
                },
              },
            },
          },
        },
      },
    }
  end

  it("finds duplicates, cross-module drift, unknown ownership, and every path", function()
    local analysis = analyzer.analyze({
      modules = {
        module("com.acme:a", "2.0.16", "2.0.16"),
        module("com.acme:b", "2.0.17", "2.0.17"),
      },
    })

    assert.equals(2, #analysis.findings.duplicates)
    assert.equals(1, #analysis.findings.drift)
    assert.equals("org.slf4j:slf4j-api", analysis.findings.drift[1].coordinate)
    assert.equals(2, #analysis.findings.unknown)
    assert.equals(4, #analysis.dependencies)
    assert.same({
      { "com.acme:a", "org.slf4j:slf4j-api", "org.example:leaf" },
    }, analyzer.paths(analysis, "org.example:leaf", "com.acme:a"))
  end)

  it("normalizes repair evidence with unique deterministic IDs", function()
    local analysis = {
      findings = {
        conflicts = {
          {
            coordinate = "com.acme:library",
            module_id = "com.acme:app",
            omitted = "1.0.0",
            selected = "2.0.0",
            path = { "com.acme:app", "com.acme:starter", "com.acme:library" },
          },
        },
        drift = { { coordinate = "com.acme:drift", versions = { "1.0.0", "2.0.0" } } },
        duplicates = {
          { coordinate = "com.acme:duplicate", module_id = "com.acme:app", lines = { 10, 20 } },
        },
        unknown = {
          { coordinate = "com.acme:unknown", module_id = "com.acme:app" },
        },
      },
      dependencies = {
        {
          coordinate = "com.acme:mediated",
          module_id = "com.acme:app",
          version = "3.0.0",
          raw_owner = { version = "2.0.0" },
        },
      },
      paths = {
        ["com.acme:app\0com.acme:library"] = {
          { "com.acme:app", "com.acme:starter", "com.acme:library" },
        },
      },
    }
    local ownership_rows = {
      ["com.acme:app\0com.acme:library"] = {
        kind = "dependency_management",
        coordinate = "com.acme:library",
        selected_version = "2.0.0",
        pom_path = "/repo/pom.xml",
        line = 14,
        writable = true,
        consumers = { "com.acme:app", "com.acme:service" },
      },
      ["com.acme:app\0com.acme:mediated"] = {
        kind = "dependency",
        coordinate = "com.acme:mediated",
        selected_version = "3.0.0",
        pom_path = "/repo/app/pom.xml",
        line = 20,
        writable = true,
      },
      ["com.acme:app\0com.acme:unknown"] = {
        kind = "external_parent",
        coordinate = "com.acme:unknown",
        writable = false,
        blocked_reason = "version owner is outside reactor",
      },
      ["com.acme:app\0com.acme:drift"] = {
        kind = "dependency",
        coordinate = "com.acme:drift",
        requested_version = "1.0.0",
        pom_path = "/repo/app/pom.xml",
        line = 20,
        writable = true,
      },
      ["com.acme:service\0com.acme:drift"] = {
        kind = "dependency",
        coordinate = "com.acme:drift",
        requested_version = "2.0.0",
        pom_path = "/repo/service/pom.xml",
        line = 20,
        writable = true,
      },
    }

    local findings = analyzer.repairable(analysis, ownership_rows, {
      used_undeclared = { "com.acme:missing" },
      unused_declared = { "com.acme:unused" },
    })
    local by_kind = {}
    for _, finding in ipairs(findings) do
      by_kind[finding.kind] = finding
    end

    local conflict = by_kind.version_conflict
    assert.equals("version_conflict:com.acme:library", conflict.id)
    assert.same({ "1.0.0", "2.0.0" }, conflict.requested_versions)
    assert.equals("2.0.0", conflict.selected_version)
    assert.is_true(conflict.repairable)
    assert.equals("dependency_management", conflict.ownership.kind)
    assert.same({ "com.acme:app", "com.acme:service" }, conflict.consumers)
    assert.equals("warning", conflict.severity)

    assert.is_true(by_kind.version_drift.repairable)
    assert.equals("reactor_alignment", by_kind.version_drift.ownership.kind)
    assert.equals(2, #by_kind.version_drift.ownership.owners)
    assert.is_true(by_kind.mediated_version.repairable)
    assert.is_false(by_kind.duplicate_declaration.repairable)
    assert.matches("duplicate", by_kind.duplicate_declaration.blocked_reason)
    assert.is_false(by_kind.used_undeclared.repairable)
    assert.matches("module attribution", by_kind.used_undeclared.blocked_reason)
    assert.equals("info", by_kind.unused_declared.severity)

    local seen = {}
    for _, finding in ipairs(findings) do
      assert.is_nil(seen[finding.id])
      seen[finding.id] = true
    end
  end)

  it("disambiguates repeated finding IDs by module", function()
    local findings = analyzer.repairable({
      findings = {
        conflicts = {
          { coordinate = "com.acme:library", module_id = "com.acme:a" },
          { coordinate = "com.acme:library", module_id = "com.acme:b" },
        },
      },
      paths = {},
    }, {}, {})

    assert.equals("version_conflict:com.acme:library:com.acme:a", findings[1].id)
    assert.equals("version_conflict:com.acme:library:com.acme:b", findings[2].id)
  end)
end)
