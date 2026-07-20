# duke.nvim project story

> `cargo new` + `cargo add` for the JVM, inside Neovim.

## The problem

Java project creation and dependency maintenance still pull editor users into build-tool prompts, XML edits, browser searches, or a full IDE. Maven can mutate dependencies when exact coordinates are already known, but that does not provide discovery, version selection, scope selection, Spring catalog awareness, or a useful outdated-dependency workflow.

duke.nvim puts that lifecycle inside Neovim. It creates Maven, Gradle, and Spring Boot projects, manages root Maven dependencies, grows Maven reactors, and exposes the same core through a callback-based Lua API.

Safety is the product. A convenient picker is worthless if one ambiguous POM edit can damage a user's project.

## What shipped

- Maven, Gradle, and Spring Boot creation through guided wizards.
- Maven dependency search, add, upgrade, outdated inspection, removal, and version information.
- Spring Initializr catalog integration and Spring Boot parent upgrade assistance.
- Maven multi-module creation with parent rollback protection.
- Telescope and native `vim.ui` workflows, with explicit confirmations before interactive writes.
- A stable headless Lua API for scripting the same operations without interactive UI.

Creation happens in private staging and promotes only after validation. POM edits target direct root structures, reject ambiguous compact XML, and re-read the file after asynchronous work before writing. A target that appears during generation is preserved rather than overwritten.

## How Codex built it

GPT-5.6 through Codex CLI was the primary implementation and verification agent. I supplied product direction, constraints, and release authorization. Other models contributed some planning and draft prose, but Codex owned the difficult path from requirements to tested code.

Each meaningful change had to satisfy repository invariants, not just produce plausible Lua:

- Process arguments remain lists. Exit codes are checked.
- Mutation code rejects uncertain structure instead of guessing.
- Generator changes need live temporary-project proof.
- Multi-module changes need a disposable real Maven reactor.
- Neovim behavior is exercised in a real listening editor when mocks cannot prove it.
- Local tests, live proof, and remote CI are reported separately.
- Main, tags, and releases require explicit human authorization.

That discipline matters more than raw generation speed. The hard part was keeping safety rules intact across generators, asynchronous callbacks, UI flows, documentation, and releases.

## Technical decisions

The generator pipeline keeps Maven, Gradle, and Spring adapters behind shared validation, staging, promotion, and cleanup behavior. The POM engine performs structural root-level edits while preserving unrelated formatting and content. Buffer-aware writes prevent stale asynchronous results from overwriting newer user edits.

Interactive commands own confirmation and progress UI. Headless APIs remain deterministic and UI-free. Telescope improves discovery when installed, while `vim.ui` remains a complete fallback rather than a degraded emergency path.

Remote metadata is treated as untrusted input. Initializr responses and caches are schema-validated. Cache replacement uses a sibling temporary file and atomic rename. Unsupported Spring dependencies that require extra BOM, repository, or annotation-processor wiring are excluded from simple POM insertion.

## What we learned

The durable feature is safe dependency mutation, not project-creation volume. Creation happens occasionally; dependency maintenance repeats throughout a project's life.

AI-written plans and completion claims are inputs, not proof. Cheap model work can accelerate exploration, but critical paths need source inspection, edge-case tests, live behavior checks, and adversarial review. This release rebuilt a useful UX proposal from main instead of merging the original branch because the original implementation weakened safety and headless behavior.

Documentation can also lie. During release review, we found a claimed Telescope preview that the picker never created and a README story link that pointed at an ignored local file. Both required the same treatment as code bugs: compare claims with observable behavior, then correct the source of truth.

## What's next

The immediate path to 1.0 is resilience proof, cold-config validation, documentation compression, and a strong demonstration of the dependency workflow. The plugin will not embed AI merely for an AI build event. The build story is how Codex helped produce and verify a real developer tool.

After 1.0, scope can grow when user evidence supports it and the same safety bar remains practical. Dependency-tree visibility and deeper Maven insight fit the current product. Gradle mutation, JDTLS management, running, testing, and formatting remain outside current scope until separately designed and justified.

The goal is not maximum feature count. The goal is a Java workflow Neovim users can trust.
