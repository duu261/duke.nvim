describe("Maven version ownership", function()
  local ownership

  before_each(function()
    package.loaded["duke.maven_ownership"] = nil
    ownership = require("duke.maven_ownership")
  end)

  local function dependency(coordinate, version, start_line, version_line)
    return {
      kind = "dependency",
      coordinate = coordinate,
      version = version,
      start_line = start_line,
      version_line = version_line or start_line,
    }
  end

  local function managed(coordinate, version, start_line, version_line)
    return {
      kind = "dependency_management",
      coordinate = coordinate,
      version = version,
      managed = true,
      start_line = start_line,
      version_line = version_line or start_line,
    }
  end

  local function module(id, path, model, effective, tree)
    return {
      id = id,
      build_file = path,
      model = model,
      resolved = {
        effective = effective,
        tree = tree or { coordinate = id, children = {} },
      },
    }
  end

  it("resolves direct, property, and managed owners from exact origins", function()
    local app_model = {
      coordinates = { group_id = "com.acme", artifact_id = "app", version = "1.0.0" },
      dependencies = {
        dependency("com.acme:direct", "1.0.0", 10, 13),
        dependency("com.acme:property", "${library.version}", 20, 23),
      },
      dependency_management = { managed("com.acme:managed", "2.0.0", 30, 33) },
      properties = {
        ["library.version"] = {
          value = "1.5.0",
          line = 6,
          consumers = { "com.acme:property" },
          other_consumers = {},
        },
      },
      profile_ranges = {},
    }
    local effective = {
      dependencies = {
        dependency("com.acme:direct", "1.0.0", 40, 43),
        dependency("com.acme:property", "1.5.0", 50, 53),
      },
      dependency_management = { managed("com.acme:managed", "2.0.0", 60, 63) },
      sources = {
        { source = "/repo/app/pom.xml", line = 13, effective_line = 43 },
        { source = "/repo/app/pom.xml", line = 23, effective_line = 53 },
        { source = "/repo/app/pom.xml", line = 33, effective_line = 63 },
      },
    }
    local snapshot = {
      root = "/repo",
      modules = {
        module("com.acme:app", "/repo/app/pom.xml", app_model, effective, {
          coordinate = "com.acme:app",
          children = {
            { coordinate = "com.acme:direct", version = "1.0.0", children = {} },
            { coordinate = "com.acme:property", version = "1.5.0", children = {} },
            { coordinate = "com.acme:managed", version = "2.0.0", children = {} },
          },
        }),
      },
    }

    local rows = ownership.resolve(snapshot)

    assert.equals("dependency", rows["com.acme:app\0com.acme:direct"].kind)
    assert.equals("property", rows["com.acme:app\0com.acme:property"].kind)
    assert.equals("library.version", rows["com.acme:app\0com.acme:property"].property)
    assert.equals("dependency_management", rows["com.acme:app\0com.acme:managed"].kind)
    assert.is_true(rows["com.acme:app\0com.acme:managed"].writable)
  end)

  it("requires BOM origin evidence and blocks external, profile, and duplicate owners", function()
    local root_model = {
      coordinates = { group_id = "com.acme", artifact_id = "root", version = "1.0.0" },
      dependencies = {},
      dependency_management = {
        vim.tbl_extend("force", managed("com.acme:platform-bom", "${platform.version}", 10, 13), {
          imported_bom = true,
          type = "pom",
          scope = "import",
        }),
        managed("com.acme:duplicate", "1.0.0", 20, 23),
        managed("com.acme:duplicate", "2.0.0", 30, 33),
      },
      properties = {
        ["platform.version"] = {
          value = "1.0.0",
          line = 6,
          consumers = { "com.acme:platform-bom" },
          other_consumers = {},
        },
      },
      profile_ranges = { { id = "dev", start_line = 40, end_line = 50 } },
    }
    local effective = {
      dependencies = {},
      dependency_management = {
        managed("com.acme:bom-owned", "3.0.0", 100, 103),
        managed("com.acme:external", "4.0.0", 110, 113),
        managed("com.acme:profile-owned", "5.0.0", 120, 123),
        managed("com.acme:duplicate", "2.0.0", 130, 133),
      },
      sources = {
        { source = "com.acme:platform-bom:1.0.0", line = 77, effective_line = 103 },
        { source = "/external/parent/pom.xml", line = 12, effective_line = 113 },
        { source = "/repo/pom.xml", line = 45, effective_line = 123 },
        { source = "/repo/pom.xml", line = 23, effective_line = 133 },
      },
    }
    local tree = {
      coordinate = "com.acme:root",
      children = {
        { coordinate = "com.acme:bom-owned", version = "3.0.0", children = {} },
        { coordinate = "com.acme:external", version = "4.0.0", children = {} },
        { coordinate = "com.acme:profile-owned", version = "5.0.0", children = {} },
        { coordinate = "com.acme:duplicate", version = "2.0.0", children = {} },
      },
    }
    local snapshot = {
      root = "/repo",
      modules = { module("com.acme:root", "/repo/pom.xml", root_model, effective, tree) },
    }

    local rows = ownership.resolve(snapshot)

    assert.equals("imported_bom", rows["com.acme:root\0com.acme:bom-owned"].kind)
    assert.equals("/repo/pom.xml", rows["com.acme:root\0com.acme:bom-owned"].pom_path)
    assert.equals("platform.version", rows["com.acme:root\0com.acme:bom-owned"].property)
    assert.equals(6, rows["com.acme:root\0com.acme:bom-owned"].line)
    assert.is_true(rows["com.acme:root\0com.acme:bom-owned"].writable)
    assert.equals("external_parent", rows["com.acme:root\0com.acme:external"].kind)
    assert.matches("outside reactor", rows["com.acme:root\0com.acme:external"].blocked_reason)
    assert.equals("profile", rows["com.acme:root\0com.acme:profile-owned"].kind)
    assert.is_false(rows["com.acme:root\0com.acme:profile-owned"].writable)
    assert.equals("unknown", rows["com.acme:root\0com.acme:duplicate"].kind)
    assert.matches("multiple candidates", rows["com.acme:root\0com.acme:duplicate"].blocked_reason)
  end)

  it("resolves coordinate-form local-parent origins only at the exact source line", function()
    local parent_model = {
      coordinates = { group_id = "com.acme", artifact_id = "parent", version = "1.0.0" },
      dependencies = {},
      dependency_management = { managed("com.acme:library", "2.0.0", 10, 13) },
      properties = {},
      profile_ranges = {},
    }
    local app_effective = {
      dependencies = {},
      dependency_management = { managed("com.acme:library", "2.0.0", 60, 63) },
      sources = {
        { source = "com.acme:parent:1.0.0", line = 13, effective_line = 63 },
      },
    }
    local app_tree = {
      coordinate = "com.acme:app",
      children = { { coordinate = "com.acme:library", version = "2.0.0", children = {} } },
    }
    local snapshot = {
      root = "/repo",
      modules = {
        module("com.acme:parent", "/repo/pom.xml", parent_model, {
          dependencies = {},
          dependency_management = {},
          sources = {},
        }),
        module("com.acme:app", "/repo/app/pom.xml", {
          coordinates = { group_id = "com.acme", artifact_id = "app", version = "1.0.0" },
          dependencies = {},
          dependency_management = {},
          properties = {},
          profile_ranges = {},
        }, app_effective, app_tree),
      },
    }

    local row = ownership.resolve(snapshot)["com.acme:app\0com.acme:library"]

    assert.equals("local_parent", row.kind)
    assert.equals("/repo/pom.xml", row.pom_path)
    assert.equals(13, row.line)
    assert.is_true(row.writable)

    snapshot.modules[2].resolved.effective.sources[1].line = 99
    row = ownership.resolve(snapshot)["com.acme:app\0com.acme:library"]
    assert.equals("unknown", row.kind)
    assert.is_false(row.writable)
  end)

  it("classifies coordinate-form origins from a non-reactor parent", function()
    local app_model = {
      coordinates = { group_id = "com.acme", artifact_id = "app", version = "1.0.0" },
      parent = {
        group_id = "com.external",
        artifact_id = "company-parent",
        version = "1.0.0",
      },
      dependencies = {},
      dependency_management = {},
      properties = {},
      profile_ranges = {},
    }
    local effective = {
      dependencies = {},
      dependency_management = { managed("com.acme:library", "2.0.0", 60, 63) },
      sources = {
        { source = "com.external:company-parent:1.0.0", line = 12, effective_line = 63 },
      },
    }
    local tree = {
      coordinate = "com.acme:app",
      children = { { coordinate = "com.acme:library", version = "2.0.0", children = {} } },
    }

    local row = ownership.resolve({
      root = "/repo",
      modules = { module("com.acme:app", "/repo/pom.xml", app_model, effective, tree) },
    })["com.acme:app\0com.acme:library"]

    assert.equals("external_parent", row.kind)
    assert.matches("outside reactor", row.blocked_reason)
    assert.is_false(row.writable)
  end)
end)
