# mutagen.mutators — mutation catalog + validate predicates + stable IDs

The catalog of AST transformations applied to source. Ten mutators ship in v1.
Each is a module that exposes a `match?/1` (does this AST node qualify?), a
`mutate/1` (produce the swapped AST), and a `validate/1` (would the result
compile sensibly, or should the site be skipped?). Each produces a stable,
content-addressed ID independent of source formatting. Each also carries a
static confidence rating that reports attach to its results.

## Intent

The catalog is the language of mutations the verifier judge will reason about.
It must be:

- **Stable across formatting**: re-running `mix mutagen` after `mix format`
  preserves IDs when normalized expressions and their ordinals are unchanged, per
  mutagen.decision.mutation_id_scheme_2.
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
5. `with_swap` — swap the first two leading `<-` clauses of a `with`.
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
  - mutagen.decision.mutation_site_paths
  - mutagen.decision.mutation_id_scheme_2
  - mutagen.decision.validate_predicates
  - mutagen.decision.with_swap_failure_priority
  - mutagen.decision.mutator_confidence
  - mutagen.decision.mutator_precision
  - mutagen.decision.ancora_migration
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
    Every `validate/1` result is `:ok` or `{:skip, reason}` with one of
    six reasons: `:structurally_invalid`, `:no_op_shadowed`,
    `:bound_var_used_before_binding`, or the `with_swap` reasons
    `:insufficient_refutable_patterns`, `:indistinguishable_failures` and
    `:else_ignores_failure`. Each rejected site lands in
    `mutation.skipped[]` with `{site_id, reason}` and is not executed. Per
    mutagen.decision.validate_predicates, the rejection happens before any
    compile so `:compile_error` is reserved for genuine compile failures
    discovered at runtime.

- id: mutagen.mutators.r3
  priority: must
  statement: |
    An ID has shape `{relative_file}:{hash}:{mutator_name}`. The lowercase
    hexadecimal MD5 hashes the canonical encoding of the lexical identity,
    normalized expression, and zero-based ordinal for equal keys and the same
    mutator. A bare literal's expression also includes its normalized parent
    and child index. Module-body sites group by module and statement head.

- id: mutagen.mutators.r4
  priority: must
  statement: |
    For each catalog mutator, inserting comments, blank lines, or a separately
    named function above or below a function preserves the existing site's ID.
    Reflowing the same source at different formatter line lengths also preserves
    those IDs. Renaming the function or changing its mutation expression gives
    the affected site a different ID.

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

- id: mutagen.mutators.r9
  priority: must
  statement: |
    `with_swap` swaps only the first two leading `<-` clauses of a `with`.
    Later clauses and the `do` and `else` blocks keep their positions.
    `validate/1` checks the swapped node in this order:

      1. `{:skip, :bound_var_used_before_binding}` when the moved-first
         right-hand side contains a variable-shaped name that the
         moved-second pattern binds. Module attributes and binary segment
         modifiers do not count as reads. Pins, guards and modifiers in the
         pattern do not count as bindings.
      2. `:ok` when the clauses are dependent: a name bound by either
         pattern occurs anywhere in the other clause, including its pins,
         guards and binary sizes, or either clause calls `binding`,
         no-argument `dbg` (bare or through `Kernel`) or reads `__ENV__`.
      3. `{:skip, :insufficient_refutable_patterns}` when either pattern is
         an unguarded variable or `_`, or a literal equal to its literal
         right-hand side.
      4. `{:skip, :indistinguishable_failures}` when both right-hand sides
         are the same variable or equal literals.
      5. `{:skip, :else_ignores_failure}` when `else` has exactly one arm
         and its pattern is the bare `_` or an unguarded variable unused
         in the arm body. Treat same-name occurrences and lexical
         introspection as possible uses.
      6. `:ok` otherwise.

    Literal equality ignores the position metadata `line`, `column`,
    `end_line`, `end_column`, `closing`, `last`, `end_of_expression`,
    `newlines` and `parens`, and the order of map entries with scalar keys.

- id: mutagen.mutators.r10
  priority: must
  statement: |
    `MutagenEx.Mutators.confidence/1` returns `:low` for `:with_swap`,
    `:pipeline` and `:guard_drop`, and `:high` for the other seven registered names. A registered
    module that exports `confidence/0` supplies its own rating and one that
    does not gets `:high`. A name outside the catalog raises
    `ArgumentError` with the message `unknown mutator: <inspected name>`.

- id: mutagen.mutators.r11
  priority: must
  statement: |
    For a `when` node with two operands, `guard_drop`'s `mutate/1` returns
    the first operand, the clause head or pattern without its guard, and
    `validate/1` returns `:ok` for it. A covered guarded `def`, `case`
    or single-parameter `fn` clause therefore yields a `guard_drop` site
    and no `skipped` entry. A multi-parameter `fn` clause keeps all
    parameters and the guard in one `when` node: `mutate/1` returns that
    node unchanged and `validate/1` returns
    `{:skip, :structurally_invalid}`.
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
      `"lib/foo.ex:<hash>:arith"` where `<hash>` encodes the enclosing
      function, normalized `+` node, and ordinal zero.

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

- id: mutagen.mutators.s8
  covers: [mutagen.mutators.r9, mutagen.mutators.r2]
  given:
    - |
      Independent pairs with a clause that always matches:
      `with a <- f(), :ok <- g(), do: a`,
      `with :ok <- :ok, :ok <- g(), do: :done` and the three-clause
      `with a <- f(), b <- g(), :ok <- h(), do: {a, b}`.
    - |
      The dependent pair `with ^x <- :old, x <- :new, do: :pass`, whose
      second pattern is a bare variable, run with `x = :old`.
  when:
    - "`with_swap` swaps each and `validate/1` runs on the swap."
  then:
    - Each independent pair returns `{:skip, :insufficient_refutable_patterns}`.
    - |
      The dependent pair returns `:ok`. The original returns `:pass` and
      the swap returns `:old`.

