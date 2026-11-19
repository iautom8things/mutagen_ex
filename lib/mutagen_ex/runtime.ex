defmodule MutagenEx.Runtime do
  @moduledoc """
  Prepares a host Mix project and its ExUnit environment for an in-process run.
  """

  alias MutagenEx.JsonReporter.Sanitizer

  @tool_version Mix.Project.config()[:version]
  @boot_timeout_ms 300_000

  def tool_version, do: @tool_version

  @doc """
  Loads test support, runs host test-alias pre-steps and starts the test suite.
  Returns a session with the test paths, ExUnit filters, and cleanup callbacks.
  Pass the session to `finish/2` after running tests. The boot worker stays alive
  through cleanup so services linked by the test helper remain available.
  Compilation is outside the startup deadline.
  """
  def boot(opts \\ []) do
    with :ok <- ensure_test_env(Mix.env(), System.get_env("MIX_ENV"), opts[:command]),
         :ok <- ensure_test_project(Mix.Project.config()),
         :ok <- step(:host_loadpaths_failed, fn -> mix_task("loadpaths") end),
         :ok <- step(:host_compile_failed, &compile_host/0),
         {:ok, session} <- timed_boot(opts) do
      {:ok, Map.merge(session, %{test_paths: test_paths(), exunit: ExUnit.configuration()})}
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
        set_phase = fn phase -> send(caller, {ref, :phase, phase}) end

        case initialize_host(opts, set_phase) do
          :ok ->
            send(caller, {ref, {:ok, %{worker: self(), callbacks: take_after_suite()}}})
            keep_helper_alive(caller)

          {:error, _, _} = error ->
            run_callbacks(take_after_suite(), empty_suite())
            send(caller, {ref, error})
        end
      end)

    await_boot(pid, monitor, ref, deadline, timeout, :host_app_start_failed)
  end

  defp keep_helper_alive(caller) do
    monitor = Process.monitor(caller)

    receive do
      :stop -> :ok
      {:DOWN, ^monitor, :process, ^caller, _} -> :ok
    end
  end

  defp await_boot(pid, monitor, ref, deadline, timeout, phase) do
    receive do
      {^ref, :phase, next} ->
        await_boot(pid, monitor, ref, deadline, timeout, next)

      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        run_callbacks(take_after_suite(), empty_suite())
        failure(phase, :exit, reason, [])
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        end

        run_callbacks(take_after_suite(), empty_suite())

        {:error, :host_setup_timeout,
         %{message: "Host setup exceeded --boot-timeout-ms #{timeout}", step: phase}}
    end
  end

  defp initialize_host(opts, set_phase) do
    set_phase.(:host_app_start_failed)

    with :ok <- step(:host_app_start_failed, fn -> mix_task("app.config") end),
         :ok <- configure_logger(opts),
         :ok <- boot_step(set_phase, :test_alias_failed, fn -> run_test_alias(opts) end),
         :ok <- boot_step(set_phase, :host_app_start_failed, fn -> maybe_start_host_app(opts) end),
         :ok <- boot_step(set_phase, :runtime_load_failed, &start_mutagen/0) do
      boot_step(set_phase, :test_helper_load_failed, &load_test_helpers/0)
    end
  end

  defp boot_step(set_phase, reason, fun) do
    set_phase.(reason)
    step(reason, fun)
  end

  defp step(reason, fun) do
    case fun.() do
      :ok -> :ok
      {:error, message} -> failure(reason, :message, message, [])
      {:error, _, _} = error -> error
    end
  rescue
    error -> failure(reason, :error, error, __STACKTRACE__)
  catch
    kind, value -> failure(reason, kind, value, __STACKTRACE__)
  end

  defp failure(reason, kind, value, stack) do
    message = if kind == :message, do: value, else: Exception.format_banner(kind, value, stack)
    IO.puts(:stderr, [message, "\n", Exception.format_stacktrace(stack)])
    summary = if kind == :error, do: Exception.message(value), else: message
    details = %{message: Sanitizer.summary(short_message(reason, summary))}

    case reason do
      :test_helper_load_failed ->
        location =
          Enum.find_value(stack, %{}, fn {_, _, _, meta} ->
            case meta[:file] && to_string(meta[:file]) do
              nil ->
                nil

              file ->
                if String.ends_with?(file, ".exs"), do: %{file: file, line: meta[:line]}
            end
          end)

        {:error, reason, Map.merge(details, location)}

      _ ->
        {:error, reason, details}
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
    Regex.replace(~r/(no match of right hand side value:).*/, message, "\\1 [REDACTED]")
  end

  defp configure_logger(opts) do
    if opts[:redirect_logger], do: route_default_logger()
    :ok
  end

  @doc false
  def route_default_logger do
    # App.start restarts Logger and reads this setting again.
    case Application.get_env(:logger, :default_handler, []) do
      handler when is_list(handler) ->
        config = Map.new(Keyword.get(handler, :config, []))

        if Keyword.get(handler, :module, :logger_std_h) == :logger_std_h and
             Map.get(config, :type, :standard_io) == :standard_io do
          Application.put_env(
            :logger,
            :default_handler,
            Keyword.put(handler, :config, Map.put(config, :type, :standard_error)),
            persistent: true
          )
        end

      _ ->
        :ok
    end

    with {:ok, %{module: :logger_std_h, config: %{type: :standard_io} = device} = config} <-
           :logger.get_handler_config(:default),
         :ok <- :logger.remove_handler(:default) do
      :logger.add_handler(:default, :logger_std_h, %{
        config
        | config: %{device | type: :standard_error}
      })
    end

    :ok
  end

  defp run_test_alias(opts) do
    if Keyword.get(opts, :test_alias, true) do
      entries = List.wrap(Mix.Project.config()[:aliases][:test])

      case Enum.split_while(entries, &(not test_task?(&1))) do
        {pre_steps, [_test_task | _]} ->
          Enum.reduce_while(pre_steps, :ok, &run_test_alias_entry/2)

        {_, []} ->
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
      continue_alias(task_result("test alias function", fun.([])))
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

  defp load_test_helpers do
    ExUnit.start(autorun: false)
    shell = Mix.shell()

    try do
      Enum.reduce_while(test_paths(), :ok, fn root, :ok ->
        file = Path.join(root, "test_helper.exs")

        case step(:test_helper_load_failed, fn ->
               Code.require_file(file)
               :ok
             end) do
          :ok -> {:cont, :ok}
          {:error, reason, details} -> {:halt, {:error, reason, Map.put(details, :file, file)}}
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
  def finish(%{worker: worker, callbacks: callbacks}, stats) do
    run_callbacks(callbacks, stats)
  after
    if is_pid(worker), do: send(worker, :stop)
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
