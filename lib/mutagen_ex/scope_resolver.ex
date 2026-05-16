defmodule MutagenEx.ScopeResolver.Scope do
  @moduledoc """
  A single resolved scope record. `file` is the path the resolver read
  source from; `line_range` is an inclusive `Range` of source lines; `module`
  is the atom name of the resolved module.
  """

  @enforce_keys [:file, :line_range, :module]
  defstruct [:file, :line_range, :module]

  @type t :: %__MODULE__{
          file: String.t(),
          line_range: Range.t(),
          module: module()
        }
end

defmodule MutagenEx.ScopeResolver do
  @moduledoc """
  Resolves user-supplied `--scope` targets into concrete
  `%MutagenEx.ScopeResolver.Scope{}` records describing the file, line range,
  and module each target points at.

  This module implements the behavioural contract in
  `.spec/specs/scope_resolution.spec.md` (`mutagen.scope_resolution`).

  ## Target shapes

  Per `mutagen.decision.scope_syntax_simplified`, exactly three shapes are
  accepted:

    * **File path** — anything ending in `.ex` (e.g. `lib/foo.ex`). Resolves
      to one record per `defmodule` block in the file (`r1`).
    * **Module name** — `Module.Name` (no `/arity`, no leading path). Resolves
      to a single record covering the matching `defmodule` block (`r2`).
    * **MFA** — `Module.Name.function/arity`. Arity is required. Resolves to
      a single record whose `line_range` covers only the matching
      `def`/`defp`/`defmacro`/`defmacrop` clause(s) for that arity (`r3`).

  Targets containing a `:` are rejected with
  `reason: :colon_syntax_unsupported` (`r4`). Module-shaped targets with a
  lowercase trailing segment but no `/arity` are rejected with
  `reason: :arity_required` (`r3`).

  Resolution is purely an AST walk: source files are read via the injectable
  loader (default `&File.read!/1`) and parsed with
  `Code.string_to_quoted/2` requesting line/column metadata. No compile is
  ever invoked; no file on disk is modified (`r6`).

  ## Atom safety (`r8`, mutagen-wrd.20)

  Module-shaped and MFA-shaped targets carry user-controlled strings (e.g.
  `Foo.Bar`, `Foo.bar/1`). The resolver does NOT call `String.to_atom/1` on
  any segment of these targets. Module matching against the source's
  `defmodule` blocks is performed via string comparison: the user's
  canonical form (e.g. `"Elixir.Foo.Bar"`) is compared against
  `Atom.to_string/1` of each AST-derived `defmodule` atom. The matched atom
  populates `%Scope{module: ...}` so downstream code keeps an atom-typed
  identifier — but that atom comes from the AST (legitimate; created during
  the parse of source files on disk), never from the user's input.

  Function-name segments use `String.to_existing_atom/1`: the function-name
  atom (`bar` in `Foo.bar/1`) is compared against atoms produced by parsing
  source `def`s. If the function name is not a registered atom anywhere,
  `String.to_existing_atom/1` raises `ArgumentError`, which the resolver
  converts to `:function_not_found`. This keeps the atom table bounded by
  the project's source corpus, not by the cardinality of attacker input.

  ## Opts

    * `:loader` — `(file :: String.t() -> String.t())`. Default
      `&File.read!/1`. Per `r7`, this is the seam that lets tests work over
      synthetic source strings without touching disk.
    * `:source_files` — `[String.t()]`. For module-name and MFA targets, the
      list of project files to search. Defaults to
      `Path.wildcard("lib/**/*.ex")` so production callers don't have to
      build the list themselves. Tests pass an explicit list of synthetic
      paths so resolution stays deterministic.

  ## Returns

  `{:ok, [%Scope{}, ...]}` on success (always exactly one record for
  module/MFA targets; one or more for file targets).

  `{:error, reason, details}` for any failure. `reason` is one atom from
  `t:reason/0`; `details` is a map with at least `:target` (the raw user
  string) and a human-readable `:message`. Reason-specific fields may also
  be present (e.g. `:file` for `:file_not_found`).
  """

  alias MutagenEx.Ast
  alias MutagenEx.ScopeResolver.Scope

  @behaviour MutagenEx.Pipeline.ScopeFacade

  @typedoc "Atom-shaped reason for a resolution failure."
  @type reason ::
          :colon_syntax_unsupported
          | :arity_required
          | :module_not_found
          | :function_not_found
          | :file_not_found
          | :file_read_failed
          | :parse_error
          | :unrecognised_target

  @typedoc "Injectable source loader. Receives a path, returns the file's bytes."
  @type loader :: (String.t() -> String.t())

  @typedoc "Result of `resolve/2`."
  @type result :: {:ok, [Scope.t()]} | {:error, reason, map()}

  @default_source_glob "lib/**/*.ex"

  @doc """
  Resolve a single raw scope target to one or more `%Scope{}` records.

  See the module doc for opts and result shape.
  """
  @impl MutagenEx.Pipeline.ScopeFacade
  @spec resolve(String.t(), keyword) :: result
  def resolve(target, opts \\ []) when is_binary(target) do
    loader = Keyword.get(opts, :loader, &File.read!/1)

    cond do
      String.contains?(target, ":") ->
        {:error, :colon_syntax_unsupported,
         %{
           target: target,
           message:
             "scope target #{inspect(target)} uses the colon form, which is not supported in v1"
         }}

      file_target?(target) ->
        resolve_file(target, loader)

      true ->
        resolve_symbolic(target, loader, opts)
    end
  end

  # --- shape dispatch --------------------------------------------------------

  defp file_target?(target), do: String.ends_with?(target, ".ex")

  # `Module.fun/arity` MUST contain a `/`; the arity-less function-named form
  # (e.g. `Foo.bar`) returns `:arity_required` per r3 / s4. The arity-less
  # module form (e.g. `Foo.Bar`) resolves to its `defmodule` block per r2.
  defp resolve_symbolic(target, loader, opts) do
    case String.split(target, "/", parts: 2) do
      [head, arity_str] ->
        with {:ok, arity} <- parse_arity(target, arity_str),
             {:ok, mod, fun} <- split_mfa(target, head) do
          resolve_mfa(target, mod, fun, arity, loader, opts)
        end

      [_just_head] ->
        resolve_module_or_arity_required(target, loader, opts)
    end
  end

  defp parse_arity(target, arity_str) do
    case Integer.parse(arity_str) do
      {n, ""} when n >= 0 ->
        {:ok, n}

      _ ->
        {:error, :unrecognised_target,
         %{
           target: target,
           message:
             "scope target #{inspect(target)} has a `/` but the suffix is not a non-negative integer arity"
         }}
    end
  end

  # `Foo.Bar.baz/1` → `{"Elixir.Foo.Bar", "baz"}`. The head must have at
  # least two dotted segments (module + function). Atom safety (`r8`):
  # BOTH the module portion AND the function segment are returned as
  # strings, not atoms. Downstream matching compares these against
  # `Atom.to_string/1` of AST atoms — `String.to_atom/1` is never called
  # on user input. The matched function atom (which DOES end up on the
  # %Scope{} record indirectly via the AST line range) comes from the
  # parsed `def` heads, never from the user's string.
  defp split_mfa(target, head) do
    case head |> String.split(".") |> Enum.reverse() do
      [fun_seg | mod_rev] when mod_rev != [] ->
        mod_str = mod_rev |> Enum.reverse() |> Enum.join(".") |> canonical_module_string()

        case validate_function_segment(fun_seg) do
          :ok ->
            {:ok, mod_str, fun_seg}

          :error ->
            {:error, :unrecognised_target,
             %{
               target: target,
               message:
                 "scope target #{inspect(target)} has function segment #{inspect(fun_seg)} that is not a valid lowercase atom"
             }}
        end

      _ ->
        {:error, :unrecognised_target,
         %{
           target: target,
           message: "scope target #{inspect(target)} has `/arity` but no `Module.function` head"
         }}
    end
  end

  # Arity-less symbolic target: either `Module.Name` (resolves to the
  # matching `defmodule`) or `Module.fun` (a function name with no `/arity`
  # — error per r3 / s4). Distinguished by case of the trailing segment.
  defp resolve_module_or_arity_required(target, loader, opts) do
    segments = String.split(target, ".")
    last = List.last(segments)

    cond do
      segments == [] or last == "" ->
        {:error, :unrecognised_target, %{target: target, message: "empty scope target"}}

      starts_lowercase?(last) ->
        {:error, :arity_required,
         %{
           target: target,
           message:
             "scope target #{inspect(target)} names a function but is missing the `/arity` suffix (e.g. #{target}/1)"
         }}

      Enum.all?(segments, &starts_uppercase?/1) ->
        mod_str = canonical_module_string(target)
        resolve_module(target, mod_str, loader, opts)

      true ->
        {:error, :unrecognised_target,
         %{
           target: target,
           message:
             "scope target #{inspect(target)} is not a valid module name (segments must start with an uppercase letter)"
         }}
    end
  end

  # Canonical string form of a module-shaped user input. NEVER calls
  # `String.to_atom/1` (`r8`, mutagen-wrd.20). Downstream matching compares
  # this string to `Atom.to_string/1` of AST atoms.
  defp canonical_module_string(name) do
    "Elixir." <> name
  end

  # Validate the shape of a user-supplied function-name segment WITHOUT
  # materializing an atom. The segment is kept as a string and compared
  # against `Atom.to_string/1` of AST `def` atoms during walk (`r8`,
  # mutagen-wrd.20). If the source genuinely defines `def fun_seg`, the
  # AST atom matches; if not, we return `:function_not_found` from the
  # caller — without ever growing the atom table.
  defp validate_function_segment(seg) do
    if seg != "" and starts_lowercase?(seg) and valid_atom_segment?(seg) do
      :ok
    else
      :error
    end
  end

  defp valid_atom_segment?(seg) do
    seg
    |> String.to_charlist()
    |> Enum.all?(fn
      c when c in ?a..?z -> true
      c when c in ?A..?Z -> true
      c when c in ?0..?9 -> true
      ?_ -> true
      ?? -> true
      ?! -> true
      _ -> false
    end)
  end

  defp starts_lowercase?(<<c, _::binary>>) when c in ?a..?z, do: true
  defp starts_lowercase?(_), do: false

  # Pretty-print a canonical `"Elixir.Foo.Bar"` form for error messages,
  # without ever materializing an atom. Strips the `"Elixir."` prefix so
  # the message reads as a user would write it (`Foo.Bar`, not
  # `:"Elixir.Foo.Bar"`).
  defp inspect_module_str("Elixir." <> rest), do: rest
  defp inspect_module_str(other), do: other

  defp starts_uppercase?(<<c, _::binary>>) when c in ?A..?Z, do: true
  defp starts_uppercase?(_), do: false

  # --- file-target resolution ------------------------------------------------

  defp resolve_file(file, loader) do
    with {:ok, source} <- load(file, loader),
         {:ok, ast} <- parse(file, source) do
      records =
        ast
        |> find_defmodules()
        |> Enum.map(fn {mod, range} ->
          %Scope{file: file, line_range: range, module: mod}
        end)

      {:ok, records}
    end
  end

  # --- module-target resolution ----------------------------------------------

  # `mod_str` is the canonical `"Elixir.Foo.Bar"` form. We compare it
  # against `Atom.to_string/1` of each AST atom — never `String.to_atom/1`
  # of `mod_str` (`r8`, mutagen-wrd.20). The matched atom flows into
  # `%Scope{module: ...}` from the AST.
  defp resolve_module(target, mod_str, loader, opts) do
    files = source_files(opts)

    case search_for_module(files, mod_str, loader) do
      {:ok, file, range, mod_atom} ->
        {:ok, [%Scope{file: file, line_range: range, module: mod_atom}]}

      :not_found ->
        {:error, :module_not_found,
         %{
           target: target,
           module: mod_str,
           message:
             "no `defmodule #{inspect_module_str(mod_str)}` found in any project source file"
         }}

      {:error, _reason, _details} = err ->
        err
    end
  end

  defp search_for_module([], _mod_str, _loader), do: :not_found

  defp search_for_module([file | rest], mod_str, loader) do
    case load_and_parse(file, loader) do
      {:ok, ast} ->
        case Enum.find(find_defmodules(ast), fn {m, _range} ->
               Atom.to_string(m) == mod_str
             end) do
          {m, range} when is_atom(m) -> {:ok, file, range, m}
          nil -> search_for_module(rest, mod_str, loader)
        end

      {:soft_skip, _err} ->
        search_for_module(rest, mod_str, loader)

      {:hard_error, err} ->
        err
    end
  end

  # --- MFA-target resolution -------------------------------------------------

  # `mod_str` is the canonical `"Elixir.Foo.Bar"` form; `fun_str` is the
  # raw function-name string from the user (`r8`, mutagen-wrd.20). Neither
  # is passed through `String.to_atom/1`. The matched module and function
  # atoms come from the AST.
  defp resolve_mfa(target, mod_str, fun_str, arity, loader, opts) do
    files = source_files(opts)

    case search_for_module_full(files, mod_str, loader) do
      {:ok, file, mod_range, body_ast, mod_atom} ->
        case find_function_clauses(body_ast, fun_str, arity) do
          [] ->
            {:error, :function_not_found,
             %{
               target: target,
               module: mod_atom,
               function: fun_str,
               arity: arity,
               message:
                 "no `def #{fun_str}/#{arity}` found in `defmodule #{inspect(mod_atom)}` (#{file})"
             }}

          ranges ->
            merged = merge_ranges(ranges)
            constrained = constrain(merged, mod_range)
            {:ok, [%Scope{file: file, line_range: constrained, module: mod_atom}]}
        end

      :not_found ->
        {:error, :module_not_found,
         %{
           target: target,
           module: mod_str,
           message:
             "no `defmodule #{inspect_module_str(mod_str)}` found in any project source file"
         }}

      {:error, _, _} = err ->
        err
    end
  end

  defp search_for_module_full([], _mod_str, _loader), do: :not_found

  defp search_for_module_full([file | rest], mod_str, loader) do
    case load_and_parse(file, loader) do
      {:ok, ast} ->
        case find_defmodule_block(ast, mod_str) do
          {:ok, range, body, mod_atom} -> {:ok, file, range, body, mod_atom}
          :not_found -> search_for_module_full(rest, mod_str, loader)
        end

      {:soft_skip, _err} ->
        search_for_module_full(rest, mod_str, loader)

      {:hard_error, err} ->
        err
    end
  end

  # Wrap load+parse so the search loops have one decision shape: ok, retry,
  # or hard fail. We treat per-file read failures (e.g. the loader threw on
  # a single missing path) as soft skips so a stray entry in
  # `source_files:` doesn't tank the whole search, but a parse error is a
  # hard fail because the user almost certainly wants to know their source
  # is malformed.
  defp load_and_parse(file, loader) do
    case load(file, loader) do
      {:ok, source} ->
        case parse(file, source) do
          {:ok, ast} -> {:ok, ast}
          {:error, _, _} = err -> {:hard_error, err}
        end

      {:error, reason, _} = err when reason in [:file_not_found, :file_read_failed] ->
        {:soft_skip, err}
    end
  end

  # --- AST walking ------------------------------------------------------------

  # Find every (possibly nested) `defmodule` block in an AST. Returns a list
  # of `{module_atom, line_range}` in source order.
  defp find_defmodules(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case extract_defmodule(node) do
          {:ok, mod, range} -> {node, [{mod, range} | acc]}
          :no -> {node, acc}
        end
      end)

    Enum.reverse(acc)
  end

  defp extract_defmodule({:defmodule, _meta, [alias_ast, [do: _body]]} = node) do
    case Ast.alias_to_module(alias_ast) do
      nil -> :no
      mod -> {:ok, mod, node_line_range(node)}
    end
  end

  defp extract_defmodule(_), do: :no

  # Locate the `defmodule mod` block specifically, returning its line range,
  # its inner body AST (the AST under `[do: ...]`), AND the matched module
  # atom (which comes from the AST — `r8`, mutagen-wrd.20). `target_mod_str`
  # is compared against `Atom.to_string/1` of each `:__aliases__`-derived
  # module atom, so the user's input is never passed through
  # `String.to_atom/1`.
  #
  # This is NOT the same as `MutagenEx.Ast.find_module_body/2`: this
  # variant returns the line range and module atom too, which the
  # resolver needs for the `%Scope{}` record. The bare body lookup in
  # `MutagenEx.Ast` is enough for the enumerator and runner, but the
  # resolver needs the extra metadata. The shared piece — alias→module
  # conversion — flows through `MutagenEx.Ast.alias_to_module/1`.
  defp find_defmodule_block(ast, target_mod_str) do
    {_ast, acc} =
      Macro.prewalk(ast, :not_found, fn
        {:defmodule, _meta, [alias_ast, [do: body]]} = node, :not_found ->
          case Ast.alias_to_module(alias_ast) do
            nil ->
              {node, :not_found}

            mod_atom ->
              if Atom.to_string(mod_atom) == target_mod_str do
                {node, {:ok, node_line_range(node), body, mod_atom}}
              else
                {node, :not_found}
              end
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # Find every `def`/`defp`/`defmacro`/`defmacrop` clause matching the given
  # function name and arity. Returns the list of line ranges (one per
  # clause) in source order. Atom safety (`r8`, mutagen-wrd.20):
  # `fun_str` is a string; we compare it against `Atom.to_string/1` of
  # each AST `def`-head atom, so the user's function-name input is never
  # passed through `String.to_atom/1`.
  defp find_function_clauses(body, fun_str, arity) do
    {_, acc} =
      Macro.prewalk(body, [], fn node, acc ->
        case extract_def(node) do
          {:ok, fun_atom, ^arity, range} ->
            if is_atom(fun_atom) and Atom.to_string(fun_atom) == fun_str do
              {node, [range | acc]}
            else
              {node, acc}
            end

          _ ->
            {node, acc}
        end
      end)

    Enum.reverse(acc)
  end

  # `def name(args) do body end` and the keyword shorthand
  # `def name(args), do: body` both parse to:
  #
  #     {def_kind, meta, [{name, _, args}, [do: body]]}
  #
  # where `def_kind` is `:def`, `:defp`, `:defmacro`, or `:defmacrop`.
  # Guard clauses wrap the head in
  # `{:when, _, [{name, _, args}, guard_expr]}`.
  defp extract_def({kind, _meta, [head, [do: _body]]} = node)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    case head_to_fun_arity(head) do
      {:ok, fun, arity} -> {:ok, fun, arity, node_line_range(node)}
      :error -> :error
    end
  end

  defp extract_def({kind, _meta, [head]} = node)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    case head_to_fun_arity(head) do
      {:ok, fun, arity} -> {:ok, fun, arity, node_line_range(node)}
      :error -> :error
    end
  end

  defp extract_def(_), do: :error

  defp head_to_fun_arity({:when, _, [inner | _]}), do: head_to_fun_arity(inner)

  defp head_to_fun_arity({fun, _, args}) when is_atom(fun) do
    arity = if is_list(args), do: length(args), else: 0
    {:ok, fun, arity}
  end

  defp head_to_fun_arity(_), do: :error

  # --- range plumbing --------------------------------------------------------

  # Compute the inclusive line range covered by an AST node. We use the
  # node's own `:line` meta as the start; we walk the subtree for the
  # maximum `:line` to get the end. `Code.string_to_quoted/2` with
  # `columns: true` populates `:line` on container nodes; we don't depend
  # on `:closing` / `:end_of_expression` because they aren't always
  # populated for the keyword-shorthand `do:` form.
  defp node_line_range(node) do
    start_line = meta_line(node) || 1
    end_line = max_line_in_subtree(node, start_line)
    start_line..end_line
  end

  defp meta_line({_kind, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line)
  defp meta_line(_), do: nil

  # Pull every line-bearing entry from a node's meta. `:line` is always
  # present on a properly-located node; `:end` and `:end_of_expression` are
  # populated when `token_metadata: true` and let us see the closing `end`
  # keyword's line — required so `defmodule` and `def` ranges cover their
  # full `do ... end` block per r1.
  defp meta_lines({_kind, meta, _args}) when is_list(meta), do: collect_lines(meta)
  defp meta_lines(_), do: []

  defp collect_lines(meta) do
    Enum.reduce(meta, [], fn
      {:line, n}, acc when is_integer(n) -> [n | acc]
      {:end, sub}, acc when is_list(sub) -> add_sub_line(sub, acc)
      {:end_of_expression, sub}, acc when is_list(sub) -> add_sub_line(sub, acc)
      {:closing, sub}, acc when is_list(sub) -> add_sub_line(sub, acc)
      {:do, sub}, acc when is_list(sub) -> add_sub_line(sub, acc)
      _, acc -> acc
    end)
  end

  defp add_sub_line(sub, acc) do
    case Keyword.get(sub, :line) do
      n when is_integer(n) -> [n | acc]
      _ -> acc
    end
  end

  defp max_line_in_subtree(node, init) do
    {_node, max} =
      Macro.prewalk(node, init, fn n, acc ->
        Enum.reduce(meta_lines(n), acc, fn line, a -> max(a, line) end)
        |> then(&{n, &1})
      end)

    max
  end

  defp merge_ranges([single]), do: single

  defp merge_ranges(ranges) do
    min_l = ranges |> Enum.map(& &1.first) |> Enum.min()
    max_l = ranges |> Enum.map(& &1.last) |> Enum.max()
    min_l..max_l
  end

  # Clamp `inner` to the bounds of `outer`. We expect the inner range to
  # already lie within outer; this is a defensive guard so MFA ranges never
  # bleed past the surrounding `defmodule` per r5.
  defp constrain(inner, outer) do
    first = max(inner.first, outer.first)
    last = min(inner.last, outer.last)
    first..last
  end

  # --- loading & parsing -----------------------------------------------------

  defp load(file, loader) do
    try do
      {:ok, loader.(file)}
    rescue
      e in File.Error ->
        {:error, :file_not_found,
         %{
           file: file,
           message: "could not read source file #{inspect(file)}: #{Exception.message(e)}"
         }}

      e ->
        {:error, :file_read_failed,
         %{
           file: file,
           message: "could not read source file #{inspect(file)}: #{Exception.message(e)}"
         }}
    end
  end

  defp parse(file, source) do
    case Code.string_to_quoted(source,
           columns: true,
           line: 1,
           file: file,
           token_metadata: true
         ) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {meta_or_line, description, token}} ->
        line = parse_error_line(meta_or_line)

        {:error, :parse_error,
         %{
           file: file,
           line: line,
           message:
             "could not parse #{inspect(file)} at line #{line}: #{IO.iodata_to_binary(format_parse_error(description, token))}"
         }}
    end
  end

  defp parse_error_line(line) when is_integer(line), do: line

  defp parse_error_line(meta) when is_list(meta) do
    Keyword.get(meta, :line, 0)
  end

  defp parse_error_line(_), do: 0

  defp format_parse_error(description, token) when is_binary(description) do
    [description, inspect(token)]
  end

  defp format_parse_error({prefix, suffix}, token)
       when is_binary(prefix) and is_binary(suffix) do
    [prefix, suffix, " ", inspect(token)]
  end

  defp format_parse_error(description, token) do
    [inspect(description), " ", inspect(token)]
  end

  # F30 / CF7 determinism contract (mutagen.scope_resolution.r9): the
  # default `Path.wildcard/1` result order is file-system-dependent
  # (HFS+ / APFS sort lexicographically; ext4 returns inode order;
  # some network filesystems return creation order). Sort
  # lexicographically here so module-name target resolution visits
  # files in a stable order regardless of host, preserving the
  # byte-identical-output guarantee in
  # `mutagen.mutation_pipeline.r15`. Explicit `:source_files` lists
  # are caller-controlled and not re-sorted (the caller already chose
  # an order).
  #
  # `@doc false` and exposed (not `defp`) so the r9 contract is
  # directly testable with an injectable `:wildcard_fn` that returns
  # a known unsorted list. Production callers never pass
  # `:wildcard_fn` — the default `&Path.wildcard/1` is used.
  @doc false
  def source_files(opts) do
    case Keyword.get(opts, :source_files) do
      nil ->
        wildcard_fn = Keyword.get(opts, :wildcard_fn, &Path.wildcard/1)
        @default_source_glob |> wildcard_fn.() |> Enum.sort()

      list when is_list(list) ->
        list
    end
  end
end
