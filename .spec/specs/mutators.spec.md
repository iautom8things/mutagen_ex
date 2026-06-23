# mutagen.mutators — mutation catalog + validate predicates + stable IDs

The catalog of AST transformations applied to source. Ten mutators ship in v1.
Each is a module that exposes a `match?/1` (does this AST node qualify?), a
`mutate/1` (produce the swapped AST), and a `validate/1` (would the result
compile sensibly, or should the site be skipped?). Each produces a stable,
content-addressed ID independent of source formatting.

## Intent

The catalog is the language of mutations the verifier judge will reason about.
It must be:

- **Stable across formatting**: re-running `mix mutagen` after `mix format`
  produces the same `mutation.results[].id` values, per
  mutagen.decision.content_addressed_ids.
- **Discriminating**: a mutator does not produce a "no-op" mutation (one
  whose meaning is identical to the original) or a "structurally invalid"
  mutation that never compiles. `validate/1` filters those out at enumeration
  time, so they never enter the test-runner phase.
- **Bounded**: ten mutators in v1, no more. No user-supplied mutator config.
  See mutagen.decision.validate_predicates for the no-op/uncompilable
  classification rules.

## Catalog (v1)

Per the refined plan:

1. `arith` — `+ ↔ -`, `* ↔ /` on numeric binary ops.
2. `compare` — `== ↔ !=`, `< ↔ >=`, `> ↔ <=`.
3. `boolean` — `and ↔ or`, `&& ↔ ||`, drop `not`/`!`.
4. `literal` — flip `true ↔ false`, swap small integer literals.
5. `with_swap` — reorder `with` clauses.
6. `case_drop` — drop the last clause of a `case`/`cond`. See note below on
   the *guarded-recursive-base-case* pattern: when the surviving clauses do
   not cover every value reachable at runtime, the mutated module raises
   `CaseClauseError` and the site classifies as `:killed`, not as a
   silent no-op or a divergent loop. This is honest behaviour, not a bug.
7. `pipeline` — reorder adjacent `|>` segments.
8. `result_tuple` — flip `{:ok, x}` / `{:error, x}` shapes.
9. `else_removal` — drop `else` branch of `if`/`with`.
10. `guard_drop` — drop a function-clause guard.

## Out of scope for this subject

- Enumerating sites across a file (see
  [mutagen.mutation_enumeration](mutation_enumeration.spec.md)).
- Running the mutated code (see
  [mutagen.mutation_pipeline](mutation_pipeline.spec.md)).
- JSON serialization of mutation results (see
  [mutagen.json_schema](json_schema.spec.md)).

```spec-meta
id: mutagen.mutators
kind: module
status: active
summary: Ten AST mutators with validate predicates and content-addressed mutation IDs.
surface:
  - lib/mutagen_ex/mutators.ex
  - lib/mutagen_ex/mutators/arith.ex
  - lib/mutagen_ex/mutators/compare.ex
  - lib/mutagen_ex/mutators/boolean.ex
  - lib/mutagen_ex/mutators/literal.ex
  - lib/mutagen_ex/mutators/with_swap.ex
  - lib/mutagen_ex/mutators/case_drop.ex
  - lib/mutagen_ex/mutators/pipeline.ex
  - lib/mutagen_ex/mutators/result_tuple.ex
  - lib/mutagen_ex/mutators/else_removal.ex
  - lib/mutagen_ex/mutators/guard_drop.ex
decisions:
  - mutagen.decision.content_addressed_ids
  - mutagen.decision.validate_predicates
realized_by:
  api_boundary:
    - "MutagenEx.Mutators"
    - "MutagenEx.Mutators.Arith"
    - "MutagenEx.Mutators.Compare"
    - "MutagenEx.Mutators.Boolean"
    - "MutagenEx.Mutators.Literal"
    - "MutagenEx.Mutators.WithSwap"
    - "MutagenEx.Mutators.CaseDrop"
    - "MutagenEx.Mutators.Pipeline"
    - "MutagenEx.Mutators.ResultTuple"
    - "MutagenEx.Mutators.ElseRemoval"
    - "MutagenEx.Mutators.GuardDrop"
```

