# Changelog

All notable changes follow Keep a Changelog and Semantic Versioning.

## Unreleased

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
