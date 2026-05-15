# mutagen.mutation_enumeration — site enumeration with skip tracking

Walks the in-scope ASTs and produces an ordered list of `%MutationSite{}`
records. Each record names a file, an AST hash, a mutator, line/column
metadata for human display, and the swapped AST ready for compile.

## Intent

The pipeline needs a deterministic, predictable list of sites to feed the
mutation runner. Determinism comes from the inputs alone — same `{ast_cache,
scope_records, covered_lines}` produces the same `[%MutationSite{}]` including
order. Mutators that `validate/1`-reject become entries in a parallel
`mutation.skipped[]` list rather than empty slots in the main list.

## Out of scope for this subject

- Catalog of mutators (see [mutagen.mutators](mutators.spec.md)).
- Running the mutation (see [mutagen.mutation_pipeline](mutation_pipeline.spec.md)).
- Coverage attribution (see [mutagen.coverage](coverage.spec.md)) — this
  subject only consumes the `covered_lines` set.

```spec-meta
id: mutagen.mutation_enumeration
kind: module
status: draft
summary: Deterministic mutation-site enumeration with validate-aware skip tracking.
surface:
  - lib/mutagen_ex/mutation_enumerator.ex
decisions:
  - mutagen.decision.validate_predicates
```

```spec-requirements
- id: mutagen.mutation_enumeration.r1
  priority: must
  statement: |
    Given a fixed input tuple `{ast_cache, scope_records, covered_lines}`,
    the enumerator produces a `[%MutationSite{}]` list that is byte-identical
    across runs of the same Elixir/OTP version. Order is fixed and is part
    of the contract.

- id: mutagen.mutation_enumeration.r2
  priority: must
  statement: |
    Sites whose AST line is outside `covered_lines` are filtered out before
    `validate/1` is consulted. The enumerator does not produce mutation
    sites for code the cited tests do not execute.

- id: mutagen.mutation_enumeration.r3
  priority: must
  statement: |
    For each site where a mutator's `validate/1` returns `{:skip, reason}`,
    the enumerator emits an entry in a parallel `skipped` list with `{site_id,
    reason}`. The `mutation.total` field in the JSON output reflects only the
    non-skipped sites; the skipped list lives at `mutation.skipped` per the
    JSON schema.

- id: mutagen.mutation_enumeration.r4
  priority: must
  statement: |
    For multi-`defmodule` files, enumeration only walks the in-scope module's
    AST sub-tree. Sibling modules' nodes never appear as candidate sites.

- id: mutagen.mutation_enumeration.r5
  priority: must
  statement: |
    A scoped module with no qualifying AST nodes (e.g., a behaviour-only
    module containing only `@callback` declarations) returns an empty
    `[%MutationSite{}]` list plus a warning naming the module. The warning
    surfaces in the JSON's top-level `warnings` array.

- id: mutagen.mutation_enumeration.r6
  priority: must
  statement: |
    Enumeration reads ASTs exclusively from the AST cache (see
    [mutagen.coverage](coverage.spec.md)). It never opens a source file for
    re-read. This is the property that lets state-drift-free restore work:
    the same AST that was enumerated is the AST that gets compiled back at
    restore time.

- id: mutagen.mutation_enumeration.r7
  priority: must
  statement: |
    `MutagenEx.MutationEnumerator.enumerate/4` accepts an opts keyword
    `:max_sites` carrying a positive integer cap. When the produced
    site list would exceed the cap, the enumerator returns
    `{:error, :too_many_sites, %{cap: <n>, count: <m>, message:
    <string>}}` instead of the success-shape map. The cap is structural
    — the pipeline aborts before the mutation runner starts.

    Absence of the option (or `nil`) leaves enumeration unbounded.
    Callers that want the cap MUST pass it; the Mix task threads
    `Config.max_sites` (default 10_000) in. See `mutagen.cli.r12`.
```

