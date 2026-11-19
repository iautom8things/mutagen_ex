defmodule MutagenEx.Runtime do
  @moduledoc """
  Prepares a host Mix project and its ExUnit environment for an in-process run.
  """

  alias MutagenEx.JsonReporter.{Provenance, Redactor}

  @tool_version Mix.Project.config()[:version]
  @boot_timeout_ms 300_000
  @stderr_note "Stderr may carry unredacted host output. Do not publish it as a CI artifact."

  def tool_version, do: @tool_version

  @doc """
  Loads test support, runs host test-alias pre-steps and starts the test suite.
  Returns a session with the test paths, ExUnit filters, and cleanup callbacks.
  Pass the session to `finish/2` after running tests. The boot worker stays alive
  through cleanup so services linked by the test helper remain available.
  Compilation is outside the startup deadline.
  """
  def boot(opts \\ []) do
    result =
      with :ok <- ensure_test_env(Mix.env(), System.get_env("MIX_ENV"), opts[:command]),
           :ok <- ensure_test_project(Mix.Project.config()),
           :ok <- step(:host_loadpaths_failed, fn -> mix_task("loadpaths") end),
           :ok <- step(:host_compile_failed, &compile_host/0),
           {:ok, session} <- timed_boot(opts) do
        {:ok, Map.merge(session, %{test_paths: test_paths(), exunit: ExUnit.configuration()})}
      end

    case result do
      {:error, reason, details, session} ->
        details = Map.put(details, :note, @stderr_note)

        if opts[:defer_cleanup] do
          {:error, reason, details, session}
        else
          _ = finish(session, empty_suite())
          {:error, reason, details}
        end

      {:error, reason, details} ->
        {:error, reason, Map.put(details, :note, @stderr_note)}

      ok ->
        ok
    end
  end

  def test_paths do
    Mix.Project.config()[:test_paths] || if(File.dir?("test"), do: ["test"], else: [])
  end

  defp ensure_test_project(config) do
    if Mix.Project.umbrella?(config) do
      {:error, :umbrella_root,
       %{message: "Run mix mutagen from apps/<app>, the umbrella child that owns the tests."}}
    else
      :ok
    end
  end

  defp ensure_test_env(:test, _, _), do: :ok
  defp ensure_test_env(_env, explicit, _) when is_binary(explicit), do: :ok

  defp ensure_test_env(env, nil, command) do
    {:error, :invalid_mix_env,
     %{
       message:
         "mix mutagen needs a test environment (current Mix environment: #{env}). " <>
           "Run #{command || "MIX_ENV=test mix mutagen --scope <target> --tests <target>"} " <>
           "or set `def cli, do: [preferred_envs: [mutagen: :test]]` in mix.exs."
     }}
  end

  defp compile_host do
    with :ok <- Application.ensure_loaded(:ex_unit) do
      mix_task("compile", ["--return-errors"])
    else
      {:error, reason} -> {:error, Application.format_error(reason)}
    end
  end

  defp timed_boot(opts) do
    timeout = Keyword.get(opts, :boot_timeout_ms, @boot_timeout_ms)
    caller = self()
    ref = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout
    events = Process.get(:mutagen_runtime_event_target)
    forced_start = Process.get(:mutagen_ensure_runtime_force_failure)

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:mutagen_runtime_event_target, events)
        Process.put(:mutagen_ensure_runtime_force_failure, forced_start)
        notify = fn key, value -> send(caller, {ref, key, value}) end

        case initialize_host(opts, notify) do
          :ok ->
            send(caller, {ref, :ok, self(), take_after_suite()})
            keep_helper_alive(caller)

          {:error, reason, details} ->
            send(caller, {ref, :error, reason, details, self(), take_after_suite()})
            keep_helper_alive(caller)
        end
      end)

    session = %{
      worker: nil,
      callbacks: [],
      patterns: [],
      warnings: [],
      helper_tags: MapSet.new(),
      cleanup_timeout: timeout
    }

    await_boot(pid, monitor, ref, deadline, timeout, :runtime_config, session)
  end

  defp keep_helper_alive(caller) do
    monitor = Process.monitor(caller)

    receive do
      :stop -> :ok
      {:DOWN, ^monitor, :process, ^caller, _} -> :ok
    end
  end

  defp await_boot(pid, monitor, ref, deadline, timeout, phase, session) do
    receive do
      {^ref, :phase, next} ->
        await_boot(pid, monitor, ref, deadline, timeout, next, session)

      {^ref, key, value} when key in [:patterns, :warnings, :helper_tags] ->
        await_boot(pid, monitor, ref, deadline, timeout, phase, Map.replace!(session, key, value))

      {^ref, :ok, worker, callbacks} ->
        Process.demonitor(monitor, [:flush])
        {:ok, %{session | worker: worker, callbacks: callbacks}}

      {^ref, :error, reason, details, worker, callbacks} ->
        Process.demonitor(monitor, [:flush])

        {:error, reason, Map.put_new(details, :step, phase),
         %{session | worker: worker, callbacks: callbacks}}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, report_reason, details} = failure(step_reason(phase), :exit, reason, [], nil)

        {:error, report_reason, Map.put(details, :step, phase),
         %{session | callbacks: take_after_suite()}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        {:error, :host_setup_timeout,
         %{
           message: "Host setup exceeded --boot-timeout-ms #{timeout}",
           step: phase,
           limit: timeout
         }, %{session | callbacks: take_after_suite()}}
    end
  end

  defp initialize_host(opts, notify) do
    set_phase = &notify.(:phase, &1)

    with :ok <- boot_step(set_phase, :runtime_config, fn -> mix_task("app.config") end),
         :ok <- configure_logger(opts),
         :ok <- boot_step(set_phase, :redact_config, fn -> validate_redact_config(notify) end),
         :ok <- boot_step(set_phase, :test_alias, fn -> run_test_alias(opts, notify) end),
         :ok <- boot_step(set_phase, :host_app, fn -> maybe_start_host_app(opts) end),
         :ok <- boot_step(set_phase, :mutagen_runtime, &start_mutagen/0) do
      boot_step(set_phase, :test_helper, fn ->
        notify.(:helper_tags, literal_helper_tags())
        load_test_helpers()
      end)
    end
  end

  defp step_reason(:runtime_config), do: :host_app_start_failed
  defp step_reason(:redact_config), do: :invalid_redact_config
  defp step_reason(:test_alias), do: :test_alias_failed
  defp step_reason(:host_app), do: :host_app_start_failed
  defp step_reason(:mutagen_runtime), do: :runtime_load_failed
  defp step_reason(:test_helper), do: :test_helper_load_failed

  defp validate_redact_config(notify) do
    case Redactor.compile(Application.get_env(:mutagen_ex, :redact, [])) do
      {:ok, patterns} ->
        notify.(:patterns, patterns)
        :ok

      :error ->
        {:error, :invalid_redact_config, %{}}
    end
  end

  defp boot_step(set_phase, reason, fun) do
    set_phase.(reason)
    step(step_reason(reason), fun)
  end

  defp step(reason, fun, helper \\ nil) do
    case fun.() do
      :ok -> :ok
      {:error, message} -> failure(reason, :message, message, [], helper)
      {:error, _, _} = error -> error
    end
  rescue
    error -> failure(reason, :error, error, __STACKTRACE__, helper)
  catch
    kind, value -> failure(reason, kind, value, __STACKTRACE__, helper)
  end

  defp failure(reason, kind, value, stack, helper) do
    message = if kind == :message, do: value, else: Exception.format_banner(kind, value, stack)
    IO.puts(:stderr, [message, "\n", Exception.format_stacktrace(stack)])
    summary = if kind == :error, do: Exception.message(value), else: message
    details = %{message: short_message(reason, summary)}
    details = put_exception_facts(details, kind, value, stack)

    if helper,
      do: {:error, reason, Map.merge(details, helper_location(helper, stack))},
      else: {:error, reason, details}
  end

  @doc false
  def exception_facts(%module{}, stack) do
    case Provenance.stack_locations(stack) do
      [{file, line} | _] -> %{exception: module, file: file, line: line}
      [] -> %{exception: module}
    end
  end

  defp put_exception_facts(details, :error, error, stack),
    do: Map.merge(details, exception_facts(error, stack))

  defp put_exception_facts(details, kind, value, _)
       when kind in [:exit, :throw] and is_atom(value),
       do: Map.put(details, :reason, value)

  defp put_exception_facts(details, _, _, _), do: details

  # The line comes from the helper's own frame. A failure raised in a file
  # the helper evaluated, such as a seeds script, is reported as the origin.
  defp helper_location(helper, stack) do
    in_helper? = fn {file, _line} -> Path.expand(file) == Path.expand(helper) end

    {inner, from_helper} =
      Provenance.stack_locations(stack)
      |> Enum.split_while(&(not in_helper?.(&1)))

    location =
      case from_helper do
        [{_file, line} | _] when is_integer(line) -> %{file: helper, line: line}
        _ -> %{file: helper}
      end

    case Enum.find(inner, fn {file, _line} -> String.ends_with?(file, ".exs") end) do
      {file, line} ->
        Map.merge(location, %{origin_file: Path.relative_to_cwd(file), origin_line: line})

      nil ->
        location
    end
  end

  defp short_message(:host_app_start_failed, "Could not start application " <> rest) do
    [app | _] = String.split(rest, ":", parts: 2)

    case Regex.run(~r/failed to start child: ([^\n]+)/, rest, capture: :all_but_first) do
      [child] -> "Could not start application #{app}. Failed child #{child}"
      _ -> "Could not start application #{app}"
    end
  end

  defp short_message(_reason, message) do
    Regex.replace(~r/(no match of right hand side value:).*/s, message, "\\1 [REDACTED]")
  end

  defp configure_logger(opts) do
    if opts[:redirect_logger], do: route_default_logger()
    :ok
  end

  @doc false
  def route_default_logger do
    stderr = {:device, Process.whereis(:standard_error)}
    # App.start restarts Logger and reads this setting again.
    case Application.get_env(:logger, :default_handler, []) do
      handler when is_list(handler) ->
        config = Map.new(Keyword.get(handler, :config, []))

        if Keyword.get(handler, :module, :logger_std_h) == :logger_std_h and
             Map.get(config, :type, :standard_io) in [:standard_io, :standard_error] do
          Application.put_env(
            :logger,
            :default_handler,
            Keyword.put(handler, :config, Map.put(config, :type, stderr)),
            persistent: true
          )
        end

      _ ->
        :ok
    end

    with {:ok, %{module: :logger_std_h, config: %{type: type} = device} = config} <-
           :logger.get_handler_config(:default),
         true <- type in [:standard_io, :standard_error],
         :ok <- :logger.remove_handler(:default) do
      :logger.add_handler(:default, :logger_std_h, %{
        config
        | config: %{device | type: stderr}
      })
    end

    :ok
  end

  defp run_test_alias(opts, notify) do
    if Keyword.get(opts, :test_alias, true) do
      entries = List.wrap(Mix.Project.config()[:aliases][:test])

      case Enum.split_while(entries, &(not test_task?(&1))) do
        {pre_steps, [_test_task | _]} ->
          Enum.reduce_while(pre_steps, :ok, &run_test_alias_entry/2)

        {[], []} ->
          :ok

        {_, []} ->
          notify.(:warnings, ["test_alias_skipped: no test entry in the host test alias"])
          :ok
      end
    else
      :ok
    end
  end

  defp test_task?(entry) when is_binary(entry),
    do: match?(["test" | _], OptionParser.split(entry))

  defp test_task?(_entry), do: false

  defp run_test_alias_entry(entry, :ok) when is_binary(entry) do
    case OptionParser.split(entry) do
      [task | args] -> continue_alias(mix_task(task, args))
      [] -> Mix.raise("Empty entry in the test alias")
    end
  end

  defp run_test_alias_entry(fun, :ok) when is_function(fun, 1) do
    try do
      fun.([])
      {:cont, :ok}
    after
      Mix.Local.append_archives()
    end
  end

  defp run_test_alias_entry(entry, :ok),
    do: Mix.raise("Invalid test alias entry: #{inspect(entry)}")

  defp continue_alias(:ok), do: {:cont, :ok}
  defp continue_alias({:error, _} = error), do: {:halt, error}

  defp maybe_start_host_app(opts) do
    if Keyword.get(opts, :host_app, true) and
         System.get_env("MUTAGEN_NO_HOST_APP") not in ["1", "true", "TRUE", "yes", "YES"] do
      with :ok <- mix_task("app.start", ["--temporary"]) do
        record_runtime_event(:append_archives_after_app_start)
        :ok
      end
    else
      record_runtime_event(:app_start_skipped)
      :ok
    end
  end

  defp mix_task(task, args \\ []) do
    with :ok <- task_result(task, Mix.Task.run(task, args)) do
      record_runtime_event({:mix_task_run, task})
      :ok
    end
  after
    # Mix compilers prune installed archive ebins, even with --no-compile.
    Mix.Local.append_archives()
  end

  defp task_result(task, {:error, diagnostics}) when is_list(diagnostics) do
    case Enum.find(diagnostics, &match?(%{severity: :error}, &1)) do
      %{message: message} -> {:error, message}
      nil -> {:error, "mix #{task} failed"}
    end
  end

  defp task_result(task, {:error, reason}), do: {:error, "mix #{task} failed: #{inspect(reason)}"}
  defp task_result(task, :error), do: {:error, "mix #{task} failed"}
  defp task_result(_, _), do: :ok

  defp record_runtime_event(event) do
    if target = Process.get(:mutagen_runtime_event_target) do
      send(target, {:mutagen_runtime_event, event})
    end
  end

  defp literal_helper_tags do
    Enum.reduce(test_paths(), MapSet.new(), fn path, acc ->
      with {:ok, source} <- File.read(Path.join(path, "test_helper.exs")),
           {:ok, ast} <- Code.string_to_quoted(source) do
        {_, tags} =
          Macro.prewalk(ast, acc, fn
            atom, tags when is_atom(atom) -> {atom, MapSet.put(tags, atom)}
            node, tags -> {node, tags}
          end)

        tags
      else
        _ -> acc
      end
    end)
  end

  defp load_test_helpers do
    ExUnit.start(autorun: false)
    shell = Mix.shell()

    try do
      Enum.reduce_while(test_paths(), :ok, fn root, :ok ->
        file = Path.join(root, "test_helper.exs")

        case step(
               :test_helper_load_failed,
               fn ->
                 Code.require_file(file)
                 :ok
               end,
               file
             ) do
          :ok -> {:cont, :ok}
          {:error, _reason, _details} = error -> {:halt, error}
        end
      end)
    after
      Mix.shell(shell)
      ExUnit.configure(autorun: false)
    end
  end

  defp start_mutagen do
    case ensure_mutagen_started() do
      {:ok, _apps} ->
        :ok

      {:error, _} = error ->
        {:error,
         "mutagen_ex could not start from the installed archive. " <>
           "Reinstall it with `mix archive.uninstall mutagen_ex && mix archive.install <ez>`. " <>
           "Last error: #{inspect(error)}"}
    end
  end

  @doc false
  def take_after_suite do
    callbacks = Application.get_env(:ex_unit, :after_suite, [])
    ExUnit.configure(after_suite: [])
    callbacks
  end

  @doc "Runs the session's after-suite callbacks and releases its boot worker."
  def finish(%{worker: worker, callbacks: callbacks} = session, stats) do
    case with_deadline(Map.get(session, :cleanup_timeout, @boot_timeout_ms), fn ->
           run_callbacks(callbacks, stats)
         end) do
      {:ok, result} -> result
      :timeout -> :timeout
      {:exit, reason} -> failure(:after_suite_failed, :exit, reason, [], nil)
    end
  after
    if is_pid(worker), do: send(worker, :stop)
  end

  @doc false
  def with_deadline(timeout, fun) do
    caller = self()
    ref = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(caller, {ref, fun.()}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        {:ok, result}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:exit, reason}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        :timeout
    end
  end

  @doc false
  def empty_suite, do: %{total: 0, failures: 0, excluded: 0, skipped: 0}

  defp run_callbacks(callbacks, stats) do
    Enum.reduce(callbacks, :ok, fn callback, result ->
      case step(:after_suite_failed, fn ->
             callback.(stats)
             :ok
           end) do
        :ok -> result
        error when result == :ok -> error
        _ -> result
      end
    end)
  end

  defp ensure_mutagen_started do
    case runtime_ensure_all_started() do
      {:ok, _apps} = ok ->
        ok

      {:error, _reason} = error ->
        maybe_repair_archive_context(error)
    end
  end

  defp maybe_repair_archive_context(error) do
    if archive_context_failure?(error) do
      # Primary repair uses Mix's documented intent-level archive path helper;
      # the ebin scan is a defensive fallback if archive appending regresses.
      Mix.Local.append_archives()

      case runtime_ensure_all_started() do
        {:ok, _apps} = ok ->
          ok

        {:error, _reason} = retry_error ->
          _ = add_first_mutagen_archive_ebin()
          retry_after_archive_scan(retry_error)
      end
    else
      error
    end
  end

  defp retry_after_archive_scan(previous_error) do
    case runtime_ensure_all_started() do
      {:ok, _apps} = ok -> ok
      {:error, _reason} -> previous_error
    end
  end

  defp runtime_ensure_all_started do
    case Process.get(:mutagen_ensure_runtime_force_failure) do
      nil ->
        Application.ensure_all_started(:mutagen_ex)

      fun when is_function(fun, 0) ->
        fun.()

      [result | rest] ->
        Process.put(:mutagen_ensure_runtime_force_failure, rest)
        result

      result ->
        result
    end
  end

  defp archive_context_failure?({:error, {:mutagen_ex, :non_existing}}), do: true
  defp archive_context_failure?({:error, {:mutagen_ex, {:non_existing, _}}}), do: true
  defp archive_context_failure?({:error, {:mutagen_ex, {_, ~c"mutagen_ex.app"}}}), do: true
  defp archive_context_failure?(_), do: false

  defp add_first_mutagen_archive_ebin do
    Mix.path_for(:archives)
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.find_value(:not_found, fn archive ->
      ebin = Mix.Local.archive_ebin(archive)
      app_file = Path.join(to_string(ebin), "mutagen_ex.app")

      if File.exists?(app_file) do
        :code.add_pathz(to_charlist(ebin))
      else
        false
      end
    end)
  end
end
