# mutagen_ex

Mutation testing for Elixir. `mix mutagen` mutates a chosen scope, runs a
cited test set against each mutation, and emits a single JSON document
classifying every mutation as `killed`, `survived`, `timeout`, `error`, or
`compile_error`.

The CLI (`mix mutagen`) is the supported user-facing entry point;
`MutagenEx.MutationRunner.run/1` is the equivalent library-caller entry
point. The JSON document is the only output. Both are stable contracts
as of v0.1.0.

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

- **JSON-first, single-document output — no pretty human renderer by
  design.** `mix mutagen` emits exactly one JSON document (to stdout or
  `--json <path>`) and nothing else. There is no `--no-json` pretty mode;
  supplying it is a hard error, not a silent fallback. Humans pipe through
  `jq`. See [`.spec/decisions/no_pretty_output_v1.md`](.spec/decisions/no_pretty_output_v1.md).

- **Content-addressed, stable mutation IDs across `mix format`.** Each
  mutation's `id` is `{relative_file}:{ast_hash}:{mutator_name}`, where the
  hash is taken over the *normalized AST* (line/column metadata stripped).
  Re-running after `mix format` reflows the source produces byte-identical
  IDs, so a judge can ask "did the same mutation survive last week?" and
  get a meaningful answer. A naive `file:line:col` scheme cannot. See
  [`.spec/decisions/content_addressed_ids.md`](.spec/decisions/content_addressed_ids.md).

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
  swaps bytecode via `Code.compile_quoted/1` and restores from a cached AST,
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
| `with_swap` | reorders `with` clauses | `with` is an Elixir control structure |
| `else_removal` | drops the `else` branch of `if`/`with` | shaped to Elixir's `if`/`with` else semantics |
| `case_drop` | drops the last `case`/`cond` clause | closest to the classic statement/clause-deletion (SDL) family, but Elixir's exhaustiveness and `CaseClauseError` behaviour make it its own thing (see Known limitations) |
| `pipeline` | reorders adjacent `\|>` segments | the pipe operator is Elixir-idiomatic |

The split is deliberate: the four classic operators give the catalog a
well-understood, citable backbone, while the six idiomatic operators cover the
fault classes that only show up in Elixir code. Treat the standard-operator
names above as the vocabulary a reviewer (human or LLM judge) already knows;
treat the idiomatic six as the Elixir-specific extension that vocabulary lacks.

## Efficacy on real codebases

The argument above is only worth anything if mutagen_ex actually surfaces
real test gaps on real code — not just on a synthetic fixture. It does. Two
empirical studies back this up.

