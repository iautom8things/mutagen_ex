defmodule MutagenEx.MutationEnumerator.Site do
  @moduledoc """
  A single mutation site emitted by `MutagenEx.MutationEnumerator`.

  Materialises the `t:MutagenEx.Types.mutation_site/0` type. Stored as a
  struct (rather than a plain map) so pattern matches catch shape drift at
  compile time — the JSON reporter, the mutation runner, and the verifier
  all destructure these records.

  Fields:

    * `:id` — scheme 2 site ID
      (`"{file}:{hash}:{mutator_name}"`) per
      `mutagen.decision.mutation_id_scheme_2`.
    * `:path` — steps from the file AST root to the original node.
    * `:function` — enclosing definition as `Mod.fun/arity`, or `nil`.
    * `:file` — project-relative source path taken from the
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

  @enforce_keys [:id, :file, :line, :column, :mutator, :original_ast, :mutated_ast, :path]
  defstruct [
    :id,
    :file,
    :line,
    :column,
    :mutator,
    :original_ast,
    :mutated_ast,
    :path,
    function: nil,
    end_line: nil,
    end_column: nil
  ]

  @type path_step ::
          :form | :left | :right | {:arg, non_neg_integer()} | {:elem, non_neg_integer()}

  @type t :: %__MODULE__{
          id: String.t(),
          file: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          mutator: atom(),
          original_ast: Macro.t(),
          mutated_ast: Macro.t(),
          path: [path_step()],
          function: String.t() | nil,
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

    * `ast_cache` — the pre-parsed AST for each file, with source text. Per
      r6 this is the **only** source of AST data: the enumerator never
      opens a file. The runner relies on this so the AST that was
      enumerated is the exact AST that gets restored on rollback.
    * `scope_records` — `[%MutagenEx.ScopeResolver.Scope{}]` produced by
      `MutagenEx.ScopeResolver.resolve/2`. Each names a file, an inclusive
      line range, module and optional function to select from the file.
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
    * within a scope, sites follow the AST's depth-first walk order;
    * within a node, mutators are tried in `Mutators.all/0` order;
    * a node that matches two mutators produces two sites, in that order;
    * site IDs use lexical occurrence counts and stay stable under formatting
      (`mutagen.decision.mutation_id_scheme_2`).

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

    scopes = scope_records |> Enum.uniq() |> Enum.with_index()

    by_file =
      scopes
      |> Enum.group_by(fn {scope, _rank} -> scope.file end)
      |> Map.new(fn {file, file_scopes} ->
        {file,
         enumerate_file(file, file_scopes, ast_cache, covered_lines, mutators, dispatch_mode)}
      end)

    final =
      Enum.reduce(scopes, %{sites: [], skipped: [], warnings: []}, fn {scope, rank}, acc ->
        append_scope(scope, rank, Map.fetch!(by_file, scope.file), acc)
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

  # Count occurrences in file order before applying scope or coverage filters.
  defp enumerate_file(file, scopes, ast_cache, covered_lines, mutators, dispatch_mode) do
    with {:ok, entry} <- Map.fetch(ast_cache, file) do
      ast = cached_ast(entry)

      env = %{
        file: file,
        by_module: Enum.group_by(scopes, fn {scope, _rank} -> scope.module end),
        covered: Map.get(covered_lines, file, MapSet.new()),
        mutators: mutators,
        dispatch_mode: dispatch_mode,
        modules: Ast.module_index(ast),
        module_key: nil,
        statement: nil,
        enclosing: nil,
        quoted: false,
        scopes: [],
        path: []
      }

      acc = %{ordinals: %{}, scopes: %{}, sites: %{}, skipped: %{}}
      walked = walk_tree(ast, {nil, 1}, nil, env, acc)
      {:ok, Map.take(walked, [:scopes, :sites, :skipped])}
    end
  end

  defp cached_ast({ast, source}) when is_binary(source), do: ast
  defp cached_ast(ast), do: ast

  defp append_scope(%Scope{file: file, module: module}, _rank, :error, acc) do
    %{acc | warnings: [{:ast_cache_miss, file, module} | acc.warnings]}
  end

  defp append_scope(%Scope{file: file, module: module}, rank, {:ok, walked}, acc) do
    case Map.get(walked.scopes, rank) do
      nil ->
        %{acc | warnings: [{:module_not_in_ast, file, module} | acc.warnings]}

      :empty ->
        %{acc | warnings: [{:no_mutation_candidates, module} | acc.warnings]}

      :matched ->
        %{
          acc
          | sites: Map.get(walked.sites, rank, []) ++ acc.sites,
            skipped: Map.get(walked.skipped, rank, []) ++ acc.skipped
        }
    end
  end

  defp walk_tree({kind, meta, [name | _]} = node, ambient, context, %{quoted: false} = env, acc)
       when kind in [:defmodule, :defprotocol, :defimpl] do
    case Map.get(env.modules, node) do
      {modules, body, path} ->
        acc = try_mutators(node, ambient, context, env, acc)
        position = update_ambient(meta, ambient)
        scopes = Enum.flat_map(modules, &Map.get(env.by_module, &1, []))

        acc =
          Enum.reduce(scopes, acc, fn {_scope, rank}, acc ->
            %{acc | scopes: Map.put_new(acc.scopes, rank, :empty)}
          end)

        module = Ast.single_module(modules)

        module_key =
          case modules do
            [] -> {:dynamic_module, env.module_key, Mutators.identity_node(name)}
            [_] -> module
            _ -> modules
          end

        body_env = %{
          env
          | module_key: module_key,
            enclosing: nil,
            scopes: Enum.sort_by(scopes ++ env.scopes, &elem(&1, 1)),
            path: Enum.reverse(path, env.path)
        }

        walk_module_body(body, position, body_env, acc)

      nil ->
        walk_node(node, ambient, context, env, acc)
    end
  end

  defp walk_tree(node, ambient, context, env, acc) do
    walk_node(node, ambient, context, env, acc)
  end

  defp walk_module_body({:__block__, meta, [_, _ | _] = args} = block, ambient, env, acc) do
    position = update_ambient(meta, ambient)
    acc = try_mutators(block, ambient, nil, %{env | statement: :block}, acc)

    args
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {child, index}, acc ->
      child_env = %{env | statement: statement_head(child), path: [{:arg, index} | env.path]}
      walk_tree(child, position, %{parent: block, index: index}, child_env, acc)
    end)
  end

  defp walk_module_body(body, ambient, env, acc) do
    context = %{parent: {:do, body}, index: 1}
    walk_tree(body, ambient, context, %{env | statement: statement_head(body)}, acc)
  end

  defp statement_head({:@, _, [{name, _, _}]}), do: {:@, name}
  defp statement_head({form, _, [first | _]}) when is_atom(form), do: {form, statement_arg(first)}
  defp statement_head({form, _, _}) when is_atom(form), do: {form}
  defp statement_head(_), do: :other

  defp statement_arg(term) when is_atom(term) or is_binary(term), do: term
  defp statement_arg({:__aliases__, _, parts}), do: Mutators.identity_node(parts)
  defp statement_arg(_), do: :_

  defp walk_node(node, ambient, context, env, acc) do
    env = enter_definition(node, env)
    acc = try_mutators(node, ambient, context, env, acc)

    case node do
      {form, meta, args} when is_list(meta) ->
        position = update_ambient(meta, ambient)

        acc =
          if is_atom(form) do
            acc
          else
            walk_child(form, position, node, :form, :form, env, acc)
          end

        if is_list(args), do: walk_children(args, position, node, :arg, env, acc), else: acc

      {left, right} ->
        acc = walk_child(left, ambient, node, 0, :left, env, acc)
        walk_child(right, ambient, node, 1, :right, env, acc)

      list when is_list(list) ->
        walk_children(list, ambient, list, :elem, env, acc)

      _ ->
        acc
    end
  end

  defp enter_definition({:quote, _, _}, env), do: %{env | quoted: true}
  defp enter_definition(_node, %{quoted: true} = env), do: env

  defp enter_definition(node, env) do
    case Ast.definition_signature(node) do
      {name, arity} ->
        %{env | enclosing: {env.module_key, name, arity}}

      nil ->
        case Ast.definition_head(node) do
          nil -> env
          head -> %{env | enclosing: {env.module_key, :generated, Mutators.identity_node(head)}}
        end
    end
  end

  defp walk_children(children, ambient, parent, step, env, acc) do
    children
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {child, index}, acc ->
      walk_child(child, ambient, parent, index, {step, index}, env, acc)
    end)
  end

  defp walk_child(child, ambient, parent, index, step, env, acc) do
    context = %{parent: parent, index: index}
    walk_tree(child, ambient, context, %{env | path: [step | env.path]}, acc)
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
  defp try_mutators(node, ambient, context, env, acc) do
    mutators =
      node
      |> pre_filter_mutators(env.mutators, env.dispatch_mode)
      |> Enum.filter(& &1.match?(node))

    case mutators do
      [] ->
        acc

      mutators ->
        normalized = identity_expression(node, context)
        enclosing = env.enclosing || {env.module_key, env.statement}

        Enum.reduce(mutators, acc, fn mutator, acc ->
          name = mutator.name()
          key = {enclosing, normalized, name}
          ordinal = Map.get(acc.ordinals, key, 0)
          acc = put_in(acc.ordinals[key], ordinal + 1)
          identity = {enclosing, normalized, ordinal}

          emit_site(mutator, node, ambient, context, env, {identity, name}, acc)
        end)
    end
  end

  defp identity_expression(node, %{parent: parent, index: index})
       when is_integer(node) or is_boolean(node),
       do: {node, Mutators.identity_node(parent), index}

  defp identity_expression(node, _context), do: Mutators.identity_node(node)

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

  defp emit_site(_mutator, _node, _ambient, _context, %{scopes: []}, _identity, acc),
    do: acc

  defp emit_site(mutator, node, ambient, context, env, identity, acc) do
    {line, column} = effective_position(node, ambient)

    with true <- is_integer(line) and MapSet.member?(env.covered, line),
         [{_scope, owner} | _] = scopes <-
           Enum.filter(env.scopes, fn {scope, _rank} -> in_scope?(scope, line, env.enclosing) end) do
      matched =
        Enum.reduce(scopes, acc.scopes, fn {_scope, rank}, acc -> Map.put(acc, rank, :matched) end)

      record_site(mutator, node, {line, column}, context, env, identity, owner, %{
        acc
        | scopes: matched
      })
    else
      _ -> acc
    end
  end

  defp in_scope?(%Scope{function: nil, line_range: range}, line, _enclosing), do: line in range

  defp in_scope?(
         %Scope{function: {name, arity}, module: module, line_range: range},
         line,
         {modules, fun, arity}
       )
       when is_atom(fun) do
    line in range and module in List.wrap(modules) and Atom.to_string(fun) == name
  end

  defp in_scope?(_scope, _line, _enclosing), do: false

  defp record_site(mutator, node, {line, column}, context, env, {identity, name}, owner, acc) do
    file = env.file
    id = Mutators.site_id(file, identity, name)
    mutated = mutator.mutate(node)

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
          function: format_function(env.enclosing),
          path: Enum.reverse(env.path),
          file: file,
          line: line,
          column: column,
          mutator: name,
          original_ast: node,
          mutated_ast: mutated,
          end_line: end_line,
          end_column: end_column
        }

        %{acc | sites: Map.update(acc.sites, owner, [site], &[site | &1])}

      {:skip, reason} ->
        entry = %{site_id: id, reason: reason, mutator: name, file: file}
        %{acc | skipped: Map.update(acc.skipped, owner, [entry], &[entry | &1])}
    end
  end

  defp format_function({module, name, arity})
       when is_atom(module) and not is_nil(module) and is_integer(arity),
       do: "#{inspect(module)}.#{name}/#{arity}"

  defp format_function(_), do: nil

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
