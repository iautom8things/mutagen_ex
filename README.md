# mutagen_ex

Mutation testing for Elixir. `mix mutagen` mutates a chosen scope, runs a
cited test set against each mutation, and emits a single JSON document
classifying every mutation as `killed`, `survived`, `timeout`, `error`, or
`compile_error`.

The CLI (`mix mutagen`) is the supported user-facing entry point;
`MutagenEx.MutationRunner.run/1` is the equivalent library-caller entry
point. The CLI ends each run with an aggregate JSON document.
`--stream` writes per-site events to the same destination before it.

## Why mutagen_ex (and how it differs from muzak)

Elixir already has a mature mutation tester:
[muzak / muzak_pro](https://hex.pm/packages/muzak) by Devon Estes. If you
want a polished, human-facing mutation-testing workflow for everyday TDD,
muzak is the established choice and mutagen_ex is not trying to replace it.

mutagen_ex exists for a different primary consumer: **an LLM verifier or
judge, not a human.** That single design constraint is the thesis behind
every difference below. When the output of mutation testing is fed to a
model that grades a test suite — or to an automated agent that decides
whether generated tests actually pin behavior — the requirements invert.
A human wants color, progress bars, and a readable summary. A model wants
one machine-parseable document, IDs it can compare across runs, and bytes
that don't change for reasons unrelated to the code under test.

Concretely, mutagen_ex differs from muzak on five deliberate axes:

- **JSON output.** `mix mutagen` writes the aggregate document to stdout or
  `--json <path>`. Use `--stream` to receive per-site JSON lines before
  the aggregate, or pipe the aggregate through `jq` to inspect it.
  [Output format decision](.spec/decisions/no_pretty_output_v1.md).

- **Stable mutation IDs.** Scheme 2 uses `{relative_file}:{hash}:{mutator}`.
  The hash includes the enclosing module, function name and declared arity,
  the parsed expression with source positions and presentation metadata
  removed, and its occurrence among identical expressions for the same mutator.
  Bare literal IDs also include the parent expression and child position.
  Module-body sites count occurrences by module and statement head.
  Formatting preserves IDs across whitespace and line reflow. Formatter
  migrations (`mix format --migrate`) can rewrite syntax and change IDs.
  Adding an identical expression earlier in a function can shift later IDs
  and transfer an old ID to a different occurrence. Persist and compare
  `function` and `before_source` alongside IDs. Require `version: "2"`,
  `meta.id_scheme: "2"`, and matching `meta.elixir_version` and
  `meta.otp_version` before comparing. IDs and reports from earlier
  versions cannot be compared with version 2.
  [Mutation ID scheme 2](.spec/decisions/mutation_id_scheme_2.md).

- **Deterministic, serial-by-default execution.** Every phase — baseline,
  coverage, and each per-mutation run — forces `max_cases: 1` and a fixed
  `--seed` (default `0`). The same `{source, --tests, --scope, --seed}`
  always yields the same per-site classification. Reproducibility is the
  point; a judge comparing two runs must be able to trust that a difference
  reflects a code change, not test-order flake. See
  [`.spec/decisions/serial_execution_and_seed.md`](.spec/decisions/serial_execution_and_seed.md).

- **The primary consumer is an LLM verifier/judge, not a human.** This is
  the real thesis, and it is why the three points above are features rather
  than omissions. mutagen_ex optimizes for being read by a model and
  consumed by automation. Human ergonomics are explicitly secondary in v1.

- **In-process pipeline (vs muzak's child-BEAM-per-mutation).** mutagen_ex
  swaps bytecode via `Code.compile_quoted/2` and restores from a cached binary,
  all inside the same BEAM VM as the Mix task — roughly 10x faster per
  mutation than spawning a fresh node each time, which matters when a model
  is waiting on feedback. The trade-off is honest: shared-VM state drift on
  `use SomeModule` macros is possible, so it is surfaced as
  `mutation.state_drift_warning` in the JSON rather than hidden. The cost of
  staying in-process is that mutagen_ex cannot mutate *itself* (doing so
  would corrupt the running runner); self-mutation is refused with
  `reason: :self_mutation_refused`. See
  [`.spec/decisions/in_process_pipeline.md`](.spec/decisions/in_process_pipeline.md)
  and [`.spec/decisions/self_mutation_refused.md`](.spec/decisions/self_mutation_refused.md).

If none of that matches your use case — if you want a human-friendly
mutation tester for interactive use — reach for muzak. If you are building
an LLM-graded or agent-driven test-quality pipeline and need stable,
machine-first output, that gap is the one mutagen_ex was built to fill.

## The mutator catalog and its lineage

mutagen_ex ships ten AST mutators (`.spec/specs/mutators.spec.md`). They fall
into two groups: four that are direct Elixir realizations of the classic,
language-agnostic mutation operators studied since the Mothra era, and six
that are Elixir-idiomatic and have no clean parallel in the C/Java mutation
literature.

The first group maps onto the *selective mutation* operator set — the small
family Offutt et al. found sufficient to retain almost all of a full operator
set's fault-detection power at a fraction of the mutant count (Offutt, Lee,
Rothermel, Untch & Zapf, "An Experimental Determination of Sufficient Mutant
Operators," *ACM TOSEM* 5(2), 1996, [doi:10.1145/227607.227610](https://doi.org/10.1145/227607.227610);
see also Jia & Harman's survey, *IEEE TSE* 37(5), 2011,
[doi:10.1109/TSE.2010.62](https://doi.org/10.1109/TSE.2010.62) for the broader
taxonomy these abbreviations come from):

| mutagen_ex mutator | Standard operator | What it does |
|---|---|---|
| `arith` | **AOR** — Arithmetic Operator Replacement | swaps `+ ↔ -`, `* ↔ /` on numeric binary ops |
| `compare` | **ROR** — Relational Operator Replacement | swaps `== ↔ !=`, `< ↔ >=`, `> ↔ <=` |
| `boolean` | **LCR** — Logical Connector Replacement | swaps `and ↔ or`, `&& ↔ \|\|`, drops `not`/`!` |
| `literal` | **CRP** — Constant Replacement | flips `true ↔ false`, swaps small integer literals |

The remaining six mutate constructs that are idiomatic to Elixir/Erlang and
have no language-agnostic equivalent in the standard catalogs — they exist
because the standard operators say nothing about tagged tuples, multi-clause
guards, `with`, or the pipe:

| mutagen_ex mutator | What it does | Why it has no classic parallel |
|---|---|---|
| `result_tuple` | flips `{:ok, x}` ↔ `{:error, x}` | targets Elixir's tagged-tuple result convention |
| `guard_drop` | drops a function-clause `when` guard | guards are an Elixir/Erlang dispatch construct |
| `with_swap` | swaps the first two leading `<-` clauses of a `with` | `with` is an Elixir control structure |
| `else_removal` | drops the `else` branch of `if`/`with` | shaped to Elixir's `if`/`with` else semantics |
| `case_drop` | drops the last `case`/`cond` clause | closest to the classic statement/clause-deletion (SDL) family, but Elixir's exhaustiveness and `CaseClauseError` behaviour make it its own thing (see Known limitations) |
| `pipeline` | reorders adjacent `\|>` segments | the pipe operator is Elixir-idiomatic |

The split is deliberate: the four classic operators give the catalog a
well-understood, citable backbone, while the six idiomatic operators cover the
fault classes that only show up in Elixir code. Treat the standard-operator
names above as the vocabulary a reviewer (human or LLM judge) already knows;
treat the idiomatic six as the Elixir-specific extension that vocabulary lacks.

### Mutator confidence

Every aggregate `mutation.results[]` entry and every NDJSON `"result"` line
has a `"confidence"` field. The ratings apply to whole operators and draw
on manual review of survivors from two Phoenix apps. Even a high-rated
survivor can be equivalent to the original code. A CI gate can filter for
`status == "survived" and confidence == "high"`. The field is part of
report schema version `"2"`. The summary counts results of both confidence
levels.

The ratings are provisional. We will re-measure each mutator as more files
are judged.

| Mutator | Confidence | Reason |
|---|---|---|
| `arith` | high | The swapped operator can change a numeric result. |
| `compare` | high | Negating the comparison can change which branch runs. |
| `boolean` | high | Swapping a connector or removing negation can change the value or short-circuit behavior. |
| `literal` | high | A caller can observe the changed value or pattern. |
| `with_swap` | low | Two checks can still return the same failure in practice, or their failures may never occur together. |
| `case_drop` | high | Inputs handled by the removed final arm can now raise a clause error. |
| `pipeline` | low | Independent stages often give the same result in either order, as with LiveView assigns or `Map.put/3` calls on different keys. |
| `result_tuple` | high | The tag swap changes which consumers treat a result as success or failure. |
| `else_removal` | high | Removing the branch changes how a false condition or failed match is handled. |
| `guard_drop` | low | Callers often cannot supply a value that the removed guard would have rejected. |

`with_swap` applies its failure-priority filters only when the two clauses
are independent. It treats a pair as dependent when a name bound by
either pattern appears anywhere in the other clause, or when either clause
uses `binding()`, `dbg()` or `__ENV__`. It records skip reasons in
`mutation.skipped`.

| Reason | When it applies |
|---|---|
| `bound_var_used_before_binding` | A variable-shaped name in the moved-first expression also appears as a binding in the now-later pattern. The check ignores module attributes and binary modifiers. |
| `insufficient_refutable_patterns` | In an independent pair, either match uses an unguarded variable, a wildcard, or a literal pattern with an equal literal expression. |
| `indistinguishable_failures` | In an independent pair, both expressions are the same literal or read the same variable. |
| `else_ignores_failure` | An independent pair has a single unguarded variable or wildcard `else` arm whose body ignores the failure. |

The RHS name check can skip a valid swap when the name has an outer binding
or appears only inside a nested binder or quote. This includes names local
to `fn`, `case`, `for`, `receive`, `rescue`, nested `with`,
`match?`, matches and `destructure`. The compiler resolves dependencies
in guards, pins and binary sizes for kept swaps. Unexpanded macros can
hide reads and bindings.
The filters can miss evaluation-order bugs such as writes that run before
a short circuit or a change in which exception is raised.

## Self-mutation

The repository tests mutation runs against the mutator registry, scope
resolver, and JSON reporter. The harness copies those modules under a
separate namespace in a temporary Mix project and runs `mix mutagen`
from a fresh shell. Run it with `mix test --include self_mutation`.
[Self-mutation test](test/integration/self_mutation_test.exs).

## Install

`mutagen_ex` is a development-time Mix task. Add it to your `mix.exs`:

```elixir
def deps do
  [
    {:mutagen_ex, "~> 0.1", only: [:dev, :test], runtime: false}
  ]
end
```

Scoping to `only: [:dev, :test]` is the recommended posture: `mutagen_ex`
starts a supervision tree (`MutagenEx.Application` → `MutagenEx.Supervisor`
→ `MutagenEx.TaskSup`) on application boot, and you do not want that tree
pulled into a `:prod` release.

Then:

```
mix deps.get
mix help mutagen
```

### Install via `mix archive` (no `mix.exs` change required)

For ad-hoc use, downstream developers can install the `mix mutagen` task
globally without changing a project's deps. This is useful for consultants
running mutagen against client repos, or for one-off mutation-testing audits
where the target project should stay untouched.

From the `mutagen_ex` repo root, build the archive:

```bash
mix archive.build
```

Then install the generated archive:

```bash
mix archive.install ./mutagen_ex-<version>.ez
```

From any project, verify the task is available and run it against a target:

```bash
mix help mutagen
MIX_ENV=test mix mutagen --scope lib/foo.ex --tests test/foo_test.exs
```

Pin the archive version or dependency version in CI.

## Host test setup

Run `MIX_ENV=test mix mutagen` with either install method. This loads
`config/test.exs` and compiles test support. Explicit environments such as
`MIX_ENV=ci` are allowed when the host configures them for tests. A host
can also set `def cli, do: [preferred_envs: [mutagen: :test]]` in `mix.exs`.
Mix may print dependency discovery output before the task runs. Use
`MIX_QUIET=1` for a dependency install when parsing stdout directly.
The task routes the VM user device, the default console Logger handler,
and ExUnit output to stderr.

After compiling, the task loads runtime config and runs the host `test`
alias entries before the `test` task. A Phoenix alias can create and migrate
the test database there. If the alias lacks those steps or you use
`--no-test-alias`, create and migrate the test database before invoking
mutagen. Pass `MIX_TEST_PARTITION` if your configuration uses it to select
a database. Mutagen ignores arguments on the `test` entry and uses
`--tests` and the helper's ExUnit configuration for selection. Alias
functions get `[]`. Mutagen ignores their return values. An alias with
entries and no recognizable `test` entry produces a report warning.

The task starts the host application and requires `test_helper.exs` once
from each configured `:test_paths` entry, with ExUnit autorun disabled. The
default is `test/test_helper.exs` when `test/` exists. Run from the app that
owns the tests in an umbrella project. `--no-host-app` or
`MUTAGEN_NO_HOST_APP=1` skips application startup and still loads runtime
config and the helper.

Coverage, baseline, and every mutant use the helper's ExUnit options.
Whole-file targets honor helper includes and excludes. An explicit tag or
line target takes precedence when narrowing the test set. A coverage or
baseline pass that executes no tests aborts with `no_tests_run`. Helper
formatters run on every pass. A formatter that writes a file may overwrite
it after each mutant. Mutagen writes the final report before running
ExUnit `after_suite` callbacks. Cleanup has its own `--boot-timeout-ms`
deadline. Cleanup errors and timeouts go to stderr and leave the
report and exit code unchanged.

`--boot-timeout-ms` bounds runtime configuration, alias pre-steps,
application startup, and helper evaluation after compilation. Coverage
and baseline each get the greater of `--boot-timeout-ms` and ten times
`--timeout-ms`. The mutation budget starts after baseline. An OS process
started by a test-alias command can outlive a boot timeout. A helper that
calls `System.halt/1` ends the BEAM before reporting.

Abort documents include a fixed hint and, where available, the step,
exception type, file and line. Host diagnostics go to stderr. Do not
publish stderr as a CI artifact. Abort documents repeat this warning in
`details.note`.

The supported CI mode is `--json PATH`. Native fd 1 writes, including
`:erlang.display/1` and direct subprocess output, bypass the VM I/O
routing and can corrupt stdout. Mix can also write to stdout before the
task starts. Mutagen writes the file with mode 0600. If it cannot safely
write the file, it warns on stderr and falls back to stdout.


## Entrypoints

`mutagen_ex` boots `MutagenEx.Application` whenever the `:mutagen_ex`
application starts. That supervisor is the program entrypoint; everything
the tool runs lives under `MutagenEx.TaskSup`.

User-facing entrypoint surfaces:

- **CLI**: `mix mutagen` (the `Mix.Tasks.Mutagen` task). This is the
  documented and supported route.
- **Library**: `MutagenEx.MutationRunner.run/1` for callers depending on
  `:mutagen_ex` directly. Same in-process pipeline, no CLI parsing.
  Library callers must ensure the `:mutagen_ex` application is started
  before invoking this entrypoint.

Only one concurrent MutagenEx mutation cycle per BEAM is supported;
concurrent callers are refused with `{:error, :cover_already_running, _}`.
See `.spec/decisions/supervision_tree.md`.

## What `mix mutagen` does

For the selected scopes, mutagen_ex:

1. Resolves the target to one or more `(module, file)` pairs.
2. Runs the cited tests to record line-level coverage for the in-scope
   modules.
3. Enumerates mutation sites in each in-scope file's AST on covered lines.
4. Runs the cited tests on the original code to check the baseline.
   A red baseline aborts the run.
5. For each site, applies the mutator, recompiles the module in place,
   re-runs the cited tests, and classifies the result.
6. Restores the original module after every site.
7. Emits the final JSON document.

Tests run serially within each pass. Mutation sites run serially by default
in the same BEAM VM. `--max-concurrency` enables experimental parallel
dispatch.

Mutagen applies changes in memory via `Code.compile_quoted/2` and restores
the original module after every site. The byte-identity contract covers
`lib/`, `_build/`, `cover/`, host project config (`mix.exs`, `mix.lock`,
`.formatter.exs`), and tmp entries with the `mutagen_ex_` prefix — see
`mutagen.mutation_pipeline.r11` and `mutagen.coverage.r7`.

## Basic usage

```bash
# Single file scope, single test file
MIX_ENV=test mix mutagen --scope lib/foo.ex --tests test/foo_test.exs

# Module scope, tag-cited tests, custom per-mutation budget
MIX_ENV=test mix mutagen --scope MyApp.Foo --tests tag:fast --timeout-ms 10000

# Function scope, deterministic seed, redirected output
MIX_ENV=test mix mutagen --scope MyApp.Foo.bar/1 \
            --tests test/foo_test.exs \
            --seed 42 \
            --json out/mutagen.json
```

## Running in CI

Run with `MIX_ENV=test` and use `--json PATH` for the report artifact.
Keep stderr out of CI artifacts.

Set `--timeout-ms` well below the 30-second default for scopes whose
tests finish quickly. A runaway mutant can consume the full timeout. Set
`--budget-ms` to stop dispatching new mutants once the mutation phase
has used its budget. Use `meta.timings_ms` to size both limits on your CI
runner. Dividing mutation time by the number of attempted sites gives
the average cost per mutant.

## Flags

| Flag | Purpose |
|---|---|
| `--scope <target>` | What to mutate. A `.ex` file path, a module name, or `Module.fun/arity`. Required. Repeatable; each occurrence accumulates. Cap: 100 occurrences. |
| `--tests <target>` | Which tests judge the mutations. A `_test.exs` path, a `file:line` pair, or `tag:<name>`. Required. Repeatable. Cap: 100 occurrences. |
| `--boot-timeout-ms <int>` | Deadline in milliseconds for startup after compilation. Default `300000`. |
| `--no-source` | Omit source excerpts, file and function fields from mutation results and compile errors, including stream entries. |
| `--include-host-output` | Include captured compiler and test stderr and abort messages, with best-effort redaction. |
| `--no-test-alias` | Skip entries in the host's test alias before the test task. |
| `--no-host-app` | Load runtime configuration and the helper without starting the host application. |
| `--timeout-ms <int>` | Wall-clock budget per mutation run. Default `30000`. Must be positive. Phoenix/Ecto-style apps often need the larger default because setup and supplemental tests can make a single mutation cycle exceed five seconds. |
| `--no-fail-fast` | Run the full cited suite for each mutant. By default, mutation runs stop executing tests at the first failure. |
| `--seed <int>` | ExUnit seed, propagated to every test-running phase. Default `0`. Controls test ordering only, not mutation enumeration order. |
| `--json <path>` | Write the final JSON document to `<path>` instead of stdout. The document always ends with a single newline. Path is canonicalised before any mutation runs: `..` segments and NUL bytes are refused at parse time, and the resolved path must stay inside the project root unless `--unsafe-json-outside-project` is also passed. |
| `--unsafe-json-outside-project` | Opt-in to writing `--json` output outside the project root. CI integrations targeting an artifacts directory above the project root pass this; everyday use should leave it off. Emits a one-shot stderr warning naming the resolved target at run start. |
| `--max-sites <int>` | Upper bound on enumerated mutation sites for one run. Default `10000`. Exceeding the cap aborts with `abort_reason: "too_many_sites"` BEFORE the mutation runner starts — narrow `--scope` (or raise the cap) to proceed. |
| `--budget-ms <int>` | Optional aggregate wall-clock budget for the mutation phase, in milliseconds. Default unbounded (`--timeout-ms` still bounds each site). When elapsed, the runner stops dispatching new sites and emits a `truncated: true` partial JSON report. |
| `--max-concurrency <int>` | Cap on the number of per-site mutation tasks `Task.Supervisor.async_stream_nolink/4` runs in parallel. Default `1` (fully serial, byte-equivalent to v1.0). Values greater than `1` are EXPERIMENTAL and emit a one-shot stderr warning because real ExUnit/:cover backends can produce incorrect kill/survive classification and corrupted coverage. See [Parallel mode](#parallel-mode-streaming-and-progress) below. |
| `--stream` | Emit one NDJSON line per completed site (and `start`/`end` envelope lines) to the same sink the aggregate document goes to. Off by default. |
| `--no-progress` | Suppress the human-readable per-site progress feed on stderr. Default is auto-on when stderr is a TTY, auto-off otherwise. |

See [Known limitations](#known-limitations) for rejected options such
as `--no-json` and `--scope file.ex:Module`.

## Per-mutant fail-fast

By default, a mutant is killed when ExUnit records a test failure before
the per-mutant deadline. This includes a mutant whose full suite would
time out in a later test. If the deadline arrives before any failure,
the mutant is classified as a timeout. Baseline and coverage have no
failure cap. JSON reports the mode as `meta.fail_fast` and reports
`true` if argument parsing fails before a mode is available.

Fail-fast preserves survivors and existing kills when tests run
independently. If one test sets up or cleans up state for another, a
failed run can skip that test and change the next mutant's verdict, even
if the next mutant runs every test. These suites already depend on
ExUnit's test ordering when the seed changes. Use `--no-fail-fast` to
run the full suite per mutant. Skipped tests can also change per-mutant
`warnings` and `tainted_predecessors`. A shorter mutation phase can
complete more sites within the same `--budget-ms`.

Mutagen sets the seed, serial execution, and the failure cap after test
files load. Each phase keeps the loaded host formatters and adds its
own failure formatter when needed. Other host options, such as test
timeouts and log capture, stay active. The resolved test filter supplies
include and exclude for each phase. Mutagen restores the host settings
after each phase.

## Parallel mode, streaming, and progress

Mutagen includes the wiring for parallel per-site dispatch, NDJSON
streaming, and a per-site progress feed. The mechanism is in place, but
`--max-concurrency > 1` is EXPERIMENTAL: the in-process pipeline shares
ExUnit's global server, the Code.Server's per-module load locks, and
`:cover` instrumentation across all per-site tasks (see "Known
limitations" below). On real ExUnit/:cover backends, parallel dispatch
may produce incorrect kill/survive classification and corrupted
coverage, so resolving `--max-concurrency > 1` emits a one-shot stderr
warning. The safe path is the default, `--max-concurrency 1`; set
`--max-concurrency N` explicitly only when your scope and test corpus
are arranged for collision-free parallel execution.

Mutagen has **no runtime dependencies** — it installs cleanly as a
dependency-free Mix archive (`mix archive.install`). Per-site
observation (NDJSON streaming and the progress feed below) rides the
mutation runner's single `:on_site_completed` callback rather than a
`:telemetry` event surface.

### NDJSON streaming (`--stream`)

When `--stream` is set, `MutagenEx.JsonStreamer` emits one JSON object
per line on the same sink the aggregate document goes to. The line
shape is byte-equal to the equivalent entry in the aggregate
`mutation.results[]` / `mutation.compile_errors[]` array, plus a
`"kind"` discriminator and the `"version"` literal:

```
{"version":"2","kind":"start","total":42,"meta":{"id_scheme":"2",...}}
{"version":"2","kind":"result","id":"...","function":"MyApp.Counter.add/2","status":"killed","mutator":"arith","confidence":"high",...}
{"version":"2","kind":"compile_error","id":"...","message":"..."}
{"version":"2","kind":"end","meta":{"id_scheme":"2",...},"aborted":false,"abort_reason":null,"kill_rate":0.81,...}
```

Per-site lines (`"result"` / `"compile_error"`) arrive in **input
order** even under `--max-concurrency > 1`, because the runner
collects via `async_stream`'s `:ordered: true` default and the
streaming callback fires from a sequential post-fold. The final line
on the sink is the aggregate document without a `kind` field. Timings
appear only in that document.

### Progress feedback

By default, when stderr is a TTY, a one-line-per-site progress feed
is written to stderr:

```
[12/345] killed   lib/foo.ex:42 :arith
[13/345] survived lib/foo.ex:43 :arith
[14/345] timeout  lib/foo.ex:51 :case_drop
```

Pass `--no-progress` to suppress unconditionally. The feed is driven
by the mutation runner's `:on_site_completed` callback (the same
per-site seam `--stream` rides) via `MutagenEx.Progress`.

### Resource caps

`mix mutagen` enforces caps on input and output volume to keep one bad
invocation from running away with the host's memory or wall-clock time:

- `--scope` and `--tests` each accept at most 100 occurrences. The 101st
  is refused at parse time with `abort_reason: "too_many_targets"`. No
  filesystem touch.
- `--max-sites` (default 10_000) caps the enumerated mutation sites.
  Exceeding the cap aborts with `abort_reason: "too_many_sites"` BEFORE
  the mutation runner starts; the error-JSON `details` map names the
  count so you can choose between narrowing `--scope` and raising
  `--max-sites`.
- `--budget-ms` (optional) caps the aggregate mutation-phase
  wall-clock. When the budget elapses the runner stops dispatching new
  sites and the JSON document carries `truncated: true` (`aborted` stays
  `false` — truncation is a graceful early exit, not an abort). The
  per-site `--timeout-ms` still bounds the in-flight site; worst-case
  overshoot is one `timeout_ms`.

### `--json` path safety

`--json <path>` is canonicalised before any mutation runs, in two layers:

1. **Parse-time** (pure-string): `..` segments and NUL bytes are refused
   with `abort_reason: "unsafe_json_path"`. No filesystem touch happens.
2. **Filesystem-canonicalisation**: every existing component is resolved
   through `File.read_link/1`. If the fully-resolved path escapes the
   project root (resolved through symlinks itself — macOS
   `/var -> /private/var` is handled correctly), the run aborts with
   `abort_reason: "unsafe_json_path"`. The final component is allowed to
   not yet exist; it is created at write time.

The default policy is **inside the project root only**. CI workflows
writing artifacts to `/tmp` or a sibling directory must pass
`--unsafe-json-outside-project`; that flag bypasses the inside-root
check and emits a one-shot stderr warning naming the resolved target.
The symlink-resolution step still runs in either mode — the resolved
path you write to is always the fully-canonical one.

## Application configuration

`mutagen_ex` reads one optional knob from `Application.get_env/3`:

| Key | Purpose |
|---|---|
| `:redact` | A list of compiled regexes or regex source strings. Mutagen validates it after loading runtime configuration and before the test alias and helper. Invalid entries abort with `invalid_redact_config`. Built-in rules run first. The default adds no custom patterns. |

Set it in `config/config.exs`:

```elixir
config :mutagen_ex,
  redact: [
    ~r/AWS_(?:ACCESS_KEY_ID|SECRET_ACCESS_KEY)=\S+/,
    ~r/Bearer [A-Za-z0-9._-]+/
  ]
```

The default report contains repository source and structured test metadata.
Treat it as sensitive as the source. Secrets committed in source can appear
in excerpts. `--no-source` omits site excerpts, file, function, and the
fixed compiler diagnostic. Scope and test paths, coverage paths, skipped
paths, module names, and site IDs still appear. Each site ID contains a
path and an unkeyed MD5 hash of the normalized source AST. A reader can
guess a low-entropy literal and check the hash offline.

Default reports keep failure counts by module, literal helper tag keys,
and counts of lost registered processes. Compiled project exception names
count as repository text. Dynamic exception names, test names, helper
filter values, host process names, and diagnostic bodies require
`--include-host-output`. Logger and cleanup output stay on stderr.

Treat an opted-in report as sensitive as the test output. Pattern
redaction is best-effort. It covers known credential shapes and can miss
plain values, prose, and encodings. It examines at most 64 KiB per field.
A regex execution error replaces the entire field with
`[REDACTED: redaction failed]`.

Emitted text bodies and source excerpts have a 4 KiB payload cap.
Source excerpts preserve tabs and newlines and remove other control
characters and Unicode format characters. A truncation marker reports
bytes dropped by the input and output caps.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Pipeline ran to completion. This includes a run where every mutation survived — kill rate of 0.0 is a valid result, not a failure. |
| `2` | Mutagen aborted and wrote an error document to the selected destination. The string field `abort_reason` names the failure, for example `"missing_scope"` or `"baseline_red"`. |

`aborted: true` in the emitted JSON always co-occurs with a non-zero exit;
`aborted: false` always co-occurs with exit 0.

## JSON output

The aggregate JSON document goes to stdout or the file named by
`--json <path>` and ends with a newline. With `--stream`, it follows
the [per-site events](#ndjson-streaming---stream).

`meta.timings_ms` measures elapsed milliseconds for boot, coverage,
baseline and mutation. The total also includes work between phases such
as enumeration, through report assembly. A phase that did not run shows
zero. For a fixed environment and deterministic tests, `meta.timings_ms`
is the only non-deterministic report field.

### Successful run

This example comes from a copy of the lane fixture with `ExUnit.start()`
in `test/test_helper.exs`. The output is indented for readability.

```bash
MIX_ENV=test mix mutagen --scope lib/lane_fixture/arith.ex \
  --tests test/lane_fixture/arith_test.exs
```

```json
{
  "abort_reason": null,
  "aborted": false,
  "baseline": {
    "failed": 0,
    "failures": [],
    "passed": 5
  },
  "coverage": {
    "covered_lines": {
      "lib/lane_fixture/arith.ex": [
        12,
        14,
        16,
        18
      ]
    }
  },
  "details": {},
  "meta": {
    "elixir_version": "1.19.6",
    "exunit_seed": 0,
    "fail_fast": true,
    "id_scheme": "2",
    "otp_version": "28",
    "timings_ms": {
      "baseline": 3,
      "boot": 75,
      "coverage": 58,
      "mutation": 80,
      "total": 235
    },
    "tool_version": "0.1.0"
  },
  "mutation": {
    "compile_error": 0,
    "compile_errors": [],
    "completed": 7,
    "kill_rate": 0.7142857142857143,
    "killed": 5,
    "results": [
      {
        "after": "a - b",
        "before": "a + b",
        "before_source": "a + b",
        "column": 24,
        "confidence": "high",
        "file": "lib/lane_fixture/arith.ex",
        "function": "LaneFixture.Arith.add/2",
        "id": "lib/lane_fixture/arith.ex:f7fc9974f882553f6b11c5428b0baac6:arith",
        "line": 12,
        "mutator": "arith",
        "status": "killed",
        "tainted_predecessors": false,
        "warnings": [
          "warning: redefining module LaneFixture.Arith (current version loaded from _build/test/lib/lane_fixture/ebin/Elixir.LaneFixture.Arith.beam)\n    │\n  1 │ defmodule LaneFixture.Arith do\n    │ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n    │\n    └─ lib/lane_fixture/arith.ex:1: LaneFixture.Arith (module)"
        ]
      },
      {
        "after": "a + b",
        "before": "a - b",
        "before_source": "a - b",
        "column": 24,
        "confidence": "high",
        "file": "lib/lane_fixture/arith.ex",
        "function": "LaneFixture.Arith.sub/2",
        "id": "lib/lane_fixture/arith.ex:02f1348e12b94f92cdcfe1d5cbd6634a:arith",
        "line": 14,
        "mutator": "arith",
        "status": "killed",
        "tainted_predecessors": false,
        "warnings": [
          "warning: redefining module LaneFixture.Arith (current version loaded from _build/test/lib/lane_fixture/ebin/Elixir.LaneFixture.Arith.beam)\n    │\n  1 │ defmodule LaneFixture.Arith do\n    │ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n    │\n    └─ lib/lane_fixture/arith.ex:1: LaneFixture.Arith (module)"
        ]
      },
      {
        "after": "a / b",
        "before": "a * b",
        "before_source": "a * b",
        "column": 24,
        "confidence": "high",
        "file": "lib/lane_fixture/arith.ex",
        "function": "LaneFixture.Arith.mul/2",
        "id": "lib/lane_fixture/arith.ex:8d516b89cd37a53d164ad5a2afe29ed0:arith",
        "line": 16,
        "mutator": "arith",
        "status": "killed",
        "tainted_predecessors": false,
        "warnings": [
          "warning: redefining module LaneFixture.Arith (current version loaded from _build/test/lib/lane_fixture/ebin/Elixir.LaneFixture.Arith.beam)\n    │\n  1 │ defmodule LaneFixture.Arith do\n    │ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n    │\n    └─ lib/lane_fixture/arith.ex:1: LaneFixture.Arith (module)"
        ]
      },
      {
        "after": "div_safe(a, b)",
        "before": "div_safe(a, b) when b != 0",
        "before_source": "div_safe(a, b) when b != 0",
        "column": 22,
        "confidence": "low",
        "file": "lib/lane_fixture/arith.ex",
        "function": "LaneFixture.Arith.div_safe/2",
        "id": "lib/lane_fixture/arith.ex:50c6b355d96c53576c96a09782b8533d:guard_drop",
        "line": 18,
        "mutator": "guard_drop",
        "status": "survived",
        "tainted_predecessors": false,
        "warnings": [
          "warning: redefining module LaneFixture.Arith (current version loaded from _build/test/lib/lane_fixture/ebin/Elixir.LaneFixture.Arith.beam)\n    │\n  1 │ defmodule LaneFixture.Arith do\n    │ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n    │\n    └─ lib/lane_fixture/arith.ex:1: LaneFixture.Arith (module)"
        ]
      },
      {
        "after": "b == 0",
        "before": "b != 0",
        "before_source": "b != 0",
        "column": 29,
        "confidence": "high",
        "file": "lib/lane_fixture/arith.ex",
        "function": "LaneFixture.Arith.div_safe/2",
        "id": "lib/lane_fixture/arith.ex:702f2afcc0d5994b0372219de4bcc4d0:compare",
        "line": 18,
        "mutator": "compare",
        "status": "killed",
        "tainted_predecessors": false,
        "warnings": [
          "warning: redefining module LaneFixture.Arith (current version loaded from _build/test/lib/lane_fixture/ebin/Elixir.LaneFixture.Arith.beam)\n    │\n  1 │ defmodule LaneFixture.Arith do\n    │ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n    │\n    └─ lib/lane_fixture/arith.ex:1: LaneFixture.Arith (module)"
        ]
      },
      {
        "after": "1",
        "before": "0",
        "before_source": "0",
        "column": 29,
        "confidence": "high",
        "file": "lib/lane_fixture/arith.ex",
        "function": "LaneFixture.Arith.div_safe/2",
        "id": "lib/lane_fixture/arith.ex:d821575fe16fe3710afb032918744e6b:literal",
        "line": 18,
        "mutator": "literal",
        "status": "survived",
        "tainted_predecessors": false,
        "warnings": [
          "warning: redefining module LaneFixture.Arith (current version loaded from _build/test/lib/lane_fixture/ebin/Elixir.LaneFixture.Arith.beam)\n    │\n  1 │ defmodule LaneFixture.Arith do\n    │ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n    │\n    └─ lib/lane_fixture/arith.ex:1: LaneFixture.Arith (module)"
        ]
      },
      {
        "after": "a * b",
        "before": "a / b",
        "before_source": "a / b",
        "column": 41,
        "confidence": "high",
        "file": "lib/lane_fixture/arith.ex",
        "function": "LaneFixture.Arith.div_safe/2",
        "id": "lib/lane_fixture/arith.ex:2edeb721487365fa8cb5322bae381f16:arith",
        "line": 18,
        "mutator": "arith",
        "status": "killed",
        "tainted_predecessors": false,
        "warnings": [
          "warning: redefining module LaneFixture.Arith (current version loaded from _build/test/lib/lane_fixture/ebin/Elixir.LaneFixture.Arith.beam)\n    │\n  1 │ defmodule LaneFixture.Arith do\n    │ ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n    │\n    └─ lib/lane_fixture/arith.ex:1: LaneFixture.Arith (module)"
        ]
      }
    ],
    "skipped": [],
    "state_drift_warning": {},
    "survived": 2,
    "timeout": 0,
    "total": 7
  },
  "scope": [
    {
      "file": "lib/lane_fixture/arith.ex",
      "line_range": [
        1,
        19
      ],
      "module": "LaneFixture.Arith"
    }
  ],
  "tests": {
    "exclude": [],
    "files": [
      "test/lane_fixture/arith_test.exs"
    ],
    "include": []
  },
  "truncated": false,
  "version": "2",
  "warnings": []
}
```

### Aborted run

When the run cannot proceed — for example, `--scope` names a module that
does not exist — `aborted` is `true`, the phase blocks that never ran are
`null`, and `details` carries a human-readable `message` plus any
reason-specific fields. The exit code is non-zero. The reason strings are
enumerated in the [Exit codes](#exit-codes) section.

```json
{
  "abort_reason": "module_not_found",
  "aborted": true,
  "baseline": null,
  "coverage": null,
  "details": {
    "message": "no `defmodule LaneFixture.Missing` found in any project source file",
    "module": "Elixir.LaneFixture.Missing",
    "target": "LaneFixture.Missing"
  },
  "meta": {
    "elixir_version": "1.19.6",
    "exunit_seed": 0,
    "fail_fast": true,
    "id_scheme": "2",
    "otp_version": "28",
    "timings_ms": {
      "baseline": 0,
      "boot": 141,
      "coverage": 0,
      "mutation": 0,
      "total": 153
    },
    "tool_version": "0.1.0"
  },
  "mutation": null,
  "scope": [],
  "tests": null,
  "truncated": false,
  "version": "2",
  "warnings": []
}
```

Both examples are from CLI runs on the fixture. The schema contract is
in [`.spec/specs/json_schema.spec.md`](.spec/specs/json_schema.spec.md).

## Baseline guard rail

Before any mutation runs, the `baseline` phase runs the cited tests
once against unmodified code. If any cited test fails, the pipeline
aborts with `reason: :baseline_red` and emits the error-JSON document
(`aborted: true`, populated `baseline.failed`) — mutation never starts.
This catches the "your suite is already red" case so kill rates are
never computed against a broken baseline.

The guard works even though the `coverage → baseline → mutation` phase
order drains `ExUnit.Server` (each `ExUnit.run/0` consumes the server's
registered-module list) and `Code.require_file/1` is one-shot per path.
Both the coverage and baseline phases explicitly re-register each cited
module with `ExUnit.Server.add_module/2` before their own `ExUnit.run/0`
(mutagen-wrd.37 / mutagen-wrd.38), so baseline sees the cited modules in
the registry and reports real failures. The production-condition
regression test for this lives in
`test/mutagen_ex/baseline_red_guard_test.exs` (it drives the real
`ExUnit.Server`, not a fake), with end-to-end coverage in
`test/mutagen_ex/end_to_end_test.exs` (`:baseline_red_scenario`).

> Earlier releases documented this as a limitation (the guard "did not
> trip"). That was fixed by the re-registration above; the manual
> `mix test`-first workaround the old docs suggested is no longer
> required.

## Known limitations

1. **`:case_drop` on a guarded recursive-base-case classifies
   `:killed`, not `:timeout`.** Documented behavior (per
   `mutagen-wrd.14`): when the dropped clause is the only non-recursing
   branch, the surviving recursive clause's guard rejects the base
   value and the BEAM raises `CaseClauseError`. The mutator catalog
   reflects this; the classification is intentional, not a bug.

## Performance

The source checkout includes a benchmark harness at
`scripts/helper_scripts/bench_ast_perf.exs`. It drives the full pipeline
against `scripts/helper_scripts/bench_fixtures/wrd25_200sites/` and
reports wall-clock, per-site time, peak `:erlang.memory/0`, and the
SHA-256 of the emitted NDJSON. Run with `mix run scripts/helper_scripts/
bench_ast_perf.exs`; pass `--baseline <path>` to capture a run for
later comparison and `--compare <path>` to score a fresh run against a
prior baseline.

The `.25` AST/perf epic measured a 1.66× wall-clock speedup on the
wrd25 fixture between commit `978a995` (pre-.25) and `78b022f`
(post-.25.6); see the `[Unreleased]` `.25` capstone entry in
`CHANGELOG.md` for the full table and the follow-up triage of the
gap to the spec's documented 2-4× target. The byte-identity of the
mutation results (site IDs, before/after slices, kill/survive
verdicts, kill_rate) is preserved across the refactor — only timing
and the diagnostic warning text changed.

## Specs

The behavioural contract for `mutagen_ex` lives in `.spec/`:

- `.spec/specs/cli.spec.md` — `mix mutagen` command surface
- `.spec/specs/mutation_pipeline.spec.md` — orchestration state machine
- `.spec/specs/mutators.spec.md` — mutator catalog and predicates
- `.spec/specs/json_schema.spec.md` — version 2 output document shape
- `.spec/specs/coverage.spec.md` — coverage phase
- `.spec/specs/mutation_enumeration.spec.md` — site enumeration rules
- `.spec/specs/scope_resolution.spec.md` — `--scope` resolution
- `.spec/specs/test_selection.spec.md` — `--tests` resolution
- `.spec/decisions/` — durable architectural decisions

When the implementation and the specs disagree, fix the spec first
(see `.spec/AGENTS.md`).

## Development

```bash
mix compile --warnings-as-errors
mix test
```

No third-party dependencies. Elixir `~> 1.19`, stdlib only.

### Test suite gates

The default `mix test` run excludes subprocess integration tests, the
end-to-end fixture runs, and the coverage spikes.

| Tag | What it covers | How to run |
|---|---|---|
| `:e2e_slow` | Full `mix mutagen` pipeline against the lane fixture; takes minutes per scenario. | `mix test --only e2e_slow` |
| `:spike` | C1/C2 integration spikes under `test/mutagen_ex/integration/` — ~500 cover lifecycles per default run. These are the gating decision artifact for the in-process pipeline (`mutagen.decision.in_process_pipeline`); they must stay runnable, just not on every default invocation. | `mix test --only spike` |
| `:host_setup_integration` | Real Postgres Sandbox and Mox through a path dependency and an installed archive. | `mix test --only host_setup_integration test/integration/host_setup_test.exs` |

`mix test.integration` includes the Postgres fixture. It defaults to the
`/tmp` Unix socket, port `5432`, and the current OS user. Set
`HOST_SETUP_DB_HOST`, `HOST_SETUP_DB_PORT`, `HOST_SETUP_DB_USER`,
`HOST_SETUP_DB_PASSWORD`, or `HOST_SETUP_DB_NAME` to override those settings.
The fixture adds a unique suffix to its database name and drops the database
after the run. Its database user needs permission to create databases.

The C2 spike accepts `MUTAGEN_SPIKE_ITERATIONS=<n>` to override the loop
count. Default is `10`; the original gating run used `100`:

```bash
# Quick smoke (10 iterations)
mix test --only spike

# Full gating run (100 iterations, ~as long as the original spike)
MUTAGEN_SPIKE_ITERATIONS=100 mix test --only spike
```

C1 retains a fixed 100-iteration count — its loop measures restore
contract fidelity across module shapes, where the cycle count is the
contract.
