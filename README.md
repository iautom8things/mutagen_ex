# mutagen_ex

Mutation testing for Elixir. `mix mutagen` mutates a chosen scope, runs a
cited test set against each mutation, and emits a single JSON document
classifying every mutation as `killed`, `survived`, `timeout`, `error`, or
`compile_error`.

The CLI (`mix mutagen`) is the supported user-facing entry point;
`MutagenEx.MutationRunner.run/1` is the equivalent library-caller entry
point. The CLI ends each run with an aggregate JSON document.
`--stream` writes per-site events to the same destination before it.

## Audit mode

Use audit mode to find tests that execute code without asserting its
behavior. Run a whole module and read the per-function table. It lists up
to 50 evaluated functions, lowest kill rate first, with zero first.

```sh
MIX_ENV=test mix mutagen --scope MyApp.Billing --tests auto --json billing.json --summary billing.md
jq '.summary.by_function[]' billing.json
```

Run each source file in a directory and rank the reported modules by kill
rate, with zero first and unevaluated runs last.

```sh
find lib/my_app -name '*.ex' | while IFS= read -r file; do
  MIX_ENV=test mix mutagen --scope "$file" --tests auto --json "audit/$file.json" --summary "audit/$file.md"
done
find audit -name '*.json' -exec cat {} + | jq -rs 'sort_by(.summary.counts.kill_rate // 2)[] | [.summary.counts.kill_rate, ([.scope[].module] | join(", "))] | @tsv'
```

### How much to trust a survivor

A blind measurement at a pre-release commit of this series covered ten
files from two private Phoenix applications. A seeded script selected the files. They included
two contexts, two controllers, LiveViews, and plain modules. A reviewer
judged each survivor after seeing only the code change and the test file.

The reviewer judged public functions by the inputs their specs admit.
For private functions, controllers, and LiveViews, the reviewer used
the inputs their real callers, routes, and forms can deliver.

| Survivors | Real test gaps | Share | 95% interval |
|---|---:|---:|---:|
| High confidence | 27 of 32 | 84% | 68% to 93% |
| High confidence, reachable by current production callers | 23 of 32 | 72% | 55% to 84% |
| Low confidence | 8 of 24 | 33% | 18% to 53% |

| Confidence | Mutator | Real test gaps |
|---|---|---:|
| High | `boolean` | 7 of 7 |
| High | `case_drop` | 12 of 15 |
| High | `else_removal` | 3 of 3 |
| High | `result_tuple` | 2 of 2 |
| High | `compare` | 1 of 1 |
| High | `literal` | 2 of 4 |
| Low | `pipeline` | 5 of 19 |
| Low | `guard_drop` | 2 of 4 |
| Low | `with_swap` | 1 of 1 |

Every figure uses one test file per module and measures gaps in the
selected tests. A follow-up ran nine of the real-gap
survivors against every test file that mentions the function. Other
test files in the same suite killed six of them. Three survived.

A survivor means “the tests you selected miss it”. First rerun with a
wider `--tests` selection before writing a test.

The sample is small and per-mutator confidence is provisional. Mutagen gives
advice for the current run. See the [advisory decision](.spec/decisions/advisory_only.md).

### Changed-code measurement before the fixes

A seeded script chose 12 real commits from two private Phoenix
applications. A reviewer judged them blind, seeing only the change and
the tests that ran.

| What the summary showed | Entries | Real gaps | Covered by a test that did not run | False claim | Noise |
|---|---:|---:|---:|---:|---:|
| Check first (not executed) | 3 | 0 | 1 | 2 | 0 |
| Worth a look (high confidence) | 3 | 0 | 0 | 0 | 3 |
| JSON only (low confidence) | 8 | 1 | 1 | 0 | 6 |

This measurement predates probe confirmation, the changed-line rule, and
opt-in escalation. Those changes address the false execution claims, the
off-diff survivors, and the noise from widening the test selection by
default.

### Third-pass measurement after the fixes

The third pass used the same 12 commits and the same blind protocol
after probe confirmation, the changed-line rule, and opt-in escalation.

