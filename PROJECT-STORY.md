# duke.nvim

> `cargo new` + `cargo add` for the JVM, inside Neovim.

Tagline: Safely scaffold Java projects and manage Maven dependencies without leaving your editor.

## Inspiration

Rust developers type `cargo new` and `cargo add`. Java developers launch IntelliJ.

The JVM ecosystem has no terminal-native project and dependency tooling that an editor can consume. Maven's `archetype:generate` is interactive soup. Adding a dependency means copy-pasting XML into a pom by hand, hoping you don't corrupt the file. Maven shipped first-party `dependency:add` in plugin version 3.11.0 (2024), but it still demands exact known coordinates, starts a separate JVM per operation, and offers no search, no version discovery, no scope selection, no catalog awareness, no staleness visibility. It's a compiler flag, not a user experience.

I watched JVM colleagues alt-tab between Neovim and a heavyweight IDE just to start a project or check if a dependency was outdated. The gap is the interactive lifecycle: discover a library, pick a version and scope, see what is outdated, and write the pom safely - all inside the editor, with the confidence that the tool won't break your files. Rust developers take this for granted. Java developers don't know it's possible.

duke.nvim closes that gap. Named after Duke, Java's official mascot, it brings `cargo`-grade tooling ergonomics to the JVM - not by wrapping Maven, but by building a safe mutation engine that treats your pom.xml as a structure, not a string.

## What it does

- **Guided project creation**: Wizards for Maven quickstart/web apps, Gradle Java/Kotlin/Groovy applications, and Spring Boot projects. Destination, coordinates, package, Java version, and build-specific choices with a final review step. All generation happens in private staging; promotion is atomic.

- **Full Maven dependency lifecycle**: Add dependencies with scope selection, upgrade individual dependency versions, remove dependencies with confirmation, and view an outdated-dependency report comparing your versions against Maven Central - all inside Neovim pickers with Telescope preview panes.

- **Spring Boot intelligence**: Dependency catalog from Initializr metadata with installed-dependency markers. Boot parent version upgrade assist with old-to-new confirmation. BOM import detection for Boot version resolution.

- **Multi-module reactor support**: Add a Maven module to an existing reactor. The child is generated in private staging; only a single structural `<module>` insert touches the parent pom.

- **Stable headless Lua API**: Script project creation and all dependency operations from your own Lua configuration. The same engine runs underneath - staging, promotion, structural edits, re-read-before-write - with sharp-tool semantics (no confirmations; your script is the confirmation).

- **Safety as the product**: Every mutation path is backed by staging directories, structural POM edits that reject ambiguity instead of guessing, pom re-reads after every network request and picker before any write, and atomic promotion that aborts if the target appears during generation. The invariant is zero corrupted files, ever.

- **Resilience**: Offline cache fallback for Initializr metadata. Schema validation on cached data. Graceful degradation when Maven is unavailable. Nothing remote can crash a wizard.

## How we built it

The entire codebase - 6,812 lines of pure Lua across 27 modules, 7 tagged releases, 50+ commits - was built by AI models operating under strict invariant discipline.

**The engine: GPT-5.6 Sol via Codex CLI.** Codex built the foundation solo. 41 commits, 7 releases - the safe POM mutation engine, the entire Maven dependency lifecycle, multi-module reactor support, the headless Lua API, Spring Boot parent upgrade assist, and the resilience fallback system. Done in roughly 2 weeks on a single OpenAI Pro plan. It one-shot feature after feature from architecture tickets. Zero corruption bugs across all its commits. The plugin's initial version shipped with zero involvement from any other AI model - pure Codex, pure GPT-5.6 Sol.

**Fable 5 came later for architecture.** Once the foundation existed, Claude Fable 5 (Anthropic) was brought in for strategic sessions: writing endgame documents that defined the 1.0 scope, the permanent cull list, the version path, and the maintenance mode operating manual. Codex built the house; Fable drew the blueprint after the foundation was done.

