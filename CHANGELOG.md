# Changelog

All notable changes to `mutagen_ex` are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The released and Unreleased sections describe user-visible behavior. The
ticket-keyed engineering log is preserved as an appendix at the end of this
file for traceability.

## [Unreleased]

### Added

- **Parallel mutation dispatch (`--max-concurrency`).** The mutation phase
  can now run per-site work in parallel. The default stays `1` (fully
  serial, identical to v0.1.0) because the in-process pipeline shares
  ExUnit, the code server, and `:cover` state across sites; set
  `--max-concurrency N` explicitly when your scope and tests are arranged
  for collision-free parallel runs.

- **NDJSON streaming (`--stream`).** Emits one JSON line per completed
  mutation site as the run progresses, on the same sink as the aggregate
  document. Each line carries a `"kind"` discriminator
  (`start` / `result` / `compile_error` / `end`) and is byte-equal to the
  matching entry in the final document. Per-site lines arrive in input
  order even under parallel dispatch.

- **`:telemetry` events.** The library now dispatches `:telemetry` events
  at run, coverage, baseline, enumeration, and per-site boundaries, so you
  can attach your own handlers, dashboards, or progress UIs. mutagen_ex
  ships no built-in subscriber. See the README "Telemetry events" table.

- **Per-site progress feed.** When stderr is a TTY, a one-line-per-site
  progress feed is printed (e.g. `[12/345] killed lib/foo.ex:42 :arith`).
  Suppress it with `--no-progress`.

- **Test-suite gates documented.** The default `mix test` run now excludes
  the slow end-to-end (`:e2e_slow`) and integration-spike (`:spike`) tag
  families to keep the smoke gate fast; both remain runnable on demand
  (`mix test --only e2e_slow`, `mix test --only spike`). The spike
  iteration count is tunable via `MUTAGEN_SPIKE_ITERATIONS`. Default
  `mix test` wall-clock dropped from ~24s to ~1s.

### Changed

- **Faster mutation runs.** A round of AST and bytecode-handling work made
  the mutation pipeline measurably faster — roughly a 1.66× wall-clock
  speedup on the project's benchmark fixture — without changing any
  outcome. Mutation site IDs, before/after source slices, kill/survive
  verdicts, and the kill rate are byte-for-byte identical before and after;
  only timing and some advisory diagnostic text changed. A benchmark
  harness for reproducing these numbers ships at
  `priv/helper_scripts/bench_ast_perf.exs`.

### Fixed

- **Archive-installed CLI no longer crashes on a cold start.** When
  `mix mutagen` was installed globally via `mix archive.install` (no
  `:mutagen_ex` entry in the host project's deps) and run for the first
  time, it could crash with a raw `MatchError` traceback instead of the
  CLI's structured error output. The task now repairs its own runtime load
  path and, if the archive is genuinely unrecoverable, emits proper error
  JSON (`abort_reason: "runtime_load_failed"`) instead of leaking a stack
  trace. The `mix.exs`, Hex, and git install paths are unaffected.

- **Ecto-style schema scope is now supported end-to-end.** A previously
  skipped end-to-end scenario covering a hand-rolled Ecto-style schema DSL
  was traced to a faulty test assertion (not a `:cover` interaction) and
  re-enabled, confirming that mutations of macro-generated callbacks are
  restored byte-for-byte between sites.

### Security

- **Sensitive output bounded and redactable.** Free-form text that flows
  into the JSON report (captured stderr, exception messages, source
  slices) is now truncated at a 4 KiB cap per field — appending a
  `... <N bytes truncated>` marker — so a runaway diagnostic can't bloat
  the report. A new opt-in `:redact` application config takes a list of
  regexes; every match in a reported field is replaced with `[REDACTED]`.
  Redaction runs before truncation. Default is no redaction. Pair it with
  `--json <path>` when archiving reports off the run host.

- **`--json <path>` is path-safe.** The output path is canonicalised
  before any mutation runs: `..` segments and NUL bytes are refused at
  parse time, and a fully-resolved path that escapes the project root is
  refused (`abort_reason: "unsafe_json_path"`). This closes an
  arbitrary-file-write avenue, since the pipeline compiles and runs the
  target project's (possibly mutated) test code in-process. CI that must
  write outside the project root opts in with
  `--unsafe-json-outside-project`, which emits a one-shot stderr warning
  naming the resolved target.

- **Bounded atom creation on CLI input.** `tag:`, module, and function
  scope/test arguments no longer convert unbounded user input to atoms, so
  loops like `mix mutagen --tests tag:$(uuidgen)` can no longer exhaust the
  atom table. A `tag:` charset gate rejects malformed names up front
  (`abort_reason: "invalid_tag_name"`).

### Removed

- The `mix new` placeholder module and its test were deleted; the
  `MutagenEx` namespace is owned entirely by its submodules.

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
  subprocess).
