describe("POM editing", function()
  local pom

  before_each(function()
    package.loaded["duke.pom"] = nil
    pom = require("duke.pom")
  end)

  it("detects Spring Boot parent version", function()
    local lines = {
      "<project>",
      "  <parent>",
      "    <groupId>org.springframework.boot</groupId>",
      "    <artifactId>spring-boot-starter-parent</artifactId>",
      "    <version>3.5.3</version>",
      "  </parent>",
      "</project>",
    }

    assert.equals("3.5.3", pom.spring_boot_version(lines))
  end)

  it("resolves a Spring Boot version property", function()
    local lines = {
      "<project>",
      "  <properties><spring-boot.version>3.4.7</spring-boot.version></properties>",
      "  <dependencyManagement>",
      "    <dependencies><dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-dependencies</artifactId>",
      "      <version>${spring-boot.version}</version>",
      "    </dependency></dependencies>",
      "  </dependencyManagement>",
      "</project>",
    }

    assert.equals("3.4.7", pom.spring_boot_version(lines))
  end)

  it("resolves only literal direct-root dependency version properties", function()
    local lines = {
      "<project>",
      "  <properties>",
      "    <direct.version>1.2.3</direct.version>",
      "    <chained.version>${direct.version}</chained.version>",
      "  </properties>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>g</groupId>",
      "      <artifactId>direct</artifactId>",
      "      <version>${direct.version}</version>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>g</groupId>",
      "      <artifactId>chained</artifactId>",
      "      <version>${chained.version}</version>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local dependencies = assert(pom.list(lines))
    local sources = assert(pom.dependency_version_sources(lines, dependencies))

    assert.same({
      kind = "property",
      property = "direct.version",
      version = "1.2.3",
      consumers = { "g:direct" },
      other_consumers = { { kind = "other", line = 4 } },
    }, sources[dependencies[1]])
    assert.is_nil(sources[dependencies[2]])
  end)

  it("inserts dependencies before root dependency close", function()
    local lines = {
      "<project>",
      "  <dependencies>",
      "  </dependencies>",
      "</project>",
    }
    local updated, added = pom.insert(lines, {
      { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-web" },
    })

    assert.equals(1, added)
    assert.same({
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }, updated)
  end)

  it("emits only non-compile dependency scopes", function()
    local updated, added = pom.insert({ "<project>", "</project>" }, {
      {
        group_id = "org.junit.jupiter",
        artifact_id = "junit-jupiter",
        version = "5.13.4",
        scope = "test",
      },
      { group_id = "com.example", artifact_id = "compile-lib", version = "1.0", scope = "compile" },
      { group_id = "com.example", artifact_id = "default-lib", version = "1.0" },
    })

    assert.equals(3, added)
    assert.is_truthy(table.concat(updated, "\n"):find("<scope>test</scope>", 1, true))
    assert.is_falsy(table.concat(updated, "\n"):find("<scope>compile</scope>", 1, true))
    assert.equals("      <version>5.13.4</version>", updated[6])
    assert.equals("      <scope>test</scope>", updated[7])
  end)

  it("handles a multiline root project tag", function()
    local lines = {
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<project xmlns="http://maven.apache.org/POM/4.0.0"',
      '  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
      "  <dependencies>",
      "  </dependencies>",
      "</project>",
    }
    local updated, added = pom.insert(lines, {
      { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-actuator" },
    })

    assert.equals(1, added)
    assert.equals("    <dependency>", updated[5])
    assert.equals("  </dependencies>", updated[9])
  end)

  it("rejects compact one-line project XML", function()
    local lines = { "<project><dependencies></dependencies></project>" }
    local updated, added, err = pom.insert(lines, {
      { group_id = "com.example", artifact_id = "demo" },
    })

    assert.equals(0, added)
    assert.matches("compact", err)
    assert.same(lines, updated)
  end)

  it("rejects self-closing root dependencies", function()
    local lines = { "<project>", "  <dependencies/>", "</project>" }
    local updated, added, err = pom.insert(lines, {
      { group_id = "com.example", artifact_id = "demo" },
    })

    assert.equals(0, added)
    assert.matches("self%-closing", err)
    assert.same(lines, updated)
  end)

  it("creates a root dependencies block when absent", function()
    local updated, added = pom.insert({ "<project>", "</project>" }, {
      { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-web" },
    })

    assert.equals(1, added)
    assert.same({
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }, updated)
  end)

  it("skips duplicate coordinates", function()
    local lines = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local updated, added = pom.insert(lines, {
      { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-web" },
    })

    assert.equals(0, added)
    assert.same(lines, updated)
  end)

  it("resolves property-backed duplicate coordinates", function()
    local lines = {
      "<project>",
      "  <properties>",
      "    <starter.group>org.springframework.boot</starter.group>",
      "  </properties>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>${starter.group}</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local updated, added = pom.insert(lines, {
      { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-web" },
    })

    assert.equals(0, added)
    assert.same(lines, updated)
  end)

  it("does not treat a classified dependency as the same default jar", function()
    local lines = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>demo</artifactId>",
      "      <classifier>tests</classifier>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local _, added = pom.insert(lines, {
      { group_id = "com.example", artifact_id = "demo" },
    })

    assert.equals(1, added)
  end)

  it("escapes dependency coordinates as XML text", function()
    local updated, added = pom.insert({ "<project>", "</project>" }, {
      { group_id = "com.example&tools", artifact_id = "demo<api>" },
    })

    assert.equals(1, added)
    assert.equals("      <groupId>com.example&amp;tools</groupId>", updated[4])
    assert.equals("      <artifactId>demo&lt;api&gt;</artifactId>", updated[5])
  end)

  it("does not insert into dependencyManagement", function()
    local lines = {
      "<project>",
      "  <dependencyManagement>",
      "    <dependencies>",
      "    </dependencies>",
      "  </dependencyManagement>",
      "</project>",
    }
    local updated = pom.insert(lines, {
      { group_id = "org.springframework.boot", artifact_id = "spring-boot-starter-web" },
    })

    assert.same({
      "<project>",
      "  <dependencyManagement>",
      "    <dependencies>",
      "    </dependencies>",
      "  </dependencyManagement>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }, updated)
  end)

  it("lists only root dependencies with versions and positions", function()
    local lines = {
      "<project>",
      "  <dependencyManagement>",
      "    <dependencies>",
      "      <dependency>",
      "        <groupId>managed</groupId>",
      "        <artifactId>catalog</artifactId>",
      "        <version>1.0</version>",
      "      </dependency>",
      "    </dependencies>",
      "  </dependencyManagement>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>org.junit.jupiter</groupId>",
      "      <artifactId>junit-jupiter</artifactId>",
      "      <version>5.13.4</version>",
      "      <scope>test</scope>",
      "    </dependency>",
      "    <!-- keep this comment between blocks -->",
      "    <dependency>",
      "      <groupId>org.springframework.boot</groupId>",
      "      <artifactId>spring-boot-starter-web</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "  <profiles>",
      "    <profile>",
      "      <dependencies>",
      "        <dependency>",
      "          <groupId>profile</groupId>",
      "          <artifactId>only</artifactId>",
      "        </dependency>",
      "      </dependencies>",
      "    </profile>",
      "  </profiles>",
      "</project>",
    }

    local dependencies, err = pom.list(lines)

    assert.is_nil(err)
    assert.equals(2, #dependencies)
    assert.same({
      group_id = "org.junit.jupiter",
      artifact_id = "junit-jupiter",
      version = "5.13.4",
    }, {
      group_id = dependencies[1].group_id,
      artifact_id = dependencies[1].artifact_id,
      version = dependencies[1].version,
    })
    assert.same({
      group_id = "org.springframework.boot",
      artifact_id = "spring-boot-starter-web",
      version = nil,
    }, {
      group_id = dependencies[2].group_id,
      artifact_id = dependencies[2].artifact_id,
      version = dependencies[2].version,
    })
    assert.is_number(dependencies[1].start_line)
    assert.is_number(dependencies[1].end_line)
  end)

  it("models root dependency management and read-only profile ranges", function()
    local lines = {
      "<project>",
      "  <groupId>com.acme</groupId>",
      "  <artifactId>app</artifactId>",
      "  <version>1.0.0</version>",
      "  <properties>",
      "    <platform.version>2.0.0</platform.version>",
      "  </properties>",
      "  <dependencyManagement>",
      "    <dependencies>",
      "      <dependency>",
      "        <groupId>com.acme</groupId>",
      "        <artifactId>platform-bom</artifactId>",
      "        <version>${platform.version}</version>",
      "        <type>pom</type>",
      "        <scope>import</scope>",
      "      </dependency>",
      "    </dependencies>",
      "  </dependencyManagement>",
      "  <profiles>",
      "    <profile>",
      "      <id>local-dev</id>",
      "      <dependencies>",
      "        <dependency>",
      "          <groupId>com.acme</groupId>",
      "          <artifactId>profile-only</artifactId>",
      "        </dependency>",
      "      </dependencies>",
      "    </profile>",
      "  </profiles>",
      "</project>",
    }

    local model = assert(pom.model(lines))
    local managed = model.dependency_management[1]

    assert.same({
      coordinate = "com.acme:platform-bom",
      version = "${platform.version}",
      scope = "import",
      type = "pom",
      managed = true,
      imported_bom = true,
      start_line = 10,
      version_line = 13,
    }, {
      coordinate = managed.coordinate,
      version = managed.version,
      scope = managed.scope,
      type = managed.type,
      managed = managed.managed,
      imported_bom = managed.imported_bom,
      start_line = managed.start_line,
      version_line = managed.version_line,
    })
    assert.same({ "com.acme:platform-bom" }, model.properties["platform.version"].consumers)
    assert.same({
      { id = "local-dev", start_line = 20, end_line = 28 },
    }, model.profile_ranges)
  end)

  it("keeps self-closing profile containers read-only and non-fatal", function()
    local model = assert(pom.model({
      "<project>",
      "  <groupId>com.acme</groupId>",
      "  <artifactId>app</artifactId>",
      "  <version>1.0.0</version>",
      "  <profiles/>",
      "</project>",
    }))

    assert.same({}, model.profile_ranges)
  end)

  it("rejects compact and self-closing root dependency blocks", function()
    local compact = {
      "<project>",
      "  <dependencies>",
      "    <dependency><groupId>com.example</groupId><artifactId>demo</artifactId></dependency>",
      "  </dependencies>",
      "</project>",
    }
    local self_closing = {
      "<project>",
      "  <dependencies>",
      "    <dependency/>",
      "  </dependencies>",
      "</project>",
    }

    local compact_dependencies, compact_error = pom.list(compact)
    local self_closing_dependencies, self_closing_error = pom.list(self_closing)

    assert.is_nil(compact_dependencies)
    assert.matches("compact", compact_error)
    assert.is_nil(self_closing_dependencies)
    assert.matches("self%-closing", self_closing_error)
  end)

  it("updates only explicit version text and preserves the dependency block", function()
    local lines = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <!-- version chosen by hand -->",
      "      <groupId>org.junit.jupiter</groupId>",
      "      <artifactId>junit-jupiter</artifactId>",
      "      <version>5.12.0</version>",
      "      <type>test-jar</type>",
      "      <classifier>tests</classifier>",
      "      <scope>test</scope>",
      "      <exclusions>",
      "        <exclusion>",
      "          <groupId>legacy</groupId>",
      "          <artifactId>engine</artifactId>",
      "        </exclusion>",
      "      </exclusions>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local dependencies = assert(pom.list(lines))

    local updated, err = pom.update_version(lines, dependencies[1], "5.13.4")

    assert.is_nil(err)
    local before = table.concat(lines, "\n")
    local after = table.concat(updated, "\n")
    assert.equals(before:gsub("<version>5.12.0</version>", "<version>5.13.4</version>"), after)
    assert.is_truthy(after:find("<scope>test</scope>", 1, true))
    assert.is_truthy(after:find("<classifier>tests</classifier>", 1, true))
  end)

  it("rejects property-backed version updates with the property name", function()
    local lines = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>demo</artifactId>",
      "      <version>${demo.version}</version>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local dependencies = assert(pom.list(lines))

    local updated, err = pom.update_version(lines, dependencies[1], "2.0")

    assert.matches("demo%.version", err)
    assert.same(lines, updated)
  end)

  it("removes selected blocks without touching siblings or surrounding formatting", function()
    local lines = {
      "<project>",
      "  <dependencies>",
      "",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>first</artifactId>",
      "    </dependency>",
      "",
      "    <!-- middle dependency stays -->",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>middle</artifactId>",
      "    </dependency>",
      "",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>last</artifactId>",
      "    </dependency>",
      "",
      "  </dependencies>",
      "</project>",
    }
    local dependencies = assert(pom.list(lines))

    local updated, removed, err = pom.remove(lines, { dependencies[1], dependencies[3] })

    assert.is_nil(err)
    assert.equals(2, removed)
    assert.same({
      "<project>",
      "  <dependencies>",
      "",
      "",
      "    <!-- middle dependency stays -->",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>middle</artifactId>",
      "    </dependency>",
      "",
      "",
      "  </dependencies>",
      "</project>",
    }, updated)
  end)

  it("keeps the root dependencies container after removing the last dependency", function()
    local lines = {
      "<project>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.example</groupId>",
      "      <artifactId>only</artifactId>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
    local dependencies = assert(pom.list(lines))

    local updated, removed = pom.remove(lines, dependencies)

    assert.equals(1, removed)
    assert.same({ "<project>", "  <dependencies>", "  </dependencies>", "</project>" }, updated)
  end)

  describe("reactor metadata", function()
    it("reads direct reactor coordinates and pom packaging", function()
      local meta, err = pom.reactor({
        "<project>",
        "  <groupId>com.example</groupId>",
        "  <artifactId>parent</artifactId>",
        "  <version>1.0.0</version>",
        "  <packaging>pom</packaging>",
        "</project>",
      })

      assert.is_nil(err)
      assert.same({
        group_id = "com.example",
        artifact_id = "parent",
        version = "1.0.0",
        packaging = "pom",
      }, meta)
    end)

    it("falls back to the root parent for inherited literal groupId and version", function()
      local meta, err = pom.reactor({
        "<project>",
        "  <parent>",
        "    <groupId>com.example</groupId>",
        "    <artifactId>company-parent</artifactId>",
        "    <version>2.0.0</version>",
        "  </parent>",
        "  <artifactId>reactor</artifactId>",
        "  <packaging>pom</packaging>",
        "</project>",
      })

      assert.is_nil(err)
      assert.equals("com.example", meta.group_id)
      assert.equals("reactor", meta.artifact_id)
      assert.equals("2.0.0", meta.version)
      assert.equals("pom", meta.packaging)
    end)

    it("rejects missing or non-pom packaging", function()
      local missing, missing_err = pom.reactor({
        "<project>",
        "  <groupId>com.example</groupId>",
        "  <artifactId>parent</artifactId>",
        "  <version>1.0.0</version>",
        "</project>",
      })
      local jar, jar_err = pom.reactor({
        "<project>",
        "  <groupId>com.example</groupId>",
        "  <artifactId>parent</artifactId>",
        "  <version>1.0.0</version>",
        "  <packaging>jar</packaging>",
        "</project>",
      })

      assert.is_nil(missing)
      assert.matches("packaging", missing_err)
      assert.is_nil(jar)
      assert.matches("packaging", jar_err)
    end)

    it("rejects missing, duplicate, property-backed, and nested coordinate fields", function()
      local no_artifact, no_artifact_err = pom.reactor({
        "<project>",
        "  <groupId>com.example</groupId>",
        "  <version>1.0.0</version>",
        "  <packaging>pom</packaging>",
        "</project>",
      })
      local duplicate, duplicate_err = pom.reactor({
        "<project>",
        "  <groupId>com.example</groupId>",
        "  <artifactId>parent</artifactId>",
        "  <artifactId>other</artifactId>",
        "  <version>1.0.0</version>",
        "  <packaging>pom</packaging>",
        "</project>",
      })
      local property_backed, property_err = pom.reactor({
        "<project>",
        "  <groupId>com.example</groupId>",
        "  <artifactId>parent</artifactId>",
        "  <version>${revision}</version>",
        "  <packaging>pom</packaging>",
        "</project>",
      })
      local nested_xml, nested_err = pom.reactor({
        "<project>",
        "  <groupId><nested/></groupId>",
        "  <artifactId>parent</artifactId>",
        "  <version>1.0.0</version>",
        "  <packaging>pom</packaging>",
        "</project>",
      })
      local profile_nested, profile_err = pom.reactor({
        "<project>",
        "  <groupId>com.example</groupId>",
        "  <artifactId>parent</artifactId>",
        "  <version>1.0.0</version>",
        "  <packaging>pom</packaging>",
        "  <profiles>",
        "    <profile>",
        "      <groupId>ignored</groupId>",
        "      <version>9.9.9</version>",
        "    </profile>",
        "  </profiles>",
        "</project>",
      })

      assert.is_nil(no_artifact)
      assert.matches("artifactId", no_artifact_err)
      assert.is_nil(duplicate)
      assert.matches("duplicate", duplicate_err)
      assert.is_nil(property_backed)
      assert.matches("property", property_err)
      assert.is_nil(nested_xml)
      assert.matches("nested", nested_err)
      assert.is_nil(profile_err)
      assert.equals("com.example", profile_nested.group_id)
      assert.equals("1.0.0", profile_nested.version)
    end)

    it("rejects compact root project XML for reactor inspection", function()
      local compact = table.concat({
        "<project>",
        "<groupId>com.example</groupId>",
        "<artifactId>p</artifactId>",
        "<version>1</version>",
        "<packaging>pom</packaging>",
        "</project>",
      })
      local meta, err = pom.reactor({ compact })

      assert.is_nil(meta)
      assert.matches("compact", err)
    end)
  end)

  describe("parent version accessor", function()
    local function boot_pom(version)
      return {
        "<project>",
        "  <parent>",
        "    <groupId>org.springframework.boot</groupId>",
        "    <artifactId>spring-boot-starter-parent</artifactId>",
        "    <version>" .. version .. "</version>",
        "  </parent>",
        "  <artifactId>demo</artifactId>",
        "</project>",
      }
    end

    it("returns offsets on a real Boot pom usable by update_version", function()
      local lines = boot_pom("3.3.0")
      local parent = assert(pom.parent(lines))

      assert.equals("org.springframework.boot", parent.group_id)
      assert.equals("spring-boot-starter-parent", parent.artifact_id)
      assert.equals("3.3.0", parent.version)

      local updated, err = pom.update_version(lines, parent, "3.3.5")
      assert.is_nil(err)
      assert.same(boot_pom("3.3.5"), updated)
    end)

    it("moves only the parent version, leaving a sibling dependency version untouched", function()
      local lines = {
        "<project>",
        "  <parent>",
        "    <groupId>org.springframework.boot</groupId>",
        "    <artifactId>spring-boot-starter-parent</artifactId>",
        "    <version>3.3.0</version>",
        "  </parent>",
        "  <artifactId>demo</artifactId>",
        "  <dependencies>",
        "    <dependency>",
        "      <groupId>com.example</groupId>",
        "      <artifactId>lib</artifactId>",
        "      <version>3.3.0</version>",
        "    </dependency>",
        "  </dependencies>",
        "</project>",
      }
      local parent = assert(pom.parent(lines))

      local updated = pom.update_version(lines, parent, "3.3.5")

      assert.equals("      <version>3.3.0</version>", updated[12])
      assert.equals("    <version>3.3.5</version>", updated[5])
    end)

    it("returns nil when there is no parent element", function()
      local parent, err =
        pom.parent({ "<project>", "  <artifactId>demo</artifactId>", "</project>" })
      assert.is_nil(parent)
      assert.matches("parent", err)
    end)

    it("refuses a non-Boot parent", function()
      local parent, err = pom.parent({
        "<project>",
        "  <parent>",
        "    <groupId>com.example</groupId>",
        "    <artifactId>company-parent</artifactId>",
        "    <version>1.0.0</version>",
        "  </parent>",
        "</project>",
      })
      assert.is_nil(parent)
      assert.matches("Spring Boot", err)
    end)

    it("rejects a self-closing parent element", function()
      local parent, err = pom.parent({ "<project>", "  <parent/>", "</project>" })
      assert.is_nil(parent)
      assert.matches("self%-closing", err)
    end)

    it("rejects a compact one-line parent element", function()
      local parent, err = pom.parent({
        "<project>",
        "  <parent><groupId>org.springframework.boot</groupId>"
          .. "<artifactId>spring-boot-starter-parent</artifactId><version>3.3.0</version></parent>",
        "</project>",
      })
      assert.is_nil(parent)
      assert.matches("compact", err)
    end)

    it("refuses a property-backed parent version via update_version", function()
      local lines = {
        "<project>",
        "  <properties><boot.version>3.3.0</boot.version></properties>",
        "  <parent>",
        "    <groupId>org.springframework.boot</groupId>",
        "    <artifactId>spring-boot-starter-parent</artifactId>",
        "    <version>${boot.version}</version>",
        "  </parent>",
        "</project>",
      }
      local parent = assert(pom.parent(lines))

      local updated, err = pom.update_version(lines, parent, "3.3.5")
      assert.matches("property boot%.version", err)
      assert.same(lines, updated)
    end)

    it("detects a stale parent block underneath a pending edit", function()
      local lines = boot_pom("3.3.0")
      local parent = assert(pom.parent(lines))

      local changed = vim.deepcopy(lines)
      changed[5] = "    <version>9.9.9</version>"

      local updated, err = pom.update_version(changed, parent, "3.3.5")
      assert.matches("changed; run command again", err)
      assert.same(changed, updated)
    end)
  end)

  describe("module insertion", function()
    it(
      "appends one module to an existing root modules block with surrounding bytes unchanged",
      function()
        local lines = {
          "<project>",
          "  <artifactId>parent</artifactId>",
          "  <!-- keep -->",
          "  <modules>",
          "    <module>existing</module>",
          "  </modules>",
          "  <profiles>",
          "    <profile>",
          "      <modules>",
          "        <module>profile-only</module>",
          "      </modules>",
          "    </profile>",
          "  </profiles>",
          "</project>",
        }
        local updated, count, err = pom.insert_module(lines, "child")

        assert.is_nil(err)
        assert.equals(1, count)
        assert.same({
          "<project>",
          "  <artifactId>parent</artifactId>",
          "  <!-- keep -->",
          "  <modules>",
          "    <module>existing</module>",
          "    <module>child</module>",
          "  </modules>",
          "  <profiles>",
          "    <profile>",
          "      <modules>",
          "        <module>profile-only</module>",
          "      </modules>",
          "    </profile>",
          "  </profiles>",
          "</project>",
        }, updated)
      end
    )

    it("creates a root modules block when absent with matching indentation", function()
      local updated, count, err = pom.insert_module({
        "<project>",
        "  <artifactId>parent</artifactId>",
        "</project>",
      }, "child")

      assert.is_nil(err)
      assert.equals(1, count)
      assert.same({
        "<project>",
        "  <artifactId>parent</artifactId>",
        "  <modules>",
        "    <module>child</module>",
        "  </modules>",
        "</project>",
      }, updated)
    end)

    it("ignores profile and plugin modules and does not insert into them", function()
      local lines = {
        "<project>",
        "  <build>",
        "    <plugins>",
        "      <plugin>",
        "        <configuration>",
        "          <modules>",
        "            <module>plugin-mod</module>",
        "          </modules>",
        "        </configuration>",
        "      </plugin>",
        "    </plugins>",
        "  </build>",
        "  <profiles>",
        "    <profile>",
        "      <modules>",
        "        <module>profile-mod</module>",
        "      </modules>",
        "    </profile>",
        "  </profiles>",
        "</project>",
      }
      local updated, count = pom.insert_module(lines, "child")

      assert.equals(1, count)
      assert.equals("  <modules>", updated[20])
      assert.equals("    <module>child</module>", updated[21])
      assert.equals("  </modules>", updated[22])
      assert.equals("            <module>plugin-mod</module>", updated[7])
      assert.equals("        <module>profile-mod</module>", updated[16])
    end)

    it("returns unchanged lines and count 0 for an already declared module", function()
      local lines = {
        "<project>",
        "  <modules>",
        "    <module>child</module>",
        "  </modules>",
        "</project>",
      }
      local updated, count, err = pom.insert_module(lines, "child")

      assert.is_nil(err)
      assert.equals(0, count)
      assert.same(lines, updated)
    end)

    it("rejects self-closing, compact, multiple root modules, and shared-line modules", function()
      local self_closing, _, self_err = pom.insert_module({
        "<project>",
        "  <modules/>",
        "</project>",
      }, "child")
      local _, _, compact_err = pom.insert_module({
        "<project>",
        "  <modules><module>a</module></modules>",
        "</project>",
      }, "child")
      local _, _, multiple_err = pom.insert_module({
        "<project>",
        "  <modules>",
        "    <module>a</module>",
        "  </modules>",
        "  <modules>",
        "    <module>b</module>",
        "  </modules>",
        "</project>",
      }, "child")
      local _, _, shared_err = pom.insert_module({
        "<project>",
        "  <modules>",
        "    <module>a</module><module>b</module>",
        "  </modules>",
        "</project>",
      }, "child")

      assert.same({
        "<project>",
        "  <modules/>",
        "</project>",
      }, self_closing)
      assert.matches("self%-closing", self_err)
      assert.matches("compact", compact_err)
      assert.matches("multiple", multiple_err)
      assert.matches("sharing lines", shared_err)
    end)
  end)

  describe("project model", function()
    local function project_lines()
      return {
        "<project>",
        "  <parent>",
        "    <groupId>com.acme</groupId>",
        "    <artifactId>parent</artifactId>",
        "    <version>1.0.0</version>",
        "  </parent>",
        "  <artifactId>root</artifactId>",
        "  <packaging>pom</packaging>",
        "  <properties>",
        "    <guava.version>32.1.3-jre</guava.version>",
        "  </properties>",
        "  <modules>",
        "    <module>app</module>",
        "  </modules>",
        "  <dependencies>",
        "    <dependency>",
        "      <groupId>com.google.guava</groupId>",
        "      <artifactId>guava</artifactId>",
        "      <version>${guava.version}</version>",
        "    </dependency>",
        "    <dependency>",
        "      <groupId>com.acme</groupId>",
        "      <artifactId>helper</artifactId>",
        "      <version>${guava.version}</version>",
        "    </dependency>",
        "  </dependencies>",
        "</project>",
      }
    end

    it("models direct project fields, modules, properties, and consumers", function()
      local model, err = pom.model(project_lines())

      assert.is_nil(err)
      assert.same(
        { group_id = "com.acme", artifact_id = "root", version = "1.0.0" },
        model.coordinates
      )
      assert.same(
        { group_id = "com.acme", artifact_id = "parent", version = "1.0.0" },
        model.parent
      )
      assert.equals("pom", model.packaging)
      assert.same({ { path = "app", line = 13 } }, model.modules)
      assert.equals(2, #model.dependencies)
      assert.same(
        { "com.acme:helper", "com.google.guava:guava" },
        model.properties["guava.version"].consumers
      )
      assert.same({
        { coordinate = "com.google.guava:guava", kind = "dependency", line = 16 },
        { coordinate = "com.acme:helper", kind = "dependency", line = 21 },
      }, model.properties["guava.version"].consumer_refs)
      assert.equals("32.1.3-jre", model.properties["guava.version"].value)
      assert.equals("property", model.properties["guava.version"].kind)
    end)

    it("updates literal and property targets in one exact batch", function()
      local lines = project_lines()
      lines[24] = "      <version>1.0.0</version>"
      table.insert(lines, 24, "      <classifier>tests</classifier>")
      local model = assert(pom.model(lines))
      local helper = model.dependencies[2]
      local updated, err = pom.update_versions(lines, {
        { target = helper, new_version = "2.0.0" },
        { target = model.properties["guava.version"], new_version = "33.4.8-jre-long" },
      })

      assert.is_nil(err)
      assert.equals("    <guava.version>33.4.8-jre-long</guava.version>", updated[10])
      assert.equals("      <version>2.0.0</version>", updated[25])
      assert.equals("      <classifier>tests</classifier>", updated[24])
      assert.equals("32.1.3-jre", model.properties["guava.version"].value)
      assert.equals("    <guava.version>32.1.3-jre</guava.version>", lines[10])
    end)

    it("rejects duplicate and stale batch targets", function()
      local lines = project_lines()
      local model = assert(pom.model(lines))
      local target = model.properties["guava.version"]
      local cloned_target = vim.deepcopy(target)
      local _, duplicate_err = pom.update_versions(lines, {
        { target = target, new_version = "33.0" },
        { target = cloned_target, new_version = "34.0" },
      })
      local changed = vim.deepcopy(lines)
      changed[10] = "    <guava.version>user-edit</guava.version>"
      local unchanged, stale_err = pom.update_versions(changed, {
        { target = target, new_version = "33.0" },
      })

      assert.matches("duplicate", duplicate_err)
      assert.same(changed, unchanged)
      assert.matches("changed", stale_err)
    end)

    it("defaults packaging to jar and ignores nested properties", function()
      local model, err = pom.model({
        "<project>",
        "  <groupId>com.acme</groupId>",
        "  <artifactId>app</artifactId>",
        "  <version>1.0.0</version>",
        "  <profiles>",
        "    <profile>",
        "      <properties>",
        "        <profile.version>9.0.0</profile.version>",
        "      </properties>",
        "    </profile>",
        "  </profiles>",
        "</project>",
      })

      assert.is_nil(err)
      assert.equals("jar", model.packaging)
      assert.same({}, model.properties)
    end)

    it("rejects ambiguous root property structures and property-backed coordinates", function()
      local duplicate, duplicate_err = pom.model({
        "<project>",
        "  <groupId>com.acme</groupId>",
        "  <artifactId>app</artifactId>",
        "  <version>1.0.0</version>",
        "  <properties>",
        "    <revision>1</revision>",
        "    <revision>2</revision>",
        "  </properties>",
        "</project>",
      })
      local property_coordinates, property_err = pom.model({
        "<project>",
        "  <groupId>com.acme</groupId>",
        "  <artifactId>app</artifactId>",
        "  <version>${revision}</version>",
        "  <properties>",
        "    <revision>1.0.0</revision>",
        "  </properties>",
        "</project>",
      })

      assert.is_nil(duplicate)
      assert.matches("duplicate", duplicate_err)
      assert.is_nil(property_coordinates)
      assert.matches("property%-backed", property_err)
    end)
  end)

  describe("mvn dependency:list line parsing", function()
    local managed

    before_each(function()
      package.loaded["duke.managed"] = nil
      managed = require("duke.managed")
    end)

    it("parses a normal dependency line with compile scope", function()
      local dep =
        managed.parse_line("org.springframework.boot:spring-boot-starter-web:jar:3.5.3:compile")
      assert.is_table(dep)
      assert.equals("org.springframework.boot", dep.group_id)
      assert.equals("spring-boot-starter-web", dep.artifact_id)
      assert.equals("3.5.3", dep.version)
    end)

    it("parses a line with test scope", function()
      local dep = managed.parse_line("com.example:my-lib:jar:1.0:test")
      assert.is_table(dep)
      assert.equals("com.example", dep.group_id)
      assert.equals("my-lib", dep.artifact_id)
      assert.equals("1.0", dep.version)
    end)

    it("parses a line with runtime scope", function()
      local dep = managed.parse_line("com.example:rt:jar:2.0:runtime")
      assert.is_table(dep)
      assert.equals("com.example", dep.group_id)
      assert.equals("rt", dep.artifact_id)
      assert.equals("2.0", dep.version)
    end)

    it("parses a line with -- module name [auto] suffix", function()
      local dep = managed.parse_line(
        "org.springframework.boot:spring-boot:jar:3.5.3:compile -- module spring-boot [auto]"
      )
      assert.is_table(dep)
      assert.equals("org.springframework.boot", dep.group_id)
      assert.equals("spring-boot", dep.artifact_id)
      assert.equals("3.5.3", dep.version)
    end)

    it("parses a line with a classifier", function()
      local dep = managed.parse_line("com.example:lib:jar:tests:1.0:test")
      assert.is_table(dep)
      assert.equals("com.example", dep.group_id)
      assert.equals("lib", dep.artifact_id)
      assert.equals("1.0", dep.version)
    end)

    it("rejects garbage input", function()
      assert.is_nil(managed.parse_line(nil))
      assert.is_nil(managed.parse_line(""))
      assert.is_nil(managed.parse_line("not a maven coordinate"))
      assert.is_nil(managed.parse_line("only:three:parts"))
      assert.is_nil(managed.parse_line(":::"))
      assert.is_nil(managed.parse_line("g:a:p:"))
    end)

    it("rejects lines with empty groupId or artifactId", function()
      assert.is_nil(managed.parse_line(":artifact:jar:1.0:compile"))
      assert.is_nil(managed.parse_line("group::jar:1.0:compile"))
      assert.is_nil(managed.parse_line(":artifact::1.0"))
    end)

    it("builds a coordinate-to-version map from full output", function()
      local stdout = table.concat({
        "[INFO] The following files have been resolved:",
        "[INFO]    org.springframework.boot:spring-boot-starter-web:jar:3.5.3:compile",
        "[INFO]    org.springframework.boot:spring-boot-autoconfigure:jar:3.5.3:compile"
          .. " -- module spring-boot-autoconfigure [auto]",
        "[INFO]    com.example:custom:jar:1.0:runtime",
        "",
        "[INFO] ------------------------------------------------------------------------",
        "[INFO] BUILD SUCCESS",
      }, "\n")
      local resolved = managed.parse_output(stdout)
      assert.equals("3.5.3", resolved["org.springframework.boot:spring-boot-starter-web"])
      assert.equals("3.5.3", resolved["org.springframework.boot:spring-boot-autoconfigure"])
      assert.equals("1.0", resolved["com.example:custom"])
    end)

    it("returns an empty map for nil or non-string stdout", function()
      local result = managed.parse_output(nil)
      assert.is_table(result)
      assert.equals(0, vim.tbl_count(result))
      result = managed.parse_output(123)
      assert.is_table(result)
      assert.equals(0, vim.tbl_count(result))
    end)
  end)
end)
