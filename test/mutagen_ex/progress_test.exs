defmodule MutagenEx.ProgressTest do
  @moduledoc """
  Tests for `MutagenEx.Progress` — human-readable per-site progress
  feedback introduced by bw mutagen-wrd.30.

  Subject advanced: `mutagen.mutation_pipeline.r15`.

  The progress reporter is driven by the runner's `:on_site_completed`
  callback: the Mix task wraps the callback, projects each per-site
  payload into a meta map (running index, total, status), and calls
  `report/2`. This test exercises the rendering surface directly; the
  Mix-task-level wiring (callback composition, TTY auto-detect) is
  exercised by the integration path.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias MutagenEx.Progress

  describe "enabled?/1" do
    test ":off → false; :on → true" do
      refute Progress.enabled?(:off)
      assert Progress.enabled?(:on)
    end

    test ":auto reflects stderr TTY-ness" do
      # In the test VM stderr is typically not a TTY. We only assert
      # the function is total and returns a boolean — TTY-state
      # depends on the runner.
      result = Progress.enabled?(:auto)
      assert is_boolean(result)
    end
  end

  describe "report/2" do
    test "writes [index/total] status file:line :mutator" do
      meta = %{
        index: 3,
        total: 42,
        status: :killed,
        file: "lib/foo.ex",
        line: 17,
        mutator: :arith,
        site_id: "x"
      }

      output = capture_io(:stderr, fn -> Progress.report(meta, :stderr) end)
      assert output =~ "[3/42]"
      assert output =~ "killed"
      assert output =~ "lib/foo.ex:17"
      assert output =~ ":arith"
      assert String.ends_with?(output, "\n")
    end

    test "status column is padded to a stable width" do
      meta_killed = %{
        index: 1,
        total: 1,
        status: :killed,
        file: "lib/a.ex",
        line: 1,
        mutator: :arith,
        site_id: "x"
      }

      meta_compile_error = %{
        meta_killed
        | status: :compile_error
      }

      out1 = capture_io(:stderr, fn -> Progress.report(meta_killed, :stderr) end)
      out2 = capture_io(:stderr, fn -> Progress.report(meta_compile_error, :stderr) end)

      # The padded status is followed by a single space then the file.
      # Asserting the padded width is stable: both lines have the same
      # offset where the file column begins.
      [_prefix, after1] = String.split(out1, "lib/a.ex", parts: 2)
      [_prefix, after2] = String.split(out2, "lib/a.ex", parts: 2)
      assert after1 == after2
    end
  end

  describe "Mix-task callback wiring (mutagen.mutation_pipeline.r15)" do
    # The progress feed is driven by the runner's `:on_site_completed`
    # callback now, not a telemetry handler. `Mix.Tasks.Mutagen` builds
    # a stateful reporter that projects each per-site callback payload
    # into the meta map `report/2` renders. These tests pin that
    # projection + the index counter + the `--no-progress` suppression.

    test "reporter renders a line per :result payload with a running index" do
      reporter = Mix.Tasks.Mutagen.__build_progress_reporter__(:on, :stderr)
      assert is_function(reporter, 2)

      result_a = %{id: "a", status: :killed, file: "lib/foo.ex", line: 17, mutator: :arith}
      result_b = %{id: "b", status: :survived, file: "lib/foo.ex", line: 18, mutator: :arith}

      out =
        capture_io(:stderr, fn ->
          reporter.({:result, result_a}, 2)
          reporter.({:result, result_b}, 2)
        end)

      lines = String.split(String.trim_trailing(out, "\n"), "\n")
      assert length(lines) == 2

      # The closed-over counter advances 1 → 2 across calls; total is
      # constant.
      assert Enum.at(lines, 0) =~ "[1/2]"
      assert Enum.at(lines, 0) =~ "killed"
      assert Enum.at(lines, 0) =~ "lib/foo.ex:17"
      assert Enum.at(lines, 1) =~ "[2/2]"
      assert Enum.at(lines, 1) =~ "survived"
    end

    test "reporter renders :compile_error payloads as compile_error status" do
      reporter = Mix.Tasks.Mutagen.__build_progress_reporter__(:on, :stderr)

      entry = %{id: "c", file: "lib/bar.ex", line: 9, mutator: :literal, message: "boom"}

      out = capture_io(:stderr, fn -> reporter.({:compile_error, entry}, 1) end)

      assert out =~ "[1/1]"
      assert out =~ "compile_error"
      assert out =~ "lib/bar.ex:9"
      assert out =~ ":literal"
    end

    test ":off / --no-progress builds no reporter (feed suppressed)" do
      assert Mix.Tasks.Mutagen.__build_progress_reporter__(:off, :stderr) == nil
    end
  end
end
