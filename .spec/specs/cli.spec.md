# mutagen.cli — `mix mutagen` command-line contract

The user-facing surface of `mutagen_ex`. `mix mutagen` is the only entry point:
it parses flags, validates them, hands off to the orchestration pipeline, and
emits a single JSON document to stdout (or to `--json <path>` if requested).

## Intent

The verifier judge (an LLM downstream) consumes the JSON; humans invoke the
tool to spot-check that judge's reasoning. The CLI is therefore a stable
machine surface first, a human surface second. Flag semantics, exit codes, and
output discipline are part of the contract — changes here ripple to the judge
prompt and to every CI integration.

## Out of scope for this subject

- The mutation algorithm itself (see [mutagen.mutators](mutators.spec.md)).
- The orchestration state machine (see
  [mutagen.mutation_pipeline](mutation_pipeline.spec.md)).
- The JSON output schema (see [mutagen.json_schema](json_schema.spec.md)).
  This subject only asserts that the CLI **emits** the schema's documents at
  the right moments.

```spec-meta
id: mutagen.cli
kind: module
status: active
summary: Parses CLI flags, validates them, and gates entry into the pipeline; owns exit-code discipline.
surface:
  - lib/mutagen_ex/config.ex
  - lib/mix/tasks/mutagen.ex
  - lib/mutagen_ex/cli.ex
  - lib/mutagen_ex/config.ex
  - lib/mutagen_ex/json_path.ex
  - lib/mutagen_ex/pipeline/default_io.ex
  - lib/mutagen_ex/runtime.ex
  - lib/mutagen_ex/types.ex
decisions:
  - mutagen.decision.changed_code_run
  - mutagen.decision.report_text_policy
  - mutagen.decision.serial_execution_and_seed
  - mutagen.decision.per_mutant_fail_fast
  - mutagen.decision.no_pretty_output_v1
  - mutagen.decision.scope_syntax_simplified
  - mutagen.decision.self_mutation_refused
  - mutagen.decision.preamble_in_run1_only
  - mutagen.decision.adoption_polish_efficacy
  - mutagen.decision.ancora_migration
  - mutagen.decision.host_test_setup
```