**Self-study (the library's own tests).** Across 22 closed tickets in
mutagen_ex's own history — each carrying a human verifier's written claim
that the tests covered the implementation — we ran `mix mutagen` against the
module under test and compared the kill rate to the verifier's verdict.
**160 mutation sites, aggregate kill rate 0.75.** mutagen_ex found concrete,
fixable test gaps in **8 of the 22 tickets** — gaps an experienced reviewer
had already approved by hand. A secondary signal held up too: tickets where
a reviewer had raised any rigor concern came back weaker (kill rate 0.68)
than clean first-try approvals (0.75), which in turn were weaker than
tickets that had been bounced and re-implemented (0.88). Human review
carries information, but routinely misses the *specific* mutation-detectable
gap.

**Cross-project study (other people's code).** Using the `mix archive.install`
adoption path (so the target repos stayed untouched), mutagen_ex was run
against three additional Elixir codebases written by different teams: a
stdlib-only library, a Phoenix/Ecto knowledge-graph application, and a
Phoenix LiveView admin application. A fourth, ETL-heavy Phoenix app was
surveyed but had too thin a verified-ticket history to study.

| Codebase shape | Mutation sites | Aggregate kill rate |
|---|---:|---:|
| Stdlib-only library (self-study) | 160 | 0.75 |
| Phoenix/Ecto knowledge-graph + MCP app | 153 | 0.67 |
| Phoenix LiveView admin app | 218 | 0.70 |

The headline result is the **convergence**: three codebases of radically
different shape, test discipline, and authorship landed within ~10 points of
each other. mutagen_ex is measuring a property of test rigor that is roughly
invariant across Elixir codebase shape — strong calibration evidence. The
small spread is itself informative: pure functional libraries (narrow units,
easy to test thoroughly) score highest, and Phoenix apps — whose
happy-path, boundary-implicit tests are inherently weaker at killing
per-branch mutations — sit a few points below. **If you run mutagen_ex
against a Phoenix app, expect an aggregate kill rate in the 0.65-0.75 band,
not 0.85+;** a merge-gate threshold calibrated for a pure library will
false-positive on every app.

### Dogfood: mutagen_ex on its own source

A mutation tester that can't report a score on its own code has a credibility
gap. mutagen_ex has a real reason it can't do this directly — the runner
shares a BEAM with the tests it cites, so mutating its own running modules
would corrupt the runner mid-flight, and it *refuses* to try (see
[`self_mutation_refused`](.spec/decisions/self_mutation_refused.md)). The
honest way around that refusal is the same external-process path a downstream
user takes: copy mutagen_ex's own source into a throwaway Mix project under a
rewritten namespace (so the `MutagenEx.` self-guard no longer matches), wire
the real `mutagen_ex` in as a dependency, and drive `mix mutagen` against the
shadow source from a fresh shell.

Run that way against its own high-value modules — the mutator-registry
(`mutators`), the scope resolver, and the JSON reporter — mutagen_ex's own
test suite scores **46 of 79 mutants killed, aggregate kill rate 0.58.** The
run is reproducible to the mutant (content-addressed IDs, serial seeded
execution): two clean runs on unchanged source produce a byte-identical
score. The number lands in the same 0.5-0.75 band as the cross-project study
rather than at a self-congratulatory 0.9+, which is the point — the tool
holds its own code to the same standard it holds everyone else's, and the
33 survivors are a standing to-do list of mutation-detectable gaps in
mutagen_ex's own tests. The harness and its assertions live in
[`test/integration/self_mutation_test.exs`](test/integration/self_mutation_test.exs);
run it with `mix test --include self_mutation`.

### Representative survivors

Aggregate numbers are abstract; the survivors are the point. Two concrete
findings from the cross-project study:

- **A config-diff module in the admin app scored a kill rate of 0.00 —
  *every* mutation survived.** It was a clean, first-try verifier approval.
  Whatever its tests were asserting, it was not the module's actual
  behaviour: nothing the test does would catch a meaningful behavioural
  change. That is the entire pitch of mutation testing made concrete in a
  single number, on production code a human had already signed off.

- **A controller action whose `{:error, changeset}` arm a verifier had
  *explicitly* flagged as uncovered** went through a bounce-and-redo cycle;
  the final approval comment named the gap and claimed it was addressed.
  mutagen_ex scored the surrounding module at kill rate 0.89 — strong — with
  exactly one residual survivor: a mutation on the precise line the verifier
  had pointed at. The redo cleaned up the neighbourhood and missed the named
  arm. A reviewer pointed at a gap, the implementer claimed to fix it, and
  mutagen_ex showed the gap was still there.

### Caveats, surfaced honestly

- **Aggregate kill rate is a lower bound on test quality.** Equivalent
  mutants (behaviourally identical to the original) count as survivors and
  need human disposition; they deflate the score without representing a real
  gap.
- **Coverage gating means structural code goes silent.** Ecto DSL,
  `defmodule`-only files, and `match?`-on-tuple code report zero sites —
  that is mutagen_ex saying it has nothing to mutate, not a gap.
- **Phoenix/Ecto apps currently need the host OTP application started before
  tests run.** The archive-install runtime starts only `:mutagen_ex` itself,
  which suits stdlib-only libraries but not apps whose tests need `Repo`,
  `Mox`, `PubSub`, or supervised GenServers up first. This is a known,
  fixable adoption gap (a small runtime-preamble change), not a property of
  the mutation engine — and it was worked around in ~12 lines in one of the
  studied apps.
- **HEEx / LiveView templates are out of scope.** The mutator catalog does
  not target templates, so template-heavy code reports no sites.

The one-sentence version, for stakeholders:

> In a four-project comparative study spanning a library, two Phoenix apps,
> and one project too young to study, mutagen_ex found concrete test gaps in
> approved code in every project that produced data — at kill rates that
> converged within ~10 points despite radically different codebase shape.

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
mix mutagen --scope lib/foo.ex --tests test/foo_test.exs
```

The `mix.exs` install above remains the recommended posture for projects
that want `mutagen_ex` pinned per repo for CI and SOC-style traceability.
The archive install is additive: suitable for ad-hoc local use, not for CI.

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
| `--timeout-ms <int>` | Wall-clock budget per mutation run. Default `30000`. Must be positive. Phoenix/Ecto-style apps often need the larger default because setup and supplemental tests can make a single mutation cycle exceed five seconds. |
| `--seed <int>` | ExUnit seed, propagated to every test-running phase. Default `0`. Controls test ordering only, not mutation enumeration order. |
| `--json <path>` | Write the final JSON document to `<path>` instead of stdout. The document always ends with a single newline. Path is canonicalised before any mutation runs: `..` segments and NUL bytes are refused at parse time, and the resolved path must stay inside the project root unless `--unsafe-json-outside-project` is also passed. |
| `--unsafe-json-outside-project` | Opt-in to writing `--json` output outside the project root. CI integrations targeting an artifacts directory above the project root pass this; everyday use should leave it off. Emits a one-shot stderr warning naming the resolved target at run start. |
| `--max-sites <int>` | Upper bound on enumerated mutation sites for one run. Default `10000`. Exceeding the cap aborts with `abort_reason: "too_many_sites"` BEFORE the mutation runner starts — narrow `--scope` (or raise the cap) to proceed. |
| `--budget-ms <int>` | Optional aggregate wall-clock budget for the mutation phase, in milliseconds. Default unbounded (`--timeout-ms` still bounds each site). When elapsed, the runner stops dispatching new sites and emits a `truncated: true` partial JSON report. |
| `--max-concurrency <int>` | Cap on the number of per-site mutation tasks `Task.Supervisor.async_stream_nolink/4` runs in parallel. Default `1` (fully serial, byte-equivalent to v1.0). Values greater than `1` are EXPERIMENTAL and emit a one-shot stderr warning because real ExUnit/:cover backends can produce incorrect kill/survive classification and corrupted coverage. See [Parallel mode](#parallel-mode-streaming-and-progress) below. |
| `--stream` | Emit one NDJSON line per completed site (and `start`/`end` envelope lines) to the same sink the aggregate document goes to. Off by default. |
| `--no-progress` | Suppress the human-readable per-site progress feed on stderr. Default is auto-on when stderr is a TTY, auto-off otherwise. |

The flag surface above is exhaustive. `mix mutagen --no-json`
and `mix mutagen --scope file.ex:Module` are both **explicitly rejected**
— see Known limitations.

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

`mix mutagen` emits exactly one JSON document — to stdout, or to the file
named by `--json <path>`. It always ends with a single trailing newline.
The same shape is used for a successful run and for an aborted one; the
`aborted` flag tells the two apart.

### Successful run

Below is a real, annotated example of a completed run that mutated one
arithmetic helper. (Comments are added here for explanation — the actual
output is plain JSON with no comments.)

```jsonc
{
  // Schema version of this document. Fixed to the literal "1" for v0.1.x.
  "version": "1",

  // false  → the pipeline ran to completion (exit code 0).
  // true   → the run was aborted before finishing (non-zero exit).
  "aborted": false,
  // The abort reason as a string, or null when "aborted" is false.
  "abort_reason": null,
  // true if a --budget-ms cap stopped the run early. A graceful partial
  // result, NOT an abort — "aborted" stays false and the exit code is 0.
  "truncated": false,

  // Environment + run parameters this document was produced under.
  "meta": {
    "tool_version": "0.1.0",     // mutagen_ex version
    "elixir_version": "1.19.5",
    "otp_version": "28",
    "exunit_seed": 0             // the --seed value used for test ordering
  },

  // What was mutated, resolved from --scope.
  "scope": [
    {
      "module": "LaneFixture.Arith",
      "file": "lib/lane_fixture/arith.ex",
      "line_range": [1, 19]
    }
  ],

  // Which tests judged the mutations, resolved from --tests.
  "tests": {
    "files": ["test/lane_fixture/arith_test.exs"],
    "include": [],               // ExUnit include filters (e.g. from tag:)
    "exclude": []
  },

  // The unmodified-code baseline. The run aborts before mutating if any
  // cited test fails here (see "Baseline guard rail").
  "baseline": {
    "passed": 5,
    "failed": 0,
    "failures": []
  },

  // Lines that were covered by the cited tests, per file. Only covered
  // lines are eligible for mutation.
  "coverage": {
    "covered_lines": {
      "lib/lane_fixture/arith.ex": { "bytes": 4 }
    }
  },

  // The heart of the report: every mutation that was applied and judged.
  "mutation": {
    "total": 6,        // mutation sites enumerated
    "completed": 6,    // sites actually run
    "killed": 5,       // a cited test caught the mutation (good)
    "survived": 1,     // no test caught it — a possible coverage gap
    "timeout": 0,      // the mutated code exceeded --timeout-ms
    "compile_error": 0, // the mutation did not compile

    // Fraction of completed mutations that were killed: killed / completed.
    // 1.0 is a perfect score; 0.0 is valid (still exit 0), not a failure.
    "kill_rate": 0.8333333333333334,

    // One entry per mutation that ran. Each describes the edit and verdict.
    "results": [
      {
        // Stable, content-addressed id: file:hash:mutator. Survives
        // `mix format` because it is keyed on AST content, not line number.
        "id": "lib/lane_fixture/arith.ex:88475230:arith",
        "file": "lib/lane_fixture/arith.ex",
        "line": 12,
        "column": 24,
        "mutator": "arith",     // which mutator produced this edit
        "before": "a + b",      // original source at the site
        "after": "a - b",       // the mutated source that was tested
        "before_source": "a + b",
        // killed | survived | timeout | error | compile_error
        "status": "killed",
        "tainted_predecessors": false,
        "warnings": { "count": 1 } // count of advisory warnings for this site
      },
      {
        "id": "lib/lane_fixture/arith.ex:88723725:literal",
        "file": "lib/lane_fixture/arith.ex",
        "line": 18,
        "column": 29,
        "mutator": "literal",
        "before": "0",
        "after": "1",
        "before_source": "0",
        "status": "survived",   // no cited test failed on this edit
        "tainted_predecessors": false,
        "warnings": { "count": 1 }
      }
      // ... remaining results elided ...
    ],

    // Sites that failed to compile when mutated. Same outer shape as a
    // result, plus a "message" field; empty here.
    "compile_errors": [],

    // Sites that were enumerated but not run, with a reason.
    "skipped": [
      {
        "site_id": "lib/lane_fixture/arith.ex:10714624:guard_drop",
        "file": "lib/lane_fixture/arith.ex",
        "mutator": "guard_drop",
        "reason": "structurally_invalid"
      }
    ],
    "state_drift_warning": {}
  },

  // Populated only on an abort (see below); empty on success.
  "details": {},
  // Run-level advisory warning count.
  "warnings": { "count": 0 }
}
```

### Aborted run

When the run cannot proceed — for example, `--scope` names a module that
does not exist — `aborted` is `true`, the phase blocks that never ran are
`null`, and `details` carries a human-readable `message` plus any
reason-specific fields. The exit code is non-zero. The reason strings are
enumerated in the [Exit codes](#exit-codes) section.

```jsonc
{
  "version": "1",
  "aborted": true,
  "abort_reason": "module_not_found",   // names which guard tripped
  "truncated": false,
  "meta": {
    "tool_version": "0.1.0",
    "elixir_version": "1.19.5",
    "otp_version": "28",
    "exunit_seed": 0
  },
  // Phases that never ran are null rather than empty objects.
  "scope": [],
  "tests": null,
  "baseline": null,
  "coverage": null,
  "mutation": null,
  // Why the run aborted, plus reason-specific fields.
  "details": {
    "message": "module Elixir.MyApp.Missing could not be resolved",
    "module": "Elixir.MyApp.Missing"
  },
  "warnings": []
}
```

The two examples above are derived directly from the project's golden
fixtures — `test/mutagen_ex/golden/end_to_end_scenario_1_arith.json` and
`error_unresolvable_scope.json` — so the field names and shapes match the
real output byte-for-byte. The full fixture set is the authoritative
schema-by-example, and the behavioural contract lives in
`.spec/specs/json_schema.spec.md`; both ship in the source repository
rather than the published package.

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
