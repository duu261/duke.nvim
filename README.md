# ☕ duke.nvim

> `cargo new` + `cargo add` for the JVM, inside Neovim.

Safely scaffold Maven, Gradle, and Spring Boot projects, understand existing Java workspaces, manage Maven dependencies, grow multi-module reactors, then open generated Java source or hand the project to another tool.

> **Built with GPT-5.6 through Codex CLI for OpenAI Build Week.** [See how Codex and I collaborated](#built-with-codex).

[Watch the 2:42 demo](https://www.youtube.com/watch?v=FvqIwBG7PMg) | [OpenAI Build Week submission](https://devpost.com/software/duke-nvim)

- [Features](#features)
- [Built with Codex](#built-with-codex)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Judge testing path](#judge-testing-path)
- [Commands](#commands)
- [Configuration](#configuration)
- [Java target and runner JVMs](#java-target-and-runner-jvms)
- [Safety behavior](#safety-behavior)
- [Project Center](#project-center)
- [Spring metadata and Maven dependency lifecycle](#spring-metadata-and-maven-dependency-lifecycle)
- [After creation](#after-creation)
- [Lua API](#lua-api)
- [Scope and limits](#scope-and-limits)
- [FAQ](#faq)
- [Troubleshooting](#troubleshooting)
- [Local development](#local-development)
- [License](#license)

## ✨ Features

- Native Maven, Gradle, and Spring Boot Creation Center with persistent fields, visible validation, Java runtime status, and Spring dependency selection.
- Native Project Center for Maven reactors and Gradle workspaces, with modules, direct dependencies, Spring configuration files, diagnostics, navigation, and explicit wrapper-backed refresh.
- Maven Doctor diagnoses reactor-wide version drift, conflicts, duplicate declarations, ownership, and dependency usage, then stages reviewable multi-POM repairs.
- Maven quickstart and web application archetypes with optional Maven Wrapper generation.
- Wrapper-backed Java, Kotlin, or Groovy Gradle applications, libraries, and plugins using Kotlin or Groovy build scripts.
- Spring Boot Maven and Gradle projects using Initializr-provided metadata and dependency choices.
- Safe Maven dependency add, upgrade, outdated inspection, and removal workflows, with installed markers in add pickers.
- Managed dependency version resolution through `mvn dependency:list` for `:DukeOutdated` and `:DukeUpgrade`; dependencies controlled by a parent or BOM show their resolved version instead of being hidden or skipped.
- `:DukeTree` shows the resolved Maven dependency tree, while `:DukeWhy` isolates the paths that pull in a direct or transitive artifact and shows the version Maven selected.
- Existing-project Maven inspection prefers an executable `mvnw` found beside or above the selected `pom.xml`, then falls back to the configured Maven command.
- `:DukeInfo [groupId:artifactId]` shows latest and recent versions with release dates from Maven Central in a read-only scratch buffer.
- `:DukeBootUpgrade` detects Spring Boot versions from parent POMs and from `spring-boot-dependencies` BOM imports in `<dependencyManagement>`, with BOM upgrades deferred.
- Version pickers show Maven Central release dates and name the selected dependency in follow-up prompts.
- Add a module to an existing Maven multi-module reactor with parent-first, rollback-safe promotion.
- Session-scoped multi-dependency Maven upgrade plans with exact before/after preview, shared-property impact, stale-source rejection, and one transactional apply.
- Separate project Java target and Maven or Gradle runner JVM selection.
- Private staging, target collision protection, structural POM edits that stay one-line reviewable diffs, and offline metadata fallback.
- Telescope or native `vim.ui` pickers, including visible multi-select counts and Java LTS markers.
- Generated Java entry opening, `User DukeProjectCreated`, and optional post-create handoff.

Focused scope: project creation, Java build-workspace intelligence, and safe Maven dependency lifecycle management. Duke complements Java language tooling such as [nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls) and [nvim-java](https://github.com/nvim-java/nvim-java); it does not run, format, or test projects, edit Gradle dependencies, edit Spring configuration values, or manage JDTLS.

## Built with Codex

I built duke.nvim with GPT-5.6 through Codex CLI during OpenAI Build Week. I supplied the product direction, Java and Neovim workflow, safety invariants, scope decisions, and release authorization. Codex accelerated implementation, edge-case investigation, test construction, documentation synchronization, live Neovim verification, and release checks.

Important human decisions included making safe Maven mutation the product's center, keeping Gradle dependency editing out until it can meet the same safety bar, leaving JDTLS management to existing tools, and requiring explicit confirmation before interactive writes. Codex implemented and verified the safe POM engine, dependency lifecycle, multi-module transaction, stable Lua interface, and interactive workflows under those constraints.

Codex's strict rule-following was valuable for file safety and release discipline, but it also taught me to separate true invariants from workflow preferences. Tests, live disposable projects, exact diffs, and CI remained the evidence for every completion claim. See the [project story](PROJECT-STORY.md) for the fuller collaboration and design history.

## 📦 Requirements

Supported editor: Neovim 0.11 or newer. CI verifies Neovim 0.11.0, stable, and nightly on Linux. The pure Lua plugin may work elsewhere when the required external tools are available, but macOS and Windows are not currently CI-verified.

Plugin core:

| Tool | Needed for |
| --- | --- |
| Neovim 0.11+ | Plugin core |

Workflow tools:

| Tool | Needed for |
| --- | --- |
| `java` | Java discovery and project workflows |
| `mvn` | Maven generation, managed version resolution, dependency insight, and Maven Doctor |
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
{ "duu261/duke.nvim", version = "*", opts = {} }
```

`version = "*"` follows tagged releases. Remove it to follow `main`. See [lazy.lua](lazy.lua) for the full command-lazy-loading spec.

## ⚡ Quick start

1. Install plugin and restart Neovim.
2. Run `:DukeHealth` to load a lazy installation and check available tools.
3. Run `:DukeNew`. Creation Center opens with Maven, Gradle, and Spring Boot choices plus every project field in one persistent view. Direct workflow commands open the same view with their generator preselected.
4. Move with `j`/`k`, press `<Enter>` to edit a field, and use `<Tab>` to move between logical sections. Spring dependencies open inside the same window.
5. Press `c` when validation passes, review the visible settings, then confirm creation.

Example:

```vim
:DukeNew
```

Enter `~/Projects` as destination and `demo` as artifact ID to create `~/Projects/demo`. Existing targets are never overwritten.

Inside an existing Maven or Gradle project, run `:Duke` instead. Project Center opens immediately from local files without running the build. Press `r` only when you want wrapper-backed dependency resolution.

Inside a Maven workspace, run `:DukeDoctor` for explicit reactor diagnosis. `:DukeDoctor!` adds deep dependency usage analysis after confirmation; Maven may compile main and test sources for that report.

## Judge testing path

No source build is required. Install the latest tagged release with the lazy.nvim snippet above. The shortest interactive path needs Neovim 0.11+, `java`, `mvn`, `curl`, and network access.

1. Run `:DukeHealth` and confirm Java, Maven, and curl are available.
2. Open an existing Maven or Gradle project and run `:Duke`. Confirm modules and Spring configuration files appear immediately. Press `r` to opt into wrapper-backed resolution; opening the panel alone runs no build tool.
3. Run `:DukeMaven` from a disposable parent directory. Choose the Maven quickstart archetype, enter temporary coordinates such as `com.example:duke-demo`, review the destination, and confirm.
4. Open the generated `pom.xml`, run `:DukeAdd`, search for `guava`, select `com.google.guava:guava`, choose a version and compile scope, review the exact coordinate, and confirm.
5. Inspect the resulting POM. The plugin adds one root dependency block without reformatting unrelated content.
6. Run `:DukeInfo com.google.guava:guava` to inspect current Maven Central version information without changing the project.
7. Run `:DukeTree` to inspect the resolved classpath, then `:DukeWhy com.google.guava:failureaccess` to show why Guava's transitive dependency is present.
8. Run `:DukeRemove`, select the added dependency, and cancel once to verify that cancellation leaves the POM unchanged. Run it again and confirm to remove the dependency.

For repository verification instead of the interactive path, clone the repository and run `make format`, `make lint`, and `make test`. GitHub CI runs lint plus tests against the exact Neovim 0.11 floor, stable, and nightly.

## Commands

| Command | Action |
| --- | --- |
| `:Duke` | Open Project Center inside Maven or Gradle workspaces; show command help elsewhere |
| `:DukeDoctor[!]` | Diagnose a Maven reactor; `!` confirms deep analysis that may compile test sources |
| `:DukeNew` | Open Creation Center with Maven, Gradle, and Spring Boot choices |
| `:DukeMaven` | Create Maven quickstart or web application project |
| `:DukeGradle` | Create Java, Kotlin, or Groovy Gradle application, library, or plugin |
| `:DukeSpring` | Create Spring Boot Maven or Gradle project |
| `:DukeModule` | Add a module to the current working directory's Maven reactor |
| `:DukeAdd` | Add dependencies to nearest `pom.xml` from Spring catalog or Maven Central |
| `:DukeUpgrade` | Update one root dependency version from Maven Central; managed deps notify about Boot upgrade |
| `:DukeBootUpgrade` | Upgrade the Spring Boot parent `<version>` from Maven Central |
| `:DukeOutdated` | Compare root dependency versions with Maven Central; resolves managed versions |
| `:DukeRemove` | Remove selected root dependencies after confirmation |
| `:DukeTree` | Show the resolved Maven dependency tree and selected versions |
| `:DukeWhy [groupId:artifactId]` | Show the path that pulls a dependency into the project |
| `:DukeInfo` | Show Maven Central versions and release dates for a coordinate |
| `:DukeClearCache` | Delete all cached Initializr metadata and dependency catalogs |
| `:DukeLog` | Show internal operation log |
| `:DukeHealth` | Load lazy plugin and run its health check |

With Telescope, use `<Tab>` to toggle add or removal choices and `<Enter>` to finish. Without Telescope, select dependencies one at a time through `vim.ui.select`, then choose the `[Done - N selected]` row. Both paths show the current selection count. Updates select one dependency per run.

Creation Center uses one state model for every generator. `creation.layout = "auto"` gives normal editors a large centered float and editors below 100 columns or 28 lines a single-column scratch buffer in the current window. Use `"wide"` or `"compact"` to keep one presentation. Cancel restores the original buffer, view, cursor, and working directory without clearing newer unsaved changes.

Controls: `j`/`k` move, `<Tab>`/`<S-Tab>` change logical section, `<Enter>` edits, `c` creates, `?` toggles help, and `q` cancels. Text and paths use `vim.ui.input`; choices use `vim.ui.select` or Telescope when installed. Spring dependencies use `<Space>` to toggle, `/` to search, `b` to return while preserving selections, and `<Enter>` to accept.

Runtime and Initializr discovery remain visible in the form. Create stays unavailable while discovery runs or validation fails. Generator failure keeps the form open with every value preserved for correction or retry. Opening, editing, failure, and cancel never change cwd or write a project. Existing staging, collision, promotion, and successful handoff rules remain authoritative.

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
  creation = {
    layout = "auto", -- "auto", "wide", or "compact"
  },
  maven = {
    command = "mvn", -- project generation and existing-project fallback
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
    required_executables = {},
  },
})
```

## Java target and runner JVMs

`java_version` is project compiler or toolchain target. `"auto"` uses active Java when supported.

Maven and Gradle choices include active Java, `JDK<version>` environment variables, configured homes, and JDKs discovered under common Linux, macOS, SDKMAN, asdf, and Maven directories. A configured home is accepted only when its `bin/java -version` output matches the configured version key.

Discovery resolves duplicate JDK paths, caps each version probe at one second, and reuses one cached snapshot throughout a Creation Center session. Run `java_runtimes({ refresh = true })` after installing or removing a JDK during the current Neovim session.

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
- POM writes skip write autocommands, so a format-on-save chain cannot reformat the file around an edit. A dependency add or version bump stays a one-line diff you can actually review. Manual `:w` still formats as configured.
- Multi-upgrade plans live only in the current Neovim session. Apply accepts an opaque random ID, re-reads every source line, ignores caller-mutated preview data, expires before writing, writes once, and emits one build-change event.
- Reactor repair plans keep canonical paths and complete POM contents private. Apply preflights every POM, compares again at each write, preserves loaded modified buffers, rolls earlier writes back in reverse order after failure, and reports rollback conflicts without overwriting concurrent edits.

## Project Center

Run `:Duke` from a Maven or Gradle workspace to open the native sidebar. Duke discovers the nearest build root, literal Maven reactor modules, active module, direct Maven declarations, Gradle settings/build/catalog files, wrappers, and Spring `application[-profile].properties`, `.yml`, and `.yaml` filenames. It returns paths, profiles, formats, and scopes only; configuration values are never read into the model or rendered.

Project Center opens from local files only. `r` explicitly permits read-only build-tool reports. Maven uses version-pinned `help:effective-pom` and `dependency:tree` goals through the project wrapper when available. Resolved dependencies expose selected versions, raw ownership, property consumers, direct or transitive status, paths, and proven conflict, drift, duplicate, or unknown-ownership findings in read-only detail buffers. Gradle uses plain-console version, project, installed-toolchain, effective Java-target, and project-scoped dependency reports. Recognized Gradle dependency nodes show requested and selected versions, project, configuration, and tree paths. Failures preserve local data and appear as single-line partial diagnostics instead of fabricated resolved data.

The Workspace and Environment groups show available roots, active module, build files, wrapper, build-tool version, Java target, scoped runner JVM, Spring Boot, toolchains, and exact-root JDTLS attachment state. Unknown evidence stays absent or explicitly unknown. Closing and reopening preserves the latest session snapshot. Writing an owned build file invalidates it, while older asynchronous refresh results cannot replace newer data.

Keys: `<CR>` opens the selected module, file, or read-only detail; `r` resolves or retries; `a` adds; `u` upgrades or stages a Doctor version repair; `x` removes or stages a Doctor exclusion; `p` shows paths; and `g` jumps to ownership. Doctor keys are `d` for normal diagnosis, `L` for confirmed deep diagnosis, `c` to clear staged repairs, `P` to build and preview, `A` to confirm and apply, and `R` to refresh findings and compare the receipt. `/` searches, `l` opens `:DukeLog`, `?` shows help, and `q` closes. Opening and refreshing preserve the code window, current buffer, working directory, and unsaved state. Failed refreshes keep the latest snapshot visible and show one concise reason with retry and log actions.

Maven analysis reports direct and transitive paths, requested and selected versions, duplicate declarations, cross-module drift, proven conflicts when Maven emits them, shared version-property consumers, and unknown ownership. Upgrade planning may edit a literal root dependency version or a unique direct-root property used only by root dependency versions. Plugin, profile, dependency-management, chained, compact, and otherwise ambiguous property ownership is refused.

`:DukeDoctor` performs explicit wrapper-aware effective-POM, dependency-tree, and active-profile inspection. It does not run during local Project Center open. `:DukeDoctor!` additionally runs Maven Dependency Plugin `dependency:analyze`; that goal may invoke `test-compile`, so Duke confirms first. Findings with profile, external-parent, ambiguous, or otherwise unproven ownership remain blocked. Repair previews show relative POM labels and exact changed values, never canonical write paths or complete POM contents. Successful apply emits one aggregate event only after every POM succeeds. Press `R` afterward to show which selected finding IDs disappeared or remain.

## Spring metadata and Maven dependency lifecycle

Spring name, description, package, Boot version, full-project build type, language, packaging, Java, and dependency choices are collected before creation. Initializr metadata supplies available Boot versions and Maven or Gradle project types. Unsupported active Java versions fall back to Initializr's default.

Initializr metadata, catalog, and project URLs must use HTTPS. Curl is restricted to HTTPS for both the original request and redirects.

Successful metadata and Boot-version catalogs are cached below `stdpath("cache")/duke.nvim`, separately for each configured Initializr URL. Fetch failures use a valid same-URL cache. Spring project creation still needs network access.

Run `:DukeClearCache` when cached Initializr data becomes stale. Next metadata request fetches fresh data.

An unreachable Initializr host, or a remote payload the plugin no longer recognizes, is not a silent event: one concise notification names the cause (unreachable host vs. unrecognized schema) and the cached data's age, while the full underlying error stays in `:DukeLog`. The cache is never auto-expired and stale data is never refused; the notification lets you decide whether to keep going or run `:DukeClearCache`.

Dependency insertion exposes only entries representable by one normal Maven `<dependency>` block. Entries requiring BOM import, custom repository, or annotation-processor wiring stay hidden. Those entries remain available during new Spring project creation, where Initializr can generate complete Maven configuration. Spring catalog and Maven Central add pickers mark root dependencies already present in the current POM with `[installed]`; marked rows remain selectable, and structural duplicate detection remains the write guard.

For a plain Maven pom, `:DukeAdd` prompts for a Maven Central query and shows `groupId:artifactId` plus latest version. Selecting one artifact opens a newest-first version picker with release dates when available, defaulted to that latest version, then a scope picker with `compile` as the default and `test`, `provided`, or `runtime` as alternatives. Both prompts include the dependency coordinate. Compile scope emits no `<scope>` element. Multi-select keeps each artifact's latest version and compile scope without another prompt. A final confirmation, defaulted to cancel, lists every dependency before the POM write. Success reports coordinates actually added. Malformed result rows are skipped without discarding valid neighbors, and `pom` artifacts remain excluded. Ranking comes from Maven Central. Rerun the command to refine a query. Search has no cache or offline fallback.

`:DukeUpgrade` lists root dependencies with explicit `<version>` elements and updates one per run from Maven Central's newest-first version list with release dates when available. The latest version is marked; selecting the current version is a no-op. A final current-to-target confirmation defaults to cancel before writing. Direct-root property versions such as `${library.version}` are resolved and updated through the safe change-plan engine. When one property controls multiple root dependencies, confirmation lists every affected coordinate. Chained properties, non-dependency consumers, missing root properties, and ambiguous structures are refused. Managed dependencies whose version comes from a parent or BOM are shown with their resolved version (resolved by `mvn dependency:list`) and marked as managed; selecting one notifies about `:DukeBootUpgrade` instead of opening a version picker. Only version text changes; scope, type, classifier, exclusions, comments, and formatting stay untouched.

`:DukeBootUpgrade` upgrades a Spring Boot `pom.xml`'s `<parent>` `<version>` from Maven Central's full release history for `org.springframework.boot:spring-boot-starter-parent`, so patch bumps on an old line (2.7.x to 2.7.18) stay reachable even after Initializr stops generating that line. A project with a corporate parent that manages Boot through `spring-boot-dependencies` in `<dependencyManagement>` is detected and its version is shown, but BOM version upgrades are deferred. A non-Boot project, or a pom with no Boot version at all, is refused. A property-backed parent version, for example `${boot.version}`, is refused because this command edits only the literal parent version. Picking the version already in the pom is a no-op. An explicit confirmation, defaulted to cancel, shows the current and target version before writing; declining or cancelling the version picker leaves `pom.xml` byte-identical. The pom is re-read after the picker and before the write, so an edit made while the picker was open is caught rather than overwritten. Only the parent `<version>` text changes; no Java version, property, or dependency edit accompanies the bump.

`:DukeOutdated` checks root dependencies with literal explicit, direct-root property-backed, or managed versions sequentially against Maven Central and lists `current -> latest` rows. Managed versions are resolved by `mvn dependency:list` and marked with their managing parent when available. If `mvn` is missing or the project fails to resolve, managed dependencies degrade to today's skipped-with-count behavior and explicit-version rows still work. Missing, chained, or structurally ambiguous property versions remain skipped with counts. Any lookup error, including a timeout or HTTP 429, stops further lookups but keeps gathered rows and reports how many dependencies were not checked. Selecting a managed row notifies about `:DukeBootUpgrade` and writes nothing. Selecting an editable row enters the same single-dependency version picker and stale-file-safe write path as `:DukeUpgrade`; canceling leaves the POM untouched.

`:DukeRemove` lists all root dependencies, including managed ones, and supports multi-select. A mandatory confirmation names every selected coordinate. Declining or canceling changes nothing. Removal deletes complete dependency blocks but keeps the root `<dependencies>` container, sibling blocks, comments, and surrounding blank-line formatting.

`:DukeInfo` accepts an optional `groupId:artifactId` argument and shows latest and recent versions with release dates from Maven Central in a scratch buffer. Without an argument, the command prompts for a coordinate. The buffer is read-only and wipes on close.

`:DukeTree` runs Maven's resolver against the nearest `pom.xml` and renders the resolved dependency tree in a read-only scratch buffer. `:DukeWhy [groupId:artifactId]` runs the same resolver with a coordinate filter, showing every ancestor path plus the version Maven selected. If a Maven version emits annotations such as `omitted for conflict with ...`, Duke preserves them, but modern Maven Dependency Plugin versions do not reliably emit omitted nodes. Without an argument, `:DukeWhy` offers root dependencies plus an option to type any transitive coordinate. Both commands show progress while Maven runs, are read-only, run Maven once, leave the POM and working directory unchanged, and keep failure detail in `:DukeLog`.

Managed dependency resolution, `:DukeTree`, and `:DukeWhy` search upward from the selected POM for an executable Maven Wrapper. When found, Duke runs its absolute path while keeping the POM directory as the process working directory. Without a wrapper, `maven.command` remains the fallback.

`:DukeModule` prompts for an artifact ID, then a package name pre-filled from the reactor's groupId, then confirms before adding a child module to the Maven reactor rooted at the current working directory. The parent `pom.xml` gains only the new `<module>` entry, created inside a fresh `<modules>` block when none exists. Canceling any prompt or the confirmation writes nothing. Only a root `pom.xml` with `<packaging>pom</packaging>` is eligible; a plain jar-packaging pom is rejected without creating a directory.

No Boot versions are hardcoded into the picker. Old-version lookup happens only when the dependency command reads an existing `pom.xml`.

## After creation

Without handoff, the plugin opens generated application Java source when available, then falls back to a build file. Opening Java naturally triggers the user's normal `nvim-jdtls`, `nvim-java`, or other filetype setup. Duke supplies project and dependency workflow around that language-server experience; it does not install or configure JDTLS.

Successful creation emits `User DukeProjectCreated` with `data.project_dir` and `data.entry_file`.

Successful dependency, module, and reactor mutations emit `User DukeBuildChanged`. Event data contains `kind`, `root`, `build_file`, `operation`, and `saved`; dependency operations also contain `coordinates`, module creation contains `module_dir`, and `repair_reactor` contains `build_files` plus aggregate `changes`. No-op, aborted, and rolled-back mutations emit nothing. This optional hook keeps JDTLS ownership outside Duke:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "DukeBuildChanged",
  callback = function(args)
    if not args.data.saved or vim.bo.filetype ~= "java" then
      return
    end
    local ok, jdtls = pcall(require, "jdtls")
    if ok then
      jdtls.update_project_config()
    end
  end,
})
```

`nvim-jdtls` refreshes the module owning the current Java buffer. Unsaved POM-buffer mutations report `saved = false`; save first, then refresh through your JDTLS setup.

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

Programmatic calls never open a wizard or picker, change directory, or invoke the configured handoff. Inspection and planning are read-only; mutation calls may update the explicit POM path or its loaded buffer. Results arrive once through a callback on the Neovim main loop:

```lua
require("duke").create("maven", {
  cwd = vim.fn.getcwd(),
  group_id = "com.example",
  artifact_id = "demo",
  java_version = "21",
}, function(result)
  if not result.ok then
    vim.notify(result.error, vim.log.levels.ERROR)
    return
  end
  print(result.project_dir)
end)
```

Maven dependency operations require an explicit POM path and exact coordinates:

```lua
require("duke").add({
  pom_path = "/path/to/project/pom.xml",
  group_id = "org.junit.jupiter",
  artifact_id = "junit-jupiter",
  version = "5.13.4",
  scope = "test",
}, function(result)
  print(result.ok, result.changed, result.saved)
end)
```

`create()` supports `maven`, `gradle`, and `spring`. `add()`, `upgrade()`, `outdated()`, and `remove()` provide the root Maven dependency lifecycle without UI. `upgrade()` may update a private direct-root dependency property; it refuses a shared property instead of silently changing extra coordinates, so callers must inspect and apply `plan_upgrades()` for that case. `upgrade_parent()` upgrades the Spring Boot parent version without UI, skipping the confirmation prompt since the API call itself is the confirmation; it refuses a non-Boot or property-backed parent the same way `:DukeBootUpgrade` does. `add_module()` adds a module to an existing Maven reactor without UI; unlike the command, `reactor_dir` is required with no current-working-directory fallback. See `:help duke-api` for exhaustive options, result fields, validation behavior, and partial outdated results.

Workspace inspection uses an error-first callback. Local inspection runs no build tool; `resolve = true` explicitly permits wrapper-backed Maven or Gradle reports:

```lua
require("duke").inspect({ path = vim.fn.getcwd(), resolve = false }, function(err, snapshot)
  if err then
    return vim.notify(err, vim.log.levels.ERROR)
  end
  print(snapshot.kind, snapshot.root, snapshot.state)
end)
```

Multi-upgrade plans use the same callback form. A missing `new_version` resolves the latest Maven Central version. Only the returned opaque session ID authorizes apply; display fields are untrusted copies:

```lua
require("duke").plan_upgrades({
  pom_path = "/path/to/project/pom.xml",
  changes = {
    { coordinate = "org.slf4j:slf4j-api", new_version = "2.0.17" },
  },
}, function(err, plan)
  if not err then
    require("duke").apply_plan(plan, function(apply_err, result)
      print(apply_err or (result.saved and "saved" or "buffer updated"))
    end)
  end
end)
```

Maven Doctor uses three error-first, session-scoped calls. Diagnosis and plan descriptors expose relative labels and display data only; canonical paths and complete POM lines remain private:

```lua
require("duke").diagnose_workspace({ path = vim.fn.getcwd(), deep = false }, function(err, diagnosis)
  if err then
    return vim.notify(err, vim.log.levels.ERROR)
  end
  require("duke").plan_repairs({
    diagnosis_id = diagnosis.id,
    repairs = {
      { finding_id = diagnosis.findings[1].id, new_version = "2.0.0" },
    },
  }, function(plan_err, plan)
    if not plan_err then
      require("duke").apply_reactor_plan(plan, function(apply_err, receipt)
        print(apply_err or receipt.ok)
      end)
    end
  end)
end)
```

`deep = true` may compile main and test sources. Headless callers provide that consent through the option itself. Plans are one-shot, expire within the current Neovim session, reject stale POMs, and ignore all caller changes except the opaque ID used for lookup.

`require("duke").new()` opens Creation Center with the generator selector active. `new_maven()`, `new_gradle()`, and `new_spring()` open the same center with that generator preselected. `new_module()` starts the `:DukeModule` wizard using the current working directory as the reactor. `dependency_tree()` and `dependency_why(coordinate)` open the read-only Maven insight views. `info(coordinate)` opens the `:DukeInfo` scratch buffer for a coordinate, or prompts for one without an argument. `add_dependency()`, `update_dependency()`, `upgrade_boot_parent()`, `outdated_dependencies()`, and `remove_dependency()` start the same nearest-`pom.xml` workflows as their commands. `clear_cache()` deletes all cached Initializr metadata and returns `true` on success.

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

V1 owns Maven, Gradle, and Spring project creation, local Java workspace discovery, explicit read-only Maven and Gradle model refresh, Spring configuration-file navigation, adding a module to an existing Maven multi-module reactor, root-level Maven dependency add, upgrade, outdated inspection, removal and safe multi-upgrade planning, resolved Maven tree and why-path inspection, Maven Central version info lookup, and Spring Boot parent version upgrade.

The plugin deliberately does not run applications, format code, execute tests, edit Gradle dependencies, edit Spring configuration values, or manage JDTLS. Existing tools remain responsible for those jobs.

## ❓ FAQ

**Why duke.nvim instead of manual POM editing?**

Every POM mutation re-reads the file after user interaction, writes without triggering format-on-save autocommands, and rejects compact XML it cannot parse safely. A dependency add or version bump stays a one-line diff you can review. Manual editing risks whole-file reformats and accidental changes to dependency management, plugins, or profiles.

**Does this replace JDTLS or nvim-jdtls?**

No. The plugin opens generated Java source, which triggers your normal filetype and LSP setup. JDTLS configuration, installation, and management stay external.

**Why are some Spring dependencies missing from `:DukeAdd`?**

Only dependencies representable as a single `<dependency>` block appear. Entries requiring a BOM import, custom repository, or annotation-processor wiring are hidden. They remain available during new Spring project creation through Initializr.

**What does `:DukeOutdated` check and what does it skip?**

The command checks root `pom.xml` dependencies with literal versions, safe direct-root property versions such as `${library.version}`, or versions resolved from a parent/BOM against Maven Central. Missing, chained, or structurally ambiguous property versions remain skipped. Transitive dependencies are never inspected. Managed dependencies without a resolvable version degrade to a skipped-with-count fallback.

**Can I use this with a multi-module project?**

Yes. `:DukeAdd`, `:DukeUpgrade`, `:DukeOutdated`, `:DukeRemove`, and `:DukeBootUpgrade` operate on the nearest `pom.xml`. `:DukeModule` adds child modules to a reactor. Run commands from the module directory whose POM you want to edit.

**Why is my Boot version not detected by `:DukeBootUpgrade`?**

The command checks `<parent>` for `spring-boot-starter-parent` and `<dependencyManagement>` for `spring-boot-dependencies`. If your Boot version comes from a property (like `${boot.version}`) or a custom parent that does not import the BOM, the command cannot resolve it.

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
make format
make test
make lint
```

See [CHANGELOG.md](CHANGELOG.md) for release history. Run `:help duke` for vimdoc.

## License

Copyright (C) 2026 duu261. Licensed under GPL-3.0-or-later. See [LICENSE](LICENSE).
