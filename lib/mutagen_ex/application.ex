defmodule MutagenEx.Application do
  @moduledoc """
  OTP `Application` callback for `:mutagen_ex`.

  Boots the `MutagenEx.Supervisor` one-for-one root supervisor with a single
  initial child: a named `Task.Supervisor` registered as `MutagenEx.TaskSup`.

  ## Why this exists

  Per `.spec/decisions/supervision_tree.md`:

  - **F25** closure — library callers depending on `:mutagen_ex` get a
    supervision tree on application start without writing any new
    public-API surface. The `mix mutagen` CLI path also benefits: the
    application boots as a side effect of the Mix task, so `MutagenEx.TaskSup`
    is available when `MutagenEx.MutationRunner.run/1` enters its task body.
  - **F2-arch** foundation — `MutagenEx.TaskSup` is the documented
    `Task.Supervisor` whose `terminate_child/2` recursively kills the per-site
    task's link tree on a `:timeout` outcome. The swap from `Task.async` +
    `Task.shutdown(:brutal_kill)` to `Task.Supervisor.async_nolink/2` +
    `Task.Supervisor.terminate_child/2` lands in S2; this S1 ticket only
    plants the supervisor.
  - **F26** singleton-ownership contract — `MutagenEx.TaskSup` is the named
    owner of `:cover_server` and `ExUnit.Server` during a MutagenEx mutation
    cycle. The rejection message in `MutagenEx.CoverageRunner.run/1` cites
    this module by name; the supervisor must exist at runtime for the
    contract to be enforceable.

  ## Topology

      MutagenEx.Supervisor (one-for-one, named)
      └── MutagenEx.TaskSup (Task.Supervisor, named)

  No other children are added in S1. `.30` (parallelism) will eventually
  introduce sibling workers, but this is the minimum tree that closes F25
  and gives S2 / S3 the named supervisor they reference.

  ## Smoke check

  From a fresh `iex -S mix`:

      Process.whereis(MutagenEx.Supervisor) |> is_pid()  # true
      Process.whereis(MutagenEx.TaskSup) |> is_pid()     # true
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: MutagenEx.TaskSup}
    ]

    opts = [strategy: :one_for_one, name: MutagenEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