- 76 runtime sites in scope, 72 evaluated (59 killed, 12 survived, 1 timed out), 1 could not tell, 3 skipped by the validator.
- 7 of 12 runs showed nothing. 5 runs showed 12 survivors in all, every one on a changed line.
- Check first: 0 entries. No “not executed” claim was made, so none was false (the earlier pass made 3, 2 of them false).
- Worth a look, high confidence: 4 entries, 0 real gaps, 4 noise.
- Worth a look, low confidence on a changed line: 8 entries, 1 real gap, 7 noise.
- Noise by kind: 6 reorderings nobody can observe, 2 inputs that cannot arrive through any caller, 2 that only the function's own contract admits, 1 fallback for malformed configuration that another test already rules out.
- Escalation, rerun on the 5 runs with survivors: 0 outcomes changed, 186 s added.
- Every compared site (28 across 5 runs) had the same status as one run with all selected tests passed explicitly.

The report still included `pipeline` in Worth a look during this
measurement. Five of the eight low-confidence entries came from
`pipeline`. None was a real gap.

On a commit that came with tests, a changed-code run is usually silent.
A listed survivor is more often an unobservable or unreachable change
than a missing test. One of the 12 survivors here was a real test gap.
Read the line before drawing a conclusion. The whole-file audit figures
above support looking for test gaps.

## Changed-code runs

Changed-code runs are quiet by design. On a commit that came with tests,
“nothing to check” is the normal and correct output. The summary shows
functions whose sites the selected tests did not execute, confirmed by
probes, functions where at least three high-confidence mutants ran and
all evaluated mutants survived, and survivors whose own source spans
overlap changed lines. The detailed JSON holds the remaining results.

```bash
MIX_ENV=test mix mutagen --since origin/main --json out/mutagen.json --summary out/mutagen.md
```

Mutagen compares the working tree with the merge base of the ref and HEAD.
A shallow checkout always aborts. Fetch full Git history and use
`fetch-depth: 0` in GitHub Actions. The run plans mutations
in named runtime functions on touched lines, then compares their group
fingerprints with the base source. Formatting, comments, and moved
unchanged functions contribute no runtime sites. Use `--scope` to narrow
the diff further. An empty runtime plan finishes before host setup.

The run includes untracked, unignored files. It excludes test roots and
test support from source planning. An incomplete run returns exit 0 with
its reasons. A tool abort returns exit 2.

Automatic test selection looks for `a/b_test.exs` under the configured
test roots for `a/b.ex` under a configured source root that has a planned
runtime mutation. When a `--since` run
has runtime sites, it also selects new test files and changed test files
whose parsed code differs from the merge base. Formatting and comment
edits alone do not add a test file to this selection. An empty runtime
plan selects no tests. Add `--escalate` to search for more tests for
surviving or uncovered sites. Mutagen searches
uncited test files for the full module name, or for the module's last
segment as a whole word in a file that aliases its parent. Brace aliases
and aliases declared with `as:` count in the module pass. It then
searches for qualified function calls or captures, or bare calls where
the matching module is imported or aliased. It counts text mentions and
uses path order to break ties. Each step takes up to 20 files per function
by default.
Mutagen tests each candidate on the original code. It allows ten times
the narrow baseline duration, with a thirty-second floor capped by the
host boot and mutant timeouts. Each step reports `candidate_deadline_ms`.
If a batch fails, Mutagen keeps the files that pass together in score order.
The module and function passes share a two-minute budget, including
candidate probes. Mutagen estimates each pass from the candidate baselines
and reports files that exceed the budget as `escalation_budget_exhausted`.
Affected survivors carry `selection.escalation_incomplete: true`.
When escalation takes more than half the run, summary notes give the
time spent in each pass. A pass judges mutants with the files admitted
in that pass. Only survivors and uncovered sites advance. A timeout stays unevaluated and
keeps the step that recorded it.

`meta.since` records the ref, merge base, and site counts.
`meta.complete` and `meta.incomplete_reasons` record missing evidence from
skipped or unreadable paths and sites that the runner dropped.
Every abort sets `meta.complete` to false and adds its reason to
`meta.incomplete_reasons`. A partial run stopped by `--budget-ms` records
`mutation_budget_exhausted`. An accounting mismatch between planned sites
and the final outcome records also marks the report incomplete.
`meta.since.unmapped` lists changed code without runtime sites and omits
blank, comment and structural lines.
`mutation.pending` shows sites with no outcome, including uncovered sites
and covered sites left unrun. Coverage includes green
tests added during escalation. `meta.tests_selected` lists why each test
file joined, and each result lists the steps it ran. Warnings name rejected
files and give a reason. Selected and rejected test paths follow `--no-source`.
Each step counts files dropped after a load attempt in `dropped_after_load`.
Result selection includes `after_dropped_file: true` for verdicts made in
that step or later. Those verdicts can reflect side effects the tool could
not undo, such as writes to persistent terms. With `--stream`, changed-code
and automatic runs emit final results and compile errors after all passes
with the same fields as the aggregate. Pending sites appear in the final
JSON document.

