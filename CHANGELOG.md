# Changelog

All notable changes to `mutagen_ex` are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **Bound stderr / exception / `Macro.to_string` output flowing into the
  JSON report; added opt-in `:redact` config knob.** Stderr captured
  during per-mutation runs, exception messages from compile/restore
  paths, and Elixir source slices in compiler diagnostics flowed
  verbatim into `mutation.results[].warnings[]`,
  `mutation.compile_errors[].message`, and abort-detail message fields.
  Combined with the lax `--json <path>` write (mutagen-wrd.21), secrets
  archived in those reports became file-system-resident. Fixed by:
  - A new `MutagenEx.JsonReporter.Sanitizer` module truncates every
    free-form text field at a 4 KiB cap, appending the literal marker
    `... <N bytes truncated>` when truncation occurs. Truncation
    splits on a codepoint boundary so the emitted string is always
    valid UTF-8. New requirement: `mutagen.json_schema.r10`.
  - Opt-in `:redact` application config (a list of `%Regex{}` or
    binary regex sources, read via `Application.get_env(:mutagen_ex,
    :redact, [])`) — each match in any sanitized field is replaced
    with the literal `[REDACTED]`. Redaction runs BEFORE truncation
    so secrets near or past the 4 KiB cap are still replaced rather
    than silently dropped. Default `:redact` is `[]` (no-op). New
    requirement: `mutagen.json_schema.r11`.
  - Wired into all sanitization choke points: `MutagenEx.AstCache`
    file-read + parse error messages; `MutagenEx.Baseline` test-file
    load + ExUnit.run failure messages; `MutagenEx.MutationRunner`
    compile-error / restore-failure / unrecoverable-restore-failure
    messages and per-result warnings (via `compose_warnings/1`).
  *(mutagen-wrd.26, closes F24 / CF9 from the consolidated Security +
  Performance review.)*

### Performance

- **`Macro.to_string/1` computed once per mutation result.** The Mix
  task's `render_result/1` (`lib/mix/tasks/mutagen.ex`) called
  `Macro.to_string(r.original_ast)` twice per result — once for
  `before` and once for `before_source` — wasting a full AST-to-string
  walk on every reported mutation. The render path now computes
  `Macro.to_string(r.original_ast)` exactly once and aliases the
  resulting binary into both `before` and `before_source`. Reference
  identity (`:erts_debug.same/2`) is the falsifiability check.
  Verbatim source-slice extraction for `before_source` (per the
  contract documented in `lib/mutagen_ex/ast_cache.ex`) is deferred
  to a follow-up since it requires extending the `Site` struct to
  carry `{end_line, end_column}` metadata. New requirement:
  `mutagen.json_schema.r12`. *(mutagen-wrd.26, closes
  F-PERF-11 from the Performance review.)*

