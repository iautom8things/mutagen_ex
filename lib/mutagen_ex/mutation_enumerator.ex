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
  defp enumerate_scope(
         %Scope{file: file, module: module} = scope,
         ast_cache,
         covered_lines,
         mutators,
         acc
       ) do
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

  # Walk a module body AST.
  #
  # Implementation note (bw mutagen-wrd.16): we used to drive this with
  # `Macro.prewalk/3`, which is deterministic and pleasant — but it has no
  # mechanism for threading "ambient" parent state downward. The literal
  # mutator surfaced the cost: Elixir 1.19's parser does NOT wrap atomic
  # literals (e.g. the `0` in `n > 0`, the `1` in `do: 1`, bare booleans
  # in boolean operands, case-clause-head literals) in
  # `{:__block__, meta, [value]}` 3-tuples — those are children of their
  # parent operator / clause-head 3-tuple and carry no metadata of their
  # own. `node_line/1` returns nil for bare literals; the old
  # `is_nil(line) -> acc` filter in `try_one_mutator/5` dropped every such
  # site even when the parent operator's line was covered.
  #
  # We picked parent-line-inheritance over a pre-pass AST rewrite (the
  # other resolution path the ticket listed) because:
  #
  #   1. It keeps the AST in the cache byte-identical to what the runner
  #      will restore (r6's "same AST enumerated is the AST restored"
  #      invariant). A pre-pass rewrite would mutate the cache value.
  #   2. It's localised: one change in the walker, no churn through the
  #      mutator catalog. Other mutators that match bare values in the
  #      future automatically inherit the same line-coverage behaviour.
  #   3. The literal mutator already handles both bare and `__block__`-
  #      wrapped shapes (bw mutagen-wrd.15); adding a normaliser would be
  #      redundant with that work.
  #
  # The walker is a hand-rolled pre-order recursion that mirrors
  # `Macro.prewalk`'s left-to-right depth-first order (so determinism r1
  # is preserved) but additionally threads an `ambient` `{line, column}`
  # tuple downward. When `try_one_mutator/5` is consulted for a node, it
  # uses the node's own positional metadata if present, else the ambient
  # tuple from the nearest enclosing 3-tuple.
  defp walk_body(body, scope, covered, mutators, acc) do
    walk_tree(body, _ambient = {nil, 1}, scope, covered, mutators, acc)
  end

  # Pre-order recursion. The visit happens BEFORE descent, which matches
  # `Macro.prewalk` semantics. `ambient` is `{ambient_line, ambient_column}`.
  defp walk_tree(node, ambient, scope, covered, mutators, acc) do
    acc = try_mutators(node, ambient, scope, covered, mutators, acc)

    case node do
      {form, meta, args} when is_list(meta) ->
        # Update ambient from this node's own metadata (if any) before
        # descending. Children that lack their own :line will inherit this
        # node's line. Falls back to the prior ambient when meta is
        # incomplete.
        new_ambient = update_ambient(meta, ambient)
        # The first element of a 3-tuple (`form`) is usually an atom
        # (e.g. `:def`, `:+`) but can itself be a nested AST node for
        # remote / dynamic calls. We recurse into both the form (when it
        # is structured) and the args. Variables have shape
        # `{name, meta, nil}` where `args` is `nil` (no children); list-
        # valued args are children to walk.
        acc = maybe_walk_node(form, new_ambient, scope, covered, mutators, acc)

        case args do
          children when is_list(children) ->
            walk_children(children, new_ambient, scope, covered, mutators, acc)

          _ ->
            acc
        end

      {a, b} ->
        # Two-tuples in AST (e.g. keyword tuples, do/else pairs). Walk
        # both halves under the same ambient — no new positional info to
        # propagate.
        acc = walk_tree(a, ambient, scope, covered, mutators, acc)
        walk_tree(b, ambient, scope, covered, mutators, acc)

      list when is_list(list) ->
        walk_children(list, ambient, scope, covered, mutators, acc)

      _atom_or_literal ->
        # Leaf — already visited above. Nothing to recurse into.
        acc
    end
  end

  # Walk a list of children left-to-right with a shared ambient.
  defp walk_children(children, ambient, scope, covered, mutators, acc) when is_list(children) do
    Enum.reduce(children, acc, fn child, child_acc ->
      walk_tree(child, ambient, scope, covered, mutators, child_acc)
    end)
  end

  # The `form` slot of a 3-tuple is usually an atom (e.g. `:def`, `:+`)
  # but can itself be a nested AST node for remote / dynamic calls. Only
  # recurse if it's a non-atom AST node — bare atoms have no further
  # structure and `try_mutators` already had its shot during the parent
  # visit (no mutator in the catalog matches a bare atom).
  defp maybe_walk_node(form, _ambient, _scope, _covered, _mutators, acc) when is_atom(form),
    do: acc

  defp maybe_walk_node(form, ambient, scope, covered, mutators, acc) do
    walk_tree(form, ambient, scope, covered, mutators, acc)
  end

  # Try each mutator on a single AST node. A node may match more than one
  # mutator; each matching mutator produces its own site (or skip).
  defp try_mutators(node, ambient, scope, covered, mutators, acc) do
    Enum.reduce(mutators, acc, fn mutator, inner_acc ->
      try_one_mutator(mutator, node, ambient, scope, covered, inner_acc)
    end)
  end

  defp try_one_mutator(mutator, node, ambient, %Scope{file: file} = _scope, covered, acc) do
    if mutator.match?(node) do
      {line, column} = effective_position(node, ambient)

      cond do
        # Per r2: filter by covered_lines BEFORE consulting validate/1.
        # A nil line means neither the node nor any enclosing ancestor
        # carried positional metadata — extremely rare in real ASTs, and
        # the right behaviour is still "uncovered" (we cannot honestly
        # attribute the site to a source line).
        is_nil(line) ->
          acc

        not MapSet.member?(covered, line) ->
          acc

        true ->
          run_mutator(mutator, node, file, line, column, acc)
      end
    else
      acc
    end
  end

  defp run_mutator(mutator, node, file, line, column, acc) do
    mutated = mutator.mutate(node)
    name = mutator.name()
    id = Mutators.site_id(file, node, name)

    case mutator.validate(mutated) do
      :ok ->
        site = %Site{
          id: id,
          file: file,
          line: line,
          column: column,
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

  # Resolve a node's effective `{line, column}` for coverage filtering and
  # for the Site's positional fields. The node's own metadata wins when
  # present; otherwise inherit from the nearest enclosing 3-tuple
  # (`ambient`).
  defp effective_position(node, {ambient_line, ambient_column}) do
    line = node_line(node) || ambient_line
    column = node_column_or_nil(node) || ambient_column || 1
    {line, column}
  end

  # Pull `{line, column}` out of a 3-tuple's metadata and slot them into
  # the ambient tuple. Missing keys fall back to the prior ambient (we
  # don't want a 3-tuple without `:column` to reset ambient_column to
  # nil — the closest known column is still useful).
  defp update_ambient(meta, {prior_line, prior_column}) when is_list(meta) do
    line = Keyword.get(meta, :line, prior_line)
    column = Keyword.get(meta, :column, prior_column)
    {line, column}
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

  # `nil` if the node has no `:column` metadata of its own. Used by
  # `effective_position/2` so missing columns can fall back to the
  # ambient column rather than masking it with `1`.
  defp node_column_or_nil({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :column)
  defp node_column_or_nil(_), do: nil
end
