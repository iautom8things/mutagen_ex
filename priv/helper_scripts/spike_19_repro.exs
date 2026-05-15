# mutagen-wrd.19 spike: isolate which EctoUser baseline test fails after
# :cover.compile_beam/1 against LaneFixture.EctoUser.
#
# Run from repo root with:
#   mix run priv/helper_scripts/spike_19_repro.exs
#
# This bypasses the e2e pipeline: it pre-compiles the lane fixture into a
# tmp ebin (mirroring end_to_end_test setup_all), takes a baseline snapshot
# of every fixture invariant, then runs :cover.compile_beam/1 against
# LaneFixture.EctoUser and re-snapshots. The diff names the exact callback /
# attribute that does not survive cover instrumentation.

fixture_root = Path.expand("test/fixtures/lane_project")
lib_files = Path.wildcard(Path.join(fixture_root, "lib/lane_fixture/*.ex"))
tmp_ebin = Path.join(System.tmp_dir!(), "mutagen_spike_19_ebin")
File.rm_rf!(tmp_ebin)
File.mkdir_p!(tmp_ebin)
Code.append_path(tmp_ebin)

IO.puts("== Pre-compiling fixture lib/ into #{tmp_ebin} ==")

Enum.each(lib_files, fn file ->
  IO.puts("  " <> file)
  Kernel.ParallelCompiler.compile_to_path([file], tmp_ebin)
end)

snapshot = fn label ->
  module = LaneFixture.EctoUser
  which = :code.which(module)
  md5 = apply(module, :__info__, [:md5])
  attrs = apply(module, :__info__, [:attributes])
  attrs_kind = Keyword.get_values(attrs, :lane_schema_kind)

  schema_kind =
    try do
      apply(module, :__schema_kind__, [])
    rescue
      e -> {:rescued, e.__struct__, Exception.message(e)}
    catch
      kind, reason -> {:caught, kind, reason}
    end

  name_fun =
    try do
      apply(module, :name, [])
    rescue
      e -> {:rescued, e.__struct__, Exception.message(e)}
    catch
      kind, reason -> {:caught, kind, reason}
    end

  age_fun =
    try do
      apply(module, :age, [])
    rescue
      e -> {:rescued, e.__struct__, Exception.message(e)}
    catch
      kind, reason -> {:caught, kind, reason}
    end

  birthday =
    try do
      apply(module, :birthday, [30])
    rescue
      e -> {:rescued, e.__struct__, Exception.message(e)}
    catch
      kind, reason -> {:caught, kind, reason}
    end

  IO.puts("---- snapshot: #{label} ----")
  IO.puts("  :code.which/1            = #{inspect(which)}")
  IO.puts("  __info__(:md5)           = #{Base.encode16(md5)}")
  IO.puts("  attrs[:lane_schema_kind] = #{inspect(attrs_kind)}")
  IO.puts("  __schema_kind__/0        = #{inspect(schema_kind)}")
  IO.puts("  name/0                   = #{inspect(name_fun)}")
  IO.puts("  age/0                    = #{inspect(age_fun)}")
  IO.puts("  birthday/1 (30)          = #{inspect(birthday)}")

  %{
    md5: md5,
    attrs_kind: attrs_kind,
    schema_kind: schema_kind,
    name: name_fun,
    age: age_fun,
    birthday: birthday,
    which: which
  }
end

pre = snapshot.("PRE :cover.compile_beam")

IO.puts("\n== Starting :cover and compile_beam(LaneFixture.EctoUser) ==")
root = List.to_string(:code.root_dir())
[tools_ebin | _] = Path.wildcard(Path.join(root, "lib/tools-*/ebin"))
IO.puts("  tools ebin = #{inspect(tools_ebin)}")
Code.append_path(tools_ebin)
{:module, :cover} = Code.ensure_loaded(:cover)
{:ok, _pid} = :cover.start()
beam_path = :code.which(LaneFixture.EctoUser)
IO.puts("  cover.compile_beam(#{inspect(beam_path)})")
result = :cover.compile_beam(beam_path)
IO.puts("  result = #{inspect(result)}")