```spec-requirements
- id: mutagen.cli.r1
  priority: must
  statement: |
    `mix mutagen` accepts `--scope <target>` (repeatable) where each
    target is a file path, a module name, or `Module.fun/arity`. Targets are
    accumulated into a list on `%Config{}`. Without `--since`, if `--scope` is omitted, the task
    exits with an error-JSON document (per mutagen.json_schema) and a non-zero
    exit code.

- id: mutagen.cli.r2
  priority: must
  statement: |
    `mix mutagen` accepts `--tests <target>` (repeatable) where each
    target is a file path, a `file:line` pair, or `tag:<name>`. Targets are
    accumulated into a list on `%Config{}`. Without `--since`, if `--tests` is omitted, the task
    exits with an error-JSON document and a non-zero exit code.

- id: mutagen.cli.r3
  priority: must
  statement: |
    `--timeout-ms <n>` populates `Config.timeout_ms` as a positive integer.
    The default ceiling is 30000. Non-positive or non-integer values cause an error-JSON
    exit before any pipeline phase runs.

- id: mutagen.cli.r4
  priority: must
  statement: |
    `--seed <n>` populates `Config.seed` and is propagated to
    `ExUnit.configure(seed: n)` for every test-running phase. Default is 0.
    Per mutagen.decision.serial_execution_and_seed, the seed governs ExUnit
    test ordering only — mutation enumeration order is independent of the
    seed.

- id: mutagen.cli.r5
  priority: must
  statement: |
    `--json <path>` writes the final JSON document to `<path>` instead of
    stdout. If the flag is absent, the document is written to stdout. In
    either case the document is terminated by a single newline. When the
    file cannot be written safely, the document goes to stdout instead
    (r23).

    While `Mix.Tasks.Mutagen.run/1` executes, Mix tasks, host code, test
    helpers, ExUnit formatters, and the default `:logger` console handler
    write to stderr. Stdout carries only the final document and, with
    `--stream` and no `--json`, the NDJSON lines before it.

- id: mutagen.cli.r6
  priority: must
  statement: |
    `mix mutagen` exits 0 on successful completion (pipeline ran to the end,
    even if every mutation survived). Non-zero exits are reserved for "bad
    input" cases: unparseable flags, unresolvable scope, no tests match, a
    host setup failure (r18, r19, r21, r22), a cited selection that runs
    no tests, red baseline, or unrecoverable pipeline errors. Mutagen
    writes an error document for its own non-zero exits. A host callback
    that calls System.halt/1 controls the VM exit code and can leave a
    completed report when it halts during after-suite cleanup.

- id: mutagen.cli.r7
  priority: must
  statement: |
    `--no-json` is not a recognised flag in v1. If supplied, `mix mutagen`
    exits with an error-JSON document explaining that pretty terminal output
    is deferred to v1.1.

- id: mutagen.cli.r8
  priority: must
  statement: |
    `mix mutagen` refuses to run if any `--scope` target resolves to a module
    in the `MutagenEx.*` or `Mix.Tasks.Mutagen` namespace, per
    mutagen.decision.self_mutation_refused. The error-JSON `reason` field is
    `:self_mutation_refused`.

- id: mutagen.cli.r9
  priority: should
  statement: |
    The `mix help mutagen` output contains a Synopsis, Flags, Examples,
    Constraints, Exit Codes, and Known Caveats section. The Synopsis and
    Flags sections document `--no-progress`. The Caveats section
    enumerates: state drift on `use SomeModule`, macro mutation slowdown,
    equivalent mutants, mix-format ID stability under scheme 2,
    no `--no-json` in v1, `--seed` controls ExUnit ordering, scope colon
    syntax dropped, self-mutation refused, the `--json` path-safety
    contract (r10), and the `tag:NAME` charset gate (r11).

- id: mutagen.cli.r10
  priority: must
  statement: |
    `--json <path>` is canonicalised before any mutation phase runs. The
    path-safety contract has two layers:

      1. Pure-string checks at parse time. A `--json` value containing a
         NUL byte (`\0`) or any `..` segment is refused with an error-JSON
         document whose `abort_reason` is `"unsafe_json_path"`. No mutation
         phase runs.
      2. Filesystem canonicalisation before the first mutation phase.
         Every existing component of the path is resolved through
         `File.read_link/1`. If any symlink target escapes the project
         root (defined as `File.cwd!/0` resolved through `Path.expand/1`),
         the run aborts with `abort_reason: "unsafe_json_path"`. The
         final component is allowed to not yet exist — it is created at
         write time. After canonicalisation, the resolved absolute path
         is stored on `Config.json_path`.

    The default policy is: the resolved path MUST live inside the project
    root. Passing `--unsafe-json-outside-project` opts out of that check
    (the symlink-escape check still runs at every component, but the
    inside-root check is bypassed). When the flag is set, `mix mutagen`
    emits a one-shot warning to stderr at startup naming the resolved
    target path. `Config.unsafe_json_outside_project` is `true` iff the
    flag was passed.

- id: mutagen.cli.r11
  priority: must
  statement: |
    `--tests tag:NAME` targets are validated at parse time against the
    charset `~r/\A[a-z][a-z_0-9]{0,63}\z/`: NAME must start with `a-z` and
    consist of `a-z`, `0-9`, or `_` thereafter, up to 64 characters total.
    Targets that fail the regex return `{:error, :invalid_tag_name, %{flag:
    "--tests", target: "tag:<bad>", message: ...}}` from `CLI.parse/1`
    before any test selector resolution runs. This is the front-door bound
    for the atom-table-DOS risk (mutagen-wrd.20): even with a downstream
    string-comparison fallback in `mutagen.test_selection` (r7), the
    charset gate keeps adversarial CI loops (`mix mutagen --tests
    tag:$(uuidgen)`) from reaching the resolver at all. Non-`tag:` `--tests`
    targets (file paths, `file:line`) are not gated by this rule — they
    don't feed atom resolution.

- id: mutagen.cli.r12
  priority: must
  statement: |
    Resource caps protect the runtime from runaway input shapes (closes
    F28 / CF11 — security M1, performance F-PERF-07/12):

      1. `--scope` accepts at most 100 occurrences. The 101st occurrence
         is refused at parse time with `reason: :too_many_targets`. The
         error-JSON `details` map carries `flag: "--scope"`, `kind:
         :scope`, `cap: 100`, and `count: <n>`. The cap is structural
         — enforced before any scope resolution. The `tag:NAME` charset
         gate (r11) runs before this cap, so invalid tag names are
         rejected at parse time regardless of count.
      2. `--tests` accepts at most 100 occurrences with the same shape
         (`flag: "--tests"`, `kind: :tests`).
      3. `--max-sites <n>` populates `Config.max_sites` as a positive
         integer. Default 10_000. Non-positive or non-integer values
         cause an error-JSON exit with `reason: :invalid_max_sites`
         before any pipeline phase runs.

    The `--max-sites` cap is enforced inside the mutation enumerator
    (see `mutagen.mutation_enumeration.r7`); the cap value flows from
    `Config.max_sites` through the orchestrator. Exceeding it aborts
    the pipeline with `abort_reason: "too_many_sites"` before the
    mutation runner starts.

- id: mutagen.cli.r13
  priority: must
  statement: |
    `--budget-ms <n>` populates `Config.budget_ms` as an optional
    positive integer aggregate wall-clock budget for the mutation
    phase, in milliseconds. Absence leaves `Config.budget_ms == nil`,
    which means unbounded — the per-site `--timeout-ms` is still the
    only cap.

    When the budget elapses, the mutation runner stops dispatching
    further sites and returns the partial result it has accumulated.
    The final JSON document on stdout (or `--json <path>`) carries
    `truncated: true` at the top level and the `mutation` block
    reflects only the completed sites. `aborted` stays `false` —
    truncation is a graceful early exit, not an abort. The site whose
    completion crossed the budget is included in `mutation.results`.
    Under `--stream`, its `result` line comes before the `end` line,
    and the streamed result lines match the aggregate `mutation.results`.

    The runner does NOT interrupt an in-flight site; the worst-case
    overshoot is one `timeout_ms`. Non-positive or non-integer
    `--budget-ms` values cause an error-JSON exit with `reason:
    :invalid_budget_ms`.

- id: mutagen.cli.r14
  priority: must
  statement: |
    `Mix.Tasks.Mutagen.run/1` parses the flags and validates the `--json`
    destination (r10) before it touches the host project. It then prepares
    the host's test environment through `MutagenEx.Runtime.boot/1`, in
    this order:

      1. The Mix environment check (r18) and the umbrella-root refusal
         (r19).
      2. `Mix.Task.run("loadpaths")`, then `Mix.Task.run("compile",
         ["--return-errors"])` with the `:ex_unit` application loaded, so
         the host's modules and compiled test support are on the code
         path and `:code.which/1` can locate scope modules.
      3. Inside the boot deadline (r21), in one boot process:
         `Mix.Task.run("app.config")`, which loads `config/runtime.exs`;
         the test alias pre-steps (r22); `Mix.Task.run("app.start",
         ["--temporary"])`, which starts the consumer project's OTP
         application so Repo/Sandbox, PubSub, Mox, and supervised support
         processes required by tests are alive;
         `Application.ensure_all_started(:mutagen_ex)`, which boots
         `MutagenEx.Application` so `MutagenEx.TaskSup` is alive when
         `MutationLoop` dispatches per-site tasks (see
         [mutagen.mutation_pipeline](mutation_pipeline.spec.md) and
         mutagen.decision.supervision_tree); `ExUnit.start(autorun:
         false)`; and `Code.require_file/1` of `test_helper.exs` from
         each entry of the project's `:test_paths`.

    After every Mix task in this sequence the preamble calls
    `Mix.Local.append_archives/0`, so an archive-installed `mutagen_ex`
    stays on the code path when a Mix task prunes archive paths. When the
    project config sets no `:test_paths`, the paths default to
    `["test"]` if a `test/` directory exists and to `[]` otherwise, so a
    project without `test/` needs no helper. ExUnit autorun stays
    disabled after the helpers load: `CoverageRunner`, `Baseline`, and
    `MutationLoop` each drive `ExUnit.run/0` themselves per the
    in-process pipeline contract. The boot process stays alive until the
    run finishes, so processes the helper linked to it stay available to
    every pass.

    Without this preamble, a downstream caller invoking `mix mutagen`
    from a fresh shell against their own project aborts with
    `:module_beam_missing` (modules not loaded), `:test_file_load_failed`
    (ExUnit not started, raising `cannot use ExUnit.Case without
    starting the ExUnit application`), a no-process crash on
    `MutagenEx.TaskSup` (`:mutagen_ex` application not started), or
    host-test setup failures because the host OTP supervision tree, the
    runtime config, or the helper's setup never ran.

    `--no-host-app` and `MUTAGEN_NO_HOST_APP=1|true|yes` opt out of the
    `app.start` step only. Runtime configuration, alias pre-steps,
    `:mutagen_ex` start and helper evaluation still run. This is
    reserved for self-test sandboxes and libraries that deliberately want
    minimal host boot.

    The preamble lives in `run/1` ONLY. `run/2` (the documented test
    seam) stays preamble-free per
    mutagen.decision.preamble_in_run1_only. The existing test suite
    drives the Mix task via `run/2` from inside an already-running
    `mix test` invocation; running the preamble again would risk
    double-compile and ExUnit ordering conflicts.

    Library callers invoking `MutagenEx.MutationRunner.run/1` directly
    (the documented library entry per `README.md`) are responsible for
    ensuring `:mutagen_ex` is started themselves. The library entry is
    NOT in this requirement's surface — `r14` covers the CLI entry only.

- id: mutagen.cli.r15
  priority: must
  statement: |
    When `--json <path>` is refused under r10's path-safety contract
    (either the parse-time `..`/NUL pure-string check or the filesystem
    canonicalisation symlink-escape check), the error-JSON document
    does NOT land at the rejected path. It is written to stdout
    instead. This refines r10: the safety check rejects the path
    semantically AND ensures no write touches the rejected target.

    Implementation: when the json-path validation phase returns
    `{:abort, _report, _config, :unsafe_json_path, _details}`, the
    abort emission path MUST clear `Config.json_path` (set to `nil`)
    before invoking the IO sink. Downstream IO routing keys on
    `json_path: nil` to emit to stdout per r5.

    Counter-example (pre-fix bug): a user runs
    `mix mutagen --json /tmp/foo.json` outside the project root with
    no `--unsafe-json-outside-project`. r10 correctly rejects with
    `abort_reason: "unsafe_json_path"`, but the error JSON is then
    written to `/tmp/foo.json` anyway — undermining the safety
    guarantee a downstream consumer relies on. The fix is mandatory:
    the rejected path must not be written to under any abort variant.

- id: mutagen.cli.r16
  priority: must
  statement: |
    When `mix mutagen` is invoked via a globally-installed archive
    (`mix archive.install ./mutagen_ex-X.Y.Z.ez`) from a project that
    does NOT carry `:mutagen_ex` as a dependency in its `mix.exs`, the
    runtime preamble self-heals the `:code` path so the OTP application
    can boot. Concretely: if `Application.ensure_all_started(:mutagen_ex)`
    in `MutagenEx.Runtime.boot/1` returns an error tuple of the shape
    `{:error, {:mutagen_ex, {_, ~c"mutagen_ex.app"}}}` (or the related
    `:non_existing` variants), the preamble calls
    `Mix.Local.append_archives/0` and retries; if the retry still errors,
    it scans `Mix.path_for(:archives)` for a directory whose
    `Mix.Local.archive_ebin/1` contains `mutagen_ex.app`, calls
    `:code.add_pathz/1` on that ebin, and retries a third time. If all
    three attempts fail, the run aborts with
    `abort_reason: "runtime_load_failed"` and a fixed `details.hint`
    that tells the user to reinstall the archive. The document goes to the
    destination of r5 and r19, and the task exits non-zero per r6. It
    MUST NOT raise a `MatchError` or put a traceback in the document.

    The repair branch is gated by the failure-tuple shape from
    `Application.ensure_all_started/1`. It runs zero code on the
    `path:` / `hex` / `git` dep adoption paths covered by r14, because
    those paths return `{:ok, _apps}` from the first attempt and never
    enter the repair branch. This refines r14: the preamble's contract
    covers both adoption shapes — dep-style and archive-installed —
    with identical observable behaviour.

    `run/1` loads `MutagenEx.JsonReporter`,
    its dependencies including `MutagenEx.JsonReporter.Sanitizer`,
    `MutagenEx.JsonStreamer`, `MutagenEx.JsonPath`, and
    `MutagenEx.Pipeline.DefaultIo` from the ebin that holds
    `Mix.Tasks.Mutagen`, before host setup and again after it, so a host
    module with one of those names does not replace the report path. If
    one of those modules cannot load from that ebin, for example because
    its `.beam` file is missing or corrupt, the run aborts with
    `abort_reason: "runtime_load_failed"` and `details.module` with
    the module name. The opted-in message names the load error. A failure
    before host setup aborts before host setup starts. Neither case
    raises. The document's `meta.tool_version` is the version
    `mutagen_ex` was built with.

- id: mutagen.cli.r17
  priority: must
  statement: |
    `Config.fail_fast` is `true` unless the arguments include
    `--no-fail-fast`, which sets it to `false`. `mix mutagen` passes the
    value to the mutation phase as `fail_fast`
    (mutagen.mutation_pipeline.r20) and reports it as `meta.fail_fast` in
    every document it emits after parsing. A document emitted because
    parsing failed reports `meta.fail_fast: true`. Baseline and coverage
    run the same way in both modes.

- id: mutagen.cli.r18
  priority: must
  statement: |
    `mix mutagen` prepares the host only in a test environment, by the
    rule `mix test` applies. When `Mix.env()` is `:test`, or the
    `MIX_ENV` variable is set explicitly to any value (for example
    `MIX_ENV=ci`), the run proceeds in that environment. When `MIX_ENV`
    is unset and Mix resolved any other environment, the run aborts with
    `abort_reason: "invalid_mix_env"` before `loadpaths` or `compile`
    runs. Its hint tells the user to run with MIX_ENV=test. The opted-in
    `details.message` names the current environment, repeats
    the original command prefixed with `MIX_ENV=test` (arguments
    shell-quoted when needed), and names the
    `def cli, do: [preferred_envs: [mutagen: :test]]` setting for
    `mix.exs`.

- id: mutagen.cli.r19
  priority: must
  statement: |
    A failure while `Mix.Tasks.Mutagen.run/1` prepares the host aborts
    the run with one error-JSON document and a non-zero exit. The
    `abort_reason` names the failing step:

      * `"umbrella_root"` when the current project is an umbrella root,
        checked before `loadpaths`. `details.hint` tells the user to
        run from `apps/<app>`.
      * `"host_loadpaths_failed"` when `mix loadpaths` fails.
      * `"host_compile_failed"` when host compilation reports an error.
      * `"host_app_start_failed"` when runtime configuration or the host
        application start fails.
      * `"runtime_load_failed"` when `:mutagen_ex` cannot start or a
        report module cannot load from the tool's ebin (r16).
      * `"test_helper_load_failed"` when a `test_helper.exs` is missing,
        raises, throws, or exits. `details.file` names that helper.
        `details.line` is the line of the helper's own stack frame, or of
        the compile error in it, when there is one. When the failure
        came from another `.exs` file the helper evaluated, such as a
        seeds script, `details.origin_file` and `details.origin_line`
        name the innermost such frame.

    If the boot process exits during a step, for example because a
    process linked to it exits, the run aborts with that step's reason.
    For these steps an opted-in `details.message` is redacted and capped
    at the report boundary. The term after
    `no match of right hand side value:` is replaced with
    `[REDACTED]`. Stderr receives the full diagnostic and stacktrace.

    Every document from a host setup failure, including those of r18,
    r21, and r22, carries `details.note` with the text
    `Stderr may carry unredacted host output. Do not publish it as a CI
    artifact.` Host code still writes raw values to stderr through its
    own messages.

    Every host setup abort, including those of r18, r21, and r22, writes
    its document to the destination validated under r10 (stdout, or the
    `--json` file) and writes no `--stream` lines.

- id: mutagen.cli.r20
  priority: must
  statement: |
    After the helpers load, every coverage, baseline, and mutation pass
    keeps the ExUnit configuration the helpers set, except for the
    options Mutagen sets for its phase: `seed` (r4), `max_cases: 1`,
    `max_failures` (unbounded in coverage and baseline, and set by
    mutagen.mutation_pipeline.r20 in the mutation phase), and `include`
    and `exclude`, which hold the cited selection merged with the
    helpers' filters (mutagen.test_selection.r8). A phase keeps the
    helpers' formatters and may append its own failure formatter. When
    the phase ends, Mutagen restores each of these options, and
    `trace`, to its value before the phase. Formatters the helper
    configures therefore run on every pass.

    Mutagen removes the ExUnit.after_suite callbacks from ExUnit's
    configuration before running the passes. It writes the final report
    before starting cleanup. Cleanup receives the last completed suite
    counts or zero counts if none completed. Each callback gets the full
    cleanup deadline, even if the preceding callback timed out. Cleanup
    errors and timeouts go to stderr. A host callback that calls
    System.halt/1 controls the VM exit code after the report is written.


- id: mutagen.cli.r21
  priority: must
  statement: |
    `--boot-timeout-ms <n>` populates `Config.boot_timeout_ms` as a
    positive integer. Default is 300000. A non-positive or non-integer
    value causes an error-JSON exit with
    `abort_reason: "invalid_boot_timeout"` before host setup runs.

    The deadline starts after host compilation and covers runtime
    configuration, test alias pre-steps, host application start,
    `:mutagen_ex` start, and helper evaluation (r14 step 3). When it
    passes, Mutagen kills the boot process and aborts with
    `abort_reason: "host_setup_timeout"`. `details.limit` gives the
    deadline in milliseconds and `details.step` names the step that was
    running, for example `"test_helper"` while a helper
    evaluates.

- id: mutagen.cli.r22
  priority: must
  statement: |
    When the host's `aliases[:test]` contains a string entry whose first
    word is `test`, the preamble runs the entries before the first such
    entry in its own VM, in order, after runtime configuration and before
    the host application starts. String entries run through
    `Mix.Task.run/2` with their arguments, and arity-one functions are
    called with `[]`. Application environment they set is in effect when
    the host application starts. Without such an entry no alias entry
    runs. A nonempty alias without a test entry adds a report warning.
    Mutagen ignores the test entry arguments and function return values.
    An entry that fails, raises, or has another shape aborts the run with
    `abort_reason: "test_alias_failed"`, and later entries do not run.
    `--no-test-alias` sets `Config.test_alias` to `false` and skips every
    entry.

- id: mutagen.cli.r23
  priority: must
  statement: |
    With `--json <path>`, `MutagenEx.Pipeline.DefaultIo` writes the
    document, preceded by any buffered `--stream` lines, to an
    exclusively created temporary file in the destination directory.
    It sets mode 0600 before writing the report and
    renames it over the destination. The destination therefore holds
    either its previous content or the whole new document. Missing parent
    directories inside the project root are created. Before creating the
    directories, before creating the temporary file, and again before
    the rename, the writer canonicalises the requested path under r10 and
    requires the same resolved path as at startup.

    If a check fails or the write fails (for example the destination is a
    directory, or a component became a symlink that leaves the project
    root), nothing is written at the destination. The document goes to
    stdout, stderr receives a warning naming `json_write_failed`, and the
    exit code is unchanged.

- id: mutagen.cli.r24
  priority: must
  statement: |
    CLI accepts --no-source and --include-host-output. Source is included
    and host text is omitted by default.

- id: mutagen.cli.r25
  priority: must
  statement: |
    An invalid :redact configuration returns invalid_redact_config before
    alias or helper code runs. A valid configuration compiles once and is
    reused for the run.

- id: mutagen.cli.r26
  priority: must
  statement: |
    The host default I/O device sends ordinary host process output to stderr
    during the run. Report aborts use the validated --json destination when
    one has been selected, including AST-cache errors.

- id: mutagen.cli.r27
  priority: must
  statement: |
    Coverage and baseline each have a deadline of max(boot timeout, ten
    times the mutation timeout). After-suite callbacks run after the report
    is written and share a separate boot timeout.

- id: mutagen.cli.r28
  priority: must
  statement: |
    A missing JSON streamer beam makes startup abort with runtime_load_failed.
    Archive packages omit the repository benchmark and spike scripts.

- id: mutagen.cli.r29
  priority: must
  statement: |
    The CI workflow pins action references by full commit SHA with an exact version comment, disables
    persisted checkout credentials, and reads the Elixir and OTP versions
    from .tool-versions in both jobs.


- id: mutagen.cli.r30
  priority: must
  statement: |
    The rerouted VM user device sends input and geometry requests to the
    original device. A report module redefined by a helper produces a
    runtime_load_failed report before installing the configured patterns.

- id: mutagen.cli.r31
  priority: must
  statement: |
    On OTP releases older than 27, the CLI stops before host setup and
    writes one startup error document with
    `abort_reason: "unsupported_otp_version"` to the selected destination.
    Encoding this document does not call OTP's `:json` module.

- id: mutagen.cli.r32
  priority: must
  statement: |
    The Mix project and CLI require Elixir 1.18.0 or later. An older Elixir
    runtime stops before host setup and writes a startup error document with
    `abort_reason: "unsupported_elixir_version"` to the selected destination.
    The project's archive allows Mix to load the task so it can report
    this error itself.
- id: mutagen.cli.r33
  priority: must
  statement: |
    --since REF permits an omitted --scope and defaults to --tests auto.
    Auto is a standalone test target. Escalation defaults on, --no-escalate
    disables it, and --escalate-max-files takes a non-negative integer
    with a default of 20. Fail-fast remains on unless disabled.

```