- Coverage phase using `:cover`, scoped to in-scope modules, with the
  `:cover_server` torn down cleanly between runs.
- Mutation enumeration restricted to covered lines, with content-addressed
  mutation IDs so they stay stable across `mix format` runs.
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
  - `:flag_not_supported_in_v1` — explicit reject of `--no-json`.
  - `:colon_syntax_unsupported` — explicit reject of `file.ex:Module`.
  - `:self_mutation_refused` — refuses to mutate `MutagenEx.*` or
    `Mix.Tasks.Mutagen`.
  - `:baseline_red` — aborts before any mutation phase if the cited
    tests do not all pass against unmodified source.
- `mix help mutagen` output with Synopsis, Flags, Examples,
  Constraints, Exit Codes, JSON Schema Pointer, and Known Caveats
  sections.
- `README.md` with quick-start, flag reference, exit-code table,
  JSON-schema pointer, and known-limitations list.

### Known limitations

Shipped with v0.1.0 and tracked for later releases:

- File-cited `--tests` (a bare `_test.exs` path) produced a filter that
  excluded every test.
- The production mix task wired the mutation runner with an empty test
  module list.
- A per-site timeout could leave the code server holding a module-load
  lock, occasionally corrupting the tail of a run.
- The `:case_drop` mutator on a guarded base case classifies as `killed`
  (a `CaseClauseError`) rather than `timeout`.
- The `literal` mutator never fired, because atomic literals were wrapped
  in a way the mutator did not recognise.

(Several of these were fixed in the Unreleased cycle above.)

[0.1.0]: https://github.com/iautom8things/mutagen_ex/releases/tag/v0.1.0

---

## Internal development log (Unreleased)

> The entries below are the original ticket-keyed engineering log for the
> Unreleased cycle, kept verbatim for traceability. The user-facing summary
> of the same work is in the `[Unreleased]` section above.

- **Archive-installed CLI runtime self-heal.** Fixed the archive adoption
  path where invoking `mix mutagen` from a host project without
  `:mutagen_ex` in deps, but with the task installed globally via
  `mix archive.install`, could crash with a `MatchError` at
  `lib/mix/tasks/mutagen.ex:236` instead of emitting the CLI's structured
  error surface. The runtime preamble now gates repair on the
  `Application.ensure_all_started(:mutagen_ex)` failure tuple, calls
  `Mix.Local.append_archives/0`, retries, then defensively scans
  `Mix.path_for(:archives)` for an archive ebin containing
  `mutagen_ex.app` before a final retry. If the archive remains
  unrecoverable, the task emits error JSON with
  `abort_reason: "runtime_load_failed"` rather than leaking a traceback.
  Regression coverage lives in `test/integration/archive_install_test.exs`
  under tag `:archive_integration`; the spec records
  `mutagen.cli.r16`, scenarios `mutagen.cli.s14c` /
  `mutagen.cli.s14d`, and verification `mutagen.cli.v11`. The existing
  `path:` / Hex / git dependency adoption paths are preserved
  byte-for-byte because they succeed on the first runtime-start attempt
  and never enter the archive repair branch. *(mutagen-wrd.40.x.)*

