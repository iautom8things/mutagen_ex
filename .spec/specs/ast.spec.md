# mutagen.ast — shared AST helpers

Owns the canonical helpers that operate over Elixir AST shapes shared by
scope resolution, mutation enumeration, and mutation runner restore. Lifts
duplicated `alias_to_module/1` and `find_module_body/2` into one module so
all three pipeline stages observe identical semantics. Caller-specific
helpers (e.g. `compute_end_position/1`, `walk_bare/N`) stay in their donor
modules — this subject does not aspire to be a general AST utility library.

## Intent

Before `.25`, the same `alias_to_module/1` was defined three times (in
`scope_resolver.ex`, `mutation_enumerator.ex`, and `mutation_runner.ex`),
and `find_module_body/2` had a near-duplicate in each. A future bug fix to
one site would silently fail to land in the others. This subject closes
that drift surface by giving the helpers one home.

The lift is narrow: only helpers used by 2+ donor modules move here. The
lift is also pure — helpers take AST and return AST or `:not_found`; no
process state, no side effects, no I/O. That keeps the module trivially
testable and lets callers compose freely.

This subject covers the API contract. The internal implementation may
evolve (e.g., switch from `Macro.prewalk/2` to a hand-rolled walker for
performance) so long as the contract holds.

## Out of scope for this subject

- The full enumerator walk (`walk_tree/6`) — stays in `mutation_enumerator.ex`
  because only enumeration uses ambient-position threading.
- Per-site path computation and bare-literal walking — stays in
  `mutation_runner.ex` because only the runner needs them.
- The `MutagenEx.AstCache` source-text + AST store — that's a separate
  subject; see [mutagen.coverage](coverage.spec.md).

```spec-meta
id: mutagen.ast
kind: module
status: draft
summary: Canonical AST helpers (alias_to_module, find_module_body, node_line) shared by scope/enumerator/runner.
surface:
  - lib/mutagen_ex/ast.ex
  - test/mutagen_ex/ast_test.exs
  - test/mutagen_ex/ast_donor_equivalence_test.exs
decisions: []
```

```spec-requirements
- id: mutagen.ast.r1
  priority: must
  statement: |
    `MutagenEx.Ast.alias_to_module/1` accepts an alias AST tuple
    `{:__aliases__, _, parts}` where every element of `parts` is an atom,
    and returns `Module.concat(parts)`. It accepts a bare module atom (e.g.
    `Foo.Bar`) and returns it unchanged. Any other shape (including aliases
    with non-atom parts, or non-atom non-alias inputs) returns `nil`. The
    function is total: it never raises, throws, or exits.

- id: mutagen.ast.r2
  priority: must
  statement: |
    `MutagenEx.Ast.find_module_body/2` takes an AST `t` and a module-name
    string `target_mod_str` and returns `{:ok, body_ast}` if a node
    `{:defmodule, meta, [alias_ast, [do: body_ast]]}` exists in `t` whose
    `alias_to_module(alias_ast) |> Atom.to_string()` (with the `Elixir.`
    prefix stripped) equals `target_mod_str`. Otherwise it returns
    `:not_found`. The function is total: it never raises, throws, or exits.

- id: mutagen.ast.r3
  priority: must
  statement: |
    `MutagenEx.Ast.node_line/1` takes a Macro AST node and returns the
    `:line` value from the node's metadata if present, or `nil` otherwise.
    A 2-tuple, list, or literal input returns `nil`. The function is total.

- id: mutagen.ast.r4
  priority: must
  statement: |
    The donor modules `MutagenEx.ScopeResolver`, `MutagenEx.MutationEnumerator`,
    and `MutagenEx.MutationRunner` consume `MutagenEx.Ast.alias_to_module/1`
    and `MutagenEx.Ast.find_module_body/2` exclusively after `.25.01` lands.
    Each module's previous private duplicate is deleted. A grep for
    `defp alias_to_module` over `lib/mutagen_ex/` returns at most one hit
    (in `lib/mutagen_ex/ast.ex` if defined privately there; ideally zero
    because the canonical function is public).

- id: mutagen.ast.r5
  priority: should
  statement: |
    For every AST shape currently handled by any donor's pre-`.25`
    `alias_to_module/1` or `find_module_body/2`, the lifted version returns
    the same result. This is the donor-equivalence invariant — a property-
    style test exercises a representative AST corpus and asserts identical
    output across donor and lifted versions.
```

