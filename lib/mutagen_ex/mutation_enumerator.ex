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
    * `:definition_line` — first line of the named runtime function.
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
    * `:source_span` — byte offset and length of the expression in the cached
      source text, when source reporting is enabled and the span is available.
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
    definition_line: nil,
    end_line: nil,
    end_column: nil,
    source_span: nil,
    source_line: nil
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
          definition_line: pos_integer() | nil,
          end_line: pos_integer() | nil,
          end_column: pos_integer() | nil,
          source_span: {non_neg_integer(), pos_integer()} | nil,
          source_line: pos_integer() | nil
        }
  @doc false
  def reference(id), do: :crypto.hash(:sha256, id) |> Base.encode16(case: :lower)

  @doc false
  def valid_selector?(id), do: opaque?(id) or selector_file(id) != nil

  @doc false
  def selector_file(id) do
    case Regex.run(~r/\A(.+\.ex):[0-9a-f]{32}:[a-z_]+\z/s, id, capture: :all_but_first) do
      [file] ->
        if Path.type(file) == :relative and MutagenEx.JsonPath.validate_literal(file) == :ok,
          do: file

      nil ->
        nil
    end
  end

  @doc false
  def matches?(id, selector),
    do: id == selector or (opaque?(selector) and reference(id) == selector)

  defp opaque?(id), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, id)
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
      lines the cited tests executed. Sites use coverage on their line
      or, for definition heads and positionless nodes, anywhere in
      their own clause body. Uncovered candidates are filtered before
      mutator validation.

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
    * `:source` — collect byte spans for source excerpts. Defaults to `true`.

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
  alias MutagenEx.AstCache
  alias MutagenEx.Mutators
  alias MutagenEx.Mutators.Dispatch
  alias MutagenEx.MutationEnumerator.Site
  alias MutagenEx.ScopeResolver.Scope

  @definition_kinds [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp]

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

  @opaque fingerprint_input :: {[Macro.t()], boolean()}
  @type planned_entry :: %{
          required(:group_key) => tuple(),
          required(:fingerprint) => fingerprint_input() | String.t(),
          required(:runtime?) => boolean(),
          optional(atom()) => term()
        }
  @type planned_result :: %{
          sites: [planned_entry()],
          skipped: [planned_entry()],
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
    * `:planned` — a map from files to lists of ascending, inclusive line ranges
      or `{from, to}` pairs.
      Selects candidates whose spans overlap those ranges and ignores
      `covered_lines`. Sites and skips are plain maps that also carry
      `:group_key`, deferred `:fingerprint` inputs, and `:runtime?`. Planned skips carry
      the source span, function and path as well as the usual skip fields.
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
  @spec enumerate(map(), [Scope.t()], map(), keyword) :: result | planned_result | error
  def enumerate(ast_cache, scope_records, covered_lines, opts \\ [])
      when is_map(ast_cache) and is_list(scope_records) and is_map(covered_lines) do
    catalog = Mutators.all()
    mutators = Keyword.get(opts, :mutators, catalog)
    max_sites = Keyword.get(opts, :max_sites)
    dispatch_mode = Keyword.get(opts, :dispatch_mode, :head_atom)
    source? = Keyword.get(opts, :source, true)

    filter =
      case Keyword.fetch(opts, :planned) do
        {:ok, changed_lines} -> {:planned, normalize_changed_lines(changed_lines)}
        :error -> {:covered, covered_lines}
      end

    unless dispatch_mode in [:head_atom, :legacy] do
      raise ArgumentError,
            "MutagenEx.MutationEnumerator.enumerate/4: " <>
              ":dispatch_mode must be :head_atom or :legacy, got #{inspect(dispatch_mode)}"
    end

    mutators = if dispatch_mode == :head_atom and mutators == catalog, do: :all, else: mutators
    scopes = scope_records |> Enum.uniq() |> Enum.with_index()

    by_file =
      scopes
      |> Enum.group_by(fn {scope, _rank} -> scope.file end)
      |> Map.new(fn {file, file_scopes} ->
        {file, enumerate_file(file, file_scopes, ast_cache, filter, mutators, dispatch_mode)}
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
          sites: add_source_spans(Enum.reverse(final.sites), ast_cache, source?),
          skipped: Enum.reverse(final.skipped),
          warnings: Enum.reverse(final.warnings)
        }
    end
  end

  defp add_source_spans(sites, _ast_cache, false), do: sites

  defp add_source_spans(sites, ast_cache, true) do
    spans_by_file =
      for {file, file_sites} <- Enum.group_by(sites, & &1.file),
          {_, source} when is_binary(source) <- [Map.get(ast_cache, file)],
          into: %{} do
        index = MutagenEx.JsonReporter.Source.index(source, file)

        spans =
          Map.new(file_sites, fn %{path: path} ->
            {path, MutagenEx.JsonReporter.Source.located_span(index, path)}
          end)

        {file, spans}
      end

    Enum.map(sites, fn site ->
      case spans_by_file[site.file][site.path] do
        {span, line} -> %{site | source_span: span, source_line: line}
        nil -> site
      end
    end)
  end

  defp normalize_changed_lines(changed_lines)
       when is_map(changed_lines) and not is_struct(changed_lines) do
    Map.new(changed_lines, fn
      {file, ranges} when is_binary(file) and byte_size(file) > 0 ->
        {file, normalize_ranges(ranges, file)}

      _ ->
        invalid_changed_lines!()
    end)
  end

  defp normalize_changed_lines(_), do: invalid_changed_lines!()

  defp normalize_ranges([], _file), do: []

  defp normalize_ranges([range | rest], file),
    do: [normalize_range(range, file) | normalize_ranges(rest, file)]

  defp normalize_ranges(_, _file), do: invalid_changed_lines!()

  defp invalid_changed_lines! do
    raise ArgumentError, ":planned must be a map from file paths to lists of line ranges"
  end

  defp normalize_range(first..last//1, file), do: normalize_range({first, last}, file)

  defp normalize_range({first, last}, _file)
       when is_integer(first) and is_integer(last) and first > 0 and first <= last,
       do: {first, last}

  defp normalize_range(range, file) do
    raise ArgumentError,
          ":planned expects a positive ascending line range for #{inspect(file)}, got #{inspect(range)}"
  end

  defp walk_groups(ast, keys), do: walk_file(ast, %{by_module: %{}, mutators: []}, keys)

  defp site_fingerprint(%{fingerprint: digest}) when is_binary(digest), do: digest
  defp site_fingerprint(%{fingerprint: input}), do: hash_fingerprint(input)

  @doc """
  Keeps planned entries whose group differs from the same group in the base.

  Pass the base source, including the old path's source for a rename, or
  `:absent` for a new file. Returns `{entries, warnings}`. All entries
  remain in scope when the base cannot be parsed. Groups with a
  counterpart in the base are hashed once per call. Changed groups
  return their resolved fingerprint. Entries with no counterpart keep
  deferred fingerprints.
  """
  @spec fingerprint_scope([planned_entry()], binary() | :absent) ::
          {[planned_entry()], [{:base_parse_error, integer() | :invalid_encoding}]}
  def fingerprint_scope(entries, :absent), do: {entries, []}

  def fingerprint_scope(entries, source) when is_binary(source) do
    case AstCache.parse("nofile", source) do
      {:ok, {ast, _source}} ->
        base = walk_groups(ast, MapSet.new(entries, & &1.group_key))
        {scope_by_group(entries, base), []}

      {:error, :parse_error, %{line: line}} ->
        {entries, [{:base_parse_error, line}]}
    end
  rescue
    UnicodeConversionError -> {entries, [{:base_parse_error, :invalid_encoding}]}
  end

  defp scope_by_group(entries, base) do
    {scoped, _decisions} =
      Enum.flat_map_reduce(entries, %{}, fn %{group_key: key} = entry, decisions ->
        case decisions do
          %{^key => decision} ->
            {scoped_entry(entry, decision), decisions}

          %{} ->
            decision = compare_group(entry, key, base)
            {scoped_entry(entry, decision), Map.put(decisions, key, decision)}
        end
      end)

    scoped
  end

  defp compare_group(entry, key, %{groups: groups, split_groups: split_groups}) do
    case groups do
      %{^key => nodes} ->
        base_hash = hash_fingerprint({nodes, MapSet.member?(split_groups, key)})
        current_hash = site_fingerprint(entry)
        if base_hash == current_hash, do: :unchanged, else: current_hash

      %{} ->
        :absent
    end
  end

  defp scoped_entry(_entry, :unchanged), do: []
  defp scoped_entry(entry, :absent), do: [entry]
  defp scoped_entry(entry, digest), do: [%{entry | fingerprint: digest}]

  @doc "Converts a planned site into the struct accepted by the mutation runner."
  @spec to_site(planned_entry()) :: Site.t()
  def to_site(%{id: _} = entry) do
    struct!(
      Site,
      Map.drop(entry, [:group_key, :fingerprint, :runtime?, :coverage_fallback, :clause_range])
    )
  end

  @doc """
  Partitions planned runtime entries by ID against the runner output and
  validator skips. An entry missing from the output is an uncovered candidate.
  """
  @spec partition_planned_runtime_sites([planned_entry()], map()) :: %{
          evaluated: [planned_entry()],
          uncovered_candidate: [planned_entry()],
          not_run: [planned_entry()]
        }
  def partition_planned_runtime_sites(entries, %{
        results: results,
        compile_errors: compile_errors,
        skipped: skipped
      }) do
    by_id =
      Enum.reduce(results, %{}, fn
        %{id: id, status: :error}, acc -> Map.put_new(acc, id, :not_run)
        %{id: id}, acc -> Map.put(acc, id, :evaluated)
      end)

    by_id = Enum.reduce(compile_errors, by_id, &Map.put(&2, &1.id, :evaluated))
    by_id = Enum.reduce(skipped, by_id, &Map.put(&2, &1.site_id, :evaluated))

    {parts, _seen} =
      Enum.reduce(
        entries,
        {%{evaluated: [], uncovered_candidate: [], not_run: []}, MapSet.new()},
        fn
          entry, {parts, seen} ->
            id = entry_id(entry)

            if MapSet.member?(seen, id) do
              raise ArgumentError, "duplicate planned mutation ID: #{inspect(id)}"
            end

            bucket = Map.get(by_id, id, :uncovered_candidate)
            {Map.update!(parts, bucket, &[entry | &1]), MapSet.put(seen, id)}
        end
      )

    Map.new(parts, fn {bucket, entries} -> {bucket, Enum.reverse(entries)} end)
  end

  defp entry_id(%{id: id}), do: id
  defp entry_id(%{site_id: id}), do: id

  # Count occurrences in file order before applying scope or coverage filters.
  defp enumerate_file(file, scopes, ast_cache, {mode, lines}, mutators, dispatch_mode) do
    with {:ok, entry} <- Map.fetch(ast_cache, file) do
      selection = file_selection(mode, Map.get(lines, file), entry)
      mutators = if selection == {:planned, []}, do: [], else: mutators

      env = %{
        file: file,
        by_module: Enum.group_by(scopes, fn {scope, _rank} -> scope.module end),
        filter: selection,
        mutators: mutators,
        dispatch_mode: dispatch_mode
      }

      group_filter = if mode == :planned and mutators != [], do: :all
      walked = walk_file(cached_ast(entry), env, group_filter)
      {:ok, finish_file(walked)}
    end
  end

  # A new file's full range overlaps every site in its cached parse.
  defp file_selection(:planned, [{1, last}], {_ast, source}) when is_binary(source) do
    if length(:binary.matches(source, "\n")) < last,
      do: {:planned, :whole_file},
      else: {:planned, [{1, last}]}
  end

  defp file_selection(:planned, lines, _entry), do: {:planned, lines || []}
  defp file_selection(:covered, lines, _entry), do: {:covered, lines || MapSet.new()}

  defp walk_file(ast, env, group_filter) do
    ambient =
      case env do
        %{filter: {:planned, [_ | _]}} -> {nil, 1, nil, nil}
        _ -> {nil, 1}
      end

    env =
      Map.merge(env, %{
        modules: Ast.module_index(ast),
        module_key: nil,
        statement: nil,
        enclosing: nil,
        group_root: nil,
        group_filter: group_filter,
        definition_kind: nil,
        clause: nil,
        quoted: false,
        scopes: [],
        path: []
      })

    walk_tree(ast, ambient, nil, env, %{
      ordinals: %{},
      definitions: %{},
      scopes: %{},
      sites: %{},
      skipped: %{},
      groups: if(group_filter, do: %{}),
      split_groups: MapSet.new()
    })
  end

  defp finish_file(%{groups: nil} = walked), do: Map.take(walked, [:scopes, :sites, :skipped])

  defp finish_file(walked) do
    %{
      scopes: walked.scopes,
      sites: attach_fingerprint_inputs(walked.sites, walked),
      skipped: attach_fingerprint_inputs(walked.skipped, walked)
    }
  end

  defp attach_fingerprint_inputs(entries_by_scope, walked) do
    Map.new(entries_by_scope, fn {rank, entries} ->
      entries =
        Enum.map(entries, fn {entry, group, runtime?} ->
          entry = if is_struct(entry, Site), do: Map.from_struct(entry), else: entry
          input = {Map.fetch!(walked.groups, group), MapSet.member?(walked.split_groups, group)}

          Map.merge(entry, %{group_key: group, runtime?: runtime?, fingerprint: input})
        end)

      {rank, entries}
    end)
  end

  defp hash_fingerprint({nodes, split?}) do
    owned =
      if split? do
        Enum.reduce(nodes, [], &[prune_group(&1) | &2])
      else
        Enum.reverse(nodes)
      end

    Mutators.identity_hash(owned, :ast_list)
  end

  defp prune_group({kind, _, [head | _]} = definition)
       when kind in @definition_kinds and not is_nil(head),
       do: prune_call(definition)

  defp prune_group(node), do: prune_nested(node)

  defp prune_nested({:quote, _, _} = node), do: node

  defp prune_nested({kind, meta, [name | options]} = node)
       when kind in [:defmodule, :defprotocol, :defimpl] do
    if Enum.any?(options, &(is_list(&1) and List.keymember?(&1, :do, 0))),
      do: {kind, meta, [name]},
      else: prune_call(node)
  end

  defp prune_nested({kind, meta, [head | _]}) when kind in @definition_kinds and not is_nil(head),
    do: {kind, meta, []}

  defp prune_nested({_, _, args} = node) when is_list(args), do: prune_call(node)

  defp prune_nested({left, right} = node) do
    if bare_mutable_literal?(left) or bare_mutable_literal?(right) or mutable_expression?(node),
      do: node,
      else: {prune_nested(left), prune_nested(right)}
  end

  defp prune_nested(list) when is_list(list) do
    if Enum.any?(list, &bare_mutable_literal?/1), do: list, else: Enum.map(list, &prune_nested/1)
  end

  defp prune_nested(node), do: node

  # A mutator can identify this entire subtree, or a bare literal can
  # identify its whole parent. Keep those ID inputs in the outer hash.
  defp prune_call({form, meta, args} = node) do
    if Enum.any?(args, &bare_mutable_literal?/1) or mutable_expression?(node),
      do: node,
      else: {prune_nested(form), meta, Enum.map(args, &prune_nested/1)}
  end

  defp bare_mutable_literal?(node) when is_integer(node) or is_boolean(node),
    do: Mutators.Literal.match?(node)

  defp bare_mutable_literal?(_node), do: false

  defp mutable_expression?(node),
    do: Enum.any?(Dispatch.mutators_for_node(node), & &1.match?(node))

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

  defp walk_tree({kind, _, [name | _]} = node, ambient, context, %{quoted: false} = env, acc)
       when kind in [:defmodule, :defprotocol, :defimpl] do
    case Map.get(env.modules, node) do
      {modules, body, path} ->
        acc = try_mutators(node, ambient, context, env, acc)
        position = update_ambient(node, ambient)
        scopes = Enum.flat_map(modules, &Map.get(env.by_module, &1, []))

        acc =
          Enum.reduce(scopes, mark_split_group(acc, env), fn {_scope, rank}, acc ->
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
            group_root: nil,
            definition_kind: nil,
            clause: nil,
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

  defp walk_module_body({:__block__, _, [_, _ | _] = args} = block, ambient, env, acc) do
    position = update_ambient(block, ambient)
    acc = try_mutators(block, ambient, nil, %{env | statement: :block}, acc)

    args
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {child, index}, acc ->
      child_env = %{env | path: [{:arg, index} | env.path]}
      walk_statement(child, position, %{parent: block, index: index}, child_env, acc)
    end)
  end

  defp walk_module_body(body, ambient, env, acc) do
    context = %{parent: {:do, body}, index: 1}
    walk_statement(body, ambient, context, env, acc)
  end

  defp walk_statement(node, ambient, context, env, acc) do
    env = %{env | statement: statement_head(node)}
    {env, acc} = record_statement(env, acc, node)
    walk_tree(node, ambient, context, env, acc)
  end

  defp record_statement(env, %{groups: nil} = acc, _node), do: {env, acc}

  defp record_statement(env, acc, node) do
    if is_nil(Ast.definition_head(node)), do: record_group(env, acc, node), else: {env, acc}
  end

  defp statement_head({:@, _, [{name, _, _}]}), do: {:@, name}
  defp statement_head({form, _, [first | _]}) when is_atom(form), do: {form, statement_arg(first)}
  defp statement_head({form, _, _}) when is_atom(form), do: {form}
  defp statement_head(_), do: :other

  defp statement_arg(term) when is_atom(term) or is_binary(term), do: term
  defp statement_arg({:__aliases__, _, parts}), do: Mutators.identity_node(parts)
  defp statement_arg(_), do: :_

  # The slash and arity in a named capture are part of the reference.
  defp walk_node(
         {:/, _, [target, arity]} = node,
         ambient,
         %{parent: {:&, _, [_]}} = context,
         env,
         acc
       )
       when is_integer(arity) do
    if function_target?(target),
      do: acc,
      else: walk_mutable_node(node, ambient, context, env, acc)
  end

  defp walk_node({:quote, _, _} = node, ambient, context, env, acc) do
    walk_mutable_node(node, ambient, context, %{env | quoted: true}, acc)
  end

  defp walk_node(
         {kind, meta, [head | _]} = node,
         ambient,
         context,
         %{quoted: false} = env,
         acc
       )
       when kind in @definition_kinds and not is_nil(head) do
    enclosing =
      case Ast.definition_signature(node) do
        {name, arity} -> {env.module_key, name, arity}
        nil -> {env.module_key, :generated, Mutators.identity_node(head)}
      end

    acc = mark_split_group(acc, env)

    acc =
      if kind in [:def, :defp] and env.scopes != [] and is_integer(meta[:line]) do
        put_in(acc.definitions, Map.put_new(acc.definitions, enclosing, meta[:line]))
      else
        acc
      end

    env = %{env | enclosing: enclosing, definition_kind: kind, clause: clause(node)}
    {env, acc} = record_group(env, acc, node)
    walk_mutable_node(node, ambient, context, env, acc)
  end

  defp walk_node(node, ambient, context, env, acc) do
    walk_mutable_node(node, ambient, context, env, acc)
  end

  defp walk_mutable_node(node, ambient, context, env, acc) do
    acc = try_mutators(node, ambient, context, env, acc)

    case node do
      {form, meta, args} when is_list(meta) ->
        position = update_ambient(node, ambient)

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

  defp group_key(env), do: env.enclosing || {env.module_key, env.statement}

  defp record_group(env, %{groups: nil} = acc, _node), do: {env, acc}

  defp record_group(env, acc, node) do
    key = group_key(env)

    if env.group_filter == :all or MapSet.member?(env.group_filter, key) do
      {%{env | group_root: key},
       %{acc | groups: Map.update(acc.groups, key, [node], &[node | &1])}}
    else
      {%{env | group_root: nil}, acc}
    end
  end

  defp mark_split_group(acc, %{group_root: nil}), do: acc

  defp mark_split_group(acc, %{group_root: group}),
    do: %{acc | split_groups: MapSet.put(acc.split_groups, group)}

  defp walk_children(children, ambient, parent, step, env, acc, index \\ 0)

  defp walk_children([], _ambient, _parent, _step, _env, acc, _index), do: acc

  defp walk_children([child | rest], ambient, parent, step, env, acc, index) do
    acc = walk_child(child, ambient, parent, index, {step, index}, env, acc)
    walk_children(rest, ambient, parent, step, env, acc, index + 1)
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
  defp try_mutators(_node, _ambient, _context, %{mutators: []}, acc), do: acc

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
        enclosing = group_key(env)

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

  defp function_target?({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: true

  defp function_target?({:unquote, _, [_]}), do: true

  defp function_target?({{:., _, [_module, name]}, _meta, []}) when is_atom(name), do: true
  defp function_target?(_target), do: false

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
  defp pre_filter_mutators(node, :all, :head_atom), do: Dispatch.mutators_for_node(node)

  defp pre_filter_mutators(node, mutators, :head_atom) do
    candidate_set = MapSet.new(Dispatch.mutators_for_node(node))
    Enum.filter(mutators, &MapSet.member?(candidate_set, &1))
  end

  defp pre_filter_mutators(_node, mutators, :legacy), do: mutators

  defp emit_site(_mutator, _node, _ambient, _context, %{scopes: []}, _identity, acc),
    do: acc

  defp emit_site(mutator, node, ambient, context, env, identity, acc) do
    {line, column} = effective_position(node, ambient)

    fallback = coverage_fallback(node, line, env.clause)

    with true <- is_integer(line),
         true <- select_span(env.filter, node, ambient, line, fallback),
         [{_scope, owner} | _] = scopes <-
           Enum.filter(env.scopes, fn {scope, _rank} -> in_scope?(scope, line, env.enclosing) end) do
      matched =
        Enum.reduce(scopes, acc.scopes, fn {_scope, rank}, acc -> Map.put(acc, rank, :matched) end)

      record_site(mutator, node, {line, column, fallback}, context, env, identity, owner, %{
        acc
        | scopes: matched
      })
    else
      _ -> acc
    end
  end

  @doc false
  def covered?(%{file: file, line: line} = site, bitmap) do
    case bitmap do
      %{^file => lines} -> covered_line?(lines, line, site[:coverage_fallback])
      _ -> false
    end
  end

  defp covered_line?(covered, line, fallback) do
    MapSet.member?(covered, line) or
      (fallback != nil and Enum.any?(fallback, &MapSet.member?(covered, &1)))
  end

  defp clause({_kind, meta, [head, body]}) when is_list(body) do
    if Keyword.has_key?(body, :do) and is_integer(meta[:line]) do
      {_, head_end} = source_range(head, nil) || {meta[:line], meta[:line]}
      # A bare body can lack metadata even when it occupies its own line.
      opening = get_in(meta, [:do, :line])
      closing = get_in(meta, [:end, :line])
      first_line = if opening, do: min(opening + 1, closing || opening + 1), else: head_end
      {first, last} = source_range(body, nil) || {first_line, first_line}
      first = if opening, do: min(first, first_line), else: first
      last = if closing, do: max(last, closing - 1), else: last
      clause_end = max(last, closing || last)
      %{head_end: head_end, body: first..last, range: {meta[:line], clause_end}}
    end
  end

  defp clause(_node), do: nil

  defp coverage_fallback(node, line, %{head_end: head_end, body: body}) do
    if (is_integer(line) and line <= head_end) or is_nil(Ast.node_line(node)), do: body
  end

  defp coverage_fallback(_node, _line, nil), do: nil

  defp select_span({:covered, covered}, _node, _ambient, line, fallback) do
    covered_line?(covered, line, fallback)
  end

  defp select_span({:planned, []}, _node, _ambient, _line, _fallback), do: false
  defp select_span({:planned, :whole_file}, _node, _ambient, _line, _fallback), do: true

  defp select_span(
         {:planned, ranges},
         node,
         {_line, _column, parent, closing_line},
         line,
         _fallback
       ) do
    case Ast.node_line(node) do
      nil ->
        last = max(line, closing_line || line)

        overlaps_range?(ranges, {line, last}) or
          overlaps_range?(ranges, positionless_range(node, parent, line, last))

      start ->
        overlaps_line?(ranges, start) or overlaps_range?(ranges, source_range(node, nil))
    end
  end

  defp positionless_range(node, parent, line, last) do
    case source_range(node, nil) || source_range(parent, nil) do
      nil -> {line, last}
      {first, ending} -> {min(first, line), max(ending, last)}
    end
  end

  defp overlaps_line?(_ranges, nil), do: false
  defp overlaps_line?(ranges, line), do: overlaps_range?(ranges, {line, line})

  defp overlaps_range?(ranges, {first, last}) do
    Enum.any?(ranges, fn {from, to} -> first <= to and from <= last end)
  end

  defp source_range({form, meta, args}, range) when is_list(meta) do
    range =
      Enum.reduce(meta, range, fn
        {:line, line}, range ->
          extend_range(range, line)

        {key, position}, range
        when key in [:closing, :end, :end_of_expression] and is_list(position) ->
          extend_range(range, Keyword.get(position, :line))

        _, range ->
          range
      end)

    source_range(args, source_range(form, range))
  end

  defp source_range({left, right}, range), do: source_range(right, source_range(left, range))
  defp source_range([first | rest], range), do: source_range(rest, source_range(first, range))
  defp source_range(_, range), do: range

  defp extend_range(range, line) when not is_integer(line), do: range
  defp extend_range(nil, line), do: {line, line}

  defp extend_range({first, last}, line) do
    {min(first, line), max(last, line)}
  end

  defp plan_mode(%{filter: {mode, _}}), do: mode

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

  defp record_site(
         mutator,
         node,
         {line, column, fallback},
         context,
         env,
         {identity, name},
         owner,
         acc
       ) do
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
        # These coordinates are the fallback when the exact source span is unavailable.
        {end_line, end_column} = compute_end_position(node)

        site = %Site{
          id: id,
          function: format_function(env.enclosing),
          definition_line: acc.definitions[env.enclosing],
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

        site = plan_site(site, plan_mode(env), env, fallback)
        %{acc | sites: Map.update(acc.sites, owner, [site], &[site | &1])}

      {:skip, reason} ->
        entry = %{site_id: id, reason: reason, mutator: name, file: file}
        entry = plan_skip(entry, node, {line, column}, plan_mode(env), env)
        %{acc | skipped: Map.update(acc.skipped, owner, [entry], &[entry | &1])}
    end
  end

  defp plan_site(site, :covered, _env, _fallback), do: site

  defp plan_site(site, :planned, env, fallback) do
    site |> Map.from_struct() |> Map.put(:coverage_fallback, fallback) |> plan_entry(env)
  end

  defp plan_skip(entry, _node, _position, :covered, _env), do: entry

  defp plan_skip(entry, node, {line, column}, :planned, env) do
    {end_line, end_column} = compute_end_position(node)

    entry
    |> Map.merge(%{
      function: format_function(env.enclosing),
      path: Enum.reverse(env.path),
      line: line,
      column: column,
      end_line: end_line,
      end_column: end_column
    })
    |> plan_entry(env)
  end

  defp plan_entry(entry, env) do
    runtime? = env.definition_kind in [:def, :defp] and entry.function != nil and not env.quoted
    {Map.put(entry, :clause_range, env.clause && env.clause.range), group_key(env), runtime?}
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
  defp effective_position(node, ambient) do
    line = Ast.node_line(node) || elem(ambient, 0)
    column = node_column_or_nil(node) || elem(ambient, 1) || 1
    {line, column}
  end

  # Pull `{line, column}` out of a 3-tuple's metadata and slot them into
  # the ambient tuple. Missing keys fall back to the prior ambient (we
  # don't want a 3-tuple without `:column` to reset ambient_column to
  # nil — the closest known column is still useful).
  defp update_ambient({_, meta, _}, {prior_line, prior_column}) do
    line = Keyword.get(meta, :line, prior_line)
    column = Keyword.get(meta, :column, prior_column)
    {line, column}
  end

  defp update_ambient({_, meta, _} = node, {prior_line, prior_column, prior_node, prior_end}) do
    column = Keyword.get(meta, :column, prior_column)
    ending = Keyword.get(meta, :end) || Keyword.get(meta, :closing)
    end_line = (ending && Keyword.get(ending, :line)) || prior_end

    case Keyword.fetch(meta, :line) do
      {:ok, line} ->
        {line, column, node, end_line}

      :error ->
        parent =
          if Enum.any?(meta, fn {key, _} -> key in [:closing, :end, :end_of_expression] end),
            do: node,
            else: prior_node

        {prior_line, column, parent, end_line}
    end
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
