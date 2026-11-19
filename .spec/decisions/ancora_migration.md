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
and the diff in a full clone, using the pinned toolchain and a cache keyed
by the tool versions and lock. Pull requests use the first parent of the
checked-out test merge. Pushes use the event's previous SHA when available,
and otherwise the merge base with the remote default branch. An explicit
`--base` compares against the supplied commit. Local checks without it
default to `origin/main` as the target.

### Prior decision clauses

| Clause in the previous decision | Disposition |
| --- | --- |
| Make machine checks required in dev and test | Retain the local gate and add it to CI. |
| Keep required tooling in the agent guide | The guide names Ancora and its validation and diff checks. |
| Given/when/then arrays and active status | Retain both. |
| Command targets and execution flags | Remove all 66 command entries. Literal requirement tags link ExUnit proof. ExUnit runs independently. |
| Hand-authored API boundaries and deferred deeper tiers | Remove the nine API boundary lists. Ancora derives production calls from tagged tests. There are no deferred binding tiers or generated state. |
| Keep the optional `mix spec.cover.test` instrumentation unused | Remove it along with the retired tooling. Ancora scans source and ExUnit runs the proof separately. |
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

Ancora now has tagged ExUnit assertions for 98 of 100 requirements.
Most tags bind production calls. AST r4 tags the ExUnit source scan
replacing the retired private-helper grep. CLI r9 tags the documentation
assertions for the required help sections and caveats. The migration
added or strengthened evidence for the following requirements:

- CLI r2 now asserts that missing `--tests` produces a non-zero code and a
  decoded error document. CLI r4 and pipeline r2 now assert that the
  mutation phase sets the caller's seed and `max_cases: 1`.
- CLI r5 now checks both output destinations and the terminal newline.
  The tagged archive integration exercises the full command. The focused
  test invokes `DefaultIo.emit/3` in an isolated VM because the sink calls
  `System.halt/1`.
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

Two enabled legacy claims have no tagged proof. Both remain in the corpus.
Each has a requirement-specific `spec/requirement_unverified: info`
override with its reason. Ancora still reports the gap.

| Requirement | Evidence and gap |
| --- | --- |
| `mutagen.coverage.r7` | The base spike exercises OTP cover and compilation directly. The existing runner test compares disk contents with injected collaborators. There is no combined test of real coverage, AST loading, and attributable temp writes. |
| `mutagen.mutation_pipeline.r4` | Open defect. After `Task.yield/2` times out, the grace-window code accepts a clean reply and the escalation path can accept a reply racing `terminate_child/2`. The requirement and timeout decision call for `:timeout` on both cancellation paths. The graceful-cancel test currently asserts `:survived` even though its name describes a timeout. |

R4's late reply can produce a `:survived` or `:killed` result after the
deadline. It undercounts timeouts and can inflate the kill rate. It also
skips the purge step and leaves subsequent results without the required
taint marker. The supervision decision describes a grace window to drain
replies sent before the deadline. This migration leaves the defect and
its existing tests for a separate behavior change.
[Timeout handling](timeout_handling.md), [supervision tree](supervision_tree.md)

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
one temporary `derived/growth: info` override with its reason. On 2026-11-19
we scheduled removal in the first commit after the migration lands on
the target branch. Keep the default warning for future test-call additions.
A commit trailer would
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

### Library-file probe

Appending a comment to each of the 56 tracked library files in a scratch
clone originally produced 36 uncovered-file warnings. Direct proof now
reaches 16 more files. JSON path and sink tests cover output and path rules.
The mutator properties name each callback they execute. The progress,
test-module discovery, bytecode, coverage and baseline tests reach their
production modules and wrappers.

The remaining 20 files have exact `change/uncovered_file: info`
exceptions. Seventeen declare behaviour callbacks. `application.ex` is
entered through OTP app boot. `config.ex` builds a struct at compile time
and `types.ex` declares typespecs. Ancora computes file coverage from
source-defined calls. These exceptions keep the findings visible while
the concrete modules and observed calls keep their normal checks.
The repeat probe changed all 56 library files and passed with zero
unexcepted uncovered files and 20 informational exceptions.

### Growth cutover complete

The first post-merge commit removes the eight import-only growth overrides.
The tagged suite is now present on the target branch. New primary bindings
use Ancora's default warning.
