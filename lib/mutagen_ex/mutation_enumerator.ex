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
    * `:end_line` / `:end_column` — 1-based EXCLUSIVE end position of the
      `original_ast` expression in the parsed source, computed
      best-effort from AST metadata per
      `mutagen.mutation_enumeration.r8`. Both are `nil` when the
      enumerator could not derive an end position (bare-literal sites
      whose meta comes from a parent operator, some macro-expanded
      forms). When non-nil, callers slice the verbatim `source_text`
      between the leftmost descendant's `{line, column}` and this
      `{end_line, end_column}` to obtain a byte-faithful
      `before_source` per `mutagen.json_schema.r4`.
  """

  @enforce_keys [:id, :file, :line, :column, :mutator, :original_ast, :mutated_ast]
  defstruct [
    :id,
    :file,
    :line,
    :column,
    :mutator,
    :original_ast,
    :mutated_ast,
    end_line: nil,
    end_column: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          file: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          mutator: atom(),
          original_ast: Macro.t(),
          mutated_ast: Macro.t(),
          end_line: pos_integer() | nil,
          end_column: pos_integer() | nil
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

  alias MutagenEx.Ast
  alias MutagenEx.Mutators
  alias MutagenEx.Mutators.Dispatch
  alias MutagenEx.MutationEnumerator.Site
  alias MutagenEx.ScopeResolver.Scope

  @behaviour MutagenEx.Pipeline.EnumeratorFacade

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

  @typedoc "Enumeration error: site cap exceeded (r7)."
  @type error :: {:error, :too_many_sites, map()}

  @doc """
  Enumerate mutation sites for `scope_records` against `ast_cache` and
  `covered_lines`.

  See the module doc for the input/output contract.

  ## Options

    * `:mutators` — list of mutator modules to consult. Defaults to
      `MutagenEx.Mutators.all/0`.
    * `:max_sites` — positive integer cap on the produced sites list
      (per `mutagen.mutation_enumeration.r7`). When the cap is exceeded
      the enumerator returns `{:error, :too_many_sites, details}` instead
      of materialising more sites than requested. Default is unbounded
      (callers that want the cap MUST pass it; the Mix task threads
      `Config.max_sites` in).
    * `:dispatch_mode` — `:head_atom` (default) or `:legacy`. Internal
      test seam exposing how the per-node mutator candidate list is
      computed:

        - `:head_atom` consults
          `MutagenEx.Mutators.Dispatch.mutators_for_node/1` to
          pre-filter the catalog by the node's head atom before
          calling `match?/1` on each (per
          `mutagen.decision.static_mutator_dispatch`). This is the
          production path.
        - `:legacy` calls `match?/1` on every mutator in `:mutators`
          for every node — the pre-dispatch behaviour. ONLY used by
          the head-atom equivalence test
          (`test/mutagen_ex/head_atom_dispatch_test.exs`) to prove the
          two paths produce identical output. NOT a public API; the
          Mix task does not expose this knob.
  """
  @impl MutagenEx.Pipeline.EnumeratorFacade
  @spec enumerate(map(), [Scope.t()], map(), keyword) :: result | error
  def enumerate(ast_cache, scope_records, covered_lines, opts \\ [])
      when is_map(ast_cache) and is_list(scope_records) and is_map(covered_lines) do
    mutators = Keyword.get(opts, :mutators, Mutators.all())
    max_sites = Keyword.get(opts, :max_sites)
    dispatch_mode = Keyword.get(opts, :dispatch_mode, :head_atom)

    unless dispatch_mode in [:head_atom, :legacy] do
      raise ArgumentError,
            "MutagenEx.MutationEnumerator.enumerate/4: " <>
              ":dispatch_mode must be :head_atom or :legacy, got #{inspect(dispatch_mode)}"
    end

    initial = %{sites: [], skipped: [], warnings: []}

    final =
      Enum.reduce(scope_records, initial, fn scope, acc ->
        enumerate_scope(scope, ast_cache, covered_lines, mutators, dispatch_mode, acc)
      end)

    site_count = length(final.sites)

    cond do
      is_integer(max_sites) and site_count > max_sites ->
        # r7: cap is structural — the pipeline aborts before the runner
        # starts. Return the count so the abort-JSON document can include
        # it.
        {:error, :too_many_sites,
         %{
           cap: max_sites,
           count: site_count,
           message:
             "mutation site enumeration produced #{site_count} sites; " <>
               "cap is --max-sites=#{max_sites}. Narrow --scope or raise --max-sites."
         }}

      true ->
        %{
          sites: Enum.reverse(final.sites),
          skipped: Enum.reverse(final.skipped),
          warnings: Enum.reverse(final.warnings)
        }
    end
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
         dispatch_mode,
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
        case Ast.find_module_body(ast, Atom.to_string(module)) do
          :not_found ->
            # The scope record names a module we cannot find in the cached
            # AST — same "programmer error" shape as above. Warn and move on.
            %{acc | warnings: [{:module_not_in_ast, file, module} | acc.warnings]}

          {:ok, body} ->
            covered = Map.get(covered_lines, file, MapSet.new())
            before_count = {length(acc.sites), length(acc.skipped)}

            acc_after = walk_body(body, scope, covered, mutators, dispatch_mode, acc)

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
  defp walk_body(body, scope, covered, mutators, dispatch_mode, acc) do
    walk_tree(
      body,
      _ambient = {nil, 1},
      _context = nil,
      scope,
      covered,
      mutators,
      dispatch_mode,
      acc
    )
  end

  # Pre-order recursion. The visit happens BEFORE descent, which matches
  # `Macro.prewalk` semantics. `ambient` is `{ambient_line, ambient_column}`.
  defp walk_tree(node, ambient, context, scope, covered, mutators, dispatch_mode, acc) do
    acc = try_mutators(node, ambient, context, scope, covered, mutators, dispatch_mode, acc)

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
        acc =
          maybe_walk_node(form, new_ambient, node, scope, covered, mutators, dispatch_mode, acc)

        case args do
          children when is_list(children) ->
            walk_children(
              children,
              new_ambient,
              node,
              scope,
              covered,
              mutators,
              dispatch_mode,
              acc
            )

          _ ->
            acc
        end

      {a, b} ->
        # Two-tuples in AST (e.g. keyword tuples, do/else pairs). Walk
        # both halves under the same ambient — no new positional info to
        # propagate.
        acc =
          walk_tree(
            a,
            ambient,
            %{parent: node, index: 0},
            scope,
            covered,
            mutators,
            dispatch_mode,
            acc
          )

        walk_tree(
          b,
          ambient,
          %{parent: node, index: 1},
          scope,
          covered,
          mutators,
          dispatch_mode,
          acc
        )

      list when is_list(list) ->
        walk_children(list, ambient, list, scope, covered, mutators, dispatch_mode, acc)

      _atom_or_literal ->
        # Leaf — already visited above. Nothing to recurse into.
        acc
    end
  end

  # Walk a list of children left-to-right with a shared ambient.
  defp walk_children(children, ambient, parent, scope, covered, mutators, dispatch_mode, acc)
       when is_list(children) do
    children
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {child, index}, child_acc ->
      walk_tree(
        child,
        ambient,
        %{parent: parent, index: index},
        scope,
        covered,
        mutators,
        dispatch_mode,
        child_acc
      )
    end)
  end

  # The `form` slot of a 3-tuple is usually an atom (e.g. `:def`, `:+`)
  # but can itself be a nested AST node for remote / dynamic calls. Only
  # recurse if it's a non-atom AST node — bare atoms have no further
  # structure and `try_mutators` already had its shot during the parent
  # visit (no mutator in the catalog matches a bare atom).
  defp maybe_walk_node(form, _ambient, _parent, _scope, _covered, _mutators, _dispatch_mode, acc)
       when is_atom(form),
       do: acc

  defp maybe_walk_node(form, ambient, parent, scope, covered, mutators, dispatch_mode, acc) do
    walk_tree(
      form,
      ambient,
      %{parent: parent, index: :form},
      scope,
      covered,
      mutators,
      dispatch_mode,
      acc
    )
  end

  # Try each mutator on a single AST node. A node may match more than one
  # mutator; each matching mutator produces its own site (or skip).
  #
  # Per `mutagen.decision.static_mutator_dispatch`: when `dispatch_mode`
  # is `:head_atom` (the production default), the catalog is pre-filtered
  # by the node's head atom via
  # `MutagenEx.Mutators.Dispatch.mutators_for_node/1`. Mutators whose
  # `match?/1` could not possibly match `node` based on head alone are
  # never asked. Order is preserved relative to `mutators` because
  # Dispatch returns a sub-sequence of `Mutators.all/0`, and we
  # intersect that sub-sequence with `mutators` while keeping
  # `mutators`'s ordering (see `pre_filter_mutators/2`).
  #
  # When `dispatch_mode` is `:legacy`, the pre-filter is skipped and
  # every mutator in `mutators` is asked. This path exists ONLY for the
  # head-atom equivalence test
  # (`test/mutagen_ex/head_atom_dispatch_test.exs`); it is not exposed
  # via the Mix task.
  defp try_mutators(node, ambient, context, scope, covered, mutators, dispatch_mode, acc) do
    candidates = pre_filter_mutators(node, mutators, dispatch_mode)

    Enum.reduce(candidates, acc, fn mutator, inner_acc ->
      try_one_mutator(mutator, node, ambient, context, scope, covered, inner_acc)
    end)
  end

  # Filter `mutators` down to the sub-sequence that could possibly match
  # `node`, preserving the relative order of `mutators`. When mode is
  # `:legacy`, no filtering happens.
  #
  # Correctness: `Dispatch.mutators_for_node/1` returns the full set of
  # candidates ordered as `Mutators.all/0`; we intersect against the
  # caller-supplied `mutators` list (which may itself be a strict
  # subset of `Mutators.all/0`, e.g. arith-only in a unit test) while
  # keeping `mutators`'s order. The result is therefore a sub-sequence
  # of `mutators`, identical in order. This preserves byte-identity of
  # site emission order (r1) when callers pass a non-default
  # `:mutators` list.
  defp pre_filter_mutators(node, mutators, :head_atom) do
    candidate_set = MapSet.new(Dispatch.mutators_for_node(node))
    Enum.filter(mutators, &MapSet.member?(candidate_set, &1))
  end

  defp pre_filter_mutators(_node, mutators, :legacy), do: mutators

  defp try_one_mutator(mutator, node, ambient, context, %Scope{file: file} = _scope, covered, acc) do
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
          run_mutator(mutator, node, context, file, line, column, acc)
      end
    else
      acc
    end
  end

  defp run_mutator(mutator, node, context, file, line, column, acc) do
    mutated = mutator.mutate(node)
    name = mutator.name()
    id = Mutators.site_id(file, node, name)

    validation =
      if contextually_invalid_literal?(name, mutated, context) do
        {:skip, :structurally_invalid}
      else
        mutator.validate(mutated)
      end

    case validation do
      :ok ->
        # Per `mutagen.mutation_enumeration.r8`: derive the exclusive
        # end position of `node` best-effort. Nil when not derivable;
        # the JSON renderer's `before_source` path treats that as the
        # signal to fall back to `Macro.to_string/1`.
        {end_line, end_column} = compute_end_position(node)

        site = %Site{
          id: id,
          file: file,
          line: line,
          column: column,
          mutator: name,
          original_ast: node,
          mutated_ast: mutated,
          end_line: end_line,
          end_column: end_column
        }

        %{acc | sites: [site | acc.sites]}

      {:skip, reason} ->
        entry = %{site_id: id, reason: reason, mutator: name, file: file}
        %{acc | skipped: [entry | acc.skipped]}
    end
  end

  defp contextually_invalid_literal?(:literal, mutated, context) do
    literal_zero?(mutated) and invalid_zero_literal_context?(context)
  end

  defp contextually_invalid_literal?(_name, _mutated, _context), do: false

  defp literal_zero?(0), do: true
  defp literal_zero?({:__block__, meta, [0]}) when is_list(meta), do: true
  defp literal_zero?(_), do: false

  # Capture positional arguments are 1-based. A literal mutation from
  # `&1` to `&0` is therefore structurally invalid and should be skipped
  # before it reaches compile/run classification.
  defp invalid_zero_literal_context?(%{parent: {:&, _meta, [_arg]}, index: 0}), do: true

  # `a..b//0` and `Range.new(a, b, 0)` are invalid range-step forms.
  # Only the third argument is rejected; endpoint literals keep their
  # normal literal mutations.
  defp invalid_zero_literal_context?(%{parent: {:..//, _meta, [_first, _last, _step]}, index: 2}),
    do: true

  defp invalid_zero_literal_context?(%{
         parent:
           {{:., _dot_meta, [{:__aliases__, _alias_meta, [:Range]}, :new]}, _call_meta, args},
         index: 2
       })
       when is_list(args),
       do: true

  defp invalid_zero_literal_context?(_context), do: false

  # Resolve a node's effective `{line, column}` for coverage filtering and
  # for the Site's positional fields. The node's own metadata wins when
  # present; otherwise inherit from the nearest enclosing 3-tuple
  # (`ambient`).
  defp effective_position(node, {ambient_line, ambient_column}) do
    line = Ast.node_line(node) || ambient_line
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
  #
  # `alias_to_module/1`, `find_module_body/2`, and `node_line/1` were
  # lifted to `MutagenEx.Ast` per `mutagen.ast` (mutagen-wrd.25.2). This
  # module routes through that canonical surface. `node_column_or_nil/1`
  # is enumerator-specific (only the ambient-position threading needs
  # column-aware fallback) and stays here.

  # `nil` if the node has no `:column` metadata of its own. Used by
  # `effective_position/2` so missing columns can fall back to the
  # ambient column rather than masking it with `1`.
  defp node_column_or_nil({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :column)
  defp node_column_or_nil(_), do: nil

  # --- end-position derivation (r8) ----------------------------------------
  #
  # Returns `{end_line, end_column}` (exclusive end) for the `original_ast`
  # of a candidate site, or `{nil, nil}` when derivation fails. The render
  # path treats `{nil, nil}` as the signal to fall back to
  # `Macro.to_string/1` for `before_source` (see `mutagen.json_schema.r4`).
  #
  # Strategy (in order of preference):
  #
  #   1. Node meta directly carries `:end_of_expression: [line, column]` —
  #      that position is already the exclusive end.
  #   2. Node meta carries `:closing: [line, column]` — closing is the
  #      position of `)` or `]`; exclusive end is `column + 1`.
  #   3. Node meta carries `:end: [line, column]` — `:end` is the
  #      position of the literal `end` keyword (3 bytes); exclusive end
  #      is `column + 3`.
  #   4. Fallback: walk to the rightmost child whose end position can be
  #      computed from AST alone. For variables `{name, meta, nil}`
  #      where `name` is an atom, the end column is
  #      `column + byte_size(Atom.to_string(name))`. For bare numeric
  #      literals, the end column is `column + byte_size(printed_form)`
  #      where the printed form uses `Integer.to_string/1` or
  #      `Float.to_string/1`. For boolean / nil literals we know the
  #      printed length statically. The walk recurses into structured
  #      children; if no rightmost descendant can be sized, returns
  #      `{nil, nil}` (the fallback path).
  @doc false
  @spec compute_end_position(Macro.t()) :: {pos_integer() | nil, pos_integer() | nil}
  def compute_end_position({_form, meta, _args} = node) when is_list(meta) do
    cond do
      end_of_expr = Keyword.get(meta, :end_of_expression) ->
        {Keyword.get(end_of_expr, :line), Keyword.get(end_of_expr, :column)}

      closing = Keyword.get(meta, :closing) ->
        line = Keyword.get(closing, :line)
        column = Keyword.get(closing, :column)
        if line && column, do: {line, column + 1}, else: walk_for_end(node)

      end_kw = Keyword.get(meta, :end) ->
        line = Keyword.get(end_kw, :line)
        column = Keyword.get(end_kw, :column)
        if line && column, do: {line, column + 3}, else: walk_for_end(node)

      true ->
        walk_for_end(node)
    end
  end

  def compute_end_position(_), do: {nil, nil}

  # Walk rightward through the node's children, returning the
  # `{end_line, end_column}` of the rightmost descendant whose size we
  # can compute. Stops short with `{nil, nil}` if no descendant
  # qualifies OR if the form is one whose printed source has trailing
  # delimiters past its rightmost AST child (e.g. function calls like
  # `foo(x)`: the rightmost child is `x` but the expression ends at
  # `)`). Such forms require explicit `:closing` / `:end` metadata.
  defp walk_for_end({form, _meta, args}) do
    if delimiterless_form?(form) do
      case rightmost_with_size(args) do
        {:ok, line, column} -> {line, column}
        :unknown -> {nil, nil}
      end
    else
      {nil, nil}
    end
  end

  defp walk_for_end(_), do: {nil, nil}

  # A form is "delimiterless" when its source representation ends
  # exactly where its rightmost AST child ends — i.e., no trailing
  # parens, brackets, or `end` keyword. Binary infix operators
  # qualify (the printed form is `{left} {op} {right}`). Function
  # calls, do/end blocks, etc., do NOT qualify and need explicit
  # metadata to size their end.
  defp delimiterless_form?(form) when is_atom(form) do
    form in [
      :+,
      :-,
      :*,
      :/,
      :==,
      :!=,
      :===,
      :!==,
      :<,
      :>,
      :<=,
      :>=,
      :&&,
      :||,
      :and,
      :or,
      :++,
      :--,
      :<>,
      :in,
      :|>,
      :|,
      :=
    ]
  end

  defp delimiterless_form?(_), do: false

  # End position of the LITERAL rightmost child. We require the
  # rightmost child to be sizeable — falling back to the next-rightmost
  # would produce a SHORTER slice than the actual expression (e.g.
  # `b != 0` would slice to just `b` because `0` is a bare literal
  # with no meta). That silent truncation is worse than declaring
  # "unknown" and letting the renderer fall back to Macro.to_string.
  defp rightmost_with_size(nil), do: :unknown
  defp rightmost_with_size([]), do: :unknown

  defp rightmost_with_size(args) when is_list(args) do
    case :lists.reverse(args) do
      [last | _] -> end_position_of_leaf_or_node_result(last)
      _ -> :unknown
    end
  end

  defp rightmost_with_size(_other), do: :unknown

  defp end_position_of_leaf_or_node_result(child) do
    case end_position_of_leaf_or_node(child) do
      {:ok, line, col} -> {:ok, line, col}
      :unknown -> :unknown
    end
  end

  # End position of a single AST term, considering both leaves
  # (bare literals, variables) and structured nodes (recurse via
  # `compute_end_position/1`).
  defp end_position_of_leaf_or_node({name, meta, nil})
       when is_atom(name) and is_list(meta) do
    # Variable: `{:a, [line: L, column: C], nil}`. Size = atom name's
    # byte length.
    line = Keyword.get(meta, :line)
    column = Keyword.get(meta, :column)

    if line && column do
      {:ok, line, column + byte_size(Atom.to_string(name))}
    else
      :unknown
    end
  end

  defp end_position_of_leaf_or_node({_form, meta, _args} = node) when is_list(meta) do
    case compute_end_position(node) do
      {nil, nil} -> :unknown
      {line, col} when is_integer(line) and is_integer(col) -> {:ok, line, col}
    end
  end

  defp end_position_of_leaf_or_node(_other) do
    # Bare literals (integers, atoms, floats, booleans) and other
    # leaves don't carry their own metadata; we cannot honestly place
    # their end position without source-text scanning, which is out
    # of scope for the enumerator (the runner ticket calls this out
    # explicitly).
    :unknown
  end
end