```spec-scenarios
- id: mutagen.mutation_enumeration.s1
  covers: [mutagen.mutation_enumeration.r1]
  given: |
    The same `{ast_cache, scope_records, covered_lines}` tuple supplied to
    the enumerator on two consecutive invocations.
  when: Both invocations complete.
  then: |
    The two output `[%MutationSite{}]` lists are equal — same length, same
    order, same site IDs.

- id: mutagen.mutation_enumeration.s2
  covers: [mutagen.mutation_enumeration.r2]
  given: |
    `lib/foo.ex` with arithmetic operations on lines 5, 10, and 15.
    `covered_lines` for `lib/foo.ex` is `MapSet.new([5, 10])` — line 15 was
    not exercised by the cited tests.
  when: The enumerator runs.
  then: |
    The output list contains mutation sites for lines 5 and 10 only. Line
    15 produces no site (covered, skipped, or otherwise).

- id: mutagen.mutation_enumeration.s3
  covers: [mutagen.mutation_enumeration.r3]
  given: |
    An AST containing a `with` chain that, when swapped by `with_swap`,
    would use a bound variable before binding.
  when: The enumerator processes that `with` site.
  then: |
    The site appears in the `skipped` list with reason
    `:bound_var_used_before_binding` and does NOT appear in the main
    `[%MutationSite{}]` list. `mutation.total` is unaffected by this site.

- id: mutagen.mutation_enumeration.s4
  covers: [mutagen.mutation_enumeration.r4]
  given: |
    `lib/multi.ex` defines `Mod.A` and `Mod.B`. The scope record targets
    only `Mod.A`.
  when: The enumerator runs.
  then: |
    Every emitted site's AST hash belongs to a node inside `Mod.A`'s
    `defmodule` block; no site has a hash from `Mod.B`'s AST.

- id: mutagen.mutation_enumeration.s5
  covers: [mutagen.mutation_enumeration.r5]
  given: |
    `lib/contract.ex` is `defmodule Contract do @callback handle(any) ::
    any end`.
  when: The enumerator is run with `Contract` as scope.
  then: |
    Output is `{[], [warning: :no_mutation_candidates, module: Contract]}`.

- id: mutagen.mutation_enumeration.s6
  covers: [mutagen.mutation_enumeration.r6]
  given: |
    The enumerator finishes producing sites.
  when: Inspecting its run.
  then: |
    No call to `File.read/1`, `File.read!/1`, or `Code.require_file/1` was
    made during enumeration; all AST data came from the cache.

- id: mutagen.mutation_enumeration.s7
  covers: [mutagen.mutation_enumeration.r7]
  given: |
    Inputs that would produce more than `:max_sites` mutation sites
    (e.g. 20 arithmetic operations covered, `:max_sites = 5`).
  when: The enumerator runs.
  then: |
    Output is `{:error, :too_many_sites, %{cap: 5, count: <n>, ...}}`
    where `<n>` > 5. No partial site list is returned.
```

```spec-verification
- id: mutagen.mutation_enumeration.v1
  covers: [mutagen.mutation_enumeration.r1, mutagen.mutation_enumeration.r4, mutagen.mutation_enumeration.r5]
  kind: command
  command: mix test test/mutagen_ex/mutation_enumerator_test.exs
  execute: true

- id: mutagen.mutation_enumeration.v2
  covers: [mutagen.mutation_enumeration.r1]
  kind: command
  command: mix test test/mutagen_ex/mutation_enumerator_property_test.exs
  execute: true

- id: mutagen.mutation_enumeration.v3
  covers: [mutagen.mutation_enumeration.r2, mutagen.mutation_enumeration.r3]
  kind: command
  command: mix test test/mutagen_ex/mutation_enumerator_test.exs --only filtering
  execute: true

- id: mutagen.mutation_enumeration.v4
  covers: [mutagen.mutation_enumeration.r7]
  kind: command
  command: mix test test/mutagen_ex/mutation_enumerator_test.exs
  execute: true
```
