# Changelog

All notable changes to `mutagen_ex` are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-05-13

First public cut. The CLI, the JSON document, and the mutator catalog are
stable as of this release.

### Added

- `mix mutagen` Mix task — the sole CLI entry point.
  - `--scope <target>` (required, repeatable): file path, module name,
    or `Module.fun/arity`.
  - `--tests <target>` (required, repeatable): test file path,
    `file:line`, or `tag:<name>`.
  - `--timeout-ms <int>` (default `5000`): per-mutation wall-clock budget.
  - `--seed <int>` (default `0`): ExUnit seed, propagated to every
    test-running phase.
  - `--json <path>`: redirect the final JSON document from stdout to a
    file.
- Orchestration state machine for the run pipeline: CLI → scope →
  tests → AST cache → coverage → enumeration → baseline → mutation →
  reporter. Every phase is dispatch-table-driven for test substitution.
- Single-process, serial-execution model (no worker pool, no shelled
  subprocess) — see `mutagen.decision.serial_execution_and_seed` and
  `mutagen.decision.in_process_pipeline`.
- Coverage phase using `:cover`, scoped to in-scope modules, with the
  `:cover_server` torn down cleanly between runs.
- Mutation enumeration via `Macro.prewalk/3` over the AST cache,
  restricted to covered lines and content-addressed for ID stability
  across `mix format` runs (see
  `mutagen.decision.content_addressed_ids`).
- Mutators shipped in v0.1.0: `arith`, `compare`, `boolean`,
  `case_drop`, `else_removal`, `withblock_with_swap`,
  `withblock_else_removal`, `literal`. (See Known limitations for the
  `literal` gap.)
- Mutation runner with per-site sandboxed compile, ExUnit re-run, and
  module restoration. Per-site outcomes classify as `:killed`,
  `:survived`, `:timeout`, `:error`, or `:compile_error`.
- JSON reporter emitting the v1 document shape (success and error
  variants), terminated by a single newline. Golden fixtures under
  `test/mutagen_ex/golden/` serve as the schema-by-example.
- Exit-code discipline: `0` on completion (even at 0.0 kill rate),
  non-zero on any abort. Every non-zero exit emits an error-JSON
  document.
- Refusals (each with a stable `reason:` atom):
  - `:missing_scope`, `:missing_tests`, `:invalid_timeout` — bad input.
  - `:flag_not_supported_in_v1` — explicit reject of `--no-json`
    (see `mutagen.decision.no_pretty_output_v1`).
  - `:colon_syntax_unsupported` — explicit reject of `file.ex:Module`
    (see `mutagen.decision.scope_syntax_simplified`).
  - `:self_mutation_refused` — refuses to mutate `MutagenEx.*` or
    `Mix.Tasks.Mutagen` (see
    `mutagen.decision.self_mutation_refused`).
  - `:baseline_red` — aborts before any mutation phase if the cited
    tests do not all pass against unmodified source.
- `mix help mutagen` output with Synopsis, Flags, Examples,
  Constraints, Exit Codes, JSON Schema Pointer, and Known Caveats
  sections.
- `README.md` with quick-start, flag reference, exit-code table,
  JSON-schema pointer, and known-limitations list.

### Known limitations

Carried forward as open tickets against v0.1.x; see the README's
"Known limitations" section for the user-facing summary.

- `mutagen-wrd.11` — file-cited `--tests` produces a filter that excludes
  every test.
- `mutagen-wrd.12` — production mix task wires the mutation runner with
  an empty `test_modules` list.
- `mutagen-wrd.13` — `Task.shutdown(:brutal_kill)` after a per-site
  timeout can leave the Code.Server with an unreleased module-load
  lock.
- `mutagen-wrd.14` — `:case_drop` on a guarded base case classifies
  `:killed` (`CaseClauseError`), not `:timeout` as the mutator catalog
  states.
- `mutagen-wrd.15` — the `literal` mutator never fires; the AST cache's
  `token_metadata: true` wraps atomic literals in `__block__` tuples
  that `Literal.match?/1` does not destructure.

[0.1.0]: https://github.com/autom8things/mutagen_ex/releases/tag/v0.1.0
