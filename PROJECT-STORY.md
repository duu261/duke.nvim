# duke.nvim project story

> `cargo new` + `cargo add` for the JVM, inside Neovim.

## The problem

Java tooling inside Neovim is powerful, but build-workspace tasks still interrupt the editing flow. Creating projects, understanding a multi-module build, investigating dependency drift, changing versions, and managing Maven modules often means leaving Neovim or editing build files manually.

I wanted the `cargo new` plus `cargo add` feeling for JVM work without turning Neovim into a full IDE. duke.nvim became the focused project and build-model layer I wanted beside tools such as nvim-jdtls.

Safety is the product. Workspace intelligence is useful only when it reports where values come from, distinguishes local files from resolved build output, and refuses uncertain mutations.

## What shipped

duke.nvim is a pure Lua plugin for Neovim 0.11 and newer. Version 0.11.0 includes:

- Maven, Gradle, and Spring Boot creation through guided workflows.
- A local-first Project Center for Maven and Gradle workspace discovery without running a build.
- Explicit wrapper-backed refresh for resolved dependency, module, profile, environment, and Java information.
- Maven Doctor reports for version drift, duplicate declarations, unknown ownership, active profiles, and dependency paths.
- Optional deep Maven dependency-usage analysis that starts only after confirmation.
- Session-scoped Maven multi-upgrade plans with exact old and new values, stale-plan rejection, and apply receipts.
- Maven dependency search, add, upgrade, outdated inspection, removal, version information, trees, and path explanations.
- Maven reactor module creation with parent rollback protection.
- Spring configuration-file discovery and navigation without reading or editing values.
- Generated-source entry, optional post-create handoff, and a stable callback-based Lua API.

Creation happens in private staging and promotes only after validation. POM edits target direct root structures, reject ambiguous compact XML, and re-read files after asynchronous work before writing. A target that appears during generation is preserved rather than overwritten.

## How Codex built it

I designed the product direction, Java and Neovim workflows, safety rules, scope, and release decisions. GPT-5.6 through Codex CLI was the primary implementation and verification collaborator.

Codex traced behavior across Lua modules, proposed transaction boundaries, implemented features, constructed Plenary tests, investigated edge cases, ran live Maven and Gradle projects, synchronized README and vimdoc, and performed release checks. I kept asking whether each feature made Java workspace work safer or merely made the plugin bigger. I reviewed the real workflows, rejected weak assumptions and unnecessary scope, and retained authority over main, tags, and releases.

Each meaningful change had to satisfy repository invariants, not merely produce plausible Lua:

- Process arguments remain lists and exit codes are checked.
- Public commands, callbacks, hooks, and scheduled work cannot leak errors into Neovim.
- Mutation code rejects uncertain structure instead of guessing.
- Async workflows re-read build files before applying changes.
- Generator changes require live temporary-project proof.
- Multi-module changes require a disposable Maven reactor and rollback proof.
- Workspace intelligence separates local inspection from explicit build execution.
- Local tests, live proof, and remote CI are reported separately.
- Main, tags, and releases require explicit human authorization.

The difficult work was preserving those rules across generators, build-model enrichment, asynchronous callbacks, interactive UI, documentation, and releases.

## Technical decisions

The generator pipeline keeps Maven, Gradle, and Spring adapters behind shared validation, private staging, promotion, and cleanup behavior. Generated projects open useful Java or build entries while JDTLS remains external.

Project Center begins with local build files, so opening it never silently runs Maven or Gradle. Resolved information appears only after an explicit refresh through the workspace wrapper. The UI keeps requested declarations, effective results, ownership, dependency paths, and runner environment distinct instead of flattening them into one misleading version.

Maven repair plans are opaque and session-scoped. A preview lists every owning POM and exact old and new value before writing. Apply revalidates the source files, rejects stale plans, preserves modified buffers, and reports a receipt that can be checked by refreshing the diagnosis.

Target Java and runner Java are separate concepts. Gradle can run on a modern JVM while a project still targets Java 8 or 11. Remote Initializr and Maven Central data are validated, cached safely where applicable, and never trusted as direct mutation instructions.

## Challenges and lessons

The hardest problem was not generating files. It was changing existing workspaces without corrupting user state.

Build files may be modified in unsaved Neovim buffers. Network requests and pickers may finish after a file changes. Maven values may come from parents, properties, active profiles, or effective models. Recovery itself can fail if logging, notification, rendering, or cleanup throws a second error.

This led to durable rules: re-read before mutation, distinguish raw ownership from effective values, separate target Java from runner Java, stage generated projects privately, contain every callback boundary, and make multi-file changes observable before and after application.

I learned that trustworthy developer tooling needs more than successful commands. It needs honest models, bounded scope, explicit side effects, conflict detection, and recovery behavior users can understand.

## What's next

The next step is not more surface area. It is hardening the complete Maven, Gradle, Spring, module, dependency, and JDTLS handoff journeys against more real projects.

Reactor-wide dependency analysis and raw-versus-effective ownership reporting can deepen further. Gradle dependency editing will remain read-only until a mutation model can meet the same safety guarantees as Maven. App running, formatting, test execution, Spring value editing, and JDTLS management remain outside duke.nvim's scope.

The goal is not maximum feature count. The goal is Java build workspaces that Neovim users can understand and evolve safely.
