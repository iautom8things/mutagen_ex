defmodule MutagenEx.JsonReporter.SanitizerTest do
  @moduledoc """
  Tests for `MutagenEx.JsonReporter.Sanitizer`.

  Subjects advanced (see `.spec/specs/json_schema.spec.md`):

    * `mutagen.json_schema.r10` / `s7` — 4 KiB truncation cap on every
      free-form text field; truncation marker is
      ` ... <N bytes truncated>`.
    * `mutagen.json_schema.r11` / `s8` — opt-in `:redact` config knob;
      each matched pattern replaced with `[REDACTED]`; redaction runs
      before truncation.
  """

  use ExUnit.Case, async: false

  alias MutagenEx.JsonReporter.Sanitizer

  # The :redact env is global to the application. Each test that flips
  # it must restore the original on exit so subsequent tests see a
  # known baseline.
  setup do
    original = Application.get_env(:mutagen_ex, :redact)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:mutagen_ex, :redact)
        v -> Application.put_env(:mutagen_ex, :redact, v)
      end
    end)

    :ok
  end

  describe "byte_size_limit/0 (r10 — fixed cap)" do
    test "default cap is exactly 4096 bytes (4 KiB)" do
      assert Sanitizer.byte_size_limit() == 4 * 1024
    end
  end

  describe "truncate/2 (r10)" do
    test "leaves strings under the cap untouched" do
      bin = String.duplicate("a", 4096)
      assert Sanitizer.truncate(bin, 4096) == bin
    end

    test "leaves a string ONE byte under the cap untouched" do
      bin = String.duplicate("a", 4095)
      assert Sanitizer.truncate(bin, 4096) == bin
    end

    test "truncates a string ONE byte over the cap and appends the marker" do
      bin = String.duplicate("a", 4097)
      out = Sanitizer.truncate(bin, 4096)

      # Payload is exactly 4096 bytes; marker says 1 byte truncated.
      assert String.starts_with?(out, String.duplicate("a", 4096))
      assert String.ends_with?(out, " ... <1 bytes truncated>")
    end

    test "marker reports the EXACT byte count that was dropped (r10 — s7)" do
      # 10_240 bytes input → 4096-byte payload + marker mentioning 6144.
      bin = String.duplicate("warning line\n", div(10_240, byte_size("warning line\n")))
      # Pad to exactly 10_240 bytes so the math is clean.
      padding = 10_240 - byte_size(bin)
      bin = bin <> String.duplicate("x", padding)
      assert byte_size(bin) == 10_240

      out = Sanitizer.truncate(bin, 4096)
      dropped = byte_size(bin) - 4096
      assert String.ends_with?(out, " ... <#{dropped} bytes truncated>")

      # Payload portion of the output is exactly the cap.
      [payload, _marker] = String.split(out, " ... <", parts: 2)
      assert byte_size(payload) <= 4096
    end

    test "truncated output is valid UTF-8 (no split codepoints)" do
      # Repeated 4-byte emoji + a tail. If we did naive byte_part the
      # boundary could land mid-codepoint and produce invalid UTF-8.
      bin = String.duplicate("🎉", 2000)
      out = Sanitizer.truncate(bin, 4096)

      assert String.valid?(out), "truncated output must be valid UTF-8"
      assert String.contains?(out, " ... <")
    end

    test "honors an explicit smaller limit for test seams" do
      bin = "hello world"
      out = Sanitizer.truncate(bin, 5)

      assert String.starts_with?(out, "hello")
      assert String.contains?(out, " ... <")
      assert String.ends_with?(out, " bytes truncated>")
    end
  end

  describe "apply_redactions/2 (r11)" do
    test "empty pattern list is a no-op" do
      assert Sanitizer.apply_redactions("hello world", []) == "hello world"
    end

    test "single regex pattern replaces every match with [REDACTED]" do
      input = "before SECRET_TOKEN=hunter2 between SECRET_TOKEN=admin after"
      out = Sanitizer.apply_redactions(input, [~r/SECRET_TOKEN=\S+/])

      assert out == "before [REDACTED] between [REDACTED] after"
      refute String.contains?(out, "hunter2")
      refute String.contains?(out, "admin")
    end

    test "binary regex source is compiled on the fly" do
      input = "AWS_SECRET_ACCESS_KEY=abc xyz"
      out = Sanitizer.apply_redactions(input, ["AWS_SECRET[A-Z_]*=\\S+"])

      assert out == "[REDACTED] xyz"
    end

    test "multiple patterns are applied in order" do
      input = "tokenA tokenB other"

      out =
        Sanitizer.apply_redactions(input, [
          ~r/tokenA/,
          ~r/tokenB/
        ])

      assert out == "[REDACTED] [REDACTED] other"
    end
  end

  describe "clean/1 (full pass: redact → truncate)" do
    test "nil passes through unchanged" do
      assert Sanitizer.clean(nil) == nil
    end

    test "reads :redact from application env by default" do
      Application.put_env(:mutagen_ex, :redact, [~r/SECRET_TOKEN=\S+/])

      input = "warning: bad value SECRET_TOKEN=hunter2 in line 42"
      out = Sanitizer.clean(input)

      assert String.contains?(out, "[REDACTED]")
      refute String.contains?(out, "hunter2")
    end

    test "no redact env means only truncation happens" do
      Application.delete_env(:mutagen_ex, :redact)

      bin = String.duplicate("a", 10_000)
      out = Sanitizer.clean(bin)

      assert String.ends_with?(out, " bytes truncated>")
      refute String.contains?(out, "[REDACTED]")
    end

    test "redaction happens BEFORE truncation so replacements are not lost (r11)" do
      Application.put_env(:mutagen_ex, :redact, [~r/SECRET_TOKEN=\S+/])

      # Place SECRET_TOKEN at the very END of a 10_000-byte string.
      # If truncation ran first, we'd drop the SECRET and silently keep
      # whatever's at the front; redact-first guarantees the secret is
      # replaced even when its position is past the cap.
      tail = "SECRET_TOKEN=hunter2"
      front_len = 10_000 - byte_size(tail)
      bin = String.duplicate("x", front_len) <> tail

      out = Sanitizer.clean(bin)

      # Sanity: the input WAS long enough to be truncated.
      assert String.contains?(out, " bytes truncated>")

      # The secret was at position 9980-9999. After redact-first +
      # truncate, the SECRET_TOKEN=hunter2 substring is gone (replaced
      # with [REDACTED]) — even though that bytewise position would
      # have been truncated away under a truncate-first ordering.
      refute String.contains?(out, "hunter2"),
             "redact must run before truncate so secrets near or past the cap are still redacted"
    end

    test "explicit opts override application env" do
      Application.put_env(:mutagen_ex, :redact, [~r/SHOULD_NOT_FIRE/])

      input = "custom CUSTOM_TOKEN=abc"
      out = Sanitizer.clean(input, patterns: [~r/CUSTOM_TOKEN=\S+/])

      assert out == "custom [REDACTED]"
    end

    test "explicit :byte_size_limit overrides the 4 KiB default" do
      input = String.duplicate("a", 100)
      out = Sanitizer.clean(input, byte_size_limit: 50)

      assert String.starts_with?(out, String.duplicate("a", 50))
      assert String.contains?(out, "bytes truncated")
    end

    test "non-binary input is coerced via to_string/1" do
      out = Sanitizer.clean(42)
      assert out == "42"
    end

    test "malformed :redact env (non-list) is treated as no patterns" do
      Application.put_env(:mutagen_ex, :redact, :not_a_list)

      out = Sanitizer.clean("untouched payload")
      assert out == "untouched payload"
    end
  end
end
