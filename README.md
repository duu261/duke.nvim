# ☕ duke.nvim

Safely scaffold Maven, Gradle, and Spring Boot projects in Neovim, manage Maven dependencies, then open generated Java source or hand the project to another tool.

## ✨ Features

- Guided Maven, Gradle, and Spring Boot wizards with destination, coordinates, package, Java, workflow-specific choices, and final review.
- Maven quickstart and web application archetypes with optional Maven Wrapper generation.
- Wrapper-backed Java, Kotlin, or Groovy Gradle applications, libraries, and plugins using Kotlin or Groovy build scripts.
- Spring Boot Maven and Gradle projects using Initializr-provided metadata and dependency choices.
- Safe Maven dependency add, upgrade, outdated inspection, and removal workflows, with installed markers in add pickers.
- Separate project Java target and Maven or Gradle runner JVM selection.
- Private staging, target collision protection, structural POM edits, and offline metadata fallback.
- Telescope or native `vim.ui` pickers, including multi-select dependency workflows.
- Generated Java entry opening, `User DukeProjectCreated`, and optional post-create handoff.

Focused scope: project creation and Maven dependency lifecycle management. The plugin does not run, format, or test projects, edit Gradle dependencies, or manage JDTLS.

## 📦 Requirements

Plugin core:

| Tool | Needed for |
| --- | --- |
| Neovim 0.11+ | Plugin core |

Workflow tools:

| Tool | Needed for |
| --- | --- |
| `java` | Java discovery and project workflows |
| `mvn` | Maven archetype generation and optional Maven Wrapper generation |
| `gradle` | Gradle project generation |
| `curl` | Spring requests and Maven Central dependency search or version lookup |
| `tar` | Spring archive inspection and extraction |

Optional integrations:

