---
id: mutagen.decision.ancora_migration
status: accepted
date: 2026-11-19
supersedes: mutagen.decision.adopt_specled_tooling
affects:
  - mutagen.ast
  - mutagen.cli
  - mutagen.coverage
  - mutagen.json_schema
  - mutagen.mutation_enumeration
  - mutagen.mutation_pipeline
  - mutagen.mutators
  - mutagen.scope_resolution
  - mutagen.test_selection
---

# Derive spec bindings with Ancora

## Context

SpecLedEx is retired. Its executable verification entries named whole
suites, and the tag scanner was disabled. A green command could count as
proof for a requirement without an assertion for that requirement.

## Decision

Use Hex Ancora `~> 1.3` in dev and test with `runtime: false`. Keep the
package file list and the dependency-free Mix archive. CI checks the corpus
and the diff in a full clone. Pull requests use the target branch ref.
Pushes use the event's previous SHA. A new branch push uses the remote
default branch. Local checks default to `origin/main`.

### Prior decision clauses

| Clause in the previous decision | Disposition |
| --- | --- |
| Make machine checks required in dev and test | Retain the local gate and add it to CI. |
| Given/when/then arrays and active status | Retain both. |
| Command targets and execution flags | Remove all 66 command entries. Literal requirement tags link ExUnit proof. ExUnit runs independently. |
| Hand-authored API boundaries and deferred deeper tiers | Remove the nine API boundary lists. Ancora derives production calls from tagged tests. There are no deferred binding tiers or generated state. |
| Keep existing decisions | Retain all decisions. Record this replacement in the old decision's frontmatter and append historical clarifications where the old branch guard is discussed. |
| Start with soft severities | Use Ancora's defaults except for any exact exceptions recorded below. Preserve append-only enforcement and check new requirements for tags. |
| Keep falsifiable, repo-resident behavioral specs | Retain every requirement and scenario. Expand the golden fixture directory to exact files. |

The former `overlap/duplicate_covers: off` allowed several scenarios to
cover different parts of a requirement. Ancora accepts those scenarios and
only checks identical verification cover lists under that code. The former
`branch_guard_unmapped_change: off` kept README edits from failing the
gate. Ancora's `change/uncovered_file` is scoped to library files, so the
README needs no exception. Keep both current checks enabled. The old
scenario-regression, untested-realization, and underspecified-realization
settings have no direct successors. Ancora checks test tags by default and
treats an existing untagged requirement as informational. New untagged
requirements fail the diff gate.

## Consequences

`mix spec.validate --strict` and `mix spec.check` inspect source and git.
Run the ExUnit and integration suites to execute the proof. No state file
or compile tracer is needed.

### Proof accounting

The previous corpus named all 100 requirements in command entries. Enabled
entries named 99. Only `mutagen.cli.r8` appeared solely under
`execute: false`, and the base already had parser and runner assertions
for it. The old gate ran suites and did not check assertion-level
coverage. The base had zero literal requirement tags.

Ancora now has anchored ExUnit assertions for 96 of 100 requirements.
The migration carried forward existing evidence for 86 and added or
strengthened proof for ten:

- CLI r2 now asserts that missing `--tests` produces a non-zero code and a
  decoded error document. CLI r4 and pipeline r2 now assert that the
  mutation phase sets the caller's seed and `max_cases: 1`.
- CLI r5 now checks both output destinations and the terminal newline in
  the archive integration test. The parse tests anchor the requirement.
- CLI r13 and schema r13 have a new assertion for the budget and its wire
  shape. CLI r13 already had parser and runner evidence.
- Schema r12 now counts the rendering calls for the fallback and slice
  paths in a process-scoped trace. The old test checked the emitted bytes
  and shared reference.
- Pipeline r13 now asserts that the app supervisor has one child and the
  running mutation task belongs to that child.
- Mutators r6 now checks a validated round trip for each catalog entry.
- Scope resolution r6 and test selection r4 now exercise real input files
  that fail if the production resolver evaluates them.

CLI r13 had substantial evidence in the base. Its count is in the 86
carried-forward requirements. The new wire assertion is counted under
schema r13.

Four enabled legacy claims have no tagged proof. Each remains in the corpus:

| Requirement | Evidence and gap |
| --- | --- |
| `mutagen.ast.r4` | An ExUnit source scan replaces the negative grep, with a nonempty file set and whole helper names. This checks private duplicates. The donor call sites use different AST helpers and the negative check does not prove the delegation clause. The scan has no production call to anchor. |
| `mutagen.cli.r9` | ExUnit checks the Mix task docs for the named sections and caveats. The old `mix help mutagen` checked exit status. Help uses Mix's documentation lookup, outside a direct call to the Mutagen task. |
| `mutagen.coverage.r7` | The base spike exercises OTP cover and compilation directly. The existing runner test compares disk contents with injected collaborators. There is no combined test of real coverage, AST loading, and attributable temp writes. |
| `mutagen.mutation_pipeline.r4` | The production timeout tests cover escalation, purge and taint. The graceful-cancel test expects `:survived` when the task returns a clean result during shutdown. The requirement says both cancellation paths classify as `:timeout`. Resolve that discrepancy in a behavior change. |

CLI r14 and r16 retain their fresh-shell integration tests. The tags
are on in-process tests of the preamble and repair branches. The two C1/C2
spikes remain architectural evidence. Tagged coverage, baseline and
runner tests exercise the corresponding production paths. Disposable
projects and subprocess calls stay in ExUnit even when Ancora cannot
derive their calls.

### Diff findings

The base had no tagged tests. Primary growth in AST, CLI, coverage,
enumeration, pipeline, mutators, scope resolution, and test selection
records the first observations of existing functions. Each subject has
one temporary `derived/growth: info` override with its reason. Remove these
overrides once the comparison base contains this tagged suite. Keep the
default warning for future test-call additions. A commit trailer would
disappear on squash merge.

The base JSON schema subject used a directory in its owned paths and
Ancora rejected that subject on the base side. Expanding the list to 18
exact fixture paths restores it. Ancora reports its first bindings at
info as acknowledgment of the newly parseable subject. Transitive growth
in the CLI, coverage, JSON schema, enumeration, pipeline and mutator
subjects comes from tagged tests that call the neighboring production
modules needed to assert the behavior. There is no library diff, and no
drift, shrink, or uncovered library file was reported. Borrowed-tag info
records the first tags on existing rules. Unresolved-call info comes
from test seams such as `apply/3` and variable-module dispatch.
