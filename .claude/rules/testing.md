---
# agent-rules: generated v0.29.5 sha256=ff1fac313f53d1e11c431e357894296262bacc5b01b0012c33fd2b7eb26572ad
description: ExUnit test patterns. Test cases, Mox, Oban, process lifecycle, LiveView assertions.
# Deliberately NOT write_only: knowing how to READ tests matters when debugging
# failures, so the native read-trigger earns its load. (mz, 2026-07-16)
paths:
  - "test/**/*.ex"
  - "test/**/*.exs"
---

## Test Cases

- `MutagenEx.DataCase` — DB tests with Ecto Sandbox
- `MutagenEx.ConnCase` — controller and LiveView tests

If the project lacks one of these cases, fall back to `ExUnit.Case` plus the
specific setup callbacks the test needs.

## Mox

Project mocks live in the `MutagenEx.Mock*` namespace. Define them in
`test/support/mocks.ex` and stub behaviour with `Mox.stub/3` or `Mox.expect/4`.
Use `Mox.verify_on_exit!()` per-test setup to fail on missing expectations.

## Oban

In test env, Oban is typically configured `testing: :inline` — jobs execute
synchronously inside the test process. If the project uses `testing: :manual`,
use `assert_enqueued/1` + `Oban.drain_queue/1` instead.

## Process Lifecycle

Start test-owned children with `start_supervised!/1` so ExUnit cleans them up.

## LiveView Tests

- Use `Phoenix.LiveViewTest` and `LazyHTML` for assertions
- Drive form interactions through `form/3` and then `render_submit` or
  `render_change`. Send hand-built event parameters when testing a forged event.
- Always reference element IDs: `assert has_element?(view, "#my-form")`
- Never test raw HTML strings
- Test outcomes, not implementation details
- Debug failing selectors with:

      document = LazyHTML.from_fragment(render(view))
      IO.inspect(LazyHTML.filter(document, "your-selector"), label: "Matches")