| Tool | Adds |
| --- | --- |
| [Telescope](https://github.com/nvim-telescope/telescope.nvim) | Optional searchable single and multi-select pickers |
| Any external project opener | Optional post-create handoff |

Missing workflow-specific tools do not affect unrelated generators. Without Telescope, the plugin uses `vim.ui`. Existing Java filetype or JDTLS setup can activate when generated Java source opens, but neither is required or managed by this plugin.

Maven Central search and version lookup need network access for every query. The service may throttle requests with HTTP 429; arbitrary searches have no offline fallback.

## 🚀 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "duu261/duke.nvim",
  version = "*",
  main = "duke",
  cmd = {
    "DukeNew",
    "DukeMaven",
    "DukeGradle",
    "DukeSpring",
    "DukeAdd",
    "DukeUpgrade",
    "DukeOutdated",
    "DukeRemove",
    "DukeClearCache",
    "DukeLog",
    "DukeHealth",
  },
  opts = {},
}
```

`version = "*"` follows tagged releases. Remove it to follow `main`.

## ⚡ Quick start

1. Install plugin and restart Neovim.
2. Run `:DukeHealth` to load a lazy installation and check available tools.
3. Run `:DukeNew`, then choose Maven, Gradle, or Spring Boot. Direct workflow commands remain available.
4. Choose the destination parent directory, coordinates, package, project options, Java target, and Spring dependencies when applicable. Maven also prompts for an archetype. Gradle prompts for source language and build-script DSL. Spring also prompts for project name, description, Boot version, and Maven or Gradle build type.
5. Review the final destination and selected settings, then confirm creation.

Example:

```vim
:DukeNew
```

Enter `~/Projects` as destination and `demo` as artifact ID to create `~/Projects/demo`. Existing targets are never overwritten.

## Commands

| Command | Action |
| --- | --- |
| `:DukeNew` | Choose Maven, Gradle, or Spring Boot, then run its wizard |
| `:DukeMaven` | Create Maven quickstart or web application project |
| `:DukeGradle` | Create Java, Kotlin, or Groovy Gradle application, library, or plugin |
| `:DukeSpring` | Create Spring Boot Maven or Gradle project |
| `:DukeAdd` | Add dependencies to nearest `pom.xml` from Spring catalog or Maven Central |
| `:DukeUpgrade` | Update one explicit root dependency version from Maven Central |
| `:DukeOutdated` | Compare literal root dependency versions with Maven Central |
| `:DukeRemove` | Remove selected root dependencies after confirmation |
| `:DukeClearCache` | Delete all cached Initializr metadata and dependency catalogs |
| `:DukeLog` | Show internal operation log |
| `:DukeHealth` | Load lazy plugin and run its health check |

With Telescope, use `<Tab>` to toggle add or removal choices and `<Enter>` to finish. Without Telescope, select dependencies one at a time through `vim.ui.select`, then choose `[Done]`. Updates select one dependency per run.

Every generator asks for a destination parent directory, defaulting to Neovim's current working directory. A final review shows destination, coordinates, build system, Java target, runner JVM when applicable, and workflow-specific settings. Choosing `Cancel` starts no generator process.

> [!IMPORTANT]
> New Spring projects show only Boot versions offered by the configured Initializr server. On a Spring Boot `pom.xml`, `:DukeAdd` reads the existing Boot version. If the server no longer supplies that old version's catalog, insertion needs a previously cached catalog from the same configured URL, a compatible custom server, or a Boot upgrade. Plain Maven poms use live Maven Central search instead.

## Configuration

Calling `setup()` is optional. Defaults:

```lua
require("duke").setup({
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
- Every POM edit re-reads the file after network requests and picker interaction. Changed selections abort the operation.
- Only the root project dependency block is edited. Dependency management, plugins, and profiles remain untouched.
- Compact one-line or self-closing project, dependencies, or dependency XML is rejected instead of guessed.

## Spring metadata and Maven dependency lifecycle

Spring name, description, package, Boot version, full-project build type, language, packaging, Java, and dependency choices are collected before creation. Initializr metadata supplies available Boot versions and Maven or Gradle project types. Unsupported active Java versions fall back to Initializr's default.

Initializr metadata, catalog, and project URLs must use HTTPS. Curl is restricted to HTTPS for both the original request and redirects.

Successful metadata and Boot-version catalogs are cached below `stdpath("cache")/duke.nvim`, separately for each configured Initializr URL. Fetch failures use a valid same-URL cache. Spring project creation still needs network access.

Run `:DukeClearCache` when cached Initializr data becomes stale. Next metadata request fetches fresh data.

Dependency insertion exposes only entries representable by one normal Maven `<dependency>` block. Entries requiring BOM import, custom repository, or annotation-processor wiring stay hidden. Those entries remain available during new Spring project creation, where Initializr can generate complete Maven configuration. Spring catalog and Maven Central add pickers mark root dependencies already present in the current POM with `[installed]`; marked rows remain selectable, and structural duplicate detection remains the write guard.

For a plain Maven pom, `:DukeAdd` prompts for a Maven Central query and shows `groupId:artifactId` plus latest version. Selecting one artifact opens a newest-first version picker defaulted to that latest version, then a scope picker with `compile` as the default and `test`, `provided`, or `runtime` as alternatives. Compile scope emits no `<scope>` element. Multi-select keeps each artifact's latest version and compile scope without another prompt. Malformed result rows are skipped without discarding valid neighbors, and `pom` artifacts remain excluded. Ranking comes from Maven Central. Rerun the command to refine a query. Search has no cache or offline fallback.

`:DukeUpgrade` lists root dependencies with explicit `<version>` elements and updates one per run from Maven Central's newest-first version list. The current version is marked; selecting it is a no-op. Managed dependencies without a version are hidden with a count notice. Property-backed versions such as `${library.version}` are listed but rejected with the property name because property editing is outside plugin scope. Only version text changes; scope, type, classifier, exclusions, comments, and formatting stay untouched.

`:DukeOutdated` checks root dependencies with literal explicit versions sequentially against Maven Central and lists `current -> latest` rows. Managed and property-backed versions are skipped with counts. Any lookup error, including a timeout or HTTP 429, stops further lookups but keeps gathered rows and reports how many dependencies were not checked. Selecting a row enters the same single-dependency version picker and stale-file-safe write path as `:DukeUpgrade`; canceling leaves the POM untouched.

`:DukeRemove` lists all root dependencies, including managed ones, and supports multi-select. A mandatory confirmation names every selected coordinate. Declining or canceling changes nothing. Removal deletes complete dependency blocks but keeps the root `<dependencies>` container, sibling blocks, comments, and surrounding blank-line formatting.

No Boot versions are hardcoded into the picker. Old-version lookup happens only when the dependency command reads an existing `pom.xml`.

## After creation

Without handoff, the plugin opens generated application Java source when available, then falls back to a build file. Opening Java naturally triggers the user's normal filetype or JDTLS setup. The plugin does not configure JDTLS.

Successful creation emits `User DukeProjectCreated` with `data.project_dir` and `data.entry_file`.

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

`require("duke").new()` opens the unified generator picker. `new_maven()`, `new_gradle()`, and `new_spring()` start individual wizards directly. `add_dependency()`, `update_dependency()`, `outdated_dependencies()`, and `remove_dependency()` start the same nearest-`pom.xml` workflows as their commands. `clear_cache()` deletes all cached Initializr metadata and returns `true` on success.

`require("duke").java_runtimes(opts)` returns discovered JDK homes for plugin or editor integration:

```lua
{
  active = "23",
  homes = { ["23"] = "/path/to/jdk-23" },
}
```

Results stay cached until `setup()` runs or `java_runtimes({ refresh = true })` requests fresh discovery. The returned table is a deep copy.

`require("duke").select_runtime(opts)` selects eligible JDK without changing environment or launching it:

```lua
local runtime = require("duke").select_runtime({
  min_version = 21,
  prefer_active = true,
})
-- { version = "23", home = "/path/to/jdk-23", executable = "/path/to/jdk-23/bin/java" }
```

Active Java wins when eligible and `prefer_active` is not `false`; otherwise the lowest eligible discovered version wins. The function returns `nil` when none exists.

## Scope and limits

V1 owns Maven, Gradle, and Spring project creation plus root-level Maven dependency add, upgrade, outdated inspection, and removal workflows.

The plugin deliberately does not run applications, format code, execute tests, edit Gradle dependencies, or manage JDTLS. Existing tools remain responsible for those jobs.

## 🩺 Troubleshooting

1. Run `:DukeHealth`. Use this command instead of direct `:checkhealth duke` when lazy-loaded plugin has not loaded yet.
2. Run `:DukeLog` for process arguments and detailed failure context.
3. Check the executable required by the selected workflow.
4. For old-Boot catalog rejection, use same-URL cache, compatible custom Initializr server, or upgrade Boot.
5. Ensure custom Initializr URLs use HTTPS.
6. Retry Maven Central search after a reported timeout or HTTP 429 rate limit; no offline search cache exists.
7. If promotion reports an existing target, choose another artifact ID or move the user-created target.

## Local development

Use local checkout with lazy.nvim:

```lua
{
  dir = "~/Projects/duke.nvim",
  name = "duke.nvim",
  main = "duke",
  opts = {},
}
```

Run gates:

```sh
make test
make lint
```

See [CHANGELOG.md](CHANGELOG.md) for release history. Run `:help duke` for vimdoc.

## License

Copyright (C) 2026 duu261. Licensed under GPL-3.0-or-later. See [LICENSE](LICENSE).
