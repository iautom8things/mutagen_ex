---
# agent-rules: generated v0.29.5 sha256=bd10a3058ec62b8cc333fed44216e8ccaf58e9ddaa1ca4df72fadd1cdbc81455
description: ExUnit flake prevention when writing tests. Mailbox ordering, deadlines, and failure symptoms.
write_only: true
paths:
  - "test/**/*.exs"
  - "test/**/*.ex"
---

## Before you write a wait

- **The test sends to itself.** Use `assert_received`.
- **The process you called sends before replying.** Use `assert_received` after the call.
- **A third process sends, or the reply only starts the work.** Use a timed
  `assert_receive` pinned to this test's message, or call the process to
  check state when that call orders the relevant messages.
- Wait on a message, a monitor, or a poll with a deadline and a failure
  message. A fixed sleep orders nothing. Keep a deliberate slow fixture
  when the delay is part of the behavior under test.
- Size positive waits for a loaded two-CPU CI runner. A short refute is
  fine once the sender's ordering supports the negative assertion.

## Symptoms and causes

| What you see | Usual cause | What to do |
| --- | --- | --- |
| Empty mailbox, refute passes too early, or refute always pays its timeout | The test picked a mailbox assertion without proving sender order | Identify the sender and use the wait rules above. |
| Late log, write, or sandbox ownership error in another test | A child of an app supervisor outlived its test | Drain the children started by the test before teardown. Fail with the pending children at the deadline. |
| LiveView assertion sees the loading state | Async assigns or tasks have yet to render | Call `render_async` before checking the result. Hold the response explicitly when testing the pending state. |
| Short text refute fails on a random page token | Substring matches a nonce, session token, or generated ID | Scope to a DOM element or compare the exact payload with volatile values removed. |
| Duplicate key, unique-index lock, or fixture matches someone else's ID | Async tests reuse a value or independent generators overlap | Generate a unique value in one shared namespace, or use a find-or-create fixture for shared data. |
| Sandbox queue drop, ownership error, or committed rows leak | Shared queue is too tight, `:auto` is left on, or owner shutdown races cleanup | Tune the queue for CI, register mode restoration before changing it, and isolate any repo process you kill. |
| Failure depends on seed, a singleton store, or a reused temp directory | Tests share a VM store, leave state behind, or repeat temp names across VMs | Give each test its own store and temp directory. Use the seed to trace leaks and reset shared state at entry and exit. |
| Query count sometimes exceeds its bound | A VM-wide telemetry handler counts work from other tests | Filter by the test PID and its task callers. |
| Lock check sees no blocker or a NULL wait event | Postgres activity and locks were read before they agreed | Poll for the expected query, wait event, and blocker together. Include the last row on timeout. |
| Budget assertion flips under load | Cold setup or other work spends the budget being tested | Warm setup before starting the measurement, or wait for the product's own deadline signal. |
| Local result differs from CI | A developer environment variable changes the branch taken | Set or clear the variable for each branch and restore its prior value. |
| Stand-in passes through an unexpected `UndefinedFunctionError` | The fake misses behavior callbacks | Declare `@behaviour` and `@impl`. Implement every callback and raise explicitly from unused ones. |
| A correct, synchronized test still fails | Product or dependency race | Capture the evidence and fix the product or dependency. Keep the test's assertions. |

Credo covers changing compile-time config, direct async global writes, unverified
Mox expectations, short positive receives, sleeps in test flow, trivial
assertions, and named starts outside supervision. Use an inline Credo disable
for a deliberate case. Put the reason in a comment directly above the directive;
leave nothing after the check name on the directive line.
