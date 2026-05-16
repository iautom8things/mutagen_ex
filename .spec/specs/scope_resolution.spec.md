# mutagen.scope_resolution — `--scope` target → AST range

Translates user-supplied `--scope` targets into concrete `{file, line_range,
module}` records that downstream stages can walk. Operates entirely over
parsed-AST data; never inspects on-disk bytecode.

## Intent

Users describe what to mutate at three granularities:

- A whole file: `lib/foo.ex`
- A module: `MyApp.Foo`
- A specific function: `MyApp.Foo.bar/2`

The pipeline needs a uniform record per target so the mutation enumerator can
filter sites. Errors here halt the pipeline before any test runs.

## Out of scope for this subject

- Mapping covered-line metadata back to AST sites (see
  [mutagen.mutation_enumeration](mutation_enumeration.spec.md)).
- Catalog of mutators applied to those sites (see
  [mutagen.mutators](mutators.spec.md)).

```spec-meta
id: mutagen.scope_resolution
kind: module
status: draft
summary: Resolves --scope targets to {file, line_range, module} records over parsed ASTs.
surface:
  - lib/mutagen_ex/scope_resolver.ex
decisions:
  - mutagen.decision.scope_syntax_simplified
```

```spec-requirements
- id: mutagen.scope_resolution.r1
  priority: must
  statement: |
    A scope target of shape `<path>.ex` resolves to one or more records, one
    per `defmodule` block in the file, each with `line_range` covering the
    entire `defmodule` block (inclusive of `do` and `end` lines).

- id: mutagen.scope_resolution.r2
  priority: must
  statement: |
    A scope target of shape `Module.Name` (no slash, no leading lib path)
    resolves to exactly one record covering the matching `defmodule` block.
    If no such module exists in the project source, the resolver returns a
    structured error with `reason: :module_not_found`.

- id: mutagen.scope_resolution.r3
  priority: must
  statement: |
    A scope target of shape `Module.Name.function/arity` resolves to exactly
    one record whose `line_range` covers only the matching `def`,
    `defp`, `defmacro`, or `defmacrop` clause(s). Arity is required: a target
    like `Module.Name.function` without `/arity` returns an error with
    `reason: :arity_required`.

- id: mutagen.scope_resolution.r4
  priority: must
  statement: |
    Targets containing a colon (e.g. `lib/foo.ex:Module.Name`) return a
    structured error with `reason: :colon_syntax_unsupported`. Per
    mutagen.decision.scope_syntax_simplified, the colon form is not part of
    the v1 surface.

- id: mutagen.scope_resolution.r5
  priority: must
  statement: |
    For multi-`defmodule` files, a module- or MFA-shaped target's
    `line_range` is restricted to the targeted module's block; sibling
    modules in the same file are NOT included.

- id: mutagen.scope_resolution.r6
  priority: must
  statement: |
    Resolution does not modify any file on disk. The resolver reads source
    via `File.read!/1` (or equivalent) and parses with
    `Code.string_to_quoted/2` requesting line/column metadata; no compile,
    no `Code.eval_*`.

- id: mutagen.scope_resolution.r7
  priority: should
  statement: |
    The resolver accepts an injectable source-loader function so unit tests
    do not need on-disk fixtures. The default loader is `&File.read!/1`.

- id: mutagen.scope_resolution.r8
  priority: must
  statement: |
    Resolution of a user-supplied `Module.Name` or `Module.Name.fun/arity`
    target does NOT materialize a fresh atom from the user's input via
    `String.to_atom/1`. Module matching against source-file `defmodule`
    blocks is performed via string comparison (the user's canonical form vs.
    `Atom.to_string/1` of each AST-derived module atom); the matched
    `%Scope{module: mod}` carries the AST-derived atom, never an atom built
    from the user's target. Function-name matching similarly uses
    `String.to_existing_atom/1` (function name atoms exist on defs found in
    the parsed AST; if the lookup raises `ArgumentError` the resolver
    returns `:function_not_found`). This is the atom-table-DOS bound
    (mutagen-wrd.20): `:erlang.system_info(:atom_count)` is unchanged across
    N calls to `resolve/2` with N distinct never-registered module-shaped or
    MFA-shaped targets (e.g. `Nope.#{n}`, `Nope.#{n}.bar/1`).

- id: mutagen.scope_resolution.r9
  priority: must
  statement: |
    For module-shaped and MFA-shaped targets, when no explicit
    `:source_files` option is supplied, the default
    `Path.wildcard("lib/**/*.ex")` result is sorted lexicographically
    (via `Enum.sort/1`) before being searched. This closes the F30 / CF7
    determinism risk: `Path.wildcard/1`'s order is file-system-dependent
    (HFS+ sorts; ext4 returns inode order), so two hosts could otherwise
    pick a different file when multiple sources happen to declare the
    same `defmodule`. The sort makes the chosen file deterministic across
    hosts, preserving the byte-identical-output gate in
    `mutagen.mutation_pipeline.r15`. Callers passing an explicit
    `:source_files` list are not re-sorted — the caller already chose
    the order.
