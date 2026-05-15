# mutagen.coverage — :cover lifecycle + AST cache

Runs `:cover` against the cited tests to determine which source lines they
exercise, and parses each in-scope source file once into a cached AST that
later phases use for site enumeration and bytecode restore.

## Intent

Two responsibilities collapsed into one subject because they share lifecycle:
both happen exactly once per `mix mutagen` run, both run before any mutation
phase, and both leave per-mutation phases free to assume their outputs as
constants.

- **Coverage**: produces `covered_lines :: %{file => MapSet.t(line)}` for the
  scoped files.
- **AST cache**: produces `ast_cache :: %{file => {quoted, source_text}}` for
  every in-scope file. `source_text` is kept so the JSON's `before_source`
  slice can be cut by `{line, col, end_line, end_col}` from AST metadata
  without re-reading disk.

## Out of scope for this subject

- The pre-mutation test pass with hard-fail semantics (see
  [mutagen.mutation_pipeline](mutation_pipeline.spec.md) — the baseline
  phase).
- Per-mutation runs (also in mutation_pipeline).

```spec-meta
id: mutagen.coverage
kind: module
status: draft
summary: One-shot :cover run plus AST + source-text caching for downstream phases.
surface:
  - lib/mutagen_ex/coverage_runner.ex
  - lib/mutagen_ex/ast_cache.ex
decisions:
  - mutagen.decision.in_process_pipeline
  - mutagen.decision.serial_execution_and_seed
  - mutagen.decision.supervision_tree
```