**The invariant discipline**: No AI model was allowed to commit without human authorization. Every mutation path required a failing test first. Generator changes demanded live temporary-project proof, not mocks alone. The verification bar included CI green on exact Neovim 0.11 floor, stable, and nightly; README, vimdoc, changelog, and config defaults synchronized across 4 sites; and a cold-config stranger test.

**The architecture**: A generator pipeline pattern where each build tool (Maven, Gradle, Spring Initializr) is an adapter implementing `validate()` and `execute()` hooks riding a shared pipeline. The safe POM mutation engine uses hand-rolled XML state machines that compute byte offsets for surgical edits - dependencies inserted only into root `<dependencies>` blocks, compact XML rejected, pom re-read from disk before every write.

**The human role**: ~30-minute review sessions between model invocations. Every function, test, and docs entry was generated by AI. The human contribution was invariant enforcement, scope discipline, and saying "cut that, permanently."

## Challenges we ran into

**Competitive reality shifted mid-build.** On the day the project strategy was written, I verified the core premise against current Maven docs and discovered that maven-dependency-plugin 3.11.0 had shipped first-party `dependency:add` and `dependency:remove` with formatting-preserving DOM manipulation. The strategy's opening claim was already stale. Solution: sharpen the moat. Raw mutation became table stakes; the plugin's value is the *interactive* lifecycle - discovery, pickers, catalog intelligence, staleness visibility - on equal safety discipline.

**AI sessions don't share memory.** When 43 independent AI sessions each produce one commit, the seams between them become architectural debt. Shallow facade modules accumulated. Identical notifier functions were copy-pasted into two modules. An architecture review found 11 deepening candidates, all caused by independent invocations lacking cross-cutting awareness. The fix is a regular adversarial review pass before releases.

**Building a file-safety culture into an AI-driven pipeline.** The hardest engineering problem was encoding "never corrupt a user's pom.xml" into instructions that survive dozens of independent model invocations, each with no memory of the last. The solution was invariant-as-code: structural XML parsing that rejects ambiguity instead of guessing; staging directories with random names and atomic promotion; re-reading the pom from disk after every network request before applying any edit; and a test suite where rejection specs outnumber success specs. The invariant is binary - either zero corrupted files, or the product thesis fails.

**Codex was so reliable it exposed gaps in other models.** The project's instruction file has a rule: no em dashes in prose. Codex needed two words in its AGENTS.md - "no emdash" - and never violated it once. It actively cleaned up em dashes left by other models. Fable 5, running the same project, has the rule in CLAUDE.md backed by a thousand-line Python hook blocking em-dash commits - and still produces them, still gets blocked, still needs the override. Codex treats constraints as constraints. That gap in compliance discipline is why Codex carried the implementation and other models stayed in planning roles.

## Accomplishments that we're proud of

- **7 releases in 7 hours** on the foundation sprint - a complete Maven dependency lifecycle, multi-module support, a stable API, and resilience armor - built by GPT-5.6 Sol from architecture documents, reviewed by a human.

- **Zero corrupted files across 7 releases.** The safety invariant held. Every mutation path is backed by staging, structural edits with rejection semantics, stale-read protection, and atomic promotion.

- **A project strategy document accurate enough to execute from.** The endgame doc defined 1.0, the cull list, the version path, pacing rules, a stall protocol, and a competitive analysis verified against live Maven and Gradle sources - all before v0.4.0 shipped. A mid-tier AI planner can read it and produce the next implementation ticket without human guidance.

- **Cold-config testability.** A fresh Neovim config can go from the README quick start to a generated, compiling Spring Boot project without reading the configuration section.

- **Documentation synchronized across 4 sites.** Commands, vimdoc, README config table, and lazy.nvim spec kept in lockstep - 4 sites updated in the same commit every time.

## What we learned

**The moat is safe mutation, not creation.** Wizards run once per project; dependency operations recur weekly. Frequency earns daily-driver status. The plugin's durable value is the trust that it will never corrupt a pom.

