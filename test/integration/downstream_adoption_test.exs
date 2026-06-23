defmodule MutagenEx.Integration.DownstreamAdoptionTest do
  @moduledoc """
  Downstream-adoption integration test (mutagen-wrd.39, S4).

  Boots a brand-new Mix project in `System.tmp_dir!()`, adds `mutagen_ex`
  as a `path:` dep pointing back at this project's root, writes a trivial
  scope module plus a trivial test file, and drives `mix mutagen` against
  the tmp project via `System.cmd/3` from a fresh shell. Parses the JSON
  document on stdout and asserts the run completed (`aborted == false`,
  `abort_reason == nil`, `mutation.total > 0`, exit code `0`).

  This is the load-bearing regression gate for the runtime preamble
  contract (`mutagen.cli.r14`, scenario `mutagen.cli.s14a`):

      Without the preamble, a downstream caller invoking `mix mutagen`
      from a fresh shell against their own project aborts with
      `:module_beam_missing` / `:test_file_load_failed` / no-process
      crash on `MutagenEx.TaskSup`.

  If S1/S2/S3's preamble pieces regress (loadpaths, compile,
  ensure_all_started, ExUnit.start(autorun: false)), this test fails.

  Tagged `:downstream_integration` so the default `mix test` run skips
  it (it spawns an OS child process per run and is slower than the
  in-process suite). The dedicated tag (rather than the shared
  `:integration` tag) avoids accidentally demoting pre-existing
  `:integration`-tagged tests in the in-process suite from the default
  lane. Run explicitly via `mix test --include downstream_integration`
  or `mix test.integration`.
  """

  use ExUnit.Case, async: false

  @moduletag :downstream_integration

  # Path to this project's root, used to wire `mutagen_ex` as a `path:` dep
  # in the generated downstream project. `__DIR__` is the directory of this
  # test file (`test/integration/`); `Path.expand("../..", __DIR__)` climbs
  # two segments back to the repo root.
  @project_root Path.expand("../..", __DIR__)

  test "fresh-shell `mix mutagen` against a downstream path: dep succeeds" do
    rand = :rand.uniform(1_000_000_000) |> Integer.to_string()
    app_name = "mutagen_ex_downstream_test_#{rand}"
    tmp_dir = Path.join(System.tmp_dir!(), app_name)

    # Hard-fail fast if a previous run left a directory behind under the
    # same name (vanishingly unlikely with a 1-in-a-billion random suffix,
    # but cheap to guard).
    File.rm_rf!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # ── 1. Bootstrap a fresh Mix project. ────────────────────────────────
    {new_out, new_code} =
      System.cmd("mix", ["new", app_name],
        cd: System.tmp_dir!(),
        stderr_to_stdout: true,
        env: clean_env()
      )

    assert new_code == 0,
           "`mix new #{app_name}` failed (exit #{new_code}):\n#{new_out}"

    assert File.dir?(tmp_dir),
           "expected `mix new` to create #{tmp_dir}, but it does not exist"

    # ── 2. Patch mix.exs to add mutagen_ex as a path: dep. The generated
    #      template inlines a `deps/0` whose body is `[ # comments... ]`.
    #      Replace the whole body with a single `:mutagen_ex` entry; the
    #      regex anchors on `defp deps do\n    [` ... `]\n  end` (the
    #      indentation `mix new` emits today) and falls back to a more
    #      permissive match if upstream tweaks whitespace. ────────────────
    mix_exs_path = Path.join(tmp_dir, "mix.exs")
    original_mix_exs = File.read!(mix_exs_path)

    deps_block = """
    defp deps do
        [
          {:mutagen_ex, path: #{inspect(@project_root)}}
        ]
      end\
    """

    patched_mix_exs =
      Regex.replace(
        ~r/defp deps do\s*\[.*?\]\s*end/s,
        original_mix_exs,
        deps_block,
        global: false
      )

    assert patched_mix_exs != original_mix_exs,
           "failed to inject mutagen_ex path: dep into generated mix.exs:\n#{original_mix_exs}"

    File.write!(mix_exs_path, patched_mix_exs)

    # ── 3. Write a trivial scope module. ─────────────────────────────────
    calc_module = Macro.camelize(app_name) <> ".Calc"
    calc_path = Path.join([tmp_dir, "lib", app_name, "calc.ex"])
    File.mkdir_p!(Path.dirname(calc_path))

    File.write!(calc_path, """
    defmodule #{calc_module} do
      @moduledoc false

      def add(a, b), do: a + b
    end
    """)

    # ── 4. Write a trivial test file. ────────────────────────────────────
    calc_test_path = Path.join([tmp_dir, "test", app_name, "calc_test.exs"])
    File.mkdir_p!(Path.dirname(calc_test_path))

    File.write!(calc_test_path, """
    defmodule #{calc_module}Test do
      use ExUnit.Case, async: true

      test "add/2 sums two integers" do
        assert #{calc_module}.add(1, 2) == 3
      end

      test "add/2 is commutative for integers" do
        assert #{calc_module}.add(2, 3) == #{calc_module}.add(3, 2)
      end
    end
    """)

    # ── 5. Resolve deps + compile the downstream project once before
    #      driving `mix mutagen`. This matches the spec's "downstream
    #      project freshly cloned and installed" precondition while
    #      keeping the assertion focused on the preamble's contract
    #      (load paths, ExUnit.start, application boot — not the
    #      first-time dep fetch). ────────────────────────────────────────
    {deps_out, deps_code} =
      System.cmd("mix", ["deps.get"],
        cd: tmp_dir,
        stderr_to_stdout: true,
        env: clean_env()
      )

    assert deps_code == 0, "`mix deps.get` failed (exit #{deps_code}):\n#{deps_out}"

    # ── 6. Drive `mix mutagen` from the tmp project root in what amounts
    #      to a fresh shell (no prior `mix test`, no IEx session, no
    #      manual preload). Capture stdout (JSON) and stderr separately
    #      so a stray warning does not pollute the JSON we decode. ──────
    relative_scope = Path.join(["lib", app_name, "calc.ex"])
    relative_tests = Path.join(["test", app_name, "calc_test.exs"])

    {mutagen_out, mutagen_code} =
      System.cmd(
        "mix",
        ["mutagen", "--scope", relative_scope, "--tests", relative_tests],
        cd: tmp_dir,
        stderr_to_stdout: false,
        env: clean_env()
      )

    assert mutagen_code == 0,
           """
           `mix mutagen` exited #{mutagen_code} in the downstream project.
           stdout:
           #{mutagen_out}
           """

    # ── 7. Parse stdout as JSON (no new deps — use OTP's built-in
    #      `:json.decode/1`). `mix mutagen` emits the final report as
    #      a single line that begins with `{` and ends with `}\n`, but
    #      stdout also carries pretty-printed ExUnit output from each
    #      mutated run (mutated tests print failure messages to stdout
    #      when they fail — that is how the mutant is judged "killed").
    #      Per `mutagen.cli.r5` the JSON document is terminated by a
    #      single newline; extract the last non-empty line that decodes
    #      as JSON. ───────────────────────────────────────────────────
    json_line = extract_json_document(mutagen_out)

    decoded =
      try do
        :json.decode(json_line)
      rescue
        e ->
          flunk("""
          extracted JSON line did not decode: #{Exception.message(e)}

          --- extracted line ---
          #{json_line}

          --- raw stdout ---
          #{mutagen_out}
          """)
      end

    assert is_map(decoded),
           "expected JSON object at top level, got: #{inspect(decoded)}"

    # ── 8. Assert the run completed without aborting and mutated
    #      something — these together prove the preamble booted the
    #      host modules, started ExUnit, and started :mutagen_ex so
    #      the pipeline could reach the mutation phase. ────────────────
    assert decoded["aborted"] == false,
           "expected aborted: false, got: #{inspect(decoded["aborted"])}\n" <>
             "full document: #{inspect(decoded, pretty: true, limit: :infinity)}"

    # OTP's `:json.decode/1` represents JSON `null` as the atom `:null`,
    # not `nil`. The ticket's "abort_reason == nil" is shorthand for
    # "the wire value is JSON null" — accept either to stay decode-impl
    # agnostic.
    assert decoded["abort_reason"] in [nil, :null],
           "expected abort_reason JSON null, got: #{inspect(decoded["abort_reason"])}\n" <>
             "full document: #{inspect(decoded, pretty: true, limit: :infinity)}"

    mutation = decoded["mutation"]

    assert is_map(mutation),
           "expected `mutation` block to be a map, got: #{inspect(mutation)}"

    total = mutation["total"]

    assert is_integer(total) and total > 0,
           "expected mutation.total > 0, got: #{inspect(total)}\n" <>
             "full document: #{inspect(decoded, pretty: true, limit: :infinity)}"

    assert mutation["completed"] > 0,
           "expected at least one mutation to have executed, not just been enumerated"
  end

  # `mix new` and `mix mutagen` both honor MIX_* and ELIXIR_* env vars from
  # the parent process. Pass a clean env that preserves PATH and HOME (so
  # `mix`, `elixir`, and `~/.mix` resolve) but drops MIX_ENV (so the tmp
  # project compiles in :dev) and MIX_TARGET (so it picks the default
  # target). Anything else inherits — we deliberately do not strip
  # everything because Hex/rebar3 paths live in HOME-rooted dirs.
  defp clean_env do
    [
      {"MIX_ENV", nil},
      {"MIX_TARGET", nil}
    ]
  end

  # Walk `mix mutagen` stdout from the bottom up and return the first
  # line that parses as a JSON object — that is the report document per
  # `mutagen.cli.r5`. Lines above it are pretty-printed ExUnit output
  # from the per-mutation runs (killed mutants emit ExUnit failure
  # messages to stdout); they are not part of the contract surface.
  defp extract_json_document(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find(fn line ->
      trimmed = String.trim(line)

      String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}") and
        json_parses?(trimmed)
    end)
    |> case do
      nil ->
        flunk("""
        no JSON document found in `mix mutagen` stdout.

        --- raw stdout ---
        #{stdout}
        """)

      line ->
        String.trim(line)
    end
  end

  defp json_parses?(line) do
    _ = :json.decode(line)
    true
  rescue
    _ -> false
  end
end
