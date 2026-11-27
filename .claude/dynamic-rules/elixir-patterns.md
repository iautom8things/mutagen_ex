---
# agent-rules: generated v0.29.5 sha256=3da33aa45ae127f6724cedb636960f02f6110d5620f1180928bb8845f33380ef
description: Elixir house conventions. Timeouts, behaviour impls, doc interpolation, block rebinding, struct access, concurrency.
# Writing conventions only — paths cover ~every file, so native read-triggered
# loading made this effectively always-on. write_only limits it to edits.
write_only: true
paths:
  - "lib/**/*.ex"
  - "test/**/*.ex"
  - "test/**/*.exs"
---

## Timeouts

Use `to_timeout/1`, never `:timer`: `to_timeout(minute: 5)`, not `:timer.minutes(5)`.

## Behaviour Implementations

Name the behaviour: `@impl GenServer`, `@impl Oban.Pro.Worker`, never `@impl true`.

## Documentation Strings

Escape `#{}` in `@moduledoc`/`@doc` examples, or Elixir interpolates it at
compile time:

    @doc """
    Items are named: `\#{app_name} - Heroku Database`
    """

## Variable Binding In Blocks

A variable rebound inside `if`/`case`/`cond` does not escape the block. Bind
the block's result, and give every branch a value:

    socket =
      if connected?(socket) do
        assign(socket, :val, val)
      else
        socket
      end

## Struct Field Access

Structs do not implement `Access`: use `struct.field`, never `struct[:field]`.

## Concurrency

Use `Task.async_stream(collection, callback, timeout: :infinity)` for concurrent enumeration with back-pressure.
