# mutagen_ex

Mutation testing for Elixir. `mix mutagen` mutates a chosen scope, runs a
cited test set against each mutation, and emits a single JSON document
classifying every mutation as `killed`, `survived`, `timeout`, `error`, or
`compile_error`.

The CLI (`mix mutagen`) is the supported user-facing entry point;
`MutagenEx.MutationRunner.run/1` is the equivalent library-caller entry
point. The JSON document is the only output. Both are stable contracts
as of v0.1.0.

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

## Entrypoints

`mutagen_ex` boots `MutagenEx.Application` whenever the `:mutagen_ex`
application starts. That supervisor is the program entrypoint; everything
the tool runs lives under `MutagenEx.TaskSup`.

User-facing entrypoint surfaces:

- **CLI**: `mix mutagen` (the `Mix.Tasks.Mutagen` task). This is the
  documented and supported route.
- **Library**: `MutagenEx.MutationRunner.run/1` for callers depending on
  `:mutagen_ex` directly. Same in-process pipeline, no CLI parsing.

Only one concurrent MutagenEx mutation cycle per BEAM is supported;
concurrent callers are refused with `{:error, :cover_already_running, _}`.
See `.spec/decisions/supervision_tree.md`.

## What `mix mutagen` does

For each `--scope` target, mutagen_ex:

1. Resolves the target to one or more `(module, file)` pairs.
2. Runs the cited tests once unmodified to establish a green baseline
   (red baseline aborts the run).
3. Records line-level coverage for the in-scope modules.
4. Enumerates mutation sites under the AST of each in-scope file,
   restricted to covered lines.
5. For each site, applies the mutator, recompiles the module in place,
   re-runs the cited tests, and classifies the result.
6. Restores the original module after every site.
7. Emits the final JSON document.

Tests run **serially** in every phase. The run is single-process: there is
no worker pool, no shelled-out subprocess.

`mix mutagen` does not write to disk. Mutations are applied in memory via
`Code.compile_quoted/2`; the original module is restored from the cached
AST after every site. The byte-identity contract is asserted across
`lib/`, `_build/`, `cover/`, host project config (`mix.exs`, `mix.lock`,
`.formatter.exs`), and tmp entries with the `mutagen_ex_` prefix — see
`mutagen.mutation_pipeline.r11` and `mutagen.coverage.r7`.

## Basic usage

```bash
# Single file scope, single test file
mix mutagen --scope lib/foo.ex --tests test/foo_test.exs

# Module scope, tag-cited tests, custom per-mutation budget
mix mutagen --scope MyApp.Foo --tests tag:fast --timeout-ms 10000

# Function scope, deterministic seed, redirected output
mix mutagen --scope MyApp.Foo.bar/1 \
            --tests test/foo_test.exs \
            --seed 42 \
            --json out/mutagen.json
```

## Flags

