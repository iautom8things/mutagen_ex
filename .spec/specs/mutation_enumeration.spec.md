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
status: active
summary: Deterministic mutation-site enumeration with validate-aware skip tracking.
surface:
  - lib/mutagen_ex/mutation_enumerator.ex
  - lib/mutagen_ex/mutators/dispatch.ex
decisions:
  - mutagen.decision.validate_predicates
  - mutagen.decision.static_mutator_dispatch
realized_by:
  api_boundary:
    - "MutagenEx.MutationEnumerator"
    - "MutagenEx.Mutators.Dispatch"
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
    If a `defmodule` is nested inside another `defmodule`, the nested
    module is matched by its fully qualified module name
    (`Outer.Inner`), not by the unqualified inner alias (`Inner`).

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

- id: mutagen.mutation_enumeration.r8
  priority: must
  statement: |
    Every `%MutagenEx.MutationEnumerator.Site{}` carries optional
    `end_line` and `end_column` fields recording an EXCLUSIVE end
    position for the site's `original_ast` against the parsed
    source: `end_line` is the line of the position just past the
    last character of the expression; `end_column` is the column
    on that line. The enumerator derives end positions
    best-effort from AST metadata:

      * If the node's meta carries `:end_of_expression`, that
        position is used (it is already the exclusive end).
      * Else if the node's meta carries `:closing` (parens or
        brackets), end is the closing position plus one column.
      * Else if the node's meta carries `:end` (do/end blocks),
        end is the position just past the literal `end` keyword.
      * Else the enumerator walks to the rightmost child whose
        size can be computed from the AST alone (variables by
        atom name length; bare numeric / atomic literals by their
        printed form's byte size; otherwise recurse).

    When derivation fails, BOTH `end_line` and `end_column` are
    `nil` and the consumer (the JSON renderer's `before_source`
    path, see `mutagen.json_schema.r4`) falls back to
    `Macro.to_string/1`.

- id: mutagen.mutation_enumeration.r9
  priority: must
  statement: |
    Before consulting each catalog mutator's `match?/1` at a given
    AST node, the enumerator MUST pre-filter the mutator list to
    a sub-sequence of the input list using a static, order-
    preserving head-atom dispatch table
    (`MutagenEx.Mutators.Dispatch.mutators_for_node/1`, per
    `mutagen.decision.static_mutator_dispatch`). The pre-filter
    has TWO contractual properties:

      * **Equivalence:** for every AST node and every mutator
        `M` in the input list, `M.match?(node) == true` if and
        only if `M` appears in the pre-filter's output for
        `node` AND `M.match?(node) == true`. Stated as a set:
        the set of mutators that `match?` accepts is identical
        whether the enumerator iterates the full input list or
        only the pre-filtered sub-sequence.

      * **Order-preservation:** the pre-filter never re-orders.
        For any two mutators `A, B` in the pre-filtered output,
        if `A` appears before `B` in the input list then `A`
        appears before `B` in the output. Concretely the
        pre-filter is a sub-sequence (in the strict
        list-as-sequence sense) of the input list — same
        relative order, possibly fewer elements.

    Order-preservation is the property that keeps site emission
    order byte-identical between the pre-dispatch and post-
    dispatch implementations; combined with `r1` it locks
    byte-identity of `mutation.results[].id` order across runs.

    The dispatch behaviour is exercised against `Mutators.all/0`
    (the legacy "iterate every catalog entry" path) via an
    internal `:dispatch_mode` option on `enumerate/4`
    (`:head_atom` is the production default; `:legacy` is the
    test seam used by the equivalence test). The option is NOT
    a public API and is NOT exposed by the Mix task.
```

```spec-scenarios
- id: mutagen.mutation_enumeration.s1
  covers: [mutagen.mutation_enumeration.r1]
  given:
    - The same `{ast_cache, scope_records, covered_lines}` tuple supplied to the enumerator on two consecutive invocations.
  when:
    - Both invocations complete.
  then:
    - The two output `[%MutationSite{}]` lists are equal — same length, same order, same site IDs.

- id: mutagen.mutation_enumeration.s2
  covers: [mutagen.mutation_enumeration.r2]
  given:
    - "`lib/foo.ex` with arithmetic operations on lines 5, 10, and 15."
    - "`covered_lines` for `lib/foo.ex` is `MapSet.new([5, 10])` — line 15 was not exercised by the cited tests."
  when:
    - The enumerator runs.
  then:
    - The output list contains mutation sites for lines 5 and 10 only. Line 15 produces no site (covered, skipped, or otherwise).

- id: mutagen.mutation_enumeration.s3
  covers: [mutagen.mutation_enumeration.r3]
  given:
    - An AST containing a `with` chain that, when swapped by `with_swap`, would use a bound variable before binding.
  when:
    - The enumerator processes that `with` site.
  then:
    - "The site appears in the `skipped` list with reason `:bound_var_used_before_binding` and does NOT appear in the main `[%MutationSite{}]` list. `mutation.total` is unaffected by this site."

- id: mutagen.mutation_enumeration.s4
  covers: [mutagen.mutation_enumeration.r4]
  given: |
    `lib/multi.ex` defines `Mod.A` and `Mod.B`. Another file defines
    `Outer` with nested `defmodule Inner`. The scope record targets only
    `Mod.A` or the fully qualified nested module `Outer.Inner`.
  when: The enumerator runs.
  then: |
    Every emitted site's AST hash belongs to a node inside the targeted
    `defmodule` block; no site has a hash from sibling modules' ASTs, and
    a nested module is not looked up by the unqualified `Inner` name.

- id: mutagen.mutation_enumeration.s5
  covers: [mutagen.mutation_enumeration.r5]
  given:
    - "`lib/contract.ex` is `defmodule Contract do @callback handle(any) :: any end`."
  when:
    - The enumerator is run with `Contract` as scope.
  then:
    - "Output is `{[], [warning: :no_mutation_candidates, module: Contract]}`."

- id: mutagen.mutation_enumeration.s6
  covers: [mutagen.mutation_enumeration.r6]
  given:
    - The enumerator finishes producing sites.
  when:
    - Inspecting its run.
  then:
    - "No call to `File.read/1`, `File.read!/1`, or `Code.require_file/1` was made during enumeration; all AST data came from the cache."

- id: mutagen.mutation_enumeration.s7
  covers: [mutagen.mutation_enumeration.r7]
  given:
    - "Inputs that would produce more than `:max_sites` mutation sites (e.g. 20 arithmetic operations covered, `:max_sites = 5`)."
  when:
    - The enumerator runs.
  then:
    - "Output is `{:error, :too_many_sites, %{cap: 5, count: <n>, ...}}` where `<n>` > 5. No partial site list is returned."

- id: mutagen.mutation_enumeration.s8
  covers: [mutagen.mutation_enumeration.r8]
  given:
    - "The source `def add(a, b), do: a + b` parsed by `Code.string_to_quoted/2` with `columns: true, token_metadata: true` and enumerated against the `arith` mutator."
  when:
    - "The enumerator produces the `:+` site."
  then:
    - "The emitted `%Site{}` has `line: L, column: 24` pointing at the `+` operator (unchanged from the pre-`mutagen-wrd.34` contract) and `end_line: L, end_column: 27` — the exclusive end position of the rightmost descendant `b` at column 26."
    - "The pair `{end_line, end_column}` together with the leftmost descendant's position (derivable from `original_ast`, here `a` at column 22) defines the source range that `Macro.to_string(original_ast)` printed; slicing `source_text` by that range yields exactly `\"a + b\"`."

- id: mutagen.mutation_enumeration.s9
  covers: [mutagen.mutation_enumeration.r9]
  given:
    - "A representative corpus of source fragments exercising every head atom in the dispatch table (`:+`, `:-`, `:*`, `:/`, `:==`, `:!=`, `:<`, `:>`, `:<=`, `:>=`, `:and`, `:or`, `:&&`, `:||`, `:not`, `:!`, `:with`, `:if`, `:case`, `:cond`, `:|>`, `:when`) plus the non-3-tuple shapes the `:any` mutators target (bare `true`/`false`/`0`/`1`/`-1`, `{:__block__, _, [literal]}` wrappers, `{:ok, _}` / `{:error, _}` 2-tuples)."
  when:
    - "The enumerator runs against the corpus once with `dispatch_mode: :head_atom` and once with `dispatch_mode: :legacy`."
  then:
    - "The two `%{sites: _, skipped: _, warnings: _}` maps are equal, including site order."
    - Per-node, the set of mutators whose `match?/1` accepts that node is identical under both paths (correctness), AND the order of the candidate list relative to `Mutators.all/0` is the same (byte-identity).
```

```spec-verification
- id: mutagen.mutation_enumeration.v1
  covers: [mutagen.mutation_enumeration.r1, mutagen.mutation_enumeration.r4, mutagen.mutation_enumeration.r5]
  kind: command
  target: mix test test/mutagen_ex/mutation_enumerator_test.exs
  execute: true

- id: mutagen.mutation_enumeration.v2
  covers: [mutagen.mutation_enumeration.r1]
  kind: command
  target: mix test test/mutagen_ex/mutation_enumerator_property_test.exs
  execute: true

- id: mutagen.mutation_enumeration.v3
  covers: [mutagen.mutation_enumeration.r2, mutagen.mutation_enumeration.r3]
  kind: command
  target: mix test test/mutagen_ex/mutation_enumerator_test.exs --only filtering
  execute: true

- id: mutagen.mutation_enumeration.v4
  covers: [mutagen.mutation_enumeration.r7]
  kind: command
  target: mix test test/mutagen_ex/mutation_enumerator_test.exs
  execute: true

- id: mutagen.mutation_enumeration.v5
  covers: [mutagen.mutation_enumeration.r9]
  kind: command
  target: mix test test/mutagen_ex/head_atom_dispatch_test.exs
  execute: true

- id: mutagen.mutation_enumeration.v6
  covers: [mutagen.mutation_enumeration.r6]
  kind: command
  target: mix test test/mutagen_ex/mutation_enumerator_test.exs
  execute: true

- id: mutagen.mutation_enumeration.v7
  covers: [mutagen.mutation_enumeration.r8]
  kind: command
  target: mix test test/mutagen_ex/mutation_enumerator_test.exs
  execute: true
```