```spec-scenarios
- id: mutagen.cli.s1
  covers: [mutagen.cli.r1, mutagen.cli.r2]
  given:
    - A user invokes `mix mutagen --scope lib/foo.ex --tests test/foo_test.exs`.
  when:
    - The CLI parses these flags.
  then:
    - |
      `%Config{}` has `scopes: ["lib/foo.ex"]` and `tests: ["test/foo_test.exs"]`
      and the pipeline is invoked with that struct.

- id: mutagen.cli.s2
  covers: [mutagen.cli.r1]
  given:
    - A user invokes `mix mutagen --tests test/foo_test.exs` without `--scope`.
  when:
    - The CLI parses these flags.
  then:
    - |
      No pipeline phase runs. An error-JSON document with `reason:
      :missing_scope` is emitted to stdout, and the task exits with a non-zero
      code.

- id: mutagen.cli.s3
  covers: [mutagen.cli.r1, mutagen.cli.r2]
  given:
    - A user invokes `mix mutagen --scope MutagenEx.Foo.bar/1 --scope lib/baz.ex --tests tag:fast`.
  when:
    - The CLI parses these flags.
  then:
    - |
      `%Config{}` has `scopes: ["MutagenEx.Foo.bar/1", "lib/baz.ex"]` and
      `tests: ["tag:fast"]`. Repeat occurrences of `--scope` accumulate; they
      do not overwrite each other.

- id: mutagen.cli.s4
  covers: [mutagen.cli.r3]
  given:
    - A user invokes `mix mutagen --timeout-ms 0 ...`.
  when:
    - The CLI parses these flags.
  then:
    - |
      An error-JSON document with `reason: :invalid_timeout` is emitted.
      `Config.timeout_ms` is never set to 0.

- id: mutagen.cli.s5
  covers: [mutagen.cli.r4]
  given:
    - A user invokes `mix mutagen --seed 42 ...`.
  when:
    - The pipeline runs.
  then:
    - |
      `ExUnit.configure(seed: 42)` is called before the baseline test run,
      before the coverage test run, and before each mutation test run. The
      final JSON document's `meta.exunit_seed` field is `42`.

- id: mutagen.cli.s6
  covers: [mutagen.cli.r6]
  given:
    - A run completes the full pipeline; every mutation survived (kill rate 0.0).
  when:
    - The task finishes.
  then:
    - |
      Exit code is 0. The JSON document on stdout has `aborted: false` and a
      populated `mutation` block.

- id: mutagen.cli.s7
  covers: [mutagen.cli.r6]
  given:
    - |
      A user invokes `mix mutagen --scope lib/foo.ex --tests test/foo_test.exs`
      but the baseline test run has failing tests.
  when:
    - The baseline phase reports red.
  then:
    - |
      Exit code is non-zero. The JSON document has `aborted: true` and
      `abort_reason` names the red baseline; no mutation phase runs.

- id: mutagen.cli.s8
  covers: [mutagen.cli.r7]
  given:
    - A user invokes `mix mutagen --no-json --scope ... --tests ...`.
  when:
    - The CLI parses these flags.
  then:
    - |
      An error-JSON document with `reason: :flag_not_supported_in_v1` is
      emitted. Exit code is non-zero.

- id: mutagen.cli.s9
  covers: [mutagen.cli.r8]
  given:
    - A user invokes `mix mutagen --scope MutagenEx.MutationRunner --tests ...`.
  when:
    - The CLI resolves scope targets to modules.
  then:
    - |
      An error-JSON document with `reason: :self_mutation_refused` is emitted
      before any mutation phase runs.

- id: mutagen.cli.s10a
  covers: [mutagen.cli.r10]
  given:
    - A user invokes `mix mutagen --json ../../etc/passwd --scope ... --tests ...`.
  when:
    - The CLI parses these flags.
  then:
    - |
      `MutagenEx.CLI.parse/1` returns
      `{:error, :unsafe_json_path, %{variant: :traversal, ...}}`. No
      filesystem touch happens; an error-JSON document with
      `abort_reason: "unsafe_json_path"` is emitted to stdout. The file at
      the traversal target is never opened.

- id: mutagen.cli.s10b
  covers: [mutagen.cli.r10]
  given:
    - |
      A user invokes `mix mutagen --json "out/report\0.json" --scope ...
      --tests ...` (NUL byte embedded in the path).
  when:
    - The CLI parses these flags.
  then:
    - |
      `MutagenEx.CLI.parse/1` returns
      `{:error, :unsafe_json_path, %{variant: :nul_byte, ...}}`. The error
      JSON is emitted; no mutation phase runs.

- id: mutagen.cli.s10c
  covers: [mutagen.cli.r10]
  given:
    - |
      A symlink `<project_root>/escape.json` exists, pointing at `/etc/passwd`.
      The user invokes `mix mutagen --json escape.json ...`.
  when:
    - The canonicalisation phase resolves the path.
  then:
    - |
      The phase aborts with `abort_reason: "unsafe_json_path"` and
      `details.variant == :outside_project_root`. `/etc/passwd` is never
      opened.

- id: mutagen.cli.s10d
  covers: [mutagen.cli.r10]
  given:
    - |
      A symlink `<project_root>/in/inside.json` exists pointing at
      `<project_root>/out/report.json` (target stays inside project root).
      The user invokes `mix mutagen --json in/inside.json ...`.
  when:
    - The canonicalisation phase resolves the path.
  then:
    - |
      The phase returns `{:ok, "<project_root>/out/report.json"}`. The mutation
      pipeline writes the report to the resolved path.

- id: mutagen.cli.s10e
  covers: [mutagen.cli.r10]
  given:
    - |
      A user invokes `mix mutagen --json /tmp/ci-artifacts/report.json
      --unsafe-json-outside-project --scope ... --tests ...`.
  when:
    - The CLI parses and the canonicalisation phase resolves.
  then:
    - |
      `Config.unsafe_json_outside_project` is `true`. The phase returns
      `{:ok, "/tmp/ci-artifacts/report.json"}` even though the path is
      outside the project root. A warning naming the resolved path is
      written to stderr exactly once.

- id: mutagen.cli.s11
  covers: [mutagen.cli.r11]
  given:
    - A user invokes `mix mutagen --scope lib/foo.ex --tests tag:$(uuidgen)`.
  when:
    - The CLI parses these flags.
  then:
    - |
      The UUID's `-` characters (and possible uppercase hex) violate the
      `~r/\A[a-z][a-z_0-9]{0,63}\z/` charset. `CLI.parse/1` returns
      `{:error, :invalid_tag_name, _}` before the test selector runs.
      `Config` is not constructed; no atom is created from the UUID string.

- id: mutagen.cli.s11b
  covers: [mutagen.cli.r11]
  given:
    - A user invokes `mix mutagen --scope lib/foo.ex --tests tag:slow`.
  when:
    - The CLI parses these flags.
  then:
    - |
      `Config.tests` is `["tag:slow"]`. `slow` matches the charset and
      flows through to test selection unchanged.

- id: mutagen.cli.s12a
  covers: [mutagen.cli.r12]
  given:
    - |
      A user invokes `mix mutagen` with 101 distinct `--scope <target>`
      occurrences and one `--tests` target.
  when:
    - The CLI parses these flags.
  then:
    - |
      `MutagenEx.CLI.parse/1` returns
      `{:error, :too_many_targets, %{flag: "--scope", kind: :scope,
      cap: 100, count: 101, ...}}`. No filesystem touch, no scope
      resolution, no mutation phase. The error-JSON document's
      `abort_reason` is `"too_many_targets"`.

- id: mutagen.cli.s12b
  covers: [mutagen.cli.r12]
  given:
    - |
      A scope/tests combination whose enumerated mutation sites exceed
      `Config.max_sites` (default 10_000), e.g. a broad `--scope` on a
      large module with thorough coverage.
  when:
    - The enumerator phase runs.
  then:
    - |
      The phase returns
      `{:error, :too_many_sites, %{cap: 10000, count: <n>, ...}}`. The
      pipeline aborts with `abort_reason: "too_many_sites"` BEFORE the
      mutation runner starts. The error-JSON document names the count
      so the user can decide whether to narrow `--scope` or raise
      `--max-sites`.

- id: mutagen.cli.s12c
  covers: [mutagen.cli.r12]
  given:
    - A user invokes `mix mutagen --max-sites 0 ...`.
  when:
    - The CLI parses these flags.
  then:
    - |
      An error-JSON document with `reason: :invalid_max_sites` is
      emitted. `Config.max_sites` is never set to 0.

- id: mutagen.cli.s13a
  covers: [mutagen.cli.r13]
  given:
    - |
      A user invokes `mix mutagen --budget-ms 1000 ...` against a scope
      whose enumerated mutation sites would take longer than 1000 ms in
      aggregate.
  when:
    - The mutation phase runs and the budget elapses.
  then:
    - |
      The runner stops dispatching new sites. The success-JSON document
      has `truncated: true` at the top level, `aborted: false`, and the
      `mutation` block holds only the completed sites' results. A
      `budget_exceeded` warning is included in the `warnings` array.

- id: mutagen.cli.s13b
  covers: [mutagen.cli.r13]
  given:
    - A user invokes `mix mutagen --budget-ms 0 ...`.
  when:
    - The CLI parses these flags.
  then:
    - |
      An error-JSON document with `reason: :invalid_budget_ms` is
      emitted. `Config.budget_ms` is never set to 0.

- id: mutagen.cli.s14a
  covers: [mutagen.cli.r14]
  given:
    - |
      A downstream project freshly cloned and installed with `mutagen_ex`
      as a dependency. A user invokes
      `MIX_ENV=test mix mutagen --scope lib/foo.ex --tests test/foo_test.exs`
      from the project root in a fresh shell — no prior `mix test`, no IEx
      session, no manual preload.
  when:
    - "`Mix.Tasks.Mutagen.run/1` starts."
  then:
    - |
      The preamble runs after flag parsing and before the scope phase.
      After the preamble: `:code.which(Foo)` returns a charlist path
      (modules loaded); `Application.started_applications/0` includes the
      host application, `:mutagen_ex`, and `:ex_unit`; host supervised
      processes are live; `test/test_helper.exs` has been required once;
      `Process.whereis(MutagenEx.TaskSup)` is a live PID.
      The coverage, baseline, and mutation phases then run normally and
      the document emitted has `aborted: false`.

- id: mutagen.cli.s14b
  covers: [mutagen.cli.r14]
  given:
    - |
      The mutagen_ex test suite (`mix test`) is running. ExUnit drives
      a test that calls `Mix.Tasks.Mutagen.run/2` with a custom
      dispatch.
  when:
    - "`run/2` executes."
  then:
    - |
      `run/2` does NOT invoke the preamble — no `Mix.Task.run("compile")`,
      no `ExUnit.start/1`, no `Application.ensure_all_started/1`. The
      test seam is preamble-free per
      mutagen.decision.preamble_in_run1_only.

- id: mutagen.cli.s14c
  covers: [mutagen.cli.r16]
  given:
    - |
      A host project that does NOT carry `:mutagen_ex` in its `mix.exs`,
      with `mutagen_ex-X.Y.Z.ez` previously installed via
      `mix archive.install ./mutagen_ex-X.Y.Z.ez` so the task is visible
      globally (`mix help mutagen` lists it).
  when:
    - |
      The user invokes `mix mutagen --scope lib/foo.ex --tests test/foo_test.exs`
      from the host project root in a fresh shell.
  then:
    - |
      The first `Application.ensure_all_started(:mutagen_ex)` in
      `MutagenEx.Runtime.boot/1` returns `{:error, {:mutagen_ex, {_, ~c"mutagen_ex.app"}}}`. The preamble
      calls `Mix.Local.append_archives/0`, retries, and the retry returns
      `{:ok, _apps}` (or, if necessary, the targeted ebin scan fires and the
      third attempt succeeds). `Process.whereis(MutagenEx.TaskSup)` is then a
      live PID. The coverage, baseline, and mutation phases run normally.
      The final JSON document on stdout has `aborted: false` and a populated
      `mutation` block.

- id: mutagen.cli.s14d
  covers: [mutagen.cli.r16]
  given:
    - |
      A host project as in s14c, but the installed archive is
      unrecoverable (the archive directory was deleted between
      `mix archive.install` and `mix mutagen`, or `~/.mix/archives`
      is unreadable). Both `Mix.Local.append_archives/0` and the
      targeted `Mix.path_for(:archives)` scan fail to make
      `mutagen_ex.app` reachable on `:code.get_path/0`.
  when:
    - "`mix mutagen ...` runs."
  then:
    - |
      `MutagenEx.Runtime.boot/1` returns
      `{:error, :runtime_load_failed, details}` instead of raising a
      `MatchError`. The task emits a structured error-JSON document to
      stdout (no `--json` was given) with
      `aborted: true`, `abort_reason: "runtime_load_failed"`, and a
      `details.hint` pointing the user at archive-install
      troubleshooting (e.g. "reinstall via `mix archive.uninstall mutagen_ex
      && mix archive.install <ez>`"). The task exits with a non-zero code
      per r6.

- id: mutagen.cli.s15
  covers: [mutagen.cli.r15, mutagen.cli.r10]
  given:
    - |
      A user invokes
      `mix mutagen --scope lib/foo.ex --tests test/foo_test.exs --json /tmp/foo.json`
      from a project whose root is `/Users/.../my_project`.
  when:
    - "`phase_json_path` runs."
  then:
    - |
      The path is refused with `abort_reason: "unsafe_json_path"` per
      r10. The error-JSON document lands on stdout. No file is created
      at `/tmp/foo.json`. The exit code is non-zero per r6.

- id: mutagen.cli.s16
  covers: [mutagen.cli.r17]
  given:
    - A cited suite with three tests in which each of the first three mutants fails the first test.
  when:
    - "A user runs `mix mutagen` once with `--no-fail-fast` and once without it, and once with the unknown flag `--bogus`."
  then:
    - "The `--no-fail-fast` report has `meta.fail_fast: false` and each killed mutant ran all three tests."
    - "The default report has `meta.fail_fast: true` and each killed mutant ran only the first test."
    - "The `--bogus` error document has `meta.fail_fast: true` and a non-zero exit code."

- id: mutagen.cli.s18
  covers: [mutagen.cli.r18]
  given:
    - A host project whose `mix.exs` sets no preferred environment for `mutagen`.
    - A user runs `mix mutagen --scope lib/foo.ex --tests test/foo_test.exs` with `MIX_ENV` unset.
  when:
    - "`Mix.Tasks.Mutagen.run/1` starts."
  then:
    - "The document has `abort_reason: \"invalid_mix_env\"`. With --include-host-output, `details.message` contains `current Mix environment: dev`, `MIX_ENV=test mix mutagen --scope lib/foo.ex --tests test/foo_test.exs`, and `preferred_envs: [mutagen: :test]`."
    - Neither `mix loadpaths` nor `mix compile` ran.
    - With `MIX_ENV=ci` set, the same command passes the environment check.