| Flag | Purpose |
|---|---|
| `--scope <target>` | What to mutate. A `.ex` file path, a module name, or `Module.fun/arity`. Required. Repeatable; each occurrence accumulates. Cap: 100 occurrences. |
| `--tests <target>` | Which tests judge the mutations. A `_test.exs` path, a `file:line` pair, or `tag:<name>`. Required. Repeatable. Cap: 100 occurrences. |
| `--timeout-ms <int>` | Wall-clock budget per mutation run. Default `5000`. Must be positive. |
| `--seed <int>` | ExUnit seed, propagated to every test-running phase. Default `0`. Controls test ordering only, not mutation enumeration order. |
| `--json <path>` | Write the final JSON document to `<path>` instead of stdout. The document always ends with a single newline. Path is canonicalised before any mutation runs: `..` segments and NUL bytes are refused at parse time, and the resolved path must stay inside the project root unless `--unsafe-json-outside-project` is also passed. |
| `--unsafe-json-outside-project` | Opt-in to writing `--json` output outside the project root. CI integrations targeting an artifacts directory above the project root pass this; everyday use should leave it off. Emits a one-shot stderr warning naming the resolved target at run start. |
| `--max-sites <int>` | Upper bound on enumerated mutation sites for one run. Default `10000`. Exceeding the cap aborts with `abort_reason: "too_many_sites"` BEFORE the mutation runner starts — narrow `--scope` (or raise the cap) to proceed. |
| `--budget-ms <int>` | Optional aggregate wall-clock budget for the mutation phase, in milliseconds. Default unbounded (`--timeout-ms` still bounds each site). When elapsed, the runner stops dispatching new sites and emits a `truncated: true` partial JSON report. |
| `--max-concurrency <int>` | Cap on the number of per-site mutation tasks `Task.Supervisor.async_stream_nolink/4` runs in parallel. Default `1` (fully serial, byte-equivalent to v1.0). Set to `System.schedulers_online()` or a positive integer to opt in to parallel dispatch. See [Parallel mode](#parallel-mode-and-observability) below. |
| `--stream` | Emit one NDJSON line per completed site (and `start`/`end` envelope lines) to the same sink the aggregate document goes to. Off by default. |
| `--no-progress` | Suppress the human-readable per-site progress feed on stderr. Default is auto-on when stderr is a TTY, auto-off otherwise. |

The flag surface above is exhaustive for v1.1.0. `mix mutagen --no-json`
and `mix mutagen --scope file.ex:Module` are both **explicitly rejected**
— see Known limitations.

## Parallel mode and observability

v1.1 adds the wiring for parallel per-site dispatch, NDJSON streaming,
and `:telemetry` events. The mechanism is in place; the default value
of `--max-concurrency` is `1` because the in-process pipeline shares
ExUnit's global server, the Code.Server's per-module load locks, and
`:cover` instrumentation across all per-site tasks (see "Known
limitations" below). Set `--max-concurrency N` explicitly when your
scope and test corpus are arranged for collision-free parallel
execution.

### Telemetry events

The library dispatches `:telemetry` events at well-defined points.
Attach your own handlers; `mutagen_ex` ships no built-in subscriber.

| Event | Measurements | Metadata |
|---|---|---|
| `[:mutagen_ex, :run, :start]` | `system_time` | `argv` |
| `[:mutagen_ex, :coverage, :stop]` | `duration` | `covered_files`, `covered_lines` |
| `[:mutagen_ex, :baseline, :stop]` | `duration` | `passed`, `failed` |
| `[:mutagen_ex, :enumeration, :stop]` | `sites` | `skipped` |
| `[:mutagen_ex, :site, :start]` | `system_time` | `site_id`, `file`, `line`, `mutator`, `index`, `total` |
| `[:mutagen_ex, :site, :stop]` | `duration` | `site_id`, `file`, `line`, `mutator`, `status`, `index`, `total` |
| `[:mutagen_ex, :run, :stop]` | `duration` | `aborted`, `abort_reason`, `killed`, `survived`, `timeout`, `compile_error`, `error` |

The `coverage`, `baseline`, and `site` spans use `:telemetry.span/3`,
so a paired `:exception` event fires automatically if the wrapped
phase raises.

### NDJSON streaming (`--stream`)

When `--stream` is set, `MutagenEx.JsonStreamer` emits one JSON object
per line on the same sink the aggregate document goes to. The line
shape is byte-equal to the equivalent entry in the aggregate
`mutation.results[]` / `mutation.compile_errors[]` array, plus a
`"kind"` discriminator and the `"version"` literal:

```
{"version":"1","kind":"start","total":42,"meta":{...}}
{"version":"1","kind":"result","id":"...","status":"killed","mutator":"arith",...}
{"version":"1","kind":"compile_error","id":"...","message":"..."}
{"version":"1","kind":"end","aborted":false,"abort_reason":null,"kill_rate":0.81,...}
```

Per-site lines (`"result"` / `"compile_error"`) arrive in **input
order** even under `--max-concurrency > 1`, because the runner
collects via `async_stream`'s `:ordered: true` default and the
streaming callback fires from a sequential post-fold.

### Progress feedback

By default, when stderr is a TTY, a one-line-per-site progress feed
is written to stderr:

```
[12/345] killed   lib/foo.ex:42 :arith
[13/345] survived lib/foo.ex:43 :arith
[14/345] timeout  lib/foo.ex:51 :case_drop
```

Pass `--no-progress` to suppress unconditionally. The feed is wired
to the `[:mutagen_ex, :site, :stop]` telemetry event via
`MutagenEx.Progress`.

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
| `:redact` | A list of `%Regex{}` values or binary regex sources. Every match in stderr captured during mutation runs, exception messages, and source slices that flow into `mutation.results[].warnings[]`, `mutation.compile_errors[].message`, and abort-detail message fields is replaced with the literal string `[REDACTED]`. Default `[]` (no redaction). Pair with `--json <path>` whenever JSON reports are archived outside the run host. |

Set it in `config/config.exs`:

```elixir
config :mutagen_ex,
  redact: [
    ~r/AWS_(?:ACCESS_KEY_ID|SECRET_ACCESS_KEY)=\S+/,
    ~r/Bearer [A-Za-z0-9._-]+/
  ]
```

Independently of `:redact`, **every** free-form text field that
captures user-code-derived bytes is truncated at 4 KiB. When truncation
occurs, the emitted string ends with `... <N bytes truncated>` where
`N` is the byte count that was dropped. The cap is fixed in v1 and
applies whether `:redact` is set or not.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Pipeline ran to completion. This includes a run where every mutation survived — kill rate of 0.0 is a valid result, not a failure. |
| non-zero | "Bad input" or unrecoverable error. Every non-zero exit also writes an error-JSON document to stdout (or `--json <path>`). The `reason` field names the abort: `:missing_scope`, `:invalid_timeout`, `:too_many_targets`, `:too_many_sites`, `:invalid_max_sites`, `:invalid_budget_ms`, `:no_tests_match`, `:baseline_red`, `:self_mutation_refused`, `:flag_not_supported_in_v1`, etc. |

`aborted: true` in the emitted JSON always co-occurs with a non-zero exit;
`aborted: false` always co-occurs with exit 0.

## JSON output

The v1 document shape is defined by-example. The authoritative reference
is the golden fixture set under `test/mutagen_ex/golden/`:

- `end_to_end_scenario_1_arith.json` — canonical successful run.
- `end_to_end_scenario_5_baseline_red.json` — abort on red baseline.
- `end_to_end_scenario_6_zero_coverage.json` — clean run with empty
  `mutation.results`.
- `error_unresolvable_scope.json` — abort before the mutation phase.

The behavioural contract for the document lives in
`.spec/specs/json_schema.spec.md`.

## Known limitations

1. **Baseline phase runs zero tests in production — `:baseline_red`
   guard rail does not trip.** The `coverage → baseline → mutation`
   phase order means `Code.require_file/1` (used by both coverage and
   baseline to load cited test files) is cached by the time baseline
   runs. `ExUnit.Server` has already been drained by coverage's
   `ExUnit.run/0`, so baseline's `ExUnit.run/0` reports `failures: 0`
   regardless of whether the cited tests actually pass. Survived/killed
   classification is **unaffected** — the mutation phase explicitly
   re-registers each module with `ExUnit.Server.add_module/2` before
   every per-site run. Tracked as `mutagen-wrd.37`. Workaround until
   fixed: confirm the cited tests pass via a normal `mix test` before
   running `mix mutagen`; mutagen_ex will not warn if they're red.

2. **`:case_drop` on a guarded recursive-base-case classifies
   `:killed`, not `:timeout`.** Documented behavior (per
   `mutagen-wrd.14`): when the dropped clause is the only non-recursing
   branch, the surviving recursive clause's guard rejects the base
   value and the BEAM raises `CaseClauseError`. The mutator catalog
   reflects this; the classification is intentional, not a bug.

## Performance

`mutagen_ex` ships a benchmark harness at
`priv/helper_scripts/bench_ast_perf.exs`. It drives the full pipeline
against `priv/helper_scripts/bench_fixtures/wrd25_200sites/` and
reports wall-clock, per-site time, peak `:erlang.memory/0`, and the
SHA-256 of the emitted NDJSON. Run with `mix run priv/helper_scripts/
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
- `.spec/specs/json_schema.spec.md` — v1 output document shape
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

The default `mix test` run excludes two tag families to keep wall-clock
under ~60s for the smoke gate:

| Tag | What it covers | How to run |
|---|---|---|
| `:e2e_slow` | Full `mix mutagen` pipeline against the lane fixture; takes minutes per scenario. | `mix test --only e2e_slow` |
| `:spike` | C1/C2 integration spikes under `test/mutagen_ex/integration/` — ~500 cover lifecycles per default run. These are the gating decision artifact for the in-process pipeline (`mutagen.decision.in_process_pipeline`); they must stay runnable, just not on every default invocation. | `mix test --only spike` |

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