```spec-scenarios
- id: mutagen.ast.s1
  covers: [mutagen.ast.r1]
  given: |
    A target alias AST `{:__aliases__, [line: 1], [:Foo, :Bar]}`.
  when: `MutagenEx.Ast.alias_to_module/1` is called with it.
  then: |
    Returns the atom `Foo.Bar` (i.e., `Module.concat([:Foo, :Bar])`).

- id: mutagen.ast.s2
  covers: [mutagen.ast.r1]
  given: |
    The bare atom `Foo.Bar` (not an alias tuple).
  when: `MutagenEx.Ast.alias_to_module/1` is called with it.
  then: |
    Returns `Foo.Bar` unchanged.

- id: mutagen.ast.s3
  covers: [mutagen.ast.r1]
  given: |
    A nonsense input like an integer, list, or `{:not_an_alias, [], [...]}`.
  when: `MutagenEx.Ast.alias_to_module/1` is called with it.
  then: |
    Returns `nil`. No exception.

- id: mutagen.ast.s4
  covers: [mutagen.ast.r2]
  given: |
    Quoted source `defmodule Foo do def bar, do: :ok end` and the target
    string `"Foo"`.
  when: `MutagenEx.Ast.find_module_body/2` is called with the parsed AST
    and `"Foo"`.
  then: |
    Returns `{:ok, body_ast}` where `body_ast` is the `do:` block contents
    (the `def bar, do: :ok` AST).

- id: mutagen.ast.s5
  covers: [mutagen.ast.r2]
  given: |
    The same AST as s4, but the target string is `"Bar"` (a module not
    defined in the AST).
  when: `MutagenEx.Ast.find_module_body/2` is called.
  then: |
    Returns `:not_found`.

- id: mutagen.ast.s6
  covers: [mutagen.ast.r3]
  given: |
    A 3-tuple node `{:foo, [line: 42], []}`.
  when: `MutagenEx.Ast.node_line/1` is called.
  then: |
    Returns `42`.

- id: mutagen.ast.s7
  covers: [mutagen.ast.r3]
  given: |
    A bare literal `42` (an integer), or a 2-tuple `{:ok, 1}`.
  when: `MutagenEx.Ast.node_line/1` is called.
  then: |
    Returns `nil`.

- id: mutagen.ast.s8
  covers: [mutagen.ast.r4]
  given: |
    The codebase after `mutagen-wrd.25.01` has landed.
  when: |
    `grep -rn "defp alias_to_module" lib/mutagen_ex/ | wc -l` runs.
  then: |
    Output is `0` (the canonical function is public in `lib/mutagen_ex/ast.ex`).
    A similar grep for `defp find_module_body` returns `0`.

- id: mutagen.ast.s9
  covers: [mutagen.ast.r5]
  given: |
    A corpus of 20+ AST shapes representative of the existing test fixtures
    (quoted modules with aliases, nested aliases, attributes, function
    heads, guards).
  when: |
    The donor-equivalence test runs each AST through the pre-`.25` version
    of `alias_to_module/1` (preserved as a test fixture function) and the
    new `MutagenEx.Ast.alias_to_module/1`.
  then: |
    Output is identical for every input.
```

```spec-verification
- id: mutagen.ast.v1
  covers: [mutagen.ast.r1, mutagen.ast.r2, mutagen.ast.r3]
  kind: source_file
  path: test/mutagen_ex/ast_test.exs
  execute: false
  description: |
    Unit tests for each public function: positive cases (alias tuple,
    bare atom, target found, target missing, node with :line metadata,
    node without).

- id: mutagen.ast.v2
  covers: [mutagen.ast.r4]
  kind: command
  command: "grep -rn 'defp alias_to_module\\|defp find_module_body' lib/mutagen_ex/"
  execute: false
  description: |
    Mechanical check that no donor module still carries a private duplicate
    of the lifted helpers. Expected output is empty.

- id: mutagen.ast.v3
  covers: [mutagen.ast.r5]
  kind: source_file
  path: test/mutagen_ex/ast_donor_equivalence_test.exs
  execute: false
  description: |
    Property-style equivalence test. The pre-.25 donor implementations are
    preserved verbatim as fixture functions; for each AST in a representative
    corpus, the test asserts donor output == lifted output. Locks in the
    safety net so a future change to the lifted version cannot silently
    diverge from established donor behaviour.
```
