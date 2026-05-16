# wrd25_200sites bench fixture

Self-contained Elixir source tree used by the `wrd25` perf bench harness
(`priv/helper_scripts/bench_ast_perf.exs`, S6) and by the determinism
safety-net test (`test/mutagen_ex/determinism_test.exs`, S1+).

## Why this exists

The `.25` epic refactors hot AST paths (helper lift, batched prewalk,
cached `.beam` restore, unified AST cache). The bench harness needs a
non-trivial, deterministic input to measure before/after wall-clock and
memory. The lane fixture (`test/fixtures/lane_project/`) is too small
(~20 sites) to surface the kind of allocation pressure the refactor is
designed to relieve.

Target: roughly 200 mutation sites at the default mutator catalog
(arith, boolean, compare, case_drop, literal, etc.). The fixture is
intentionally synthetic — no library code, no third-party dependencies,
no test framework cleverness — so the bench is measuring `mutagen`
work, not collaborator overhead.

## Layout

```
wrd25_200sites/
  lib/
    arith_dense.ex       # heavy `+ - * /` density
    boolean_dense.ex     # `and / or / not / && / || / !` density
    case_dense.ex        # case-clause-heavy
    mixed_a.ex           # representative app-shaped module 1
    mixed_b.ex           # representative app-shaped module 2
  test/
    arith_dense_test.exs
    boolean_dense_test.exs
    case_dense_test.exs
    mixed_a_test.exs
    mixed_b_test.exs
```

Each `lib/` module has a colocated test that pins enough behaviour
that mutations actually kill — without that, the bench would measure
the survivor branch only (no `:killed` paths) and miss most of the
runtime cost.

## Stability

This tree is part of the .25 contract:

  * Modules and tests are versioned with the epic. If you change them,
    update the bench numbers in the epic's PR.
  * `mix mutagen --scope <module>` over this tree at the default
    catalog should produce a stable site count run-to-run on the same
    Elixir/OTP version (mutagen.mutation_pipeline.r15).
