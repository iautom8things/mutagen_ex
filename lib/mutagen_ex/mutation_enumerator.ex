defmodule MutagenEx.MutationEnumerator.Site do
  @moduledoc """
  A single mutation site emitted by `MutagenEx.MutationEnumerator`.

  Materialises the `t:MutagenEx.Types.mutation_site/0` type. Stored as a
  struct (rather than a plain map) so pattern matches catch shape drift at
  compile time — the JSON reporter, the mutation runner, and the verifier
  all destructure these records.

  Fields:

    * `:id` — content-addressed site ID
      (`"{file}:{ast_hash}:{mutator_name}"`) per
      `mutagen.decision.content_addressed_ids`.
    * `:file` — relative path the site lives in, as taken from the
      `MutagenEx.ScopeResolver.Scope` it came from.
    * `:line` / `:column` — 1-based source coordinates of the original AST
      node, for human display only; they do **not** participate in `:id`.
    * `:mutator` — the snake_case atom name of the mutator that produced
      this site (e.g. `:arith`).
    * `:original_ast` — the unmodified AST node, kept so the runner can
      restore it byte-for-byte at compile time (the state-drift-free
      restore invariant in `mutagen.mutation_enumeration.r6`).
    * `:mutated_ast` — the swapped AST node returned by the mutator's
      `mutate/1`.
  """

  @enforce_keys [:id, :file, :line, :column, :mutator, :original_ast, :mutated_ast]
  defstruct [:id, :file, :line, :column, :mutator, :original_ast, :mutated_ast]

  @type t :: %__MODULE__{
          id: String.t(),
          file: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          mutator: atom(),
          original_ast: Macro.t(),
          mutated_ast: Macro.t()
        }
end

