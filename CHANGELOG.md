# Changelog

All notable changes follow Keep a Changelog and Semantic Versioning.

## Unreleased

### Added

- Initializr cache fallback now surfaces to the user: one concise notification names whether the host was unreachable or the remote schema was not recognized, plus the cached data's age. The full error still goes to `:DukeLog`.

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
