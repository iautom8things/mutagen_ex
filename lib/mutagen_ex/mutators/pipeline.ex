defmodule MutagenEx.Mutators.Pipeline do
  @moduledoc """
  Reorders two adjacent `|>` segments.

  Per `mutagen.mutators` catalog entry 7.

  ## AST shape

  `a |> b() |> c()` parses left-associative:

      {:|>, _, [{:|>, _, [a, b_call]}, c_call]}

  We rewrite the outer pipe so that `a |> b() |> c()` becomes
  `a |> c() |> b()` — i.e. swap the two pipe stages while keeping the
  initial value `a`.

  ## Validation

  * `:structurally_invalid` — `match?/1` already rules out single-stage
    pipelines and non-pipe nodes; if `validate/1` somehow sees one it skips.
  * `:no_op_shadowed` — when the two function call segments are textually
    identical (`a |> f() |> f()`) the reorder is a no-op. Detected by
    structural equality of the normalised AST of the two call segments.

  Reorder symmetry: applying `mutate/1` twice on a two-stage pipe restores
  the original. The property test exercises this for two-stage pipes.
  """

  @behaviour MutagenEx.Mutators

  alias MutagenEx.Mutators

  @impl true
  def match?({:|>, _meta, [{:|>, _, [_initial, _inner]}, _outer]}), do: true
  def match?(_), do: false

  @impl true
  def name, do: :pipeline

  @impl true
  def mutate({:|>, outer_meta, [{:|>, inner_meta, [initial, inner_call]}, outer_call]}) do
    {:|>, outer_meta, [{:|>, inner_meta, [initial, outer_call]}, inner_call]}
  end

  @impl true
  def validate({:|>, _outer_meta, [{:|>, _inner_meta, [_initial, inner_call]}, outer_call]}) do
    if Mutators.normalize(inner_call) == Mutators.normalize(outer_call) do
      {:skip, :no_op_shadowed}
    else
      :ok
    end
  end

  def validate(_), do: {:skip, :structurally_invalid}
end
