defmodule MutagenEx.Test.RunGroupTest do
  use ExUnit.Case, async: false

  alias MutagenEx.MutationRunner.MutationLoop
  alias MutagenEx.Test.RunGroup

  defmodule SpawningExUnit do
    @moduledoc false
    # Starts an unlinked worker, as ExUnit's runner does, then returns or
    # blocks past the site deadline.
    def configure(_opts), do: :ok

    def run do
      {owner, block?} = :persistent_term.get({MutagenEx.Test.RunGroupTest, :site})
      worker = spawn(fn -> Process.sleep(:infinity) end)
      send(owner, {:worker, worker})
      if block?, do: Process.sleep(:infinity)
      %{total: 1, failures: 0, excluded: 0, skipped: 0}
    end
  end

  setup do
    on_exit(fn -> :persistent_term.erase({__MODULE__, :site}) end)
  end

  describe "per-site process group (mutagen.mutation_pipeline.s21)" do
    @describetag spec: "mutagen.mutation_pipeline.r22"

    test "a timed-out site's unlinked workers are dead when MutationLoop.run/1 returns" do
      :persistent_term.put({__MODULE__, :site}, {self(), true})

      assert {:timeout, _meta} = MutationLoop.run(site_input())
      assert_received {:worker, worker}
      refute Process.alive?(worker)
    end

    test "a completed site's surviving workers get the caller's group leader back" do
      :persistent_term.put({__MODULE__, :site}, {self(), false})

      assert {:completed, %{total: 1}, _meta} = MutationLoop.run(site_input())
      assert_received {:worker, worker}
      on_exit(fn -> Process.exit(worker, :kill) end)

      assert Process.alive?(worker)
      assert Process.info(worker, :group_leader) == {:group_leader, Process.group_leader()}
    end

    test "the group forwards member I/O and reaps processes its members spawn" do
      {:ok, device} = StringIO.open("")
      group = RunGroup.start(device)
      parent = self()

      member =
        spawn(fn ->
          Process.group_leader(self(), group)
          IO.write("forwarded")
          send(parent, {:child, spawn(fn -> Process.sleep(:infinity) end)})
          Process.sleep(:infinity)
        end)

      assert_receive {:child, child}
      assert StringIO.contents(device) == {"", "forwarded"}
      assert :ok = RunGroup.stop(group, :reap)
      refute Process.alive?(member)
      refute Process.alive?(child)
    end
  end

  defp site_input do
    %{test_modules: [], timeout_ms: 300, cancel_grace_ms: 0, ex_unit: SpawningExUnit}
  end
end