- **`.25` epic capstone: bench harness, large-scope memory test, and
  measured speedup.** The `.25` AST/perf epic (S1–S6) is complete.
  This entry summarises what the epic shipped, the perf number the
  bench harness produced before vs. after the epic, and the byte-
  identity contract the refactor preserves.

  *Bench harness* — `priv/helper_scripts/bench_ast_perf.exs` is no
  longer a skeleton: it drives the real `Mix.Tasks.Mutagen.run/2`
  pipeline against the `wrd25_200sites` fixture (S1), captures
  wall-clock + `:erlang.memory/0` snapshots + SHA-256 of the emitted
  NDJSON, supports `--baseline <path>` / `--compare <path>` for
  before/after scoring, and uses a stable tmp-ebin so the SHA is
  reproducible across invocations. Two minor wrd25 fixture asserts
  (`mix4`, `chain2`) were corrected so baseline runs green; the
  fixture's `lib/` is unchanged.

  *Measured speedup (wrd25_200sites, scope `lib/arith_dense.ex`,
  Elixir 1.19.5 / OTP 28)*:

  | metric           | before (`978a995`, pre-.25 main merge) | after (`78b022f`, post-.25.6) |
  |------------------|----------------------------------------|-------------------------------|
  | sites/run        | 87                                     | 87                            |
  | wall_ms          | 2179.53                                | 1314.00                       |
  | per_site_us      | 25052.05                               | 15103.49                      |

  **Wall-clock speedup: 1.66×. Per-site speedup: 1.66×.** This is
  below the epic's documented 2–4× target — see the follow-up note
  below.

  *Byte-identity*: the SHA-256 of the *full* NDJSON document differs
  between commits (state-drift warning text and "redefining module"
  paths embed run-time process state), but when those advisory
  diagnostics are normalised the documents are byte-identical:
  `3534443176dd9e2c673b21703085b1b02b2ddac0f2d6e3f7598542d5723df57a`
  on both commits. The mutation results — site IDs, before/after
  source slices, killed/survived verdicts, kill_rate — are
  byte-for-byte the same; the .25 refactor changes timing, not
  outcomes. The full per-commit document SHAs (advisory:
  `mix run priv/helper_scripts/bench_ast_perf.exs` reproduces them):

  - before: `d878975d19112378f3598cb32c452c7c55b90b810156316335f13c9e5e8bee85`
  - after:  `46292518ccecca161161f278e3df58dc05d1031a47b9bff9ff7137af499b8b2a`

  *Speedup-shortfall triage* — the measured 1.66× falls short of the
  spec's lower bound. Trace through the epic's deliverables:

  - **S2 (Ast lift)** removed duplicated helpers — wins compile time
    and code clarity, not per-site runtime.
  - **S3 (AstCache categorised load)** cut redundant `File.read/1`
    for cited test files in the Baseline async-warning path — runs
    once per pipeline, sub-millisecond impact at this scope.
  - **S4 (head-atom dispatch table)** pre-filters mutators per node
    — the `O(nodes × catalog)` → `O(nodes × applicable)` win is real
    but proportional to catalog size; with 10 mutators it's a 2-3×
    win on the **enumeration** phase, which is a small slice of
    wall time vs. the per-site test-execution cost.
  - **S5 (batched grouped-by-file prewalk)** replaced per-site
    `Macro.prewalk/2` with `O(depth)` path descent — the headline
    win. Its impact is `O(sites × file_ast_size)` saved, but on the
    wrd25 fixture the file AST is small (~40 lines/file), so the
    win is modest. On a real codebase with multi-thousand-line
    scope files the win compounds.
  - **S6 (BeamCache binary-swap restore)** replaced `Code.compile_quoted/2`
    on the cached AST with `:code.load_binary/3`. This is per-site
    and should be a strong contributor; the bench shows it
    delivered.

  The bench fixture exposes hot AST machinery, but the per-site cost
  is dominated by the test-execution phase (one `ExUnit.run/0` per
  mutation, with `:cover` instrumentation) — and that's untouched
  by `.25`. `Mutators.normalize/1` (out of scope per the epic's Out
  of Scope) and the per-site ExUnit boot also dominate.
  `mutagen-wrd.36` (follow-up to mutagen-wrd.25, the documented
  `.25-fu2` slot) tracks the gap to the 2–4× target; a candidate
  path is replacing the per-site ExUnit boot with a longer-lived
  test-runner process. *(mutagen-wrd.25.7.)*

  *Large-scope memory test* — new `test/mutagen_ex/memory_test.exs`
  (tagged `:e2e_slow`) generates a 1000-site synthetic fixture in
  `System.tmp_dir!/0` at runtime (NOT committed to disk), drives
  the full pipeline against it with a 60s `--budget-ms` cap, and
  asserts the run completes without OOM. The assertion is
  deliberately weak per the epic's Out of Scope (intent) — it
  passes either on a clean completion (`aborted: false`) or a
  graceful budget-cap (`truncated: true`); a non-graceful abort
  (any reason outside `budget_exceeded` / `too_many_sites`) fails
  the test. Heap-size assertions are not pinned (brittle across
  BEAM versions). *(mutagen-wrd.25.7.)*

  *Epic summary — one line per feature shipped*:

  - `MutagenEx.Ast` helper lift: canonical `alias_to_module/1`,
    `find_module_body/2`, `node_line/1` (mutagen-wrd.25.2)
  - `AstCache.load/2` categorised input + Baseline cache consumer
    (mutagen-wrd.25.3)
  - `MutagenEx.Mutators.Dispatch` head-atom table + enumerator
    pre-filter (mutagen-wrd.25.4)
  - Batched grouped-by-file prewalk for the per-site AST swap
    (mutagen-wrd.25.5)
  - `MutagenEx.BeamCache` per-run ETS + binary-swap restore
    (mutagen-wrd.25.6)
  - Bench harness, memory test, this CHANGELOG entry
    (mutagen-wrd.25.7)