```spec-requirements
- id: mutagen.mutators.r1
  priority: must
  statement: |
    Every mutator implements `match?(ast_node) :: boolean`, `mutate(ast_node)
    :: ast_node`, and `validate(swapped_ast_node) :: :ok | {:skip, atom}`.
    Enumeration discovers a site by `match?/1`, performs the swap with
    `mutate/1`, then asks `validate/1` whether the swapped form is sensible.
    `{:skip, reason}` excludes the site from `mutation.total`; `:ok` keeps
    the site for execution.

- id: mutagen.mutators.r2
  priority: must
  statement: |
    `validate/1` rejection reasons used in v1 include
    `:structurally_invalid`, `:no_op_shadowed`, and
    `:bound_var_used_before_binding`. Each rejected site lands in
    `mutation.skipped[]` with `{site_id, reason}`. Per
    mutagen.decision.validate_predicates, the rejection happens before any
    compile so `:compile_error` is reserved for genuine compile failures
    discovered at runtime.

- id: mutagen.mutators.r3
  priority: must
  statement: |
    Every mutation site has an ID of shape
    `{relative_file}:{ast_hash}:{mutator_name}`. `relative_file` is the file
    path relative to the project root. `ast_hash` is `:erlang.phash2/2` of
    the normalized AST node, where normalization strips `:line`, `:column`,
    `:end_line`, and `:end_column` from every metadata keyword. `mutator_name`
    is the snake_case atom name (`:arith`, `:case_drop`, etc.).

- id: mutagen.mutators.r4
  priority: must
  statement: |
    Mutation IDs are stable across `mix format`. Specifically: running the
    enumerator on a file, then running `mix format` on that file, then
    running the enumerator again, produces the same site ID set (modulo
    sites that `mix format` actually removed, which is none for the
    supported subset).

- id: mutagen.mutators.r5
  priority: must
  statement: |
    For mutators whose swap is symmetric (e.g., `arith` swapping `+` and
    `-`, `compare` swapping `< >=`), `mutate(mutate(node)) == node`. This
    invariant is property-tested per the merge gate of S4a in the refined
    plan.

- id: mutagen.mutators.r6
  priority: must
  statement: |
    Every catalog entry's `Macro.to_string(mutate(ast))` produces source
    text that `Code.string_to_quoted/2` accepts without error for any input
    where `validate/1` returned `:ok`. This is the bridge between the AST
    layer and the JSON's `after` field; failure here means a `:compile_error`
    that should have been a `:skip`.

- id: mutagen.mutators.r7
  priority: must
  statement: |
    The catalog is closed in v1: ten mutators, no plugin interface, no
    user-supplied addition. Adding a new mutator requires a code change and
    a spec revision.

- id: mutagen.mutators.r8
  priority: must
  statement: |
    `:case_drop`'s `validate/1` does NOT attempt to prove that the
    surviving clauses cover every value reachable at runtime. When the
    dropped clause was the only one that matched a value the program
    actually produces (the *guarded-recursive-base-case* pattern is the
    canonical example: a `case` with a guarded recursive clause plus an
    unguarded base clause; dropping the base leaves only the guarded
    clause), the mutated module raises `CaseClauseError` at runtime and
    the mutation_pipeline classifies the site `:killed` per
    mutagen.mutation_pipeline.r5. This is the honest classification: the
    cited tests observably distinguished the dropped clause from the
    survivors. `:case_drop` is therefore NOT a reliable trigger for
    `:timeout` classification — authoring fixtures or test cases that
    require deterministic `:timeout` (e.g., lane-project recursion that
    must exceed `Config.timeout_ms`) should use `:arith` against the
    recursive descent so the recursion truly diverges without
    encountering a clause-miss.
```