post = snapshot.("POST :cover.compile_beam")

IO.puts("\n== :cover.stop and verifying restore ==")
:cover.stop()

after_stop = snapshot.("POST :cover.stop")

# Force purge + reload to simulate what the e2e per-scenario reset does
IO.puts("\n== Forcing :code.purge + :code.load_file to simulate per-scenario reset ==")
:code.purge(LaneFixture.EctoUser)
:code.purge(LaneFixture.EctoUserSchema)
case :code.load_file(LaneFixture.EctoUser) do
  {:module, _} -> IO.puts("  load_file(EctoUser) -> :module")
  err -> IO.puts("  load_file(EctoUser) -> #{inspect(err)}")
end
case :code.load_file(LaneFixture.EctoUserSchema) do
  {:module, _} -> IO.puts("  load_file(EctoUserSchema) -> :module")
  err -> IO.puts("  load_file(EctoUserSchema) -> #{inspect(err)}")
end

after_reload = snapshot.("POST :code.load_file")

diff = fn label, left, right ->
  IO.puts("\n-- diff(#{label}) --")
  diffs =
    for {k, v1} <- left, v2 = Map.fetch!(right, k), v1 != v2 do
      "#{k}: left=#{inspect(v1, limit: :infinity)} | right=#{inspect(v2, limit: :infinity)}"
    end

  if diffs == [] do
    IO.puts("  no observable diff")
  else
    Enum.each(diffs, &IO.puts("  - " <> &1))
  end
end

diff.("pre vs post compile_beam", pre, post)
diff.("post compile_beam vs post stop", post, after_stop)
diff.("pre vs after load_file", pre, after_reload)

# Now simulate the full coverage_runner cycle by ALSO loading the test
# file under cover, running the tests, then stopping cover. That mirrors
# what the e2e pipeline's coverage phase does: cover-instrument the in-
# scope module, then run the ENTIRE test file (which exercises the macro
# callbacks and the schema attribute) WITH cover instrumentation on.
IO.puts("\n== Now simulate coverage RUN: instrument + load test file + run ExUnit ==")
ExUnit.start(autorun: false)

# Re-instrument
{:ok, _} = :cover.start()
:cover.compile_beam(:code.which(LaneFixture.EctoUser))

# Load the test file (this is what coverage_runner does via load_test_files)
test_file = Path.join(fixture_root, "test/lane_fixture/ecto_user_test.exs")
IO.puts("  compiling test file: #{test_file}")
prior = Code.compiler_options()
Code.compiler_options(ignore_module_conflict: true)
Code.compile_file(test_file)
Code.compiler_options(prior)

# Snapshot the EctoUser module BEFORE running ExUnit
inside_cover = snapshot.("INSIDE cover, after test file compiled, before ExUnit.run")

# Try running just the EctoUser test module via ExUnit
ExUnit.configure(max_cases: 1, seed: 0)
_result = ExUnit.run([LaneFixture.EctoUserTest])

after_exunit_under_cover = snapshot.("INSIDE cover, after ExUnit.run on EctoUserTest")

# Now stop cover (mirrors coverage_runner.run/1 lifecycle exit)
:cover.stop()

after_full_cover_cycle = snapshot.("POST :cover.stop after full coverage cycle")

# Per-scenario reset
:code.purge(LaneFixture.EctoUser)
:code.delete(LaneFixture.EctoUser)
:code.load_file(LaneFixture.EctoUser)
:code.purge(LaneFixture.EctoUserSchema)
:code.delete(LaneFixture.EctoUserSchema)
:code.load_file(LaneFixture.EctoUserSchema)

after_full_reset = snapshot.("POST full reset (mirrors reset_e2e_state!)")

diff.("pre vs inside_cover (before exunit)", pre, inside_cover)
diff.("pre vs after_exunit_under_cover", pre, after_exunit_under_cover)
diff.("pre vs after_full_cover_cycle", pre, after_full_cover_cycle)
diff.("pre vs after_full_reset", pre, after_full_reset)

:ok