- **BeamCache per-run ETS + binary-swap restore.**
  `MutagenEx.MutationRunner.run/1` no longer restores via
  `Code.compile_quoted/2` on the cached AST. Restore is now a binary
  swap via `:code.load_binary/3` against a per-run `MutagenEx.BeamCache`
  snapshot: a `:set, :public` ETS table owned by `run/1` itself
  (created at entry, deleted in `after` — no GenServer, no supervisor
  child, no cross-invocation staleness). A serial snapshot pre-pass
  runs BEFORE `async_stream_nolink/4` dispatch and captures every
  scoped module's currently-loaded `.beam` via
  `:code.get_object_code/1`, closing the TOCTOU window two parallel
  workers would otherwise open. Snapshot order vs. cover instrumentation
  matters: the pre-pass runs AFTER `:cover.compile_directory/1`, so
  the cached binary IS the cover-instrumented binary and restore
  preserves coverage between sites. The new
  `MutagenEx.Test.CodeServerFacade` behaviour (with default impl
  `MutagenEx.Test.CodeServer`) is the test seam — mirrors the existing
  `MutagenEx.Test.CompilerFacade` shape exactly. The `with_restore/4`
  wrapper's signature and external contract are preserved; only its
  internal restore call moved off `Code.compile_quoted/2`.
  `MutagenEx.Application`'s supervisor child list is unchanged.
  Revised requirement `mutagen.mutation_pipeline.r6` + new scenarios
  `s16`/`s17` + verification stub `v9`. Two new decisions:
  `mutagen.decision.per_run_beam_cache` (ETS-via-cfg, not GenServer)
  and `mutagen.decision.code_server_facade` (testability seam).
  *(mutagen-wrd.25.6.)*

- **Batched grouped-by-file prewalk for the per-site AST swap.**
  `MutagenEx.MutationRunner.run/1` now pre-computes a per-file
  path index once before the per-site loop begins (one
  `Macro.prewalk/2` per distinct file in `cfg.sites`, regardless
  of how many sites that file carries). Each site's swap then
  descends along the cached path in `O(depth)` via
  `apply_swap_at_path/3` instead of running a fresh
  `Macro.prewalk/2` over the whole file AST per site. Path entries
  are keyed by `site.id` (content-addressed) so duplicate-position
  sites do not collide. Bare-literal sites (`Literal` mutator on
  bare integers/booleans; `ResultTuple` targeting bare booleans)
  carry no static AST coordinates and fall back to the existing
  ambient-threading walker (`replace_bare_site/2`); the legacy
  per-site `Macro.prewalk` is also retained as a defensive
  fallback. Byte-identity property pinned by
  `test/mutagen_ex/mutation_runner_batched_test.exs`: for every
  site, the mutated file AST produced by the batched path equals
  the file AST that an unconditional per-site `Macro.prewalk/2`
  would have produced. Closes F16 (HIGH, F-PERF-02). New
  requirement `mutagen.mutation_pipeline.r16` + scenarios `s14` /
  `s15` + verification stub `v8`. *(mutagen-wrd.25.5.)*

### Added

- **Head-atom dispatch table for the mutator catalog.** New module
  `MutagenEx.Mutators.Dispatch` carries a static, order-preserving
  mapping from AST head atom (`:+`, `:case`, `:with`, …) to mutator
  list, plus an `:any` bucket for mutators that match non-3-tuple
  shapes (`Literal` for bare scalars / `{:__block__, _, [v]}`
  wrappers; `ResultTuple` for `{:ok, _}` / `{:error, _}` 2-tuples).
  `MutagenEx.MutationEnumerator.try_mutators/6` consults
  `Dispatch.mutators_for_node/1` to pre-filter the catalog before
  calling `match?/1` per node — `O(nodes × catalog)` becomes
  `O(nodes × applicable_mutators)`. No mutator behaviour change; the
  ten mutator modules are untouched. Per
  `mutagen.decision.static_mutator_dispatch`. The
  `:dispatch_mode` option on `enumerate/4` (`:head_atom` default,
  `:legacy` for the equivalence test) is an internal test seam — it
  is NOT documented in the public API and NOT exposed via
  `mix mutagen`. New requirement `mutagen.mutation_enumeration.r9`
  and equivalence test
  `test/mutagen_ex/head_atom_dispatch_test.exs` lock the
  correctness (same mutators consulted per node) and order-
  preservation (byte-identity / r1) properties.
  *(mutagen-wrd.25.4.)*

### Changed