- id: mutagen.cli.s19a
  covers: [mutagen.cli.r19, mutagen.cli.r5]
  given:
    - "`test/test_helper.exs` raises a `RuntimeError` whose first line is `helper did not start: password: hunter2` and whose message continues on a second line."
    - A user passes `--json out/report.json` inside the project root.
  when:
    - The preamble requires the helper.
  then:
    - "With --include-host-output, `out/report.json` holds a document with `abort_reason: \"test_helper_load_failed\"`, `details.file == \"test/test_helper.exs\"`, and `details.message == \"helper did not start: password: [REDACTED]\"`."
    - Stdout is empty. Stderr carries the full message and stacktrace. The exit code is non-zero.

- id: mutagen.cli.s19b
  covers: [mutagen.cli.r19]
  given:
    - A user runs `mix mutagen` from the root of an umbrella project.
  when:
    - The preamble checks the project.
  then:
    - "The document has `abort_reason: \"umbrella_root\"` and `details.hint` contains `apps/<app>`."
    - "`mix loadpaths` and `mix compile` did not run."

- id: mutagen.cli.s19c
  covers: [mutagen.cli.r19]
  given:
    - "A host module body contains `:ok = {:error, @token}`, where `@token` holds a credential-like string."
  when:
    - The preamble compiles the host.
  then:
    - "The document has `abort_reason: \"host_compile_failed\"`. With --include-host-output, `details.message` contains `no match of right hand side value: [REDACTED]` and does not contain the token."

