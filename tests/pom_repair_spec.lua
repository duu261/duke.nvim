describe("POM repair", function()
  local repair

  before_each(function()
    package.loaded["duke.pom_repair"] = nil
    repair = require("duke.pom_repair")
  end)

  local function pom_lines()
    return {
      "<project>",
      "  <groupId>com.acme</groupId>",
      "  <artifactId>app</artifactId>",
      "  <version>1.0.0</version>",
      "  <properties>",
      "    <library.version>1.0.0</library.version>",
      "  </properties>",
      "  <dependencyManagement>",
      "    <dependencies>",
      "      <dependency>",
      "        <groupId>com.acme</groupId>",
      "        <artifactId>platform-bom</artifactId>",
      "        <version>1.0.0</version>",
      "        <type>pom</type>",
      "        <scope>import</scope>",
      "      </dependency>",
      "    </dependencies>",
      "  </dependencyManagement>",
      "  <dependencies>",
      "    <dependency>",
      "      <groupId>com.acme</groupId>",
      "      <artifactId>starter</artifactId>",
      "      <version>${library.version}</version>",
      "    </dependency>",
      "    <dependency>",
      "      <groupId>com.acme</groupId>",
      "      <artifactId>literal</artifactId>",
      "      <version>1.0.0</version>",
      "    </dependency>",
      "  </dependencies>",
      "</project>",
    }
  end

  it("applies literal, property, and imported BOM upgrades exactly", function()
    local after, changes = repair.apply(pom_lines(), {
      {
        kind = "upgrade",
        target = {
          kind = "property",
          property = "library.version",
          requested_version = "1.0.0",
          consumers = { "com.acme:starter" },
        },
        new_version = "2.0.0",
      },
      {
        kind = "upgrade",
        target = {
          kind = "imported_bom",
          owner_coordinate = "com.acme:platform-bom",
          requested_version = "1.0.0",
        },
        new_version = "2.1.0",
      },
      {
        kind = "upgrade",
        target = {
          kind = "dependency",
          owner_coordinate = "com.acme:literal",
          requested_version = "1.0.0",
        },
        new_version = "3.0.0",
      },
    })

    assert.equals("    <library.version>2.0.0</library.version>", after[6])
    assert.equals("        <version>2.1.0</version>", after[13])
    assert.equals("      <version>3.0.0</version>", after[28])
    assert.equals(3, #changes)
  end)

  it("inserts one exact transitive exclusion and treats duplicates as no-op", function()
    local after, changes = repair.apply(pom_lines(), {
      {
        kind = "exclude",
        direct_coordinate = "com.acme:starter",
        excluded_coordinate = "com.acme:legacy",
      },
    })

    assert.same({
      "      <exclusions>",
      "        <exclusion>",
      "          <groupId>com.acme</groupId>",
      "          <artifactId>legacy</artifactId>",
      "        </exclusion>",
      "      </exclusions>",
    }, vim.list_slice(after, 24, 29))
    assert.equals("exclude", changes[1].kind)

    local unchanged, duplicate_changes = repair.apply(after, {
      {
        kind = "exclude",
        direct_coordinate = "com.acme:starter",
        excluded_coordinate = "com.acme:legacy",
      },
    })
    assert.same(after, unchanged)
    assert.same({}, duplicate_changes)
  end)

  it("refuses blocked owners, unsafe properties, ambiguity, and overlap", function()
    local lines = pom_lines()
    local _, _, blocked = repair.apply(lines, {
      {
        kind = "upgrade",
        target = { kind = "external_parent", writable = false },
        new_version = "2.0.0",
      },
    })
    assert.matches("not writable", blocked)

    local _, _, shared = repair.apply(lines, {
      {
        kind = "upgrade",
        target = {
          kind = "property",
          property = "library.version",
          requested_version = "1.0.0",
          other_consumers = { { kind = "other", line = 4 } },
        },
        new_version = "2.0.0",
      },
    })
    assert.matches("other consumers", shared)

    local duplicate = vim.deepcopy(lines)
    local duplicate_block = {
      "    <dependency>",
      "      <groupId>com.acme</groupId>",
      "      <artifactId>literal</artifactId>",
      "      <version>1.0.0</version>",
      "    </dependency>",
    }
    for index, line in ipairs(duplicate_block) do
      table.insert(duplicate, 30 + index - 1, line)
    end
    local _, _, ambiguous = repair.apply(duplicate, {
      {
        kind = "upgrade",
        target = { kind = "dependency", owner_coordinate = "com.acme:literal" },
        new_version = "2.0.0",
      },
    })
    assert.is_string(ambiguous)

    local _, _, overlap = repair.apply(lines, {
      {
        kind = "upgrade",
        target = { kind = "dependency", owner_coordinate = "com.acme:literal" },
        new_version = "2.0.0",
      },
      {
        kind = "upgrade",
        target = { kind = "dependency", owner_coordinate = "com.acme:literal" },
        new_version = "3.0.0",
      },
    })
    assert.matches("overlap", overlap)

    local _, _, unsafe = repair.apply(lines, {
      {
        kind = "upgrade",
        target = { kind = "dependency", owner_coordinate = "com.acme:literal" },
        new_version = "2.0.0</version>",
      },
    })
    assert.matches("non%-empty token", unsafe)
  end)
end)