**Scope discipline is a feature.** Publishing permanent non-goals (no app running, no testing, no JDTLS management, no Gradle mutation, no AI features) is a promise to users. The plugin is complete at 1.0 and enters maintenance mode. Growth stops on purpose.

**A single reliable model beats a committee.** Codex one-shot feature after feature with zero corruption bugs. It followed every rule, every invariant, every verification step - not because it was prompted carefully each time, but because it treats constraints as constraints. The best architecture decision was picking the right model and getting out of its way.

**The model budget matters.** One implementation slice at a time. Two failed attempts triggers a stall. Every minor release is a valid stopping point. No calendar pressure. The human's job is scope discipline, not implementation.

**Documentation is the continuity mechanism.** When independent AI sessions have no shared memory, the strategy documents, invariants file, and slice tickets are the only thing carrying context between invocations. Vague documents produce aimless sessions; sharp ones produce shipping commits.

## What's next for duke.nvim

**v1.0.0 - Declaration and launch.** The plugin is functionally complete. What remains: a resilience live proof, a cold-config stranger test, the harvest checklist (demo GIF, case study on my personal site, launch posts), and the docs freeze. v1.0 is a declaration, not a milestone. After it, the plugin enters maintenance mode.

**v1.1.0 - Dependency tree visibility.** A `:DukeTree` / `:DukeWhy` command showing why a dependency is in your project. Read-only, zero corruption risk. Ticket is already costed and gated behind 1.0.

**Maintenance mode.** Accepted work: security fixes, Neovim API deprecations, Initializr and Maven Central schema drift, Java/Gradle/JUnit compatibility threshold updates, bug fixes with regression specs. Target: under 2 hours per month. Refused: new generators, new build systems, Gradle mutation, config surface growth, AI features.

**The scope is deliberately small.** This project was chosen because it's a complete, maintainable product at finite scope - it can sit unattended for months and still work. I picked a problem one person and one AI can own end-to-end. Zero ongoing AI token cost in maintenance mode. The decision to stop at 1.0 and refuse scope growth was the single most important architectural decision in the project.

**If resources permitted**, the natural expansion is a Neovim Java IDE plugin - language server integration, debugging, test runners, project view. A "Java IDE for Neovim" that treats the editor as a first-class JVM platform, not an IntelliJ downgrade. That's a different project with different scope discipline. duke.nvim proved the model; the IDE plugin would scale it.

**The 2.0 conversation** only reopens if Declarative Gradle reaches mainstream defaults, first-party tooling closes the interactivity gap, or my daily-driver needs change. None are expected soon. The project is designed to survive its own completion.

## A note on Codex

I want to be specific about what OpenAI's model did here, because it deserves the credit.

GPT-5.6 Sol via the Codex CLI was the workhorse. The entire foundation - safe POM mutation engine, dependency lifecycle, multi-module reactor, headless API, Spring Boot parent upgrade, resilience armor - was Codex solo. 41 commits, 7 releases, zero corruption bugs. Done in roughly 2 weeks on a single Pro plan, with zero involvement from any other AI model at the start.

It one-shot feature after feature. Give it a specification ticket, it returns a working implementation with tests, docs, and live proof. Every invariant followed: red specs first, staging before promotion, re-read before write, rejection over guessing. Not because it was prompted carefully each time - because it treats constraints as constraints.

The rule-following gap is real and measurable. The project has a simple rule: no em dashes in prose. Codex needed two words in its instruction file - "no emdash" - and never violated it once. It cleaned up em dashes left by other models in files it touched. Other models, given the same rule, a thousand-line Python hook, and multiple blocks, still can't comply. Codex doesn't need guardrails. It needs a spec.

The architecture that shipped this project was simple: Codex built it, a human reviewed it, and Fable 5 occasionally wrote the roadmap. The project would not exist without GPT-5.6 Sol.
