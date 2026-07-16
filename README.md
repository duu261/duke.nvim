# ☕ java-scaffold.nvim

Create Maven, Gradle, and Spring Boot projects safely from Neovim, then open generated Java source or hand the project to another tool.

## ✨ Features

- Maven quickstart and web application archetypes with optional Maven Wrapper generation.
- Wrapper-backed Java, Kotlin, or Groovy Gradle applications, libraries, and Gradle plugins.
- Spring Boot Maven and Gradle projects using live Spring Initializr choices.
- Unified project generator picker plus direct workflow commands.
- Safe dependency insertion from Spring catalogs or Maven Central into an existing `pom.xml`.
- Separate project Java target and Maven or Gradle runner JVM selection.
- Private staging, target collision protection, structural POM edits, and offline metadata fallback.
- Generated Java entry opening, `User JavaScaffoldProjectCreated`, and optional post-create handoff.

## 📦 Requirements

| Tool | Needed for |
| --- | --- |
| Neovim 0.11+ | Plugin core |
| `java` | Java discovery and project workflows |
| `mvn` | Maven archetype generation and optional Maven Wrapper generation |
| `gradle` | Gradle project generation |
| `curl` | Spring requests and Maven Central dependency search |
| `tar` | Spring archive inspection and extraction |
| [Telescope](https://github.com/nvim-telescope/telescope.nvim) | Optional searchable single and multi-select pickers |
| Any external project opener | Optional post-create handoff |

Missing workflow-specific tools do not affect unrelated generators. Without Telescope, the plugin uses `vim.ui`.

Maven Central search needs network access for every query. The service may throttle requests with HTTP 429; arbitrary searches have no offline fallback.

## 🚀 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "duu261/java-scaffold.nvim",
  version = "*",
  main = "java_scaffold",
  cmd = {
    "JavaScaffoldNew",
    "JavaScaffoldMaven",
    "JavaScaffoldGradle",
    "JavaScaffoldSpring",
    "JavaScaffoldAddDependency",
    "JavaScaffoldClearCache",
    "JavaScaffoldLog",
    "JavaScaffoldHealth",
  },
  opts = {},
}
```

`version = "*"` follows tagged releases. Remove it to follow `main`.

## ⚡ Quick start

1. Install plugin and restart Neovim.
2. Run `:JavaScaffoldHealth` to load a lazy installation and check available tools.
3. Run `:JavaScaffoldNew`, then choose Maven, Gradle, or Spring Boot. Direct workflow commands remain available.
4. Choose the destination parent directory, coordinates, package, project options, Java target, and Spring dependencies when applicable. Maven also prompts for an archetype. Gradle prompts for source language and build-script DSL. Spring also prompts for project name, description, Boot version, and Maven or Gradle build type.
5. Review the final destination and selected settings, then confirm creation.

Example:

```vim
:JavaScaffoldNew
```

Enter `~/Projects` as destination and `demo` as artifact ID to create `~/Projects/demo`. Existing targets are never overwritten.

## Commands

| Command | Action |
| --- | --- |
| `:JavaScaffoldNew` | Choose Maven, Gradle, or Spring Boot, then run its wizard |
| `:JavaScaffoldMaven` | Create Maven quickstart or web application project |
| `:JavaScaffoldGradle` | Create Java, Kotlin, or Groovy Gradle application, library, or plugin |
| `:JavaScaffoldSpring` | Create Spring Boot Maven or Gradle project |
| `:JavaScaffoldAddDependency` | Add dependencies to nearest `pom.xml` from Spring catalog or Maven Central |
| `:JavaScaffoldClearCache` | Delete all cached Initializr metadata and dependency catalogs |
| `:JavaScaffoldLog` | Show internal operation log |
| `:JavaScaffoldHealth` | Load lazy plugin and run its health check |

With Telescope, use `<Tab>` to toggle dependencies and `<Enter>` to finish. Without Telescope, select dependencies one at a time through `vim.ui.select`, then choose `[Done]`.

Every generator asks for a destination parent directory, defaulting to Neovim's current working directory. A final review shows destination, coordinates, build system, Java target, runner JVM when applicable, and workflow-specific settings. Choosing `Cancel` starts no generator process.

> [!IMPORTANT]
> New Spring projects show only Boot versions offered by the configured Initializr server. On a Spring Boot `pom.xml`, `:JavaScaffoldAddDependency` reads the existing Boot version. If the server no longer supplies that old version's catalog, insertion needs a previously cached catalog from the same configured URL, a compatible custom server, or a Boot upgrade. Plain Maven poms use live Maven Central search instead.

## Configuration

Calling `setup()` is optional. Defaults:

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
    central_search_url = "https://search.maven.org/solrsearch/select",
    central_search_rows = 20,
    central_search_timeout = 15000,
    archetypes = {
      {
        name = "Maven quickstart",
        group_id = "org.apache.maven.archetypes",
        artifact_id = "maven-archetype-quickstart",
        version = "1.5",
      },
      {
        name = "Maven web application",
        group_id = "org.apache.maven.archetypes",
        artifact_id = "maven-archetype-webapp",
        version = "1.5",
      },
    },
  },
  gradle = {
    command = "gradle",
    runner_java_version = "auto", -- active Java; toolchain targets selection
    dsl = "kotlin",
    dsls = { "kotlin", "groovy" },
    languages = { "java", "kotlin", "groovy" },
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

## Java target and runner JVMs

`java_version` is project compiler or toolchain target. `"auto"` uses active Java when supported.

Maven and Gradle choices include active Java, `JDK<version>` environment variables, configured homes, and JDKs discovered under common Linux, macOS, SDKMAN, asdf, and Maven directories. A configured home is accepted only when its `bin/java -version` output matches the configured version key.

Discovery resolves duplicate JDK paths, caps each version probe at one second, and reuses one cached snapshot throughout Maven and Gradle wizards. Run `java_runtimes({ refresh = true })` after installing or removing a JDK during the current Neovim session.

`maven.runner_java_version` and `gradle.runner_java_version` select the build JVM independently from the project target. This lets modern Gradle run on a modern JVM while the generated project still targets Java 8 or 11. Runner `JAVA_HOME` and `PATH` stay scoped to the child process; global shell state never changes.

`gradle.test_framework = "auto"` uses JUnit 4 for Java 8 or 11 and JUnit Jupiter for Java 17+.

## 🛡️ Safety behavior

- Every generator builds inside a private sibling staging directory.
- The selected destination is the staging and final-project parent; changing Neovim's working directory first is optional.
- Promotion happens only after expected build files exist.
- A target appearing during generation is treated as user-owned; promotion aborts and preserves it.
- Process commands use argument lists, never shell command strings.
- Spring archives are inspected before extraction; absolute paths, parent traversal, symlinks, and hardlinks are rejected.
- POM insertion re-reads file after network requests and picker interaction.
- Only the root project dependency block is edited. Dependency management, plugins, and profiles remain untouched.
- Compact one-line or self-closing dependency XML is rejected instead of guessed.

## Spring metadata and dependency insertion

Spring name, description, package, Boot version, full-project build type, language, packaging, Java, and dependency choices are collected before creation. Initializr metadata supplies available Boot versions and Maven or Gradle project types. Unsupported active Java versions fall back to Initializr's default.

Initializr metadata, catalog, and project URLs must use HTTPS. Curl is restricted to HTTPS for both the original request and redirects.

Successful metadata and Boot-version catalogs are cached below `stdpath("cache")/java-scaffold.nvim`, separately for each configured Initializr URL. Fetch failures use a valid same-URL cache. Spring project creation still needs network access.

Run `:JavaScaffoldClearCache` when cached Initializr data becomes stale. Next metadata request fetches fresh data.

Dependency insertion exposes only entries representable by one normal Maven `<dependency>` block. Entries requiring BOM import, custom repository, or annotation-processor wiring stay hidden. Those entries remain available during new Spring project creation, where Initializr can generate complete Maven configuration.

For a plain Maven pom, `:JavaScaffoldAddDependency` prompts for a Maven Central query and shows `groupId:artifactId` plus latest version. Selecting one artifact opens a newest-first version picker defaulted to that latest version. Multi-select keeps each artifact's latest version. Malformed result rows are skipped without discarding valid neighbors, and `pom` artifacts remain excluded. Ranking comes from Maven Central. Rerun the command to refine a query. Search has no cache or offline fallback.

No Boot versions are hardcoded into the picker. Old-version lookup happens only when the dependency command reads an existing `pom.xml`.

## After creation

Without handoff, the plugin opens generated application Java source when available, then falls back to a build file. Opening Java naturally triggers the user's normal filetype or JDTLS setup. The plugin does not configure JDTLS.

Successful creation emits `User JavaScaffoldProjectCreated` with `data.project_dir` and `data.entry_file`.

Optional handoff invokes any external project opener:

```lua
handoff = {
  enabled = true,
  command = { "project-opener", "{project}" },
  required_executables = { "project-opener" },
}
```

`{project}` and `{file}` placeholders expand before launch. Without placeholders, project path is appended. Handoff stays disabled by default. Failure falls back to opening project inside current Neovim.

## Lua API

`require("java_scaffold").new()` opens the unified generator picker. `new_maven()`, `new_gradle()`, and `new_spring()` start individual wizards directly. `clear_cache()` deletes all cached Initializr metadata and returns `true` on success.

`require("java_scaffold").java_runtimes(opts)` returns discovered JDK homes for plugin or editor integration:

```lua
{
  active = "23",
  homes = { ["23"] = "/path/to/jdk-23" },
}
```

Results stay cached until `setup()` runs or `java_runtimes({ refresh = true })` requests fresh discovery. The returned table is a deep copy.

`require("java_scaffold").select_runtime(opts)` selects eligible JDK without changing environment or launching it:

```lua
local runtime = require("java_scaffold").select_runtime({
  min_version = 21,
  prefer_active = true,
})
-- { version = "23", home = "/path/to/jdk-23", executable = "/path/to/jdk-23/bin/java" }
```

Active Java wins when eligible and `prefer_active` is not `false`; otherwise the lowest eligible discovered version wins. The function returns `nil` when none exists.

## Scope and limits

V1 owns Maven, Gradle, and Spring project creation plus dependency insertion into Maven poms from Spring catalogs or Maven Central.

The plugin deliberately does not run applications, format code, execute tests, edit Gradle dependencies, or manage JDTLS. Existing tools remain responsible for those jobs.

## 🩺 Troubleshooting

1. Run `:JavaScaffoldHealth`. Use this command instead of direct `:checkhealth java_scaffold` when lazy-loaded plugin has not loaded yet.
2. Run `:JavaScaffoldLog` for process arguments and detailed failure context.
3. Check the executable required by the selected workflow.
4. For old-Boot catalog rejection, use same-URL cache, compatible custom Initializr server, or upgrade Boot.
5. Ensure custom Initializr URLs use HTTPS.
6. Retry Maven Central search after a reported timeout or HTTP 429 rate limit; no offline search cache exists.
7. If promotion reports an existing target, choose another artifact ID or move the user-created target.

## Local development

Use local checkout with lazy.nvim:

```lua
{
  dir = "~/Projects/java-scaffold.nvim",
  name = "java-scaffold.nvim",
  main = "java_scaffold",
  opts = {},
}
```

Run gates:

```sh
make test
make lint
```

See [CHANGELOG.md](CHANGELOG.md) for release history. Run `:help java-scaffold` for vimdoc.

## License

Copyright (C) 2026 duu261. Licensed under GPL-3.0-or-later. See [LICENSE](LICENSE).
