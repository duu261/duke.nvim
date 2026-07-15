# java-scaffold.nvim

Create Maven, Gradle, and Spring Boot projects, add Spring dependencies, and open the generated project or Java source without leaving Neovim.

## Requirements

- Neovim 0.11+
- `java`
- `mvn` for Maven projects
- `gradle` for Gradle projects
- `curl` and GNU `tar` for Spring Initializr
- Optional: Telescope for searchable pickers
- Optional: any project handoff command

## Installation

Local checkout with lazy.nvim:

```lua
{
  dir = "~/Projects/java-scaffold.nvim",
  name = "java-scaffold.nvim",
  cond = vim.fn.isdirectory(vim.fn.expand("~/Projects/java-scaffold.nvim")) == 1,
  opts = {},
}
```

GitHub installation after publishing:

```lua
{
  "duu261/java-scaffold.nvim",
  opts = {},
}
```

## Configuration

Defaults:

```lua
require("java_scaffold").setup({
  group_id = "com.example",
  artifact_id = "demo",
  java_version = "auto", -- active user JDK when supported
  java_versions = {}, -- extra choices for Maven/Gradle projects
  java_homes = {}, -- optional version-to-JDK-home map
  entry_selector = nil, -- optional function(project_dir, detected_entry)
  maven = {
    command = "mvn",
    runner_java_version = "auto", -- active Java; separate from project target
    wrapper = false, -- generate Maven Wrapper before project promotion
    project_version = "1.0-SNAPSHOT",
    timeout = 180000,
    archetype = {
      group_id = "org.apache.maven.archetypes",
      artifact_id = "maven-archetype-quickstart",
      version = "1.5",
    },
  },
  gradle = {
    command = "gradle",
    runner_java_version = "auto", -- active Java; toolchain targets selection
    dsl = "kotlin",
    test_framework = "auto", -- JUnit 4 for Java 8/11; Jupiter for 17+
    timeout = 180000,
    default_project_type = "java-application",
    project_types = {
      { id = "java-application", name = "Java application" },
      { id = "java-library", name = "Java library" },
      { id = "java-gradle-plugin", name = "Gradle plugin" },
    },
  },
  spring = {
    metadata_url = "https://start.spring.io",
    dependencies_url = "https://start.spring.io/dependencies",
    starter_url = "https://start.spring.io/starter.tgz",
    project_type = "maven-project",
    language = "java",
    packaging = "jar",
    metadata_timeout = 30000,
    timeout = 60000,
  },
  handoff = {
    enabled = false,
    command = nil, -- project path is appended to this argv list
    required_executables = {},
  },
})
```

`java_version = "auto"` selects the project compiler/toolchain target and defaults to the active Java version. Maven and Gradle choices include active Java, `JDK<version>` environment variables, configured homes, and JDKs discovered under common Linux, macOS, SDKMAN, asdf, and Maven directories. A configured home is accepted only when its `bin/java -version` output matches the configured version key.

Build JVM selection stays independent through each workflow's `runner_java_version`. This lets Gradle run on a modern JVM while targeting Java 8 or 11. Known runner homes become scoped `JAVA_HOME` and `PATH` values; global shell state stays unchanged. Wrappers may override `JAVA_HOME`, so health checks and project creation report the detected runner Java.

Spring choices come from Initializr metadata for the selected Boot version. Unsupported active Java versions fall back to Initializr's default.

## Public API

`require("java_scaffold").setup(opts)` applies configuration and clears cached runtime discovery. Calling `setup()` is optional.

`require("java_scaffold").java_runtimes(opts)` exposes the same JDK discovery used by the plugin:

```lua
{
  active = "23",
  homes = { ["23"] = "/path/to/jdk-23" },
}
```

Results stay cached until `setup()` runs or `java_runtimes({ refresh = true })` requests fresh discovery. Each call returns a deep copy, so caller changes cannot mutate the cache.

