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
end)