- id: mutagen.cli.s20a
  covers: [mutagen.cli.r20]
  given:
    - "The host helper calls `ExUnit.start(exclude: [:integration])` and registers one `ExUnit.after_suite/1` callback that drops a test schema."
  when:
    - "`mix mutagen` runs coverage, baseline, and five mutation passes and completes."
  then:
    - "Every pass runs with `:integration` excluded, Mutagen's seed, and `max_cases: 1`."
    - The callback ran exactly once, after the last mutation pass, with the baseline pass's counts.
    - "If the callback raises, stderr carries the failure and the already-written report retains the original verdict."

- id: mutagen.cli.s20b
  covers: [mutagen.cli.r20]
  given:
    - The host helper registers one after-suite callback, and its filters exclude every cited test.
  when:
    - The coverage pass executes no tests.
  then:
    - "The document has `abort_reason: \"no_tests_run\"`."
    - The callback ran exactly once.

- id: mutagen.cli.s21a
  covers: [mutagen.cli.r21]
  given:
    - The host application's `start/2` callback sleeps forever.
  when:
    - "A user runs `mix mutagen ... --boot-timeout-ms 1000`."
  then:
    - "Within a few seconds after compilation, the document has `abort_reason: \"host_setup_timeout\"` and `details.step == \"host_app_start_failed\"`."