- id: mutagen.mutators.s9
  covers: [mutagen.mutators.r9]
  given:
    - |
      Sources parsed with `columns: true, token_metadata: true` whose two
      right-hand sides are equal literals: `%{a: 1, b: %{c: 2}}` against
      `%{b: %{c: 2}, a: 1}`, a multiline `{:a, :b, :c}` against a one-line
      copy, `Foo.Bar` twice and `<<1, 2>>` twice, matched by `:left` and
      `:right`.
    - |
      `with :ok <- x, {:ok, x} <- x, do: :pass` run with `x = {:ok, :ok}`.
  when:
    - "`with_swap` swaps each and `validate/1` runs on the swap."
  then:
    - |
      Each equal-literal pair returns `{:skip, :indistinguishable_failures}`
      and both orders return the same literal.
    - |
      The repeated-variable pair returns `:ok` because the second pattern
      rebinds `x`. The original returns `{:ok, :ok}` and the swap returns
      `:pass`.

- id: mutagen.mutators.s10
  covers: [mutagen.mutators.r9]
  given:
    - |
      `with :ok <- f(), :ok <- g(), do: :done, else: (_ -> :error)` and the
      same expression with `else: (error -> error)`.
    - |
      `with {:ok, x} <- a, {:ok, x} <- b, do: x, else: (_ -> :failed)` run
      with `a = {:ok, 1}` and `b = {:ok, 2}`.
    - |
      A three-clause `with` whose `else` has a `{:error, reason}` arm and
      a `_` arm.
  when:
    - "`with_swap` swaps each and `validate/1` runs on the swap."
  then:
    - |
      The sole wildcard arm returns `{:skip, :else_ignores_failure}` and
      the `error -> error` arm returns `:ok`.
    - |
      The rebinding pair returns `:ok` despite its wildcard arm. The
      original returns `2` and the swap returns `1`.
    - |
      The three-clause swap returns `:ok` and leaves the third clause and
      both blocks unchanged.

- id: mutagen.mutators.s11
  covers: [mutagen.mutators.r9]
  given:
    - |
      Pairs with a sole `_` `else` arm whose moved-first pattern reads the
      other pattern's binding through `^x`, `<<_v::binary-size(n)>>` or
      the guard `n when n > x`, run with an outer binding of that name.
    - |
      Pairs whose clauses use `binding()`, `Kernel.binding()`,
      no-argument `dbg()` or `__ENV__` next to a fresh binding.
  when:
    - "`with_swap` swaps each and `validate/1` runs on the swap."
  then:
    - |
      Each returns `:ok`. Each pin, size and guard swap returns `:pass`
      where the original returned the `else` value, and each
      introspection swap changes the returned value.
    - |
      Without an outer binding, a kept pin, guard or size swap fails to
      compile with an undefined variable diagnostic.

- id: mutagen.mutators.s12
  covers: [mutagen.mutators.r10]
  given:
    - The ten registered mutator names and the name `:not_in_catalog`.
  when:
    - "`Mutators.confidence/1` runs on each."
  then:
    - "`:with_swap`, `:pipeline`, and `:guard_drop` return `:low`. The other seven return `:high`."
    - |
      `:not_in_catalog` raises `ArgumentError` with the message
      `unknown mutator: :not_in_catalog`.

- id: mutagen.mutators.s13
  covers: [mutagen.mutators.r9]
  given:
    - |
      `with {:ok, limit} <- a, true <- b < @limit, do: limit` and
      `with @expected <- a, :ok <- (if expected, do: :ok, else: :no), do: :pass`
      in a module that defines both attributes.
    - |
      `with {:ok, binary} <- a, :ok <- String.to_atom("#{b}"), do: binary`
      and the same pair with `~s|#{b}|`.
    - |
      `with {:ok, x} <- a, :ok <- (fn x -> x end).(:b), do: x` run with
      `a = :a`.
  when:
    - "`with_swap` swaps each and `validate/1` runs on the swap."
  then:
    - |
      The attribute and interpolation pairs return `:ok` and each swap
      changes the returned value.
    - |
      Interpolating the bound name itself, `"#{binary}"`, returns
      `{:skip, :bound_var_used_before_binding}`.
    - |
      The nested `fn` binder also returns
      `{:skip, :bound_var_used_before_binding}`, although the swap compiles
      and returns `:b` where the original returns `:a`.

- id: mutagen.mutators.s14
  covers: [mutagen.mutators.r11]
  given:
    - |
      The lane fixture `lib/lane_fixture/guarded.ex` with
      `def only_positive(n) when is_integer(n) and n > 0` and
      `def only_atoms(x) when is_atom(x)`, and its tests, which call each
      function with an argument its guard rejects.
  when:
    - "`mix mutagen` runs with that file as scope and its test file as tests."
  then:
    - |
      `mutation.results` holds two `guard_drop` entries with `after`
      values `only_positive(n)` and `only_atoms(x)`, both `killed`.
    - "`mutation.skipped` holds no `guard_drop` entry."
```

```spec-verification
- kind: tagged_tests
  target: test/mutagen_ex
  covers:
    - mutagen.mutators.r1
    - mutagen.mutators.r2
    - mutagen.mutators.r3
    - mutagen.mutators.r4
    - mutagen.mutators.r5
    - mutagen.mutators.r6
    - mutagen.mutators.r7
    - mutagen.mutators.r8
    - mutagen.mutators.r9
    - mutagen.mutators.r10
    - mutagen.mutators.r11
```