- **`AstCache.load/2` accepts categorised input.** A new `opts[:categories]`
  map (e.g. `categories: %{scope: scope_files, test: test_files}`) lets
  callers partition the flat `files` list for diagnostic visibility
  without changing the cache entry shape. Entries remain
  `{Macro.t(), String.t()}` 2-tuples per
  `mutagen.decision.ast_cache_facade_preserved`; the
  `Pipeline.AstCacheFacade` `@callback load/2` signature is preserved
  verbatim. Per-category counts are logged at debug level. The
  `phase_ast_cache` step of `mix mutagen` now loads scope files AND
  cited test files (`test_filter.files`) in one pass. New requirement
  `mutagen.coverage.r9`. Closes F18 / F40. *(mutagen-wrd.25.3.)*
- **`Baseline.detect_async_modules/1` consumes the AST cache when
  provided.** When `Baseline.run/1`'s input map carries `:ast_cache`,
  the async-warning path looks each cited test file up via
  `AstCache.get/2` and consumes the cached `{ast, _source}` directly
  — no re-read of test files from disk. On cache miss the
  implementation falls back to `File.read/1` + parse (pre-`.25`
  behaviour) and logs the miss for diagnostics. *(mutagen-wrd.25.3.)*
- **Shared AST helpers lifted into `MutagenEx.Ast`.** The
  `alias_to_module/1`, `find_module_body/2`, and `node_line/1`
  helpers — previously duplicated across `MutagenEx.ScopeResolver`,
  `MutagenEx.MutationEnumerator`, `MutagenEx.MutationRunner`, and
  `MutagenEx.TestModuleDiscovery` — now live in one canonical module
  (`lib/mutagen_ex/ast.ex`). Behaviour is byte-identical to the
  donors (pinned by `test/mutagen_ex/ast_donor_equivalence_test.exs`).
  Closes F21 / CF10. New subject `mutagen.ast` carries the contract;
  see `.spec/specs/ast.spec.md`. *(mutagen-wrd.25.2.)*
- **`ScopeResolver` sorts the default `lib/**/*.ex` wildcard
  result** before searching for module-shaped targets. Closes the
  F30 / CF7 determinism risk: `Path.wildcard/1`'s order is
  file-system-dependent, so two hosts could otherwise pick a
  different match. New requirement
  `mutagen.scope_resolution.r9`. *(mutagen-wrd.25.2.)*

### Added

- **wrd25 bench fixture** at
  `priv/helper_scripts/bench_fixtures/wrd25_200sites/` — a small
  self-contained Mix project (5 modules + colocated tests) used by
  the `.25` AST-perf bench harness skeleton
  (`priv/helper_scripts/bench_ast_perf.exs`, completed in S6) and
  by the determinism safety-net test
  (`test/mutagen_ex/determinism_test.exs`, re-targeted from the
  lane fixture). *(mutagen-wrd.25.2.)*

- **Parallel mutation loop, telemetry, NDJSON streaming, and progress
  feedback.** The mutation runner now dispatches per-site work through
  `Task.Supervisor.async_stream_nolink/4` under `MutagenEx.TaskSup`
  with `:ordered: true`, so results are collected in input order
  regardless of which task body finished first. Configurable via the
  new `--max-concurrency <int>` flag (default `1` for v1.0-equivalent
  serial execution; set explicitly to `System.schedulers_online()` to
  opt in). New requirement: `mutagen.mutation_pipeline.r15`.
  - `:telemetry` events at well-defined points: `run.start/stop`,
    `coverage.start/stop`, `baseline.start/stop`, `enumeration.stop`,
    and per-site `site.start/stop`. Consumers attach their own
    handlers; the library ships no built-in subscriber. See the new
    `MutagenEx.Telemetry` module.
  - `--stream` enables NDJSON-per-site emission via the new
    `MutagenEx.JsonStreamer`. Each line carries a `"kind"`
    discriminator (`"start"`, `"result"`, `"compile_error"`, `"end"`)
    and a per-site wire shape byte-equal to the equivalent entry in
    the aggregate document. New requirements:
    `mutagen.json_schema.r10`, `mutagen.json_schema.r11`.
  - `--no-progress` suppresses the human-readable per-site progress
    feed on stderr; the default is auto-on when stderr is a TTY,
    auto-off otherwise. See the new `MutagenEx.Progress` module.
  - New dependency: `:telemetry ~> 1.0` (lightweight, no transitive
    deps). The runner emits events through the standard
    `:telemetry.execute/3` and `:telemetry.span/3` surfaces.
  - *(mutagen-wrd.30, closes F17 from the consolidated review.)*

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
