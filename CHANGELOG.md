# Changelog

All notable changes follow Keep a Changelog and Semantic Versioning.

## Unreleased

### Added

- Project Center now exposes resolved Maven ownership, consumers, findings, paths, exact declaration navigation, and resolved Gradle dependency rows in read-only detail buffers.
- Contextual `a`, `u`, `x`, `p`, and `g` actions reuse Duke's existing Maven workflows for the selected module or dependency.

### Changed

- Project Center now shows available workspace, wrapper, Java target, scoped runner JVM, Spring Boot, Gradle, toolchain, and exact-root JDTLS state. Its latest session snapshot survives close and reopen, invalidates after an owned build-file write, and rejects stale refresh completion.

### Fixed

- Maven effective-POM inspection now runs non-recursively per reactor module, preventing an aggregated root `<projects>` document from degrading otherwise valid workspace resolution to partial state.

## 0.10.0 - 2026-07-20

### Added

- `:DukeNew`, `:DukeMaven`, `:DukeGradle`, and `:DukeSpring` now share a native Creation Center with persistent editable state, configurable responsive, wide, or compact layouts, visible validation and discovery status, and an integrated Spring dependency view.
- `:Duke` now opens a native Project Center inside Maven and Gradle workspaces, showing local modules, direct dependencies, Spring configuration filenames, diagnostics, and navigation without running a build tool.
- Explicit Project Center refresh adds wrapper-backed, read-only Maven effective/dependency analysis and project-scoped Gradle Java, toolchain, and dependency reports, with selected versions, dependency paths, analysis counts, and partial states instead of fabricated resolved data.
- `duke.inspect(opts, callback)` exposes local or explicitly resolved workspace snapshots to scripts and integrations.
- `duke.plan_upgrades(opts, callback)` and `duke.apply_plan(plan, callback)` provide opaque session-scoped Maven multi-upgrade plans with exact preview, shared-property impact, complete stale-source checks, one write, and one build-change event.
- `:DukeTree` renders Maven's resolved dependency tree and selected versions in a read-only scratch buffer, preserving any annotations Maven emits.
- `:DukeWhy [groupId:artifactId]` shows the ancestor path for a direct or transitive dependency. Without an argument, root dependencies seed the picker and a typed-coordinate path remains available.
- Successful dependency and module mutations emit `User DukeBuildChanged` with build root, build file, operation, and save-state data for optional tool integration.

### Changed

- Project creation failures preserve the form for correction or retry. Observable target collisions block before confirmation. Cancel restores editor state, stale async callbacks are ignored, duplicate completion callbacks are suppressed, and Creation Center boundary failures are contained and logged.
- Product scope now includes read-only Maven/Gradle workspace intelligence and Spring configuration-file navigation while keeping JDTLS, app running, formatting, tests, Gradle dependency editing, and Spring value editing external.
- Existing-project Maven resolution and dependency insight prefer an executable project Maven Wrapper, with `maven.command` as fallback.

## 0.9.0 - 2026-07-20

### Added

- `:Duke` opens grouped command help in a read-only scratch window.
- Long-running Initializr, managed-dependency, and Maven Central operations show truthful start, count, completion, and failure feedback.
- Dependency pickers use consistent coordinates, contextual version and scope prompts, Java LTS markers, and selected-item counts in both Telescope and `vim.ui` flows.

### Changed

- `:DukeAdd` and `:DukeUpgrade` now require a final confirmation, defaulted to cancel, before writing `pom.xml`.
- Successful dependency insertion reports the coordinates actually added.

### Fixed

- Removed unused dependency preview callbacks. The Telescope dropdown never created a preview pane, despite earlier documentation claiming previews were visible.
- Managed-dependency progress stays in interactive commands; stable headless API calls remain UI-free.

## 0.8.0 - 2026-07-17

### Added

- `:DukeOutdated` and `:DukeUpgrade` now resolve versions of managed dependencies (those without explicit `<version>`, managed by a parent POM or BOM) through `mvn dependency:list`. Managed dependencies appear with their resolved version, marked as managed by the Boot parent when present. Selecting a managed row in either command notifies about `:DukeBootUpgrade` instead of writing. If Maven is missing or the project fails to resolve, the commands degrade to the prior skip-with-count behavior and explicit-version rows continue to work. Transitive artifacts from `dependency:list` are excluded by intersecting with declared root dependencies.
- `duke.outdated` result rows gain an optional `managed` boolean and `managing_parent` string field. The result table gains an optional `managing_parent` field.
- `:DukeInfo [groupId:artifactId]` shows latest and recent versions with release dates from Maven Central in a read-only scratch buffer. Prompts for a coordinate when called without an argument.
- `:DukeAdd` and `:DukeUpgrade` version pickers now show release dates from Maven Central timestamps when available.
- `:DukeBootUpgrade` now detects Spring Boot versions from `<dependencyManagement>` BOM imports, not just `<parent>`. Projects with a custom corporate parent that manage Boot through `spring-boot-dependencies` in dependency management are recognized; upgrading the BOM version is deferred to a future release.
- `:DukeAdd` Telescope preview shows artifact description, release date, and version when available. Spring catalog items show name, group, and description in the preview window.

### Fixed

- POM writes no longer trigger write autocommands. A format-on-save chain (for example conform.nvim falling back to lemminx) previously reformatted the whole POM around a one-line dependency or parent edit, turning a reviewable change into a whole-file diff. Plugin edits now write with `noautocmd`; a manual `:w` still formats as configured.