defmodule MutagenEx.MutationEnumerator do
  @moduledoc """
  Walks the in-scope ASTs from the AST cache and produces a deterministic,
  ordered list of `%MutagenEx.MutationEnumerator.Site{}` records, plus a
  parallel `skipped` list and a `warnings` list.

  Implements the behavioural contract in
  [`mutagen.mutation_enumeration`](../../.spec/specs/mutation_enumeration.spec.md).

  ## Inputs

    * `ast_cache` — `%{file => ast}`. The pre-parsed AST for each file. Per
      r6 this is the **only** source of AST data: the enumerator never
      opens a file. The runner relies on this so the AST that was
      enumerated is the exact AST that gets restored on rollback.
    * `scope_records` — `[%MutagenEx.ScopeResolver.Scope{}]` produced by
      `MutagenEx.ScopeResolver.resolve/2`. Each names a file, an inclusive
      line range, and a module — together they pin down the `defmodule`
      sub-tree to walk.
    * `covered_lines` — `%{file => MapSet.t(pos_integer())}`. The set of
      lines the cited tests actually executed. A node whose `:line` meta
      falls outside this set is filtered out before any mutator's
      `validate/1` runs (r2).

  ## Output

  Returns `%{sites: [Site.t()], skipped: [skipped_entry()], warnings:
  [warning()]}`.

    * `:sites` is the ordered, deterministic list of mutation sites.
      Determinism (r1) is by construction: scope records are processed in
      input order, AST traversal is `Macro.prewalk` (left-to-right depth-
      first), and within a node mutators are tried in
      `MutagenEx.Mutators.all/0`'s canonical order.
    * `:skipped` is the parallel list of `{:skip, reason}` outcomes (r3).
      Each entry is `%{site_id: id, reason: atom, mutator: name, file:
      path}`.
    * `:warnings` carries module-scoped advisories. Currently the only
      warning is `{:no_mutation_candidates, module}` from r5 (a scope that
      produced zero sites AND zero skipped entries — e.g. a behaviour-only
      module).

  ## Opts

    * `:mutators` — list of mutator modules to consult. Defaults to
      `MutagenEx.Mutators.all/0`. Exposed so unit tests can drive the
      enumerator against a smaller, deterministic subset (e.g. arith-only)
      without bringing the whole catalog into a fixture.

  ## Determinism contract (r1)

  Given a fixed input tuple `{ast_cache, scope_records, covered_lines}`,
  the output is byte-identical across runs of the same Elixir/OTP version.
  Specifically:

    * scope records are walked in input order;
    * within a scope, the AST is walked by `Macro.prewalk/2` which is
      deterministic for a given AST;
    * within a node, mutators are tried in `Mutators.all/0` order;
    * a node that matches two mutators produces two sites, in that order;
    * site IDs are `:erlang.phash2`-based and stable under formatting
      (`mutagen.decision.content_addressed_ids`).

  The property test exercises this on randomly generated input tuples.
  """

  alias MutagenEx.Mutators
  alias MutagenEx.MutationEnumerator.Site
  alias MutagenEx.ScopeResolver.Scope

  @typedoc "Skip-tracked site: see r3 and `mutagen.decision.validate_predicates`."
  @type skipped_entry :: %{
          site_id: String.t(),
          reason: atom(),
          mutator: atom(),
          file: String.t()
        }

  @typedoc "Enumeration warning. Currently only the empty-scope variant (r5)."
  @type warning :: {:no_mutation_candidates, module()}

  @typedoc "Enumeration result."
  @type result :: %{
          sites: [Site.t()],
          skipped: [skipped_entry()],
          warnings: [warning()]
        }

  @doc """
  Enumerate mutation sites for `scope_records` against `ast_cache` and
  `covered_lines`.

  See the module doc for the input/output contract.
  """
  @spec enumerate(map(), [Scope.t()], map(), keyword) :: result
  def enumerate(ast_cache, scope_records, covered_lines, opts \\ [])
      when is_map(ast_cache) and is_list(scope_records) and is_map(covered_lines) do
    mutators = Keyword.get(opts, :mutators, Mutators.all())

    initial = %{sites: [], skipped: [], warnings: []}

    final =
      Enum.reduce(scope_records, initial, fn scope, acc ->
        enumerate_scope(scope, ast_cache, covered_lines, mutators, acc)
      end)

    %{
      sites: Enum.reverse(final.sites),
      skipped: Enum.reverse(final.skipped),
      warnings: Enum.reverse(final.warnings)
    }
  end

  # Walk one scope record. Pulls the AST for the scope's file out of the
  # cache, narrows to the matching `defmodule` body (r4), runs each
  # qualifying node through the mutator catalog. If the walk produces no
  # sites AND no skips, emit the no-mutation-candidates warning (r5).
  defp enumerate_scope(%Scope{file: file, module: module} = scope, ast_cache, covered_lines, mutators, acc) do
    case Map.fetch(ast_cache, file) do
      :error ->
        # No AST entry for this file in the cache. We surface this as a
        # warning rather than crashing — the caller (S5 pipeline) populates
        # the cache and is responsible for ensuring scope files are present;
        # a missing entry here is a programmer error, but we keep
        # enumeration moving for the remaining scope records.
        %{acc | warnings: [{:ast_cache_miss, file, module} | acc.warnings]}

      {:ok, ast} ->
        case find_module_body(ast, module) do
          :not_found ->
            # The scope record names a module we cannot find in the cached
            # AST — same "programmer error" shape as above. Warn and move on.
            %{acc | warnings: [{:module_not_in_ast, file, module} | acc.warnings]}

          {:ok, body} ->
            covered = Map.get(covered_lines, file, MapSet.new())
            before_count = {length(acc.sites), length(acc.skipped)}

            acc_after = walk_body(body, scope, covered, mutators, acc)

            if {length(acc_after.sites), length(acc_after.skipped)} == before_count do
              # Scope produced nothing — neither sites nor skips. Warn per r5.
              %{acc_after | warnings: [{:no_mutation_candidates, module} | acc_after.warnings]}
            else
              acc_after
            end
        end
    end
  end

  # Walk a module body AST. For each node, try each mutator in catalog
  # order. `Macro.prewalk/3` gives us a deterministic traversal; the order
  # of nested children matches Elixir's own ordering.
  defp walk_body(body, scope, covered, mutators, acc) do
    {_, final} =
      Macro.prewalk(body, acc, fn node, inner_acc ->
        new_acc = try_mutators(node, scope, covered, mutators, inner_acc)
        {node, new_acc}
      end)

    final
  end

  # Try each mutator on a single AST node. A node may match more than one
  # mutator; each matching mutator produces its own site (or skip).
  defp try_mutators(node, scope, covered, mutators, acc) do
    Enum.reduce(mutators, acc, fn mutator, inner_acc ->
      try_one_mutator(mutator, node, scope, covered, inner_acc)
    end)
  end

  defp try_one_mutator(mutator, node, %Scope{file: file} = _scope, covered, acc) do
    if mutator.match?(node) do
      line = node_line(node)

      cond do
        # Per r2: filter by covered_lines BEFORE consulting validate/1.
        # A nil line means the node carries no positional metadata (rare —
        # mostly small literal subterms). We treat absent line as
        # "uncovered" so the enumerator stays honest: if we cannot
        # attribute the node to a source line, we cannot claim a test
        # exercises it.
        is_nil(line) ->
          acc

        not MapSet.member?(covered, line) ->
          acc

        true ->
          run_mutator(mutator, node, file, line, acc)
      end
    else
      acc
    end
  end

  defp run_mutator(mutator, node, file, line, acc) do
    mutated = mutator.mutate(node)
    name = mutator.name()
    id = Mutators.site_id(file, node, name)

    case mutator.validate(mutated) do
      :ok ->
        site = %Site{
          id: id,
          file: file,
          line: line,
          column: node_column(node),
          mutator: name,
          original_ast: node,
          mutated_ast: mutated
        }

        %{acc | sites: [site | acc.sites]}

      {:skip, reason} ->
        entry = %{site_id: id, reason: reason, mutator: name, file: file}
        %{acc | skipped: [entry | acc.skipped]}
    end
  end

  # --- AST helpers ----------------------------------------------------------

  # Locate the body AST for `defmodule mod do ... end` inside an AST. This
  # is r4: enumeration walks only the named module's subtree; sibling
  # `defmodule` blocks in the same file are not visited.
  defp find_module_body(ast, target_mod) do
    {_ast, acc} =
      Macro.prewalk(ast, :not_found, fn
        {:defmodule, _meta, [alias_ast, [do: body]]} = node, :not_found ->
          case alias_to_module(alias_ast) do
            ^target_mod -> {node, {:ok, body}}
            _ -> {node, :not_found}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp alias_to_module({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      Module.concat(parts)
    else
      nil
    end
  end

  defp alias_to_module(mod) when is_atom(mod), do: mod
  defp alias_to_module(_), do: nil

  defp node_line({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line)
  defp node_line(_), do: nil

  defp node_column({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :column, 1)
  defp node_column(_), do: 1
end