- id: mutagen.cli.s21b
  covers: [mutagen.cli.r21]
  given:
    - A user invokes `mix mutagen --boot-timeout-ms 0 ...`.
  when:
    - The CLI parses these flags.
  then:
    - "`MutagenEx.CLI.parse/1` returns `{:error, :invalid_boot_timeout, %{flag: \"--boot-timeout-ms\", ...}}`. No host setup runs."

- id: mutagen.cli.s22
  covers: [mutagen.cli.r22]
  given:
    - "The host `mix.exs` defines `aliases: [test: [\"ecto.create --quiet\", \"ecto.migrate --quiet\", &seed/1, \"test\"]]`."
  when:
    - The preamble boots the host.
  then:
    - "`ecto.create`, `ecto.migrate`, and `seed/1` ran in that order before the host application started."
    - With `--no-test-alias`, none of them ran.
    - "If `ecto.migrate` raises, the document has `abort_reason: \"test_alias_failed\"` and `seed/1` did not run."

- id: mutagen.cli.s23a
  covers: [mutagen.cli.r23]
  given:
    - "`--json new/nested/report.json` names a path inside the project root whose parent directories do not exist."
  when:
    - The report is written twice.
  then:
    - "`new/nested/` exists and holds only `report.json`, whose content is the second document."