## 0.7.0 - 2026-07-16

### Added

- Initializr cache fallback now surfaces to the user: one concise notification names whether the host was unreachable or the remote schema was not recognized, plus the cached data's age. The full error still goes to `:DukeLog`.
- `:DukeBootUpgrade` command and `duke.upgrade_parent(opts, callback)` API verb to upgrade a Spring Boot pom's `<parent>` version from Maven Central. Refuses a non-Boot parent, a missing parent, and a property-backed version. Interactive flow shows an explicit current-to-target confirmation defaulted to cancel and re-reads the pom after the version picker and before writing.

## 0.6.0 - 2026-07-16

### Added

- `:DukeModule` command and `duke.add_module(opts, callback)` API verb to add a module to an existing Maven multi-module reactor.
- Maven multi-module core: stage a child module privately, insert one root `<module>` entry, promote only after the parent edit succeeds, and restore the exact parent on promotion failure.
- Pure POM reactor inspection and root `<modules>` insertion with the same root-only structural policy as dependency edits.

## 0.5.0 - 2026-07-16

### Added

- Stable callback-based Lua API for headless Maven, Gradle, and Spring project creation.
- Programmatic root Maven dependency add, upgrade, outdated inspection, and removal with explicit POM paths and no UI.

### Changed

- Shared one buffer-aware POM read/write boundary between interactive and programmatic dependency workflows.

## 0.4.0 - 2026-07-16

### Added

- Scope selection for single-artifact Maven Central dependency insertion, with compile as the default and test, provided, or runtime as alternatives.
- Single-dependency Maven Central version updates that preserve all other dependency block content and hide managed versions.
- Confirmed multi-select removal of root Maven dependency blocks with stale-file protection.
- Read-only outdated dependency checks with sequential Maven Central lookups, partial results on throttling, and handoff to the existing single-dependency upgrade flow.
- Installed markers in Spring catalog and Maven Central add pickers, based on a fresh read of root POM dependencies.

### Changed

- Renamed the plugin from `java-scaffold.nvim` to `duke.nvim`. The Lua module is now `duke`, the health provider is now `duke`, the project-created event is now `DukeProjectCreated`, and existing `stdpath("cache")/java-scaffold.nvim` directories are left orphaned without migration.

| Old command | New command |
| --- | --- |
| `:JavaScaffoldNew` | `:DukeNew` |
| `:JavaScaffoldMaven` | `:DukeMaven` |
| `:JavaScaffoldGradle` | `:DukeGradle` |
| `:JavaScaffoldSpring` | `:DukeSpring` |
| `:JavaScaffoldAddDependency` | `:DukeAdd` |
| `:JavaScaffoldUpdateDependency` | `:DukeUpgrade` |
| `:JavaScaffoldRemoveDependency` | `:DukeRemove` |
| `:JavaScaffoldClearCache` | `:DukeClearCache` |
| `:JavaScaffoldLog` | `:DukeLog` |
| `:JavaScaffoldHealth` | `:DukeHealth` |

## 0.3.1 - 2026-07-16

### Changed

- Split wizard orchestration, generator execution, Java runtime discovery, and Initializr metadata into focused internal modules without changing public APIs or documented behavior.

## 0.3.0 - 2026-07-16

### Added

- Package prompts for Maven and Gradle, Maven archetype selection, Gradle source-language and DSL selection, and single-artifact Maven Central version selection.

### Changed

- Renamed `maven.archetype` (single table) to `maven.archetypes` (list). A legacy single `maven.archetype` override is still accepted and wrapped into the list.

### Fixed

- Reject Java reserved words in package segments, keep valid Maven Central rows beside malformed rows, and report Maven Central timeouts and HTTP 429 rate limits directly.

## 0.2.0 - 2026-07-16

### Added

- Unified project generator picker through `:JavaScaffoldNew`.
- Spring language and packaging pickers backed by Initializr metadata.
- Spring project name, description, package, Boot version, and Maven or Gradle project type fields.
- Maven Central dependency search for plain Maven poms.
- Initializr metadata cache removal through `:JavaScaffoldClearCache`.
- Explicit destination selection for every generator.
- Pre-creation review and confirmation for Maven, Spring, and Gradle projects.

### Fixed

- Reject symlink and hardlink members before Spring archive extraction.

## 0.1.0 - 2026-07-16

### Added

- Maven quickstart wizard with active-JDK selection.
- Gradle application, library, and plugin wizard with wrapper generation.
- Scoped Maven runner JDK selection through discovered Java homes.
- Separate project target and Maven/Gradle runner Java selection.
- Common JDK installation discovery and scoped Gradle runner selection.
- Spring Initializr wizard with metadata-driven Java and dependency pickers.
- Cached dependency metadata and structural POM insertion.
- Configurable post-create project handoff.
- Transactional project staging and target-safe promotion.
- Generated Java entry opening, creation event, and handoff placeholders.
- Cached Java runtime discovery and minimum-version runtime selection.
- Optional Maven Wrapper generation before project promotion.
- Configured JDK-home version verification and precise nvim-jdtls health text.

### Fixed

- Report Spring Initializr JSON errors instead of generic curl status text.
- Reject malformed nested Initializr metadata before picker or POM use.
- Isolate metadata caches by configured Initializr URL.
- Reuse one Java runtime snapshot per wizard, cap version probes, and deduplicate JDK paths.
- Reject unsafe Spring archive paths before extraction and restrict curl to HTTPS.

### Changed

- Test claimed Neovim 0.11 floor alongside stable and nightly in CI.