`require("java_scaffold").select_runtime(opts)` selects one discovered JDK and returns its version, home, and Java executable:

```lua
local runtime = require("java_scaffold").select_runtime({
  min_version = 21,
  prefer_active = true,
})
-- { version = "23", home = "/path/to/jdk-23", executable = "/path/to/jdk-23/bin/java" }
```

`prefer_active` defaults to `true`. When active Java is unavailable or below `min_version`, the lowest eligible discovered version is selected. The function returns `nil` when no eligible JDK home exists.

## Project coverage

- Maven quickstart: conventional console project and tests; optional Maven Wrapper generation
- Gradle: Java application, library, or Gradle plugin; Kotlin DSL; JUnit 4 for Java 8/11 and Jupiter for 17+
- Spring Boot: Boot versions, Java versions, and dependencies supplied by Initializr metadata
- Existing Spring project: safe direct dependency insertion into nearest root `pom.xml`

## Usage

| Command | Action |
| --- | --- |
| `:JavaScaffoldMaven` | Create Maven quickstart project |
| `:JavaScaffoldGradle` | Create Gradle application, library, or plugin |
| `:JavaScaffoldSpring` | Create Spring Boot project |
| `:JavaScaffoldAddDependency` | Add Spring dependencies to nearest `pom.xml` |
| `:JavaScaffoldLog` | Show internal operation log |
| `:JavaScaffoldHealth` | Load the plugin and run its health check |

Creation runs in the current working directory. Each generator builds inside a private staging directory, validates expected build files, then promotes the finished project without deleting an existing target. Wizards prompt for coordinates and Java, plus project type for Gradle or dependencies for Spring.

With `maven.wrapper = true`, Maven runs `wrapper:wrapper` inside staging. Promotion requires `mvnw`, `mvnw.cmd`, and `.mvn/wrapper/maven-wrapper.properties`.

Without handoff, the plugin opens generated application source when available. This triggers the existing Java filetype or JDTLS setup; the plugin does not manage JDTLS. Successful creation emits `User JavaScaffoldProjectCreated` with `data.project_dir` and `data.entry_file`.

Optional handoff can invoke any external project opener:

```lua
handoff = {
  enabled = true,
  command = { "project-opener", "{project}" },
  required_executables = { "project-opener" },
}
```

Replace `project-opener` with an available command. `{project}` and `{file}` placeholders are expanded. Without placeholders, project path is appended for compatibility. Successful creation above calls:

```text
project-opener /absolute/project/path
```

When handoff is disabled or fails, project opens in current Neovim.

## Offline metadata

Successful Initializr responses are cached under `stdpath("cache")/java-scaffold.nvim`, separately for each configured Initializr URL. Fetch failures fall back to cached project metadata and Boot-version dependency coordinates. Project creation still needs network access; cached coordinates keep supported POM insertion working offline.

Initializr may stop serving dependency catalogs for old Spring Boot versions. Insertion for such a project requires a catalog for that Boot version cached earlier from the same configured Initializr URL. Without that cache, the Initializr rejection is reported. Upgrade the project or configure an Initializr server that still supplies the catalog.

The plugin does not add unsupported Boot versions to new-project choices or bypass Initializr compatibility rules. Old-version lookup happens only when `:JavaScaffoldAddDependency` reads that version from an existing `pom.xml`.

## Dependency insertion limits

V1 inserts only Initializr dependencies representable by one normal Maven `<dependency>` block. Entries requiring a BOM import, custom repository, or annotation-processor/plugin wiring are hidden because direct insertion would create a broken build. They remain available during Spring project creation, where Initializr generates the required Maven configuration.

Run `:checkhealth java_scaffold` when something fails. Health checks verify configured JDK versions and report only nvim-jdtls module availability.

## Development

```sh
make test
make lint
```

## License

Copyright (C) 2026 duu261. Licensed under GPL-3.0-or-later. See
[LICENSE](LICENSE).