- id: mutagen.cli.s23b
  covers: [mutagen.cli.r23, mutagen.cli.r15]
  given:
    - "`--json out/report.json` passed r10 validation at startup. Before the report is written, `out` becomes a symlink to a directory outside the project root."
  when:
    - The report is written.
  then:
    - Nothing is written outside the project root.
    - "The document goes to stdout, stderr carries a `json_write_failed` warning, and the exit code is the pipeline's."
```

```spec-verification
- kind: tagged_tests
  target: test
  covers:
    - mutagen.cli.r1
    - mutagen.cli.r2
    - mutagen.cli.r3
    - mutagen.cli.r4
    - mutagen.cli.r5
    - mutagen.cli.r6
    - mutagen.cli.r7
    - mutagen.cli.r8
    - mutagen.cli.r9
    - mutagen.cli.r10
    - mutagen.cli.r11
    - mutagen.cli.r12
    - mutagen.cli.r13
    - mutagen.cli.r14
    - mutagen.cli.r15
    - mutagen.cli.r16
    - mutagen.cli.r17
    - mutagen.cli.r18
    - mutagen.cli.r19
    - mutagen.cli.r20
    - mutagen.cli.r21
    - mutagen.cli.r22
    - mutagen.cli.r23
    - mutagen.cli.r24
    - mutagen.cli.r25
    - mutagen.cli.r26
    - mutagen.cli.r27
    - mutagen.cli.r28
    - mutagen.cli.r29
    - mutagen.cli.r30
    - mutagen.cli.r31
    - mutagen.cli.r32
```