```spec-scenarios
- id: mutagen.mutators.s1
  covers: [mutagen.mutators.r1, mutagen.mutators.r3]
  given:
    - |
      Source `def f(x), do: x + 1` at line 5 column 17.
  when:
    - The `arith` mutator processes the `+` node.
  then:
    - |
      `match?` returns true. `mutate/1` returns the AST for `x - 1`.
      `validate/1` returns `:ok`. The site ID is
      `"lib/foo.ex:<hash>:arith"` where `<hash>` is the `:erlang.phash2`
      of the normalized `+` AST node.

- id: mutagen.mutators.s2
  covers: [mutagen.mutators.r2]
  given:
    - |
      A `with` clause `with {:ok, a} <- f(), {:ok, b} <- g(a), do: a + b`.
  when:
    - |
      The `with_swap` mutator swaps the two clauses to produce
      `with {:ok, b} <- g(a), {:ok, a} <- f(), do: a + b`.
  then:
    - |
      `validate/1` returns `{:skip, :bound_var_used_before_binding}` because
      `g(a)` now references `a` before it's bound. The site is recorded in
      `mutation.skipped` with that reason and is NOT executed.

- id: mutagen.mutators.s3
  covers: [mutagen.mutators.r4]
  given:
    - |
      A file `lib/foo.ex` containing several mutation candidates. The
      enumerator is run once producing site IDs `S1`. Then `mix format` runs
      on the same file. Then the enumerator is run again producing site IDs
      `S2`.
  when:
    - Comparing the two ID sets.
  then:
    - |
      `S1 == S2` (set equality).

- id: mutagen.mutators.s4
  covers: [mutagen.mutators.r5]
  given:
    - The `compare` mutator and a randomly generated `<` binary operation AST.
  when:
    - We apply `mutate/1` twice in succession.
  then:
    - |
      The doubly-swapped AST is structurally equal to the input. Property
      tested with `StreamData`.

- id: mutagen.mutators.s5
  covers: [mutagen.mutators.r6]
  given:
    - |
      Any mutator and any source AST where `validate/1` of the swap returned
      `:ok`.
  when:
    - |
      We `Macro.to_string/1` the swap and then `Code.string_to_quoted/2`
      the resulting string.
  then:
    - |
      The round-trip succeeds: the parsed string is structurally equivalent
      to the swapped AST.

- id: mutagen.mutators.s6
  covers: [mutagen.mutators.r1, mutagen.mutators.r2]
  given:
    - An `if x do ... else ... end` block.
  when:
    - |
      The `else_removal` mutator removes the `else` branch and `validate/1`
      runs on the swap.
  then:
    - |
      `validate/1` checks the surrounding context; if the call site of the
      enclosing function pattern-matches an explicit `else`-returning shape,
      it returns `{:skip, :structurally_invalid}`. Otherwise `:ok`.

- id: mutagen.mutators.s7
  covers: [mutagen.mutators.r8]
  given:
    - |
      A module with a guarded-recursive-base-case pattern, e.g.

          def count_down(n) when is_integer(n) do
            case n do
              n when n > 0 -> count_down(n - 1)
              0 -> :done
            end
          end

      and a test that calls `count_down(3)` expecting `:done`.
  when:
    - |
      `:case_drop` drops the last clause (`0 -> :done`), the mutated
      module compiles, and `MutationRunner` executes the cited test.
  then:
    - |
      `validate/1` returns `:ok` (the catalog does not prove coverage).
      At runtime the recursion reaches `count_down(0)` which fails the
      `n > 0` guard on the surviving clause and raises `CaseClauseError`.
      The cited test fails. The site is classified `:killed` per
      mutagen.mutation_pipeline.r5. The site is NOT classified
      `:timeout`. Tests requiring deterministic `:timeout` must trigger
      divergence by another mechanism (e.g., `:arith` against the
      recursive descent).
```

```spec-verification
- id: mutagen.mutators.v1
  covers: [mutagen.mutators.r1, mutagen.mutators.r2, mutagen.mutators.r7]
  kind: command
  target: mix test test/mutagen_ex/mutators_test.exs
  execute: true

- id: mutagen.mutators.v2
  covers: [mutagen.mutators.r3, mutagen.mutators.r4]
  kind: command
  target: mix test test/mutagen_ex/mutators/id_stability_test.exs
  execute: true

- id: mutagen.mutators.v3
  covers: [mutagen.mutators.r5, mutagen.mutators.r6]
  kind: command
  target: mix test test/mutagen_ex/mutators_property_test.exs
  execute: true

- id: mutagen.mutators.v4
  covers: [mutagen.mutators.r2]
  kind: command
  target: mix test test/mutagen_ex/mutators/ --only validate
  execute: true

- id: mutagen.mutators.v5
  covers: [mutagen.mutators.r8]
  kind: command
  target: mix test test/mutagen_ex/mutators/case_drop_classification_test.exs
  execute: true
```
