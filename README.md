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
| `--scope <target>` | What to mutate. A `.ex` file path, a module name, or `Module.fun/arity`. Required. Repeatable; each occurrence accumulates. |
| `--tests <target>` | Which tests judge the mutations. A `_test.exs` path, a `file:line` pair, or `tag:<name>`. Required. Repeatable. |
| `--timeout-ms <int>` | Wall-clock budget per mutation run. Default `5000`. Must be positive. |
| `--seed <int>` | ExUnit seed, propagated to every test-running phase. Default `0`. Controls test ordering only, not mutation enumeration order. |
| `--json <path>` | Write the final JSON document to `<path>` instead of stdout. The document always ends with a single newline. |

The flag surface above is exhaustive for v0.1.0. `mix mutagen --no-json`
and `mix mutagen --scope file.ex:Module` are both **explicitly rejected**
in v0.1.0 — see Known limitations.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Pipeline ran to completion. This includes a run where every mutation survived — kill rate of 0.0 is a valid result, not a failure. |
| non-zero | "Bad input" or unrecoverable error. Every non-zero exit also writes an error-JSON document to stdout (or `--json <path>`). The `reason` field names the abort: `:missing_scope`, `:invalid_timeout`, `:no_tests_match`, `:baseline_red`, `:self_mutation_refused`, `:flag_not_supported_in_v1`, etc. |

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

These are real production gaps in v0.1.0. Each has an open follow-up
ticket; the v0.1.0 cut ships the surface and the contract, not the fix.

1. **File-cited `--tests` selects zero tests.**
   `--tests test/foo_test.exs` (or any test-file path) currently produces
   a filter that excludes every test, so every mutation lands in the
   `survived` bucket. Tag-cited and `file:line`-cited tests are not
   affected. Workaround: use `--tests tag:<name>` until fixed.
   *(mutagen-wrd.11)*

2. **The production mix task does not populate ExUnit modules for the
   mutation phase.** Even when test selection is correct, the mix task
   wires the mutation runner with an empty `test_modules` list, so
   `ExUnit.run/0` reports zero tests during the mutation phase and every
   mutation classifies as `survived`. End-to-end correctness today
   requires the test-side driver fork. *(mutagen-wrd.12)*

3. **`:case_drop` on a guarded base case classifies `:killed`, not
   `:timeout`.** When the dropped clause is the only non-recursing
   branch, the surviving recursive clause's guard rejects the base value
   and the BEAM raises `CaseClauseError` — the mutator catalog's
   stated `:timeout` outcome does not happen. *(mutagen-wrd.14)*

4. **The `literal` mutator never fires.** The AST cache parses with
   `token_metadata: true`, which wraps atomic literals in
   `{:__block__, _, [value]}` tuples. `Literal.match?/1` only matches
   bare literals, so the mutator skips every candidate site. The other
   mutators (`compare`, `boolean`, `case_drop`, `else_removal`,
   `withblock_*`) are unaffected. *(mutagen-wrd.15)*

In all four cases the JSON document is well-formed and the contract is
honoured; the gap is in upstream classification fidelity, not in the
output schema.

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
