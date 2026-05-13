# mutagen.test_selection — `--tests` target → ExUnit filter

Translates user-supplied `--tests` targets into the `{include, exclude, files}`
shape that ExUnit's filter system expects.

## Intent

Users cite tests at three granularities:

- A whole test file: `test/foo_test.exs`
- A specific test inside a file: `test/foo_test.exs:42`
- A tag: `tag:integration`

The cited tests are the ones run for baseline + coverage + every mutation.
Resolution happens via AST walks of test files — never by loading and
introspecting ExUnit's in-memory module registry — so the selector remains
unit-testable without driving the harness.

## Out of scope for this subject

- Running the tests (see [mutagen.mutation_pipeline](mutation_pipeline.spec.md)
  and [mutagen.coverage](coverage.spec.md)).
- Coverage attribution (see [mutagen.coverage](coverage.spec.md)).

```spec-meta
id: mutagen.test_selection
kind: module
status: draft
summary: Resolves --tests targets to ExUnit-shaped filter records via AST walking.
surface:
  - lib/mutagen_ex/test_selector.ex
decisions: []
```

```spec-requirements
- id: mutagen.test_selection.r1
  priority: must
  statement: |
    A target of shape `<path>_test.exs` resolves to `{include: [], exclude:
    [:test], files: [<path>_test.exs]}`. ExUnit's "include + exclude :test"
    pattern is the documented way to run only the files named.

- id: mutagen.test_selection.r2
  priority: must
  statement: |
    A target of shape `<path>_test.exs:<line>` resolves to `{include:
    [{:location, {<path>_test.exs, <line>}}], exclude: [:test], files:
    [<path>_test.exs]}`.

- id: mutagen.test_selection.r3
  priority: must
  statement: |
    A target of shape `tag:<name>` resolves to `{include: [<name>], exclude:
    [:test], files: <walk_of_test_dir>}` where `<walk_of_test_dir>` is the
    list of test files determined by AST-walking `test/**/*_test.exs` and
    keeping those that contain at least one `@tag :<name>` attribute on a
    `test` or `describe` block.

- id: mutagen.test_selection.r4
  priority: must
  statement: |
    Tag resolution does not load any test module. It uses
    `Code.string_to_quoted/2` to scan each candidate file. Loading the test
    module would interfere with mutagen.mutation_pipeline's state hygiene
    contract.

- id: mutagen.test_selection.r5
  priority: must
  statement: |
    If the resolver's resolution produces zero matching tests (e.g., a
    `tag:unused` that matches nothing, or a `:line` that points outside any
    test block), it returns a structured error with `reason:
    :no_tests_match`.

- id: mutagen.test_selection.r6
  priority: must
  statement: |
    Multiple `--tests` targets compose by union: the final filter's `files`
    list and `include` list are the union of each target's contribution.
    Duplicates are deduplicated.
```

```spec-scenarios
- id: mutagen.test_selection.s1
  covers: [mutagen.test_selection.r1]
  given: A target `test/foo_test.exs`.
  when: The selector resolves it.
  then: |
    Result is `%TestFilter{include: [], exclude: [:test], files:
    ["test/foo_test.exs"]}`.

- id: mutagen.test_selection.s2
  covers: [mutagen.test_selection.r2]
  given: A target `test/foo_test.exs:42`.
  when: The selector resolves it.
  then: |
    Result is `%TestFilter{include: [{:location, {"test/foo_test.exs",
    42}}], exclude: [:test], files: ["test/foo_test.exs"]}`.

- id: mutagen.test_selection.s3
  covers: [mutagen.test_selection.r3, mutagen.test_selection.r4]
  given: |
    Two test files: `test/a_test.exs` contains `@tag :slow` on one test,
    `test/b_test.exs` has no `@tag :slow`.
  when: The selector resolves `tag:slow`.
  then: |
    Result `files` contains `test/a_test.exs` and NOT `test/b_test.exs`.
    `include` is `[:slow]`. The selector did not call `Code.require_file/1`
    or `Code.eval_*` on either file.

- id: mutagen.test_selection.s4
  covers: [mutagen.test_selection.r5]
  given: |
    The project has no `@tag :unused_tag` anywhere.
  when: The selector resolves `tag:unused_tag`.
  then: |
    Result is `{:error, reason: :no_tests_match, target: "tag:unused_tag"}`.

- id: mutagen.test_selection.s5
  covers: [mutagen.test_selection.r6]
  given: |
    Targets `test/a_test.exs` and `test/b_test.exs`.
  when: The selector resolves both.
  then: |
    Result `files` is `["test/a_test.exs", "test/b_test.exs"]` (order
    irrelevant for the contract; deduplicated if user passed the same target
    twice).
```

```spec-verification
- id: mutagen.test_selection.v1
  covers: [mutagen.test_selection.r1, mutagen.test_selection.r2, mutagen.test_selection.r3, mutagen.test_selection.r6]
  kind: command
  command: mix test test/mutagen_ex/test_selector_test.exs
  execute: false

- id: mutagen.test_selection.v2
  covers: [mutagen.test_selection.r4]
  kind: source_file
  source_file: test/mutagen_ex/test_selector_test.exs
  execute: false

- id: mutagen.test_selection.v3
  covers: [mutagen.test_selection.r5]
  kind: command
  command: mix test test/mutagen_ex/test_selector_test.exs --only no_match_cases
  execute: false
```
