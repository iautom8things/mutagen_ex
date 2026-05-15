defmodule MutagenEx.JsonPathTest do
  @moduledoc """
  Tests for `MutagenEx.JsonPath.validate_literal/1` and
  `MutagenEx.JsonPath.canonicalize/2`.

  Coverage of `mutagen.cli.r10` (path safety contract on `--json <path>`):

    * `mutagen.cli.s10a` — `..` traversal rejected at parse time
    * `mutagen.cli.s10b` — NUL byte rejected at parse time
    * `mutagen.cli.s10c` — symlink whose target escapes the project root is
      rejected at canonicalisation
    * `mutagen.cli.s10d` — symlink whose target stays inside the project
      root is resolved and accepted
    * `mutagen.cli.s10e` — `unsafe_outside_project: true` opts out of the
      inside-root check; the resolved path is returned even when outside

  Each test that needs a project root uses an isolated tmp dir so the
  inside-root check is exercised against a known boundary. Symlink tests
  use `File.ln_s/2`; the suite assumes the host filesystem supports
  symlinks (macOS and Linux dev workstations always do).
  """

  use ExUnit.Case, async: true

  alias MutagenEx.JsonPath

  describe "validate_literal/1 — pure-string checks (s10a, s10b)" do
    test "accepts a normal relative path" do
      assert :ok = JsonPath.validate_literal("out/mutagen.json")
    end

    test "accepts a normal absolute path" do
      assert :ok = JsonPath.validate_literal("/tmp/mutagen.json")
    end

    test "rejects an empty string" do
      assert {:error, :unsafe_json_path, details} = JsonPath.validate_literal("")
      assert details.variant == :empty_path
      assert details.path == ""
      assert is_binary(details.message)
    end

    test "rejects a path containing a NUL byte (s10b)" do
      path = "out/mutagen" <> <<0>> <> ".json"

      assert {:error, :unsafe_json_path, details} = JsonPath.validate_literal(path)
      assert details.variant == :nul_byte
      assert details.path == path
      assert details.message =~ "NUL byte"
    end

    test "rejects a path containing a `..` segment (s10a)" do
      assert {:error, :unsafe_json_path, details} =
               JsonPath.validate_literal("../../etc/passwd")

      assert details.variant == :traversal
      assert details.path == "../../etc/passwd"
      assert details.message =~ ".."
    end

    test "rejects a path with `..` in the middle of segments" do
      assert {:error, :unsafe_json_path, details} =
               JsonPath.validate_literal("out/../etc/passwd")

      assert details.variant == :traversal
    end

    test "rejects an absolute path with `..`" do
      assert {:error, :unsafe_json_path, details} =
               JsonPath.validate_literal("/tmp/../etc/passwd")

      assert details.variant == :traversal
    end

    test "accepts a literal containing two dots that is NOT a segment" do
      # `..foo` is not a `..` segment — it's a name that happens to start
      # with two dots. The traversal check splits on path separators and
      # compares segment-equal, so this should pass.
      assert :ok = JsonPath.validate_literal("..foo/report.json")
      assert :ok = JsonPath.validate_literal("foo..bar/report.json")
      assert :ok = JsonPath.validate_literal("foo/...hidden/report.json")
    end
  end

  describe "canonicalize/2 — inside-project-root check (s10c, s10d)" do
    setup do
      tmp = unique_tmp_dir()
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      # `canonicalize/2` resolves the project root through symlinks (e.g.
      # macOS `/var -> /private/var`), so test assertions must compare
      # against the resolved root, not the literal one.
      {:ok, project_root: tmp, resolved_root: resolve_symlinks(tmp)}
    end

    test "accepts a relative path inside the project root", %{
      project_root: root,
      resolved_root: resolved_root
    } do
      assert {:ok, resolved} =
               JsonPath.canonicalize("out/report.json", project_root: root)

      assert resolved == Path.join([resolved_root, "out", "report.json"])
    end

    test "accepts a nested relative path whose parent directories don't exist", %{
      project_root: root,
      resolved_root: resolved_root
    } do
      # The `out/` directory does not exist yet — canonicalize/2 still
      # accepts the path because the final report-file component is
      # allowed to be missing.
      assert {:ok, resolved} =
               JsonPath.canonicalize("a/b/c/report.json", project_root: root)

      assert resolved == Path.join([resolved_root, "a", "b", "c", "report.json"])
    end

    test "accepts an absolute path inside the project root", %{
      project_root: root,
      resolved_root: resolved_root
    } do
      target = Path.join(root, "deep/report.json")
      resolved_target = Path.join(resolved_root, "deep/report.json")

      assert {:ok, ^resolved_target} = JsonPath.canonicalize(target, project_root: root)
    end

    test "rejects an absolute path outside the project root by default", %{
      project_root: root,
      resolved_root: resolved_root
    } do
      assert {:error, :unsafe_json_path, details} =
               JsonPath.canonicalize("/tmp/nope.json", project_root: root)

      assert details.variant == :outside_project_root
      assert details.project_root == resolved_root
      # The resolved field carries the canonical absolute form of the
      # caller-supplied path. On macOS `/tmp` resolves through to
      # `/private/tmp`; on Linux it stays as `/tmp`.
      assert details.resolved == resolve_symlinks("/tmp/nope.json")
      assert details.message =~ "outside the project root"
    end

    test "rejects a symlink whose target escapes the project root (s10c)", %{
      project_root: root
    } do
      # Pick an existing path outside the root as the symlink target.
      # `/etc/hosts` exists on every macOS/Linux dev box. We do not write
      # to it — the canonicalisation must refuse before any write happens.
      escape = Path.join(root, "escape.json")
      File.ln_s!("/etc/hosts", escape)

      assert {:error, :unsafe_json_path, details} =
               JsonPath.canonicalize("escape.json", project_root: root)

      assert details.variant == :outside_project_root
      # `details.resolved` is the fully-resolved final path. On macOS
      # `/etc -> /private/etc`; we compare against the resolved form.
      assert details.resolved == resolve_symlinks("/etc/hosts")
      # Sanity: the reported path escaped the project root.
      refute String.starts_with?(details.resolved, details.project_root <> "/")
    end

    test "accepts a symlink whose target stays inside the project root (s10d)", %{
      project_root: root,
      resolved_root: resolved_root
    } do
      # Make a symlink IN the root pointing at another path in the root.
      File.mkdir_p!(Path.join(root, "out"))
      target = Path.join(root, "out/report.json")
      link = Path.join(root, "inside.json")
      File.ln_s!(target, link)

      assert {:ok, resolved} =
               JsonPath.canonicalize("inside.json", project_root: root)

      # The resolved path is the symlink TARGET (in canonical resolved
      # form), not the link itself.
      assert resolved == Path.join(resolved_root, "out/report.json")
    end

    test "rejects a directory-traversal-via-symlink even when only the parent is symlinked",
         %{project_root: root} do
      # Symlink `data` -> `/tmp` (outside root). Then `--json data/report.json`
      # would resolve to `/tmp/report.json`. The canonicaliser must refuse
      # the resolved final path because it lands outside the project root.
      escape_parent = Path.join(root, "data")
      File.ln_s!("/tmp", escape_parent)

      assert {:error, :unsafe_json_path, details} =
               JsonPath.canonicalize("data/report.json", project_root: root)

      assert details.variant == :outside_project_root
    end
  end

  describe "canonicalize/2 — unsafe_outside_project escape hatch (s10e)" do
    setup do
      tmp = unique_tmp_dir()
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, project_root: tmp}
    end

    test "accepts an absolute path outside the root when flag is true", %{
      project_root: root
    } do
      expected = resolve_symlinks("/tmp/ci-artifacts/report.json")

      assert {:ok, ^expected} =
               JsonPath.canonicalize("/tmp/ci-artifacts/report.json",
                 project_root: root,
                 unsafe_outside_project: true
               )
    end

    test "still rejects a NUL-byte path even with the escape hatch set", %{
      project_root: root
    } do
      assert {:error, :unsafe_json_path, details} =
               JsonPath.canonicalize("/tmp/x" <> <<0>> <> ".json",
                 project_root: root,
                 unsafe_outside_project: true
               )

      # The escape hatch only bypasses the inside-root check; NUL bytes
      # are always refused.
      assert details.variant == :nul_byte
    end
  end

  describe "canonicalize/2 — project root resolution" do
    test "defaults to File.cwd!/0 when :project_root is not passed" do
      # cwd is the test process's cwd. We pass a path we know is inside
      # cwd (the test directory itself) and check the resolved path is
      # inside cwd-resolved.
      cwd = File.cwd!() |> Path.expand()
      relative = "test/dummy_report.json"

      assert {:ok, resolved} = JsonPath.canonicalize(relative)
      assert String.starts_with?(resolved, cwd <> "/")
    end

    test "resolves a symlinked project root through symlinks" do
      # On macOS `/tmp` is itself a symlink to `/private/tmp`. We want the
      # inside-root check to still work when cwd happens to be a symlinked
      # path: the project root is walked through the symlink resolver so
      # comparisons use the canonical root.
      real = unique_tmp_dir()
      File.mkdir_p!(real)
      on_exit(fn -> File.rm_rf!(real) end)

      resolved_root = resolve_symlinks(real)

      assert {:ok, resolved} =
               JsonPath.canonicalize("report.json", project_root: real)

      assert resolved == Path.join(resolved_root, "report.json")
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp unique_tmp_dir do
    base = Path.expand(System.tmp_dir!())
    suffix = "mutagen_jsonpath_#{:erlang.unique_integer([:positive])}"
    Path.join(base, suffix)
  end

  # Resolve every symlink in `path` using the same algorithm `canonicalize/2`
  # uses for its project root. Returns the fully-resolved absolute path.
  # Used in tests to predict what `canonicalize/2` will produce on a host
  # whose tmp / etc / var paths are themselves symlinks (macOS).
  defp resolve_symlinks(path) do
    absolute = Path.expand(path)
    segments = Path.split(absolute)

    {head, rest} =
      case segments do
        ["/" | tail] -> {"/", tail}
        other -> {"", other}
      end

    walk_resolve(rest, head)
  end

  defp walk_resolve([], acc), do: acc

  defp walk_resolve([segment | rest], acc) do
    candidate = Path.join(acc, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:ok, target} = File.read_link(candidate)
        resolved_target = Path.expand(target, acc)

        new_segments =
          case Path.split(resolved_target) do
            ["/" | inner] -> inner ++ rest
            inner -> inner ++ rest
          end

        walk_resolve(new_segments, "/")

      {:ok, _stat} ->
        walk_resolve(rest, candidate)

      {:error, :enoent} ->
        Path.join([candidate | rest])
    end
  end
end