```

```spec-scenarios
- id: mutagen.scope_resolution.s1
  covers: [mutagen.scope_resolution.r1]
  given: A file `lib/foo.ex` containing one `defmodule Foo do ... end` between lines 1 and 30.
  when: The resolver is called with `--scope lib/foo.ex`.
  then: |
    The resolver returns `[%Scope{file: "lib/foo.ex", line_range: 1..30,
    module: Foo}]`.

- id: mutagen.scope_resolution.s2
  covers: [mutagen.scope_resolution.r2]
  given: |
    A project containing `lib/foo/bar.ex` with `defmodule Foo.Bar`.
  when: The resolver is called with `--scope Foo.Bar`.
  then: |
    The resolver returns a single `%Scope{}` record naming the file path it
    found `defmodule Foo.Bar` in. No other file is searched once a match is
    found.

- id: mutagen.scope_resolution.s3
  covers: [mutagen.scope_resolution.r3]
  given: |
    `lib/foo.ex` contains `defmodule Foo do; def bar(x), do: x; def bar(x,
    y), do: x + y; end`.
  when: The resolver is called with `--scope Foo.bar/1`.
  then: |
    The returned `line_range` covers only the `bar/1` clause, not `bar/2`.

- id: mutagen.scope_resolution.s4
  covers: [mutagen.scope_resolution.r3]
  given: A scope target `Foo.bar` (no `/arity`).
  when: The resolver runs.
  then: |
    An error tuple `{:error, reason: :arity_required, target: "Foo.bar"}` is
    returned.

- id: mutagen.scope_resolution.s5
  covers: [mutagen.scope_resolution.r4]
  given: A scope target `lib/foo.ex:Foo.bar/1`.
  when: The resolver runs.
  then: |
    An error tuple `{:error, reason: :colon_syntax_unsupported, target:
    "lib/foo.ex:Foo.bar/1"}` is returned.

- id: mutagen.scope_resolution.s6
  covers: [mutagen.scope_resolution.r5]
  given: |
    `lib/multi.ex` contains `defmodule A do ... end` (lines 1..10) and
    `defmodule B do ... end` (lines 12..25).
  when: The resolver is called with `--scope A`.
  then: |
    The returned `line_range` is 1..10. Lines 12..25 are not included.

- id: mutagen.scope_resolution.s7
  covers: [mutagen.scope_resolution.r6]
  given: A resolver run that completes successfully.
  when: The resolver returns.
  then: |
    Comparing each affected source file's bytes before and after the
    resolver call shows zero changes. `cover/` is not created by the
    resolver. The `.beam` files in `_build/` are unchanged.

- id: mutagen.scope_resolution.s8
  covers: [mutagen.scope_resolution.r8]
  given: |
    A loader returning a fixed `defmodule Foo do end` and N distinct
    never-registered module-shaped targets (`Nope1`, `Nope2`, ...,
    `NopeN`).
  when: The resolver is called once per target.
  then: |
    Every call returns `{:error, :module_not_found, _}`.
    `:erlang.system_info(:atom_count)` is identical before and after the N
    calls — no atom is created from any of the `NopeN` strings. The same
    invariant holds for MFA-shaped targets (`NopeN.bar/1`): no atom is
    created from `NopeN` or from the function-name segment `bar` when
    `bar` is not already a registered atom.

- id: mutagen.scope_resolution.s9
  covers: [mutagen.scope_resolution.r9]
  given: |
    A project source layout where `Path.wildcard("lib/**/*.ex")` would
    return files in some host-dependent order (the contract here is
    properties of the resolver's behaviour, not of the underlying
    file system).
  when: |
    `resolve/2` is called twice for the same module target with no
    `:source_files` option, on the same project.
  then: |
    Both calls iterate the candidate file list in the same lexicographic
    order. The implementation `MutagenEx.ScopeResolver.source_files/1`
    wraps the wildcard result in `Enum.sort/1` before returning.
```

```spec-verification
- id: mutagen.scope_resolution.v1
  covers: [mutagen.scope_resolution.r1, mutagen.scope_resolution.r2, mutagen.scope_resolution.r3, mutagen.scope_resolution.r5]
  kind: command
  command: mix test test/mutagen_ex/scope_resolver_test.exs
  execute: true

- id: mutagen.scope_resolution.v2
  covers: [mutagen.scope_resolution.r3, mutagen.scope_resolution.r4]
  kind: command
  command: mix test test/mutagen_ex/scope_resolver_test.exs --only error_cases
  execute: true

- id: mutagen.scope_resolution.v3
  covers: [mutagen.scope_resolution.r1, mutagen.scope_resolution.r2]
  kind: command
  command: mix test test/mutagen_ex/scope_resolver_property_test.exs
  execute: true

- id: mutagen.scope_resolution.v4
  covers: [mutagen.scope_resolution.r8]
  kind: command
  command: mix test test/mutagen_ex/scope_resolver_test.exs --only atom_safety
  execute: true
```