```spec-requirements
- id: mutagen.coverage.r1
  priority: must
  statement: |
    `CoverageRunner.run/1` checks for an already-running `:cover` server
    before starting. If `Process.whereis(:cover_server)` returns a pid, the
    run aborts with a structured error
    `{:error, :cover_already_running, %{message: msg}}` whose `msg` names
    `MutagenEx.TaskSup` as the documented singleton owner during a MutagenEx
    mutation cycle and points to `.spec/decisions/supervision_tree.md`. The
    pipeline halts and emits the error-shaped JSON.

- id: mutagen.coverage.r2
  priority: must
  statement: |
    After `CoverageRunner.run/1` returns (success or error), `:cover.stop/0`
    has been called at least once. The implementation guards the call with
    `try/rescue` so repeated stops are idempotent. The stop happens in an
    `on_exit/1` callback in the implementation tests; per
    mutagen.decision.in_process_pipeline this is part of the in-process
    state-hygiene contract.

- id: mutagen.coverage.r3
  priority: must
  statement: |
    After successful `CoverageRunner.run/1`, for every module that was
    cover-instrumented, `:code.which/1` returns a non-`cover_compiled` value
    (i.e., the path to a real `.beam` or the atom `:non_existing`). This is
    the property cover-compatible restore depends on; failure means
    subsequent `Code.compile_quoted/1` calls may not replace the cover-
    instrumented module.

- id: mutagen.coverage.r4
  priority: must
  statement: |
    `CoverageRunner.run/1` forces `ExUnit.configure(max_cases: 1, seed:
    config.seed)` before running. Concurrent test execution is not permitted
    in v1 per mutagen.decision.serial_execution_and_seed.

- id: mutagen.coverage.r5
  priority: must
  statement: |
    `CoverageRunner.run/1` produces a `covered_lines` map of shape `%{file
    => MapSet.t(non_neg_integer)}` keyed by relative file path. The map
    contains entries only for files inside `Config.scopes` — coverage data
    for out-of-scope files is discarded before return.

- id: mutagen.coverage.r6
  priority: must
  statement: |
    `AstCache.load/1` reads each in-scope source file exactly once,
    parses with `Code.string_to_quoted/2` requesting line/column metadata,
    and stores both the AST and the verbatim source text. The cache is
    immutable after the first build; no later phase mutates it. The
    `source_text` is byte-identical to `File.read!(file)` at the moment of
    load — critical for `before_source` slice correctness.

- id: mutagen.coverage.r7
  priority: must
  statement: |
    Neither `CoverageRunner.run/1` nor `AstCache.load/1` modifies any file
    on disk. The working tree is byte-identical before and after both
    complete, asserted across at minimum:
      * `lib/**/*.{ex,exs}` — source surface.
      * `_build/**/*.{beam,app}` — compiled artifacts. Cover-instrumented
        modules live in memory; .beam files on disk must not change.
      * `cover/**` — coverage reports. The runner produces
        `covered_lines :: %{file => MapSet.t(line)}` in memory and
        does not call `:cover.analyse_to_file/*`.
      * Host project config: `mix.exs`, `mix.lock`, `.formatter.exs`.
      * Tmp entries created with a `mutagen_ex_`-attributable prefix
        under `System.tmp_dir!()`.
    Allowed-write list: NONE. AST cache and coverage results live
    in-process per mutagen.decision.in_process_pipeline; nothing
    persists to disk.

- id: mutagen.coverage.r8
  priority: must
  statement: |
    `MutagenEx.TaskSup` is the documented singleton owner of two
    BEAM-global named processes (`:cover_server` and `ExUnit.Server`)
    during a MutagenEx mutation cycle. A second concurrent caller in
    the same BEAM is refused per mutagen.coverage.r1 once the first
    caller has registered `:cover_server`. The window between the
    first caller's `cover_already_running?/1` check and its
    `:cover.start/0` is not guarded by this contract; concurrent
    callers entering during that window collide on `:cover.start/0`
    and fall back to the existing
    `{:error, {:already_started, _pid}} -> :ok` path. Closing this
    window is a v2 mitigation target (see
    `.spec/decisions/supervision_tree.md` §"Won't-Have").
```

```spec-scenarios
- id: mutagen.coverage.s1
  covers: [mutagen.coverage.r1]
  given: |
    Another process started `:cover` and holds the `:cover_server` named
    process before `mix mutagen` runs.
  when: `CoverageRunner.run/1` is invoked.
  then: |
    The run returns `{:error, :cover_already_running}` immediately. No
    `:cover.compile_*` call is made.

- id: mutagen.coverage.s2
  covers: [mutagen.coverage.r2]
  given: |
    A successful coverage run.
  when: We inspect process state afterwards.
  then: |
    `Process.whereis(:cover_server)` is `nil` (cover stopped). Calling
    `CoverageRunner.run/1` a second time in the same VM succeeds — the
    first stop did not leave cover in a broken state.

- id: mutagen.coverage.s3
  covers: [mutagen.coverage.r3]
  given: |
    `Foo` was cover-instrumented during the run.
  when: After `CoverageRunner.run/1` returns successfully, we call
        `:code.which(Foo)`.
  then: |
    The return value is the actual `.beam` path string, not the atom
    `:cover_compiled`.

- id: mutagen.coverage.s4
  covers: [mutagen.coverage.r4]
  given: A `Config{seed: 42}` passed to `CoverageRunner.run/1`.
  when: The runner starts.
  then: |
    `ExUnit.configuration()[:max_cases] == 1` and
    `ExUnit.configuration()[:seed] == 42` at the moment ExUnit begins
    executing test files.

- id: mutagen.coverage.s5
  covers: [mutagen.coverage.r5]
  given: |
    A run scoped to `lib/foo.ex` whose cited tests also exercise
    `lib/unrelated.ex` (because `foo` calls into it).
  when: `CoverageRunner.run/1` returns.
  then: |
    The returned `covered_lines` map has a key for `lib/foo.ex` and does NOT
    have a key for `lib/unrelated.ex`.

- id: mutagen.coverage.s6
  covers: [mutagen.coverage.r6]
  given: |
    A scope referencing `lib/foo.ex`.
  when: `AstCache.load/1` runs.
  then: |
    The cache contains `{"lib/foo.ex", {quoted, source_text}}` where
    `source_text == File.read!("lib/foo.ex")` at the moment `load/1` was
    called. A subsequent `AstCache.get(cache, "lib/foo.ex")` returns the
    same `{quoted, source_text}` tuple.

- id: mutagen.coverage.s7
  covers: [mutagen.coverage.r7]
  given: |
    `lib/foo.ex` with a known SHA-256 hash before the run.
  when: `CoverageRunner.run/1` + `AstCache.load/1` complete.
  then: |
    The hash is unchanged. No file under `cover/`, `_build/`, or `lib/` was
    written by these phases.

- id: mutagen.coverage.s8
  covers: [mutagen.coverage.r1, mutagen.coverage.r8]
  given: |
    `:cover_server` is registered on the BEAM (simulating an
    in-flight MutagenEx mutation cycle).
  when: |
    A caller invokes `MutagenEx.CoverageRunner.run/1` with a
    well-formed input
    (`%{seed: 0, in_scope_modules: [],
       test_filter: %TestFilter{include: [], exclude: [], files: []}}`).
  then: |
    The call returns `{:error, :cover_already_running, %{message: msg}}`
    immediately, without entering the cover lifecycle. `msg` names
    `MutagenEx.TaskSup` as the singleton owner.
```

```spec-verification
- id: mutagen.coverage.v1
  covers: [mutagen.coverage.r1, mutagen.coverage.r2, mutagen.coverage.r3, mutagen.coverage.r4]
  kind: command
  command: mix test test/mutagen_ex/coverage_runner_test.exs
  execute: true

- id: mutagen.coverage.v2
  covers: [mutagen.coverage.r5]
  kind: command
  command: mix test test/mutagen_ex/coverage_runner_test.exs --only scope_filter
  execute: true

- id: mutagen.coverage.v3
  covers: [mutagen.coverage.r6]
  kind: command
  command: mix test test/mutagen_ex/ast_cache_test.exs
  execute: true

- id: mutagen.coverage.v4
  covers: [mutagen.coverage.r7]
  kind: command
  command: mix test --only spike test/mutagen_ex/integration/c1_test.exs
  execute: true

- id: mutagen.coverage.v5
  covers: [mutagen.coverage.r1, mutagen.coverage.r8]
  kind: command
  command: mix test test/mutagen_ex/supervision_test.exs
  execute: true
```
