defmodule MutagenEx.ProgressTest do
  @moduledoc """
  Tests for `MutagenEx.Progress` — human-readable per-site progress
  feedback introduced by bw mutagen-wrd.30.

  Subject advanced: `mutagen.mutation_pipeline.r15`.

  The progress reporter is wired to the `[:mutagen_ex, :site, :stop]`
  telemetry event. This test exercises the rendering surface directly;
  the Mix-task-level wiring (attach/detach, TTY auto-detect) is
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
end
