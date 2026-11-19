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
  - lib/mutagen_ex/json_reporter/source.ex
  - lib/mutagen_ex/mutators/dispatch.ex
decisions:
  - mutagen.decision.mutation_site_paths
  - mutagen.decision.mutation_id_scheme_2
  - mutagen.decision.validate_predicates
  - mutagen.decision.static_mutator_dispatch
  - mutagen.decision.adoption_polish_efficacy
  - mutagen.decision.ancora_migration
  - mutagen.decision.planned_runtime_sites
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
    Enumeration emits only sites in a selected module and scope line range.
    An MFA scope emits only sites for that definition, even when its clauses
    span other definitions. Overlapping scopes emit each site once.
    The site records an AST path from the original file root and carries the
    nearest named definition's module, name, and declared arity. Protocols
    and static implementations contribute their own module identities.
    Guard definitions are named definitions. Quoted definitions do not
    replace the enclosing function. Dynamic names report no function.
    Ordinals count candidates before scope and coverage filters.

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
    `nil`. The report uses the exact source span from r11 when available.
    Otherwise it uses the legacy coordinates or the rendered AST.

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

- id: mutagen.mutation_enumeration.r10
  priority: must
  statement: |
    The enumerator offers no mutator the subtree rooted at the `/` of
    a named function capture such as `&fun/1`, `&Mod.fun/2` or
    `&:erlang.fun/2`, including a quoted `&unquote(fun)/1`. Neither the reference nor any of its children,
    including the arity integer, yields a site or a skipped entry in
    either dispatch mode. Expressions and literals inside anonymous
    capture bodies such as `&(&1 / 1)` remain eligible.

- id: mutagen.mutation_enumeration.r11
  priority: must
  statement: |
    A site enumerated from cached source text carries the byte offset and
    length of its original expression. Parsing that slice produces the
    same AST after dropping metadata, including for bare literals,
    receivers and parenthesized operands. Disabling source reporting
    skips span collection without changing mutation IDs or order.

- id: mutagen.mutation_enumeration.r12
  priority: must
  statement: |
    `MutagenEx.MutationEnumerator.group_fingerprints/1` returns each
    group's lowercase MD5 of the canonical identity
    encoding of its list of normalized clauses or statements in file walk
    order. A nested module or definition contributes its boundary to the
    outer group's AST and contributes its own sites to its own group.
    When the normalized expression used by an outer site's ID includes
    nested syntax, the outer fingerprint includes that syntax too.
    Planned enumeration hashes only groups that own a planned site or
    skip. Each planned entry carries the fingerprint of its existing ID
    group. Formatting, comments, blank lines, and edits outside the group
    preserve the fingerprint. For named definitions, matching fingerprints
    preserve the mapping from ID to clause occurrence and path within that
    clause. File-root paths also match when the clauses stay at the same
    file-root paths.

- id: mutagen.mutation_enumeration.r13
  priority: must
  statement: |
    Planned enumeration selects sites whose inclusive source range
    overlaps a supplied changed-line range in the same file. The source
    range spans the line, closing, end and end-of-expression metadata in
    the subtree. A subtree without positions uses its nearest positioned
    ancestor's range. Changed lines accept positive, ascending inclusive
    ranges or endpoint pairs. Malformed inputs raise `ArgumentError`.
    Planning ignores coverage and retains validator skips with planned
    metadata. `MutagenEx.MutationEnumerator.to_site/1` converts a planned
    site into the corresponding runner site struct. Classic enumeration
    keeps the coverage filter and result shape.

- id: mutagen.mutation_enumeration.r14
  priority: must
  statement: |
    A planned entry has `runtime?: true` exactly when it has a named
    enclosing function, that definition is a `def` or `defp`, and the
    entry is outside `quote`.

- id: mutagen.mutation_enumeration.r15
  priority: must
  statement: |
    `MutagenEx.MutationEnumerator.fingerprint_scope/2` keeps only entries
    whose group is absent from the base source or has a different
    fingerprint there. It parses the base with `MutagenEx.AstCache.parse/2` and
    hashes only keys present in the supplied entries. A new file scopes
    all its planned entries. A base
    source that fails to parse scopes all the planned entries and returns
    a warning.

- id: mutagen.mutation_enumeration.r16
  priority: must
  statement: |
    `MutagenEx.MutationEnumerator.partition_planned_runtime_sites/2` puts
    each planned runtime entry in exactly one bucket by ID and rejects
    duplicate planned IDs with `ArgumentError`. Killed, survived,
    timed-out, skipped, and compile-error entries
    are evaluated. Runner errors are not run. IDs absent from all run
    output are uncovered candidates pending the coverage decision.
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
  given:
    - |
      `lib/multi.ex` defines `Mod.A` and `Mod.B`. Another file defines
      `Outer` with nested `defmodule Inner`. The scope record targets only
      `Mod.A` or the fully qualified nested module `Outer.Inner`.
  when:
    - The enumerator runs.
  then:
    - |
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

- id: mutagen.mutation_enumeration.s10
  covers: [mutagen.mutation_enumeration.r10]
  given:
    - |
      A covered module with `Enum.map(xs, &double/1)`,
      `Enum.map(xs, &Kernel.abs/1)`, `Enum.map(xs, &:erlang.abs/1)`,
      `Enum.map(xs, &(&1 / 1))`, `x / 2` and `x * 2`.
  when:
    - The enumerator runs in `:head_atom` and in `:legacy` dispatch mode.
  then:
    - |
      Both modes emit no sites or skipped entries for the named
      captures. Both emit an `arith` site and a `literal` site for
      the anonymous capture body, and `arith` sites for `x / 2` and
      `x * 2`.
```

```spec-verification
- kind: tagged_tests
  target: test/mutagen_ex
  covers:
    - mutagen.mutation_enumeration.r1
    - mutagen.mutation_enumeration.r2
    - mutagen.mutation_enumeration.r3
    - mutagen.mutation_enumeration.r4
    - mutagen.mutation_enumeration.r5
    - mutagen.mutation_enumeration.r6
    - mutagen.mutation_enumeration.r7
    - mutagen.mutation_enumeration.r8
    - mutagen.mutation_enumeration.r9
    - mutagen.mutation_enumeration.r10
    - mutagen.mutation_enumeration.r11
    - mutagen.mutation_enumeration.r12
    - mutagen.mutation_enumeration.r13
    - mutagen.mutation_enumeration.r14
    - mutagen.mutation_enumeration.r15
    - mutagen.mutation_enumeration.r16
```