Site IDs are stable within an unchanged function. Editing a function can
reassign IDs, so use them to inspect the current report.

## Why mutagen_ex (and how it differs from muzak)

Elixir already has a mature mutation tester:
[muzak / muzak_pro](https://hex.pm/packages/muzak) by Devon Estes. If you
want a polished, human-facing mutation-testing workflow for everyday TDD,
muzak is the established choice and mutagen_ex is not trying to replace it.

mutagen_ex is built for repeatable audits and automated review. It gives
people a Markdown summary and gives scripts and agents a stable JSON
report with site IDs they can compare across runs.

mutagen_ex focuses on these workflows:

- **JSON output.** `mix mutagen` writes the aggregate document to stdout or
  `--json <path>`. Use `--stream` to receive per-site JSON lines before
  the aggregate. Read the `--json` file with `jq` to inspect it.
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

- **Readable audit reports.** Markdown shows findings by function and
  offers a command to rerun each example. The JSON retains every site for
  scripts that rank modules or compare outcomes.

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
survivor can be equivalent to the original code.

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

The RHS name check can skip a valid swap when the name has an outer binding
or appears only inside a nested binder or quote. This includes names local
to `fn`, `case`, `for`, `receive`, `rescue`, nested `with`,
`match?`, matches and `destructure`. The compiler resolves dependencies
in guards, pins and binary sizes for kept swaps. Unexpanded macros can
hide reads and bindings.
An `else` arm does not affect validation. Even if it ignores the failure
value, swapping the clauses can run side effects or raise an exception
that the original order avoided.

## Self-mutation

The repository tests mutation runs against the mutator registry, scope
resolver, and JSON reporter. The harness copies those modules under a
separate namespace in a temporary Mix project and runs `mix mutagen`
from a fresh shell. Run it with `mix test --include self_mutation`.
[Self-mutation test](test/integration/self_mutation_test.exs).

## Install

`mutagen_ex` is a development-time Mix task. It requires Elixir 1.18.0
or later and Erlang/OTP 27 or later. To install it as a dependency, add it to your `mix.exs`.

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

Build the archive on the oldest OTP release that will run it. An older
VM can reject BEAM files from a newer OTP release before Mutagen starts.

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
Mix may print dependency discovery output before the task runs.

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
Cases retain their declared `async` value. With `max_cases: 1`, ExUnit
runs cases serially in its usual async-then-sync order.
Whole-file targets honor helper includes and excludes. An explicit tag or
line target takes precedence when narrowing the test set. A coverage or
baseline pass that executes no tests aborts with `no_tests_run`. Helper
formatters run on every pass. A formatter that writes a file may overwrite
it after each mutant. Mutagen writes the final report before running
ExUnit `after_suite` callbacks. Each callback gets its own
`--boot-timeout-ms` deadline. Cleanup errors and timeouts go to stderr.
A callback that calls `System.halt/1` decides the VM exit code.

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

`--json PATH` is the guaranteed report channel. The file contains exactly
one JSON document, or NDJSON with `--stream`, regardless of host output.

Without `--json`, Mutagen writes the report to stdout and routes the
`:user` device and known console logger handlers to stderr. The VM can
write directly to file descriptor 1, including when an OTP logger
handler crashes. In-process I/O routing cannot intercept those writes.
Mutagen prints a reminder on stderr when it writes to stdout. Use
`--json PATH` and `--summary PATH` in CI.

Mutagen writes the file with mode 0600. If it cannot safely write the
file, it warns on stderr and falls back to stdout.


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
3. Enumerates mutation sites from each in-scope file's AST. It uses line
   coverage first and probes remaining runtime sites before reporting
   them as unexecuted.
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

A survivor means “the tests you selected miss it”. First rerun with a
wider `--tests` selection before writing a test.

## Reading the summary

Add `--summary mutagen.md` for a Markdown file you can read or paste into a
pull request. The JSON always includes the same findings under `summary`.
Both output paths use the project-root boundary by default.

The headline leads with the highest-priority finding. `summary.checked`
reports `full` or `partial` along with the total sites, uncovered sites,
and sites left unevaluated for other reasons. A partial run states how
many sites it could not check. When it has no finding, the headline
says “Mutagen found nothing in the sites it could check.”

- **Check first** groups findings by function. `not_executed` means none
  of its in-scope sites recorded a hit during an execution probe.
  Mutagen uses line coverage first. For the remaining sites, it installs
  counters in the original runtime expressions, runs the admitted tests
  once, and restores the original bytecode. A probe hit adds the site to
  the mutation queue. Captures, interpolation, bitstring segments,
  map-update values, keyword arguments, function-head patterns, guards,
  and `cond` heads can prevent probe placement. Such sites, compile
  failures, and failed probe runs yield `could_not_tell`. An empty test
  selection also leaves execution unknown and has its own note.
  Results report their execution evidence in `execution`, and
  `meta.timings_ms.probe` records the probe phase when it runs.
  `nothing_asserted` means the tests that ran let every evaluated mutant
  in the function survive, including at least three high-confidence
  mutants without a recorded escalation shortfall. If a dropped test file
  mentions the function and fails alone on the unmutated code, the summary
  leads with the failed test file.
  A file that fails in combination appears in the notes.
- **Worth a look** in a changed-code run lists survivors whose spans
  overlap changed lines. Within each confidence group, entries sort by
  file and line. On-line `with_swap` and `guard_drop` survivors follow the
  high-confidence entries and carry a low-confidence label. Pipeline
  survivors and survivors away from changed lines stay in the JSON. The
  notes count them.
- Classic and audit runs keep the provisional
  [precision order](docs/precision/blind-2026-11.csv). They list
  high-confidence survivors outside Check first, followed by those marked
  `not fully escalated`. Low-confidence survivors stay in the JSON.
  Change the default five Worth a look entries with `--summary-max N`.
- Timeouts count as unevaluated because the tests did not finish. The
  summary kill rate uses killed and surviving
  sites. Notes count results after a timeout or host state change. They
  list skipped escalation files and explain when a kill followed a file
  that had already loaded before Mutagen dropped it.
  When three or more mutants time out and the waits take over half the
  mutation phase, the summary points to `--timeout-ms` and `--budget-ms`.

Copy the printed `MIX_ENV=test mix mutagen --site …` command from the
summary to rerun the one site with `--tests auto --escalate` and up to 40
test files per function in each pass. The escalation cap is the larger
of 30 seconds and ten times the narrow baseline. A smaller configured
budget still applies. The summary says when escalation admitted no files.
Changed-code reruns keep the merge base from the report. Run
the command from the same project checkout. Broader tests can kill a site
that previously survived. With `--no-source`, the summary omits file names,
function names and excerpts and prints an opaque reference for the rerun.

## Running in CI

Mutagen is advisory. Each run reports the current checkout and uses no
repository state from previous runs. A shallow checkout aborts because the
diff needs the merge base. Use `fetch-depth: 0`. The unmapped list names
changed lines Mutagen could not map to a runtime site, such as attributes
and macros. A separate list shows changed lines outside an explicit
`--scope`. The summary names changed lines that tests missed inside
evaluated sites and reports partial coverage. Use `--json PATH` and
`--summary PATH` in CI. Upload the JSON file and keep stderr out of
artifacts.

```yaml
name: Mutation advice
on: pull_request

jobs:
  mutagen:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: erlef/setup-beam@54075bcc5e249e4758d363f27d099f55d843f124 # v1.24.1
        with:
          version-file: .tool-versions
          version-type: strict
      - name: Collect mutation advice
        continue-on-error: true
        env:
          MUTAGEN_BASE: ${{ github.event.pull_request.base.sha }}
        run: |
          MIX_ENV="test" mix deps.get
          MIX_ENV=test mix mutagen --since "$MUTAGEN_BASE" --json mutagen.json --summary mutagen.md
      - name: Add advice to the job summary
        if: always()
        run: |
          if [ -f mutagen.md ]; then
            cat mutagen.md >> "$GITHUB_STEP_SUMMARY"
          fi
      - uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        if: always()
        with:
          name: mutagen
          path: mutagen.json
```

A successful tool run exits 0 even when tests miss mutations. The
`continue-on-error` setting also allows the job to proceed after a tool
abort. The job summary includes the abort reason and its hint. To post the Markdown on a same-repository pull request, grant
`pull-requests: write` to the job and set `GH_TOKEN` and `PR_NUMBER` for an
optional step. Run `gh pr comment "$PR_NUMBER" --body-file mutagen.md`
when the file exists.

This repository runs its normal tests and host fixtures in CI. Mutagen
refuses a changed-code run on its own runtime modules.

Set `--timeout-ms` for scopes whose
tests finish quickly. A runaway mutant can consume the full timeout. Set
`--budget-ms` to stop dispatching new mutants once the mutation phase
has used its budget. Use `meta.timings_ms` to size both limits on your CI
runner. Dividing mutation time by the number of attempted sites gives
the average cost per mutant.

## Flags

| Flag | Purpose |
|---|---|
| `--summary <path>` | Write a Markdown summary to a separate file. As with `--json`, the path must stay within the project root unless `--unsafe-json-outside-project` is set. |
| `--summary-max <int>` | Maximum entries in Worth a look. Default 5. Zero keeps only the omitted count. |
| `--site <id>` | Rerun one site using the report ID or opaque reference. |
| `--scope <target>` | What to mutate. A `.ex` file path, a module name, or `Module.fun/arity`. Required unless you use `--since` or `--site`. Repeatable up to 100 occurrences. |
| `--tests <target>` | A `_test.exs` path, a `file:line` pair, or `tag:<name>`. Repeatable up to 100 times. Use `auto` on its own. Required unless you use `--since` or `--site`. |
| `--boot-timeout-ms <int>` | Deadline in milliseconds for startup after compilation. Default `300000`. |
| `--no-source` | Omit source excerpts, excerpt lines, file and function fields from mutation results and compile errors, including stream entries. |
| `--include-host-output` | Include captured compiler and test stderr and abort messages, with best-effort redaction. |
| `--no-test-alias` | Skip entries in the host's test alias before the test task. |
| `--no-host-app` | Load runtime configuration and the helper without starting the host application. |
| `--since <ref>` | Plan changed runtime sites from the merge base. Defaults to `--tests auto`. |
| `--escalate` | Widen automatic test selection for surviving or uncovered sites. Off by default. |
| `--no-escalate` | Accepted with no effect for one release. |
| `--escalate-max-files <int>` | Maximum test files per function in each extra pass. Default `20`. |
| `--escalate-budget-ms <int>` | Total time for the extra passes. Default `120000`. Zero removes the limit for runs without `--site`. A single-site run caps the budget at the larger of 30 seconds and ten times the narrow baseline. |
| `--timeout-ms <int>` | Override the per-mutant deadline in milliseconds. The default uses three times the baseline duration with a 5000 ms floor. Mutagen warns if a requested timeout is shorter than the baseline. |
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
coverage. Every report records `meta.max_concurrency`. Values above 1
emit a stderr warning and add "Verdicts are unreliable in experimental
parallel mode." to the report's top-level `warnings`. The default is 1.

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
{"version":"2","kind":"end","meta":{"id_scheme":"2",...},"aborted":false,"abort_reason":null,"truncated":false,"kill_rate":0.81,...}
```

Per-site lines (`"result"` / `"compile_error"`) arrive in **input
order** even under `--max-concurrency > 1`, because the runner
collects via `async_stream`'s `:ordered: true` default and the
streaming callback fires from a sequential post-fold. The final line
on the sink is the aggregate document without a `kind` field. Timings
appear only in that document. The `end` line includes `truncated`.

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
| `0` | Mutagen wrote its report. This includes incomplete runs and runs where every mutation survived. |
| `2` | Mutagen aborted and wrote an error document to the selected destination. The string field `abort_reason` names the failure, for example `"missing_scope"` or `"baseline_red"`. |

A host callback that calls `System.halt/1` decides the VM exit code.
An `after_suite` callback can therefore leave a completed report with
`aborted: false` and a non-zero exit.

### Abort reasons

| `abort_reason` | Meaning |
|---|---|
| `arity_required` | The function scope omits its arity. |
| `baseline_red` | One or more tests failed against the original code. |
| `baseline_timeout` | The baseline phase exceeded its deadline. |
| `colon_syntax_unsupported` | A function scope uses colon syntax. |
| `cover_already_running` | An existing OTP coverage session owns modules. |
| `cover_compile_failed` | OTP coverage could not instrument a selected module. |
| `cover_module_unavailable` | The OTP coverage module failed to load. |
| `coverage_timeout` | The coverage phase exceeded its deadline. |
| `diff_unavailable` | Git cannot provide a usable diff for the changed-code run. |
| `escalation_crashed` | An unexpected exception ended automatic test discovery. |
| `ex_unit_run_failed` | ExUnit raised, threw, or exited while running a suite. |
| `file_not_found` | A selected source or test file does not exist. |
| `file_read_failed` | Mutagen could not read a required file. |
| `flag_not_supported_in_v1` | An option requests an unsupported output format. |
| `function_not_found` | The scoped function and arity could not be found. |
| `host_app_start_failed` | The host application failed to start. |
| `host_compile_failed` | Mix failed to compile the host project. |
| `host_loadpaths_failed` | Mix failed to load the host project dependencies. |
| `host_setup_timeout` | Host setup exceeded its deadline. |
| `invalid_boot_timeout` | The host setup and cleanup timeout is invalid. |
| `invalid_budget_ms` | The mutation phase time budget is invalid. |
| `invalid_input` | An argument or runner input is malformed. |
| `invalid_line` | The test location has an invalid line number. |
| `invalid_max_concurrency` | The mutation dispatch limit is invalid. |
| `invalid_max_sites` | The mutation site cap is invalid. |
| `invalid_mix_env` | The command selected an unsupported Mix environment. |
| `invalid_redact_config` | The configured report redaction patterns are invalid. |
| `invalid_seed` | The ExUnit seed is invalid. |
| `invalid_site` | The site selector has an invalid format. |
| `invalid_since_ref` | `--since` has an invalid Git ref. |
| `invalid_summary_max` | The summary limit must be a non-negative integer. |
| `invalid_tag_name` | The test tag contains unsupported characters or has an invalid length. |
| `invalid_target` | The test selector has an unsupported format. |
| `invalid_timeout` | The per-site timeout is invalid. |
| `missing_scope` | No mutation scope was supplied. |
| `missing_tests` | No test selection was supplied. |
| `module_beam_missing` | The compiled module could not be located. |
| `module_not_found` | The scope module could not be resolved. |
| `no_tests_match` | A test selector matched no files. |
| `no_tests_run` | ExUnit executed no tests in coverage or baseline. |
| `parse_error` | Mutagen could not parse a source or test file. |
| `runtime_load_failed` | The MutagenEx runtime or a report module could not load. |
| `self_mutation_refused` | The scope targets MutagenEx code in the active VM. |
| `site_not_found` | The site ID is absent from the current selection. |
| `summary_path_conflict` | The JSON and Markdown paths resolve to the same file. |
| `summary_write_failed` | Mutagen could not write the Markdown file. |
| `test_alias_failed` | A host test alias setup step failed. |
| `test_file_load_failed` | A cited test file could not be loaded or matched to its compiled path. |
| `test_helper_load_failed` | A required test helper could not load. |
| `too_many_sites` | The scope yielded more sites than the configured cap. |
| `too_many_targets` | The command exceeds the scope or test target limit. |
| `umbrella_root` | The command ran from an umbrella root. |
| `unknown_flag` | The command contains an unrecognised option. |
| `unrecognised_target` | The scope target has an unsupported format. |
| `unrecoverable_restore_failure` | Mutagen could not restore the original module. |
| `unsafe_json_path` | The report path failed validation. |
| `unsafe_summary_path` | The Markdown path failed validation. |
| `unsupported_elixir_version` | The Elixir release is below 1.18.0. |
| `unsupported_otp_version` | The Erlang/OTP release is below 27. |

## JSON output

The aggregate and the stream end record include `summary`. The examples
below show the existing pipeline fields. See [Reading the summary](#reading-the-summary)
for the ranked findings and the per-function counts.

The aggregate JSON document goes to stdout or the file named by
`--json <path>` and ends with a newline. With `--stream`, it follows
the [per-site events](#ndjson-streaming---stream).

`meta.timings_ms` measures elapsed milliseconds for boot, coverage,
baseline and mutation. The total also includes work between phases such
as enumeration, through report assembly. A phase that did not run shows
zero. `meta.timings_ms.mutant_deadline` records the effective per-mutant
deadline in milliseconds. Escalation records the baseline duration and
deadline for each pass that runs mutants. Captured host output can contain
timestamps, process identifiers, and references.

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
    "max_concurrency": 1,
    "otp_version": "28",
    "timings_ms": {
      "baseline": 2,
      "boot": 93,
      "coverage": 49,
      "mutation": 98,
      "total": 266
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
        "warnings": []
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
        "warnings": []
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
        "warnings": []
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
        "warnings": []
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
        "warnings": []
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
        "warnings": []
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
        "warnings": []
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
does not exist, `aborted` is `true` and the phase blocks that never ran are
`null`. The default `details` contains a fixed hint and any available
structured facts. The exit code is non-zero. The reason strings are
listed in the [abort reason table](#abort-reasons).

```json
{
  "abort_reason": "module_not_found",
  "aborted": true,
  "baseline": null,
  "coverage": null,
  "details": {
    "hint": "Check the module name and that its source compiles.",
    "module": "Elixir.LaneFixture.Missing",
    "note": "Stderr may carry unredacted host output. Do not publish it as a CI artifact.",
    "step": "scope"
  },
  "meta": {
    "elixir_version": "1.19.6",
    "exunit_seed": 0,
    "fail_fast": true,
    "id_scheme": "2",
    "max_concurrency": 1,
    "otp_version": "28",
    "timings_ms": {
      "baseline": 0,
      "boot": 62,
      "coverage": 0,
      "mutation": 0,
      "total": 72
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
so baseline sees the cited modules in the registry and reports real failures. The production-condition
regression test for this lives in
`test/mutagen_ex/baseline_red_guard_test.exs` (it drives the real
`ExUnit.Server`, not a fake), with end-to-end coverage in
`test/mutagen_ex/end_to_end_test.exs` (`:baseline_red_scenario`).

> Earlier releases documented this as a limitation (the guard "did not
> trip"). That was fixed by the re-registration above; the manual
> `mix test`-first workaround the old docs suggested is no longer
> required.

## Known limitations

- A `:case_drop` mutation can remove the only base case of a guarded
  recursive function. If the remaining guard rejects the base value,
  the BEAM raises `CaseClauseError`. The report classifies the site
  as `killed`.
- Mutagen reaps timed-out work spawned by the site runner. Work a test
  starts through a host-owned supervisor, such as
  `Task.Supervisor.async_nolink/2` or `DynamicSupervisor.start_child/2`,
  can outlive the timeout. The host supervisor owns those children.
- Macros can expand differently when a probe wraps an argument whose AST
  they pattern-match. The expansion can discard the counter, and a test
  with weak assertions can pass despite the changed behavior. Mutagen may
  then report a site as unexecuted even though the original suite ran it.
- Probes, coverage, and mutation runs only observe work during the suite
  in the local node with the current module version. Code running on
  another node, after the suite ends, or in a process still using old
  code escapes those checks.

### Changed-code planning

Planning compares changed lines and the enclosing group's source
fingerprint. An edit to a module attribute such as `@limit`, a
`defguard`, a `defmacro`, a `defdelegate` target, `alias`, `import`,
`use` options, or `defstruct` defaults can change runtime behavior and
still plan zero runtime sites. Callers of a changed private helper
keep their own fingerprints. For a deletion hunk, Mutagen considers
the remaining lines next to the deletion. A deletion can plan zero sites
when neither neighbor touches a runtime site.

Runtime classification uses syntax. A named `def` or `defp` outside
`quote` qualifies even if only compile-time code calls it. An expression
inside `unquote` still falls outside the runtime plan when it sits
inside `quote`, even if a runtime call evaluates the expression.

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

No third-party dependencies. Requires Elixir 1.18.0 or later for ExUnit
case registration and Erlang/OTP 27 or later for JSON and trace sessions.

### Test suites

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