- **Bound atom creation on CLI input.** Three call sites converted
  attacker- or typo-controlled strings to atoms with no upper bound,
  making CI loops like `mix mutagen --tests tag:$(uuidgen)` a fast
  atom-table sink (atoms are not GC'd; the default cap is ~1M). Fixed
  by:
  - `MutagenEx.CLI` now applies a `tag:NAME` charset gate at the front
    door (`~r/\A[a-z][a-z_0-9]{0,63}\z/`); inputs outside the charset
    return `{:error, :invalid_tag_name, _}` before any test resolution
    runs. New requirement: `mutagen.cli.r11`.
  - `MutagenEx.TestSelector.resolve/2` for `tag:NAME` no longer calls
    `String.to_atom(name)`. Instead it walks the test corpus and
    compares the user's `NAME` string against `Atom.to_string/1` of each
    `@tag :ATOM` literal found in the parsed AST; the matched
    AST-derived atom flows into `include:`. New requirement:
    `mutagen.test_selection.r7`.
  - `MutagenEx.ScopeResolver.resolve/2` for `Module.Name` and
    `Module.Name.fun/arity` targets no longer calls `String.to_atom` on
    user input. Module matching uses canonical-string comparison
    (`"Elixir.Foo.Bar"` vs. `Atom.to_string/1` of each AST `defmodule`
    atom); function-name matching uses string comparison against
    AST-derived `def`-head atoms. The matched module atom comes from
    the AST. `details.module` on `:module_not_found` is now the
    canonical string (e.g. `"Elixir.Nope"`); `details.function` on
    `:function_not_found` is the user's string segment. New
    requirement: `mutagen.scope_resolution.r8`. *(mutagen-wrd.20,
    closes F6 from the consolidated security review.)*

### Changed

- **Test-seam call sites swapped to behaviour-backed facades.** The
  eleven `apply(Map.get(cfg, :facade, ProductionMod), :fun, [args])`
  call sites in `MutagenEx.Baseline`, `MutagenEx.CoverageRunner`,
  `MutagenEx.MutationRunner`, and `MutagenEx.MutationRunner.MutationLoop`
  now dispatch through named behaviours instead of `apply/3` with no
  compile-time leverage. New facade modules under
  `lib/mutagen_ex/test/`:
  - `MutagenEx.Test.ExUnitFacade` (defaults to `MutagenEx.Test.ExUnit`,
    delegates to `ExUnit.configure/1`, `ExUnit.run/0`).
  - `MutagenEx.Test.ExUnitServerFacade` (defaults to
    `MutagenEx.Test.ExUnitServer`, delegates to
    `ExUnit.Server.add_module/2`).
  - `MutagenEx.Test.CaptureIoFacade` (defaults to
    `MutagenEx.Test.CaptureIo`, delegates to
    `ExUnit.CaptureIO.with_io/2`).
  - `MutagenEx.Test.CompilerFacade` (defaults to
    `MutagenEx.Test.Compiler`, delegates to `Code.compile_quoted/2`).
  - `MutagenEx.Test.CoverFacade` (defaults to `MutagenEx.Test.Cover`,
    delegates to `:cover.start/0`, `:cover.stop/0`,
    `:cover.compile_beam/1`, `:cover.analyse/3`).

  Existing facade-using tests continue to swap modules (not function
  names) and pass without changes. The `:compiler` config key also
  accepts a legacy `{module, function}` tuple for back-compat with
  pre-bw-mutagen-wrd.24 stubs; new callers should pass a behaviour-
  implementing module atom. *(mutagen-wrd.24)*

### Fixed

- **Scenario 7 (`:ecto_user_scenario`) un-skipped.** The end-to-end
  Scenario 7 `@tag :skip` in `test/mutagen_ex/end_to_end_test.exs` was
  long blamed on a `:cover` + Ecto-style DSL interaction. The
  `mutagen-wrd.19` spike (direct reproduction in
  `priv/helper_scripts/spike_19_repro.exs`) showed every macro-injected
  callback — `__schema_kind__/0`, `field/2`-generated `name/0` and
  `age/0`, the `birthday/1` arithmetic helper, and the persisted
  `:lane_schema_kind` attribute — survives `:cover.compile_beam/1` ->
  `:cover.stop/0` -> `:code.purge/1` -> `:code.load_file/1`
  byte-for-byte. The actual baseline-red came from one assertion in
  `test/fixtures/lane_project/test/lane_fixture/ecto_user_test.exs:30`
  (`assert :registered in Keyword.get_values(attrs, :lane_schema_kind)`)
  that fails because `persist: true` attributes serialise their value
  wrapped in a list — `Keyword.get_values/2` returns `[[:registered]]`,
  not `[:registered]`, and `:registered in [[:registered]]` is `false`.
  The test fails identically with or without `:cover`. The assertion
  was rewritten to flatten the values plus an explicit
  `Keyword.fetch!(attrs, :lane_schema_kind) == [:registered]` check,
  Scenario 7's `@tag :skip` was removed, and README "Known limitations"
  item 5 was marked resolved. The Spike-I bytecode-identical-restore
  invariant is now exercised end-to-end against the hand-rolled DSL.
  *(mutagen-wrd.32, the .19b follow-up to mutagen-wrd.19's Option B
  disposition.)*

### Security

- **`--json <path>` is canonicalised before any mutation runs.** Closes
  F7 (HIGH, Security reviewer H2): `mix mutagen --json <path>` previously
  accepted any binary, which combined with the in-process compile-and-
  execute pipeline (`mutagen.decision.in_process_pipeline`) was an
  arbitrary-file-write primitive — a malicious mutated test could
  redirect the report into `/etc/`, `~/.ssh/`, or any symlinked path.
  Two layers of check now run before any mutation phase:
  1. Parse-time pure-string check refuses paths with NUL bytes or any
     `..` segment (`abort_reason: "unsafe_json_path"`).
  2. Filesystem canonicalisation expands every component through
     `File.read_link/1` and refuses paths whose fully-resolved target
     escapes the project root (also `abort_reason: "unsafe_json_path"`).
  CI integrations that need to write outside the project root pass
  `--unsafe-json-outside-project` explicitly; that flag emits a one-shot
  stderr warning naming the resolved target. New invariant:
  `mutagen.cli.r10`. *(mutagen-wrd.21)*

- **Resource caps on input and output volume.** Closes F28 / CF11
  (MEDIUM consensus from Security M1 + Performance F-PERF-07/12): the
  CLI previously accepted unlimited `--scope` / `--tests` repetition,
  the enumerator materialised every site in memory before the runner
  started, and there was no aggregate wall-clock budget — three
  avenues for runaway resource use.
  - `--scope` and `--tests` each cap at 100 occurrences; the 101st is
    refused at parse time with `abort_reason: "too_many_targets"`.
  - `--max-sites` caps enumerated mutation sites (default 10_000).
    Exceeding the cap aborts the pipeline with
    `abort_reason: "too_many_sites"` BEFORE the mutation runner
    starts.
  - `--budget-ms` is an optional aggregate wall-clock budget for the
    mutation phase. When the budget elapses the runner stops
    dispatching new sites and emits a `truncated: true` partial JSON
    report (`aborted: false`; the per-site `--timeout-ms` still
    bounds the in-flight site). New invariants: `mutagen.cli.r12`,
    `mutagen.cli.r13`, `mutagen.mutation_enumeration.r7`.
    *(mutagen-wrd.22)*

### Added

- `MutagenEx.JsonPath` — single home for the `--json` path-safety
  contract. `validate_literal/1` is the pure-string check the CLI parser
  calls at parse time; `canonicalize/2` is the filesystem-aware check
  the mix task calls before any mutation phase. The project root is
  resolved through its own symlinks (handles macOS
  `/var -> /private/var`); the inside-root comparison uses the canonical
  form. *(mutagen-wrd.21)*
- `--unsafe-json-outside-project` flag on `mix mutagen`. Boolean opt-in
  that bypasses the inside-root check while still resolving symlinks.
  Lands on `Config.unsafe_json_outside_project`. *(mutagen-wrd.21)*
- `MutagenEx.Application` — a one-for-one supervisor (`MutagenEx.Supervisor`)
  whose only child is a named `Task.Supervisor` registered as
  `MutagenEx.TaskSup`. Declared via `mod: {MutagenEx.Application, []}` in
  `mix.exs`, so the supervision tree starts whenever `:mutagen_ex` boots —
  for both the `mix mutagen` CLI path and library callers depending on
  `:mutagen_ex` directly. New invariant:
  `mutagen.mutation_pipeline.r13`. *(mutagen-wrd.18)*
- `test/mutagen_ex/supervision_test.exs` exercising start_link / terminate
  cycles, recursive-kill propagation across an OTP-supervised descendant
  subtree and an untrapped linked grandchild, and concurrent-caller
  rejection of `CoverageRunner.run/1`. Covers
  `mutagen.mutation_pipeline.r13`, `mutagen.mutation_pipeline.r14`,
  `mutagen.coverage.r1`, and `mutagen.coverage.r8`. *(mutagen-wrd.18)*
- `.spec/decisions/supervision_tree.md` documenting the
  Application + named `Task.Supervisor` choice, the singleton-ownership
  contract for `:cover_server` / `ExUnit.Server`, and the v2 won't-haves
  (out-of-process workers, `:cover.start/0` race arbiter).
  *(mutagen-wrd.18)*
- `test/support/disk_snapshot_helper.exs` — disk-snapshot diffing helper
  used by the r11 / r7 "no disk writes" tests. Captures byte-identity
  across `lib/**`, `_build/**/*.{beam,app}`, `cover/**`, host project
  config (`mix.exs`, `mix.lock`, `.formatter.exs`), and `mutagen_ex_`-
  attributable entries under `System.tmp_dir!()`. *(mutagen-wrd.27)*

### Changed

- `Mix.Tasks.Mutagen.phase_scope/3` now accumulates per-target scope
  records in O(n) overall instead of O(n²). The previous
  `acc ++ records` pattern was quadratic in the cumulative record
  count — a measurable cost on broad `--scope` workloads. The new
  accumulator prepends chunks and flattens once via
  `:lists.append(:lists.reverse(acc))`. Closes F-PERF-12 (the
  half-overlap with F20). Order of records is preserved; a new
  regression test (`test/mutagen_ex/mix_task_phase_scope_test.exs`)
  asserts both ordering and a 2_000 ms ceiling for 10_000 records
  across 2_000 targets. *(mutagen-wrd.22)*

- `MutationRunner.safe_compile_quoted/3` and
  `MutationLoop.capture_stderr/2` now use
  `ExUnit.CaptureIO.with_io/3` — which returns `{closure_result,
  captured_io}` directly — instead of `capture_io/2` paired with a
  `make_ref/Process.put/Process.get` smuggle to extract the closure's
  return value. Removes the dependency on the (undocumented) fact that
  `capture_io/2` runs its closure in the calling process and deletes
  the per-call process-dictionary lifetime bookkeeping. Spec
  `mutagen.mutation_pipeline.r9` updated to name `with_io/3`; behavior
  is byte-identical (same stderr capture, same suppression, same
  warning attachment). The `:capture_io` seam used by tests now
  requires `with_io/3` (test stubs `CaptureIoStub` and
  `RaisingCaptureIO` updated in lock-step). *(mutagen-wrd.23)*

- The r11 disk-write test in `mutation_runner_test.exs` and the r7
  disk-write test in `coverage_runner_test.exs` now assert byte-identity
  across `lib/`, `_build/`, `cover/`, host project config, and
  `mutagen_ex_`-attributable tmp entries — not just `lib/**/*.ex`.
  Closes Testing-reviewer F13: the original tests would have shipped
  green if the runner accidentally rewrote `mix.exs`, dropped artifacts
  under `_build/`, or wrote a coverage report to `cover/`. The
  `mutagen.mutation_pipeline.r11` and `mutagen.coverage.r7` spec
  statements were updated to name the broader surface explicitly, with
  an allowed-write list of `NONE`. *(mutagen-wrd.27)*

- `MutationRunner.run_one_site/3` now routes the loaded-mutation window
  through a new `with_restore/4` lifecycle helper that mirrors
  `MutagenEx.CoverageRunner.with_cover_lifecycle/2`. A raise, throw, or
  exit inside the window (e.g. a misbehaving `:capture_io` seam) now
  triggers restore before the exception re-propagates. The original
  `{kind, value, stacktrace}` is preserved via `reraise/2` /
  `:erlang.raise/3`; restore failure during propagation is swallowed
  inside `safe_restore/3` and never masks the original cause. New
  invariant: `mutagen.mutation_pipeline.r12`. *(mutagen-wrd.17)*
- The `:compile_error` branch now surfaces defensive-restore failure as
  `:unrecoverable_restore_failure` (with both the restore failure and
  the original `:compile_error` message in `details.message`) instead
  of silently discarding it via `_ = restore(...)`. Per
  `mutagen.mutation_pipeline.r6`. *(mutagen-wrd.17)*
- `MutationLoop.run/1` spawns its per-site task via
  `Task.Supervisor.async_nolink(MutagenEx.TaskSup, ...)` instead of
  `Task.async/1`. The two-phase cancel keeps `Task.shutdown(task,
  cancel_grace_ms)` for the mailbox-drain window, then escalates to
  `Task.Supervisor.terminate_child(MutagenEx.TaskSup, task.pid)` —
  which propagates `Process.exit(_, :shutdown)` through the task's
  link tree, reaping untrapped linked grandchildren and OTP-supervised
  descendant subtrees synchronously with respect to the direct task
  pid and asynchronously for the descendant fan-out. A
  `Process.demonitor(task.ref, [:flush])` follows to prevent stale
  `:DOWN` messages accumulating in the runner's mailbox across timeout
  sites. The `.13` `:code.purge/1` post-timeout settle pass is retained
  on top. Per `mutagen.mutation_pipeline.r4` /
  `mutagen.mutation_pipeline.r14`. *(mutagen-wrd.18)*
- `CoverageRunner.run/1`'s `:cover_already_running` rejection message
  now names `MutagenEx.TaskSup` as the documented singleton owner of
  `:cover_server` and `ExUnit.Server` during a MutagenEx mutation cycle,
  and points readers at `.spec/decisions/supervision_tree.md`. Per
  `mutagen.coverage.r1` / `mutagen.coverage.r8`. *(mutagen-wrd.18)*
- The C1/C2 integration spikes under `test/mutagen_ex/integration/` are
  now tagged `:spike` and excluded from the default `mix test` run.
  `test/test_helper.exs` calls `ExUnit.start(exclude: [:e2e_slow,
  :spike])`. The spikes remain the gating decision artifact for the
  in-process pipeline (per `mutagen.decision.in_process_pipeline`) and
  are runnable on demand via `mix test --only spike`. Default `mix
  test` wall-clock drops from ~24s to ~1s; the smoke gate is no longer
  dominated by ~500 cover lifecycles every run. *(mutagen-wrd.28)*
- The C2 spike's iteration count is now controlled by the
  `MUTAGEN_SPIKE_ITERATIONS` env var (default `10`, original gating
  value `100`). The invariants — `failures == 0`, process growth ≤ 50,
  memory growth ≤ 1.5× — hold at any positive N; the count is a
  cycle-time knob, not a contract. C1's 100-iteration count is
  unchanged because its loop count IS the contract (restore fidelity
  measured across cycles). *(mutagen-wrd.28)*
- `README.md` documents the `:spike` opt-in and the
  `MUTAGEN_SPIKE_ITERATIONS` knob under a new "Test suite gates"
  subsection. *(mutagen-wrd.28)*

### Notes

- User-visible cancellation latency per timeout-classified site is
  dominated by `cancel_grace_ms` (100 ms by default). The supervisor's
  `:shutdown_timeout` (5_000 ms) bounds only a hypothetical scenario in
  which the per-site task itself traps `:shutdown`; in practice the task
  dies on the signal in microseconds and grandchild teardown is
  asynchronous afterwards. *(mutagen-wrd.18)*
- Closes F2-arch for the common grandchild classes (untrapped linked
  processes, OTP-supervised subtrees). Hand-rolled trap-exit'd
  GenServers that swallow `{:EXIT, _, :shutdown}` info messages remain
  out of reach; the `r7` snapshot-delta machinery continues to detect
  these as advisory growth signals.

### Removed

- `lib/mutagen_ex.ex` and `test/mutagen_ex_test.exs` (`mix new`
  placeholders) are deleted. The `MutagenEx` namespace is owned by its
  submodules; no top-level module body is necessary. *(mutagen-wrd.17)*
- The README's `.13` caveat ("re-run if the tail of the run looks
  wrong" after a timeout-classified mutation) is removed. The `.18`
  supervised teardown + `:code.purge` settle pass + recursive shutdown
  through the link tree close the underlying Code.Server hang condition.
  *(mutagen-wrd.18)*

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
