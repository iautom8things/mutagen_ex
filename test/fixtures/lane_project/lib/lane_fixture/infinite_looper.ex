defmodule LaneFixture.InfiniteLooper do
  @moduledoc """
  Recursive function whose mutation creates a deterministic infinite loop.

  Exercises `mutagen.mutation_pipeline.r4` / `r5` (`:timeout` classification).
  The verification target says "`infinite_looper.ex` mutation classifies
  as `:timeout`" — what matters is that AT LEAST ONE mutation produces
  a deterministic infinite loop and is therefore classified `:timeout`
  by the per-site timeout wrapper.

  ## Deterministic trigger

  We use `:arith` against the recursive descent: `count_down(n - 1)` flips
  to `count_down(n + 1)`. Starting from any positive integer, the call
  diverges away from the base case (`0`) forever. The `case` head's
  `n > 0` guard remains true on each iteration, so no clause-miss
  exception fires — the loop is unbounded.

  Per the S7 ticket's risk note ("infinite_looper.ex's deterministic
  infinite-loop mutation is a `case` clause drop on a recursive
  function's base case"), the original plan was `:case_drop`. In
  practice, `:case_drop` on this module's `case` removes the BASE case
  (the last clause), which leaves the recursive clause whose guard
  rejects n=0 — that raises a `CaseClauseError` and the mutation
  classifies as `:killed`, not `:timeout`. The `:arith` trigger gives
  the same deterministic infinite recursion without the false signal.

  This is the documented contract, not a deviation: see
  `mutagen.mutators.r8` and `mutagen.mutation_pipeline.r5` for the
  classification rule, and `mutagen.mutators` catalog entry 6 for the
  fixture-authoring guidance that points :case_drop fixtures at :arith.
  """

  def count_down(n) when is_integer(n) do
    case n do
      n when n > 0 -> count_down(n - 1)
      0 -> :done
    end
  end
end
