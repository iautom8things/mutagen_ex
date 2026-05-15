defmodule MutagenEx.CLI do
  @moduledoc """
  Pure command-line argument parser for `mix mutagen`.

  Built on `OptionParser` with no third-party dependency, per
  `mutagen.cli` Out of Scope (intent).

  ## Contract

  `parse/1` is total: every input shape returns either
  `{:ok, %MutagenEx.Config{}}` or `{:error, reason, details}` where `reason`
  is an atom matching the JSON schema's `abort_reason` vocabulary. The Mix
  task (`Mix.Tasks.Mutagen`) is responsible for handing the error tuple to
  the reporter and choosing an exit code; this module never calls `IO`,
  `System.halt/1`, or `File.write!/2`.

  This split is the seam the ticket's "private dispatch table" exploits: the
  Mix task's reporter can be swapped in tests, but the parser is pure enough
  to be tested directly without any injection.

  ## Recognised flags

    * `--scope <target>` — required, repeatable (max 100 occurrences). Raw
      target string; shape validation happens during scope resolution.
    * `--tests <target>` — required, repeatable (max 100 occurrences). Raw
      target string; shape validation happens during test selection.
    * `--timeout-ms <int>` — positive integer, default 5000.
    * `--seed <int>` — non-negative integer, default 0.
    * `--json <path>` — optional file path; when omitted, the final document
      is written to stdout. The path is validated at parse time (NUL bytes
      and `..` segments are refused) and canonicalised at write time
      (symlinks resolved; the resolved path must stay inside the project
      root unless `--unsafe-json-outside-project` is passed).
    * `--unsafe-json-outside-project` — boolean, default false. Opt-in to
      writing the `--json` output outside the project root. CI integrations
      that target an artifacts directory above the project root pass this
      flag explicitly; everyday use should leave it off.
    * `--max-sites <int>` — positive integer, default 10_000. Upper bound
      on enumerated mutation sites for one run. Exceeding it aborts with
      `:too_many_sites` before any mutation phase runs (per
      `mutagen.mutation_enumeration.r7`).
    * `--budget-ms <int>` — optional positive integer. Aggregate wall-clock
      budget for the mutation phase in milliseconds. When exceeded the
      runner terminates gracefully and the JSON document carries
      `truncated: true` (per `mutagen.cli.r13`).
    * `--max-concurrency <int>` — positive integer, default `1`
      (fully-serial, matches v1.0 semantics exactly). The mutation loop
      dispatches per-site tasks via `Task.Supervisor.async_stream_nolink/4`;
      results are collected in input order so the JSON document remains
      byte-identical across `--max-concurrency` values on deterministic
      scopes. Set to `N > 1` to opt in to parallelism; only safe for
      callers with collision-free input (no two sites mutating the same
      module, no shared `:cover` instrumentation state). See
      `mutagen.mutation_pipeline.r15` for the in-process pipeline
      caveat that motivates default-1.
    * `--stream` — boolean, default false. When set, the runner emits
      one NDJSON line per completed site (and one envelope line on start
      and finish) to the configured output (`stdout` by default, or
      `--json <path>`). The final aggregate JSON document is still
      emitted on the same sink as the last line. Consumers tee on `\\n`.
    * `--no-progress` — boolean, default false. When set, the human-
      readable progress bar / counter is never written to stderr.
      Default behaviour is to emit progress only when stderr is a TTY
      (`:io.getopts/0` reports `:terminal`).

  ## Refused flags

    * `--no-json` — refused per `mutagen.decision.no_pretty_output_v1`.
    * Self-mutation scope targets — any raw `--scope` target whose module-name
      shape begins with `MutagenEx.` or equals exactly `Mix.Tasks.Mutagen` is
      refused at parse time per `mutagen.decision.self_mutation_refused`. This
      is a defence-in-depth heuristic; full resolution-based refusal lives in
      `MutagenEx.ScopeResolver` (S3a) and ultimately at pipeline entry (S6).
    * `--tests tag:NAME` where `NAME` falls outside the charset
      `~r/\A[a-z][a-z_0-9]{0,63}\z/`. This is the front-door bound on the
      atom-table-DOS risk (`mutagen.cli.r11`, mutagen-wrd.20): even though
      `MutagenEx.TestSelector` uses string comparison and never materializes
      an atom from the user-supplied tag name, the charset gate keeps
      adversarial inputs (`tag:$(uuidgen)`-style loops) from reaching the
      selector at all. Non-`tag:` `--tests` targets (file paths, file:line)
      are not gated by this rule — they don't feed atom resolution.

  ## Caps

  Per `mutagen.cli.r12`, `--scope` and `--tests` accept at most 100
  occurrences each. Excess is refused with `:too_many_targets`. The cap
  is structural: it is enforced before any filesystem touch (scope or
  test target resolution).
  """

  alias MutagenEx.Config

  @typedoc "Atom-shaped reason for a parse failure (see `mutagen.json_schema.abort_reason`)."
  @type reason ::
          :missing_scope
          | :missing_tests
          | :invalid_timeout
          | :invalid_seed
          | :invalid_max_concurrency
          | :flag_not_supported_in_v1
          | :unknown_flag
          | :self_mutation_refused
          | :unsafe_json_path
          | :invalid_tag_name
          | :too_many_targets
          | :invalid_max_sites
          | :invalid_budget_ms

  @typedoc "Structured error returned by `parse/1`."
  @type error :: {:error, reason, map()}

  @doc """
  Parse a list of raw CLI argv tokens into a `%MutagenEx.Config{}` or a
  structured error.

  Argv is what `Mix.Task.run/1` hands the task: every token after `mix
  mutagen` as a separate string.

  Returns `{:ok, %Config{}}` for valid input.

  Returns `{:error, reason, details}` for any failure. `reason` is one atom
  from `t:reason/0`; `details` is a map with at least a `:message` string and
  any reason-specific fields (e.g. `:flag` for `:unknown_flag`, `:value` for
  `:invalid_timeout`).
  """
  @spec parse([String.t()]) :: {:ok, Config.t()} | error()
  def parse(argv) when is_list(argv) do
    with :ok <- refuse_unsupported(argv),
         {:ok, parsed, rest, invalid} <- option_parse(argv),
         :ok <- check_invalid(invalid),
         :ok <- check_no_extra_args(rest),
         scopes = collect(parsed, :scope),
         tests = collect(parsed, :tests),
         :ok <-
           require_nonempty(scopes, :missing_scope, "at least one --scope target is required"),
         :ok <- require_nonempty(tests, :missing_tests, "at least one --tests target is required"),
         :ok <- refuse_self_mutation(scopes),
         :ok <- validate_tag_charset(tests),
         :ok <- enforce_target_cap(scopes, :scope),
         :ok <- enforce_target_cap(tests, :tests),
         {:ok, timeout_ms} <- pick_timeout(parsed),
         {:ok, seed} <- pick_seed(parsed),
         {:ok, json_path} <- pick_json_path(parsed),
         {:ok, max_sites} <- pick_max_sites(parsed),
         {:ok, budget_ms} <- pick_budget_ms(parsed),
         {:ok, max_concurrency} <- pick_max_concurrency(parsed),
         unsafe_outside_project = pick_unsafe_outside_project(parsed),
         stream = pick_stream(parsed),
         progress = pick_progress(parsed) do
      {:ok,
       %Config{
         scopes: scopes,
         tests: tests,
         timeout_ms: timeout_ms,
         seed: seed,
         json_path: json_path,
         unsafe_json_outside_project: unsafe_outside_project,
         max_sites: max_sites,
         budget_ms: budget_ms,
         max_concurrency: max_concurrency,
         stream: stream,
         progress: progress
       }}
    end
  end

  # --- pre-OptionParser screen ------------------------------------------------

  # OptionParser would happily silently coerce `--no-json` to `--json = false`
  # because we declare `--json` as `:string`. Catch it before parsing so the
  # error is the right shape per mutagen.decision.no_pretty_output_v1.
  defp refuse_unsupported(argv) do
    cond do
      "--no-json" in argv ->
        {:error, :flag_not_supported_in_v1,
         %{
           flag: "--no-json",
           message: "--no-json is not supported in v1 (pretty output deferred to v1.1)"
         }}

      true ->
        :ok
    end
  end

  # --- OptionParser wiring ----------------------------------------------------

  @option_switches [
    scope: :keep,
    tests: :keep,
    timeout_ms: :integer,
    seed: :integer,
    json: :string,
    unsafe_json_outside_project: :boolean,
    max_sites: :integer,
    budget_ms: :integer,
    max_concurrency: :integer,
    stream: :boolean,
    no_progress: :boolean
  ]

  # Resource caps — see mutagen.cli.r12.
  @target_cap 100

  # OptionParser converts dashes to underscores in switch names. The user
  # types `--timeout-ms`, the parser key is `:timeout_ms`.
  defp option_parse(argv) do
    {parsed, rest, invalid} =
      OptionParser.parse(argv,
        strict: @option_switches
      )

    {:ok, parsed, rest, invalid}
  end

  # `invalid` is a list of `{flag, value}` tuples for unrecognised flags AND
  # for type-mismatched values (e.g. `--timeout-ms abc`). We distinguish the
  # two by checking whether the flag name is one we declared.
  defp check_invalid([]), do: :ok

  defp check_invalid([{flag, value} | _]) do
    cond do
      flag == "--timeout-ms" ->
        {:error, :invalid_timeout,
         %{flag: flag, value: value, message: "--timeout-ms requires a positive integer"}}

      flag == "--seed" ->
        {:error, :invalid_seed,
         %{flag: flag, value: value, message: "--seed requires a non-negative integer"}}

      flag == "--max-sites" ->
        {:error, :invalid_max_sites,
         %{flag: flag, value: value, message: "--max-sites requires a positive integer"}}

      flag == "--budget-ms" ->
        {:error, :invalid_budget_ms,
         %{flag: flag, value: value, message: "--budget-ms requires a positive integer"}}

      flag == "--max-concurrency" ->
        {:error, :invalid_max_concurrency,
         %{flag: flag, value: value, message: "--max-concurrency requires a positive integer"}}

      true ->
        {:error, :unknown_flag, %{flag: flag, value: value, message: "unrecognised flag #{flag}"}}
    end
  end

  defp check_no_extra_args([]), do: :ok

  defp check_no_extra_args([arg | _]) do
    {:error, :unknown_flag,
     %{flag: arg, value: nil, message: "unexpected positional argument #{arg}"}}
  end

  # --- per-flag picks ---------------------------------------------------------

  # `:keep`-flagged switches appear once per occurrence in `parsed`. Order in
  # `parsed` matches user order, which we preserve on the struct.
  defp collect(parsed, key) do
    for {^key, value} <- parsed, do: value
  end

  defp require_nonempty([], reason, message), do: {:error, reason, %{message: message}}
  defp require_nonempty(_, _, _), do: :ok

  # Per `mutagen.cli.r12`: cap repetition of `--scope` / `--tests` at
  # @target_cap. The cap is structural — checked before any filesystem
  # touch — so a CI step that mistakenly passes thousands of targets fails
  # fast instead of materialising a huge list of scope/test resolutions.
  defp enforce_target_cap(targets, kind) do
    count = length(targets)

    if count <= @target_cap do
      :ok
    else
      flag =
        case kind do
          :scope -> "--scope"
          :tests -> "--tests"
        end

      {:error, :too_many_targets,
       %{
         flag: flag,
         kind: kind,
         cap: @target_cap,
         count: count,
         message:
           "#{flag} accepts at most #{@target_cap} occurrences; got #{count}"
       }}
    end
  end

  # Pick the LAST occurrence of a non-`:keep` flag — matches OptionParser's
  # documented behaviour for non-`:keep` switches and avoids surprises when
  # users repeat them.
  defp pick_timeout(parsed) do
    case List.keyfind(parsed, :timeout_ms, 0, :default) do
      :default ->
        {:ok, 5_000}

      {:timeout_ms, n} when is_integer(n) and n > 0 ->
        {:ok, n}

      {:timeout_ms, n} ->
        {:error, :invalid_timeout,
         %{flag: "--timeout-ms", value: n, message: "--timeout-ms must be a positive integer"}}
    end
  end

  defp pick_seed(parsed) do
    case List.keyfind(parsed, :seed, 0, :default) do
      :default ->
        {:ok, 0}

      {:seed, n} when is_integer(n) and n >= 0 ->
        {:ok, n}

      {:seed, n} ->
        {:error, :invalid_seed,
         %{flag: "--seed", value: n, message: "--seed must be a non-negative integer"}}
    end
  end

  # `--max-sites` defaults to 10_000 (the structural site cap per
  # `mutagen.mutation_enumeration.r7`). Zero and negative values are
  # rejected — a cap of 0 would mean "enumerate nothing" which is
  # better expressed by simply not running mutagen at all.
  defp pick_max_sites(parsed) do
    case List.keyfind(parsed, :max_sites, 0, :default) do
      :default ->
        {:ok, 10_000}

      {:max_sites, n} when is_integer(n) and n > 0 ->
        {:ok, n}

      {:max_sites, n} ->
        {:error, :invalid_max_sites,
         %{flag: "--max-sites", value: n, message: "--max-sites must be a positive integer"}}
    end
  end

  # `--budget-ms` is optional. Absence leaves `Config.budget_ms` as `nil`
  # which means "no aggregate wall-clock cap"; per-site `--timeout-ms` is
  # still enforced. Zero / negative are rejected.
  defp pick_budget_ms(parsed) do
    case List.keyfind(parsed, :budget_ms, 0, :default) do
      :default ->
        {:ok, nil}

      {:budget_ms, n} when is_integer(n) and n > 0 ->
        {:ok, n}

      {:budget_ms, n} ->
        {:error, :invalid_budget_ms,
         %{flag: "--budget-ms", value: n, message: "--budget-ms must be a positive integer"}}
    end
  end

  defp pick_json_path(parsed) do
    case List.keyfind(parsed, :json, 0, :default) do
      :default ->
        {:ok, nil}

      {:json, ""} ->
        {:error, :unknown_flag, %{flag: "--json", value: "", message: "--json requires a path"}}

      {:json, path} when is_binary(path) ->
        # Pure-string safety checks happen at parse time so a malformed
        # `--json` value produces an `:unsafe_json_path` abort-JSON before
        # any filesystem touch. The filesystem-level canonicalisation
        # (symlink resolution, inside-project-root check) happens later in
        # the mix task, before any mutation phase runs.
        case MutagenEx.JsonPath.validate_literal(path) do
          :ok -> {:ok, path}
          {:error, _, _} = err -> err
        end
    end
  end

  # `--unsafe-json-outside-project` is a plain boolean flag. OptionParser
  # accepts both `--unsafe-json-outside-project` and
  # `--unsafe-json-outside-project=true` shapes; either lands here as `true`.
  # When the flag is absent OptionParser does not include it in `parsed`, so
  # we fall back to `false`.
  defp pick_unsafe_outside_project(parsed) do
    case List.keyfind(parsed, :unsafe_json_outside_project, 0, :default) do
      :default -> false
      {:unsafe_json_outside_project, value} when is_boolean(value) -> value
    end
  end

  # `--max-concurrency <int>` — positive integer. `nil` (the default
  # stored on `Config`) means "use System.schedulers_online() at run
  # time"; the parser intentionally does NOT eagerly resolve to a
  # concrete number, so the same parsed config can produce different
  # concurrency on machines with different scheduler counts. Setting
  # to `1` forces v1.0-equivalent serial execution.
  defp pick_max_concurrency(parsed) do
    case List.keyfind(parsed, :max_concurrency, 0, :default) do
      :default ->
        {:ok, nil}

      {:max_concurrency, n} when is_integer(n) and n > 0 ->
        {:ok, n}

      {:max_concurrency, n} ->
        {:error, :invalid_max_concurrency,
         %{
           flag: "--max-concurrency",
           value: n,
           message: "--max-concurrency must be a positive integer"
         }}
    end
  end

  # `--stream` — boolean. Absent means false; present means true.
  defp pick_stream(parsed) do
    case List.keyfind(parsed, :stream, 0, :default) do
      :default -> false
      {:stream, value} when is_boolean(value) -> value
    end
  end

  # `--no-progress` — boolean. Absent means `:auto` (TTY-detected);
  # `--no-progress` forces `:off`. There is no `--progress` flag in v1.1
  # — the auto-detection behaviour is the documented default and an
  # explicit override would just shadow it.
  defp pick_progress(parsed) do
    case List.keyfind(parsed, :no_progress, 0, :default) do
      :default -> :auto
      {:no_progress, true} -> :off
      {:no_progress, false} -> :auto
    end
  end

  # --- tag-charset gate (atom-table-DOS bound, r10) ---------------------------

  # The downstream selector (`MutagenEx.TestSelector`) uses string comparison
  # against atoms found in test files' parsed AST — it never materializes a
  # fresh atom from the user's `tag:NAME` input. The charset gate is the
  # front-line bound: even with the safe selector, this keeps adversarial
  # inputs (`tag:$(uuidgen)`-style loops) from reaching the selector and
  # spending walk-time on guaranteed-no-match strings.
  #
  # Charset: `~r/\A[a-z][a-z_0-9]{0,63}\z/`. Lowercase-first, then lowercase
  # ASCII / digit / underscore, up to 64 chars total. Matches Elixir's
  # idiomatic atom-naming convention for tag literals (`@tag :slow`,
  # `@tag :integration_smoke`). Tags that need other shapes (e.g. with `?`
  # or `!` suffixes, or uppercase) are out of scope for `mix mutagen`'s
  # `tag:NAME` shorthand in v1 — the user can still cite tests by
  # `path` or `path:line`.
  @tag_name_regex ~r/\A[a-z][a-z_0-9]{0,63}\z/

  defp validate_tag_charset(tests) do
    case Enum.find(tests, &invalid_tag_target?/1) do
      nil ->
        :ok

      bad ->
        "tag:" <> name = bad

        {:error, :invalid_tag_name,
         %{
           flag: "--tests",
           target: bad,
           name: name,
           message:
             "--tests #{inspect(bad)} fails the tag-name charset gate " <>
               "(must match ~r/\\A[a-z][a-z_0-9]{0,63}\\z/); " <>
               "this is the atom-table-DOS bound (mutagen.cli.r11)"
         }}
    end
  end

  defp invalid_tag_target?("tag:" <> name) do
    not Regex.match?(@tag_name_regex, name)
  end

  defp invalid_tag_target?(_), do: false

  # --- self-mutation guard (heuristic, raw-string only) -----------------------

  @self_module_prefix "MutagenEx."
  @self_mix_task "Mix.Tasks.Mutagen"

  defp refuse_self_mutation(scopes) do
    case Enum.find(scopes, &self_module?/1) do
      nil ->
        :ok

      offender ->
        {:error, :self_mutation_refused,
         %{
           target: offender,
           message:
             "scope target #{inspect(offender)} names a mutagen_ex module; mutagen_ex cannot mutate itself in v1"
         }}
    end
  end

  # A target is "self" if it has a module-name shape (no `.ex` suffix, no
  # filesystem-y leading path component) and either starts with the self
  # prefix or matches the mix-task module exactly. The module-name shape
  # covers both bare `Module.Name` and `Module.Name.fun/arity` (MFA) forms —
  # for the MFA form we strip the trailing `/<arity>` and the trailing
  # function segment before testing the prefix.
  #
  # File-path scope targets that happen to live under `lib/mutagen_ex/` are
  # NOT caught here — the scope resolver (S3a) owns that check via real
  # resolution. This is the cheap front-line guard; full coverage lives at
  # pipeline entry per `mutagen.decision.self_mutation_refused`.
  defp self_module?(target) do
    cond do
      String.ends_with?(target, ".ex") -> false
      String.contains?(target, "/") -> self_module?(strip_mfa(target))
      target == @self_mix_task -> true
      String.starts_with?(target, @self_module_prefix) -> true
      true -> false
    end
  end

  # `MutagenEx.Foo.bar/1` → `MutagenEx.Foo`. We drop the `/<arity>` tail and
  # the final function segment. Anything that doesn't fit this shape (e.g.
  # `foo/bar.ex` — has a slash, but it's filesystem-y) drops the slash-tail
  # half and falls through to the file-path branch on the recursive call.
  defp strip_mfa(target) do
    case String.split(target, "/", parts: 2) do
      [head, _arity] ->
        case String.split(head, ".") |> Enum.reverse() do
          [_fun | mod_rev] when mod_rev != [] -> mod_rev |> Enum.reverse() |> Enum.join(".")
          _ -> head
        end

      _ ->
        target
    end
  end
end
