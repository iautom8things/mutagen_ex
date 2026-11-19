---
id: mutagen.decision.host_test_setup
status: accepted
date: 2026-11-19
affects:
  - mutagen.cli
  - mutagen.coverage
  - mutagen.json_schema
  - mutagen.mutation_pipeline
  - mutagen.test_selection
supersedes:
  - "mutagen.decision.runtime_preamble_starts_host_app: the preamble order compile, app.start, :mutagen_ex start, ExUnit start"
  - "mutagen.decision.preamble_in_run1_only: the list of what the run/1 preamble ensures, and its place before flag parsing"
  - "mutagen.decision.timeout_handling: the closed set of unrecoverable exits (red baseline, restore failure, cover already running)"
  - "mutagen.decision.supervision_tree: the cover refusal message that points at this decision file, and the leak of trap-exit descendants that keep the site's group leader"
---

# Run the host's test setup before mutating

## Context

The `run/1` preamble started the host application and ExUnit, but it never
ran the host's own test setup. Projects that configure Ecto sandboxes, Mox
definitions, database creation, or ExUnit filters in `test_helper.exs` or
in a `test` alias reached baseline without that setup. The Ecto and Mox
reproduction recorded with this change aborted with `baseline_red` for
that reason, both as a path dependency and as an installed archive.

The same work found several gaps around startup and reporting:

- Mutagen accepted the default `dev` environment, so it compiled and
  started the host with the wrong config.
- A preamble failure raised or printed a Mix error. The archive repair path
  wrote JSON to stdout only, even when the user passed `--json`.
- A helper or application start that hung blocked the run forever.
- Loading the helper also loads its `ExUnit.after_suite/1` callbacks.
  ExUnit runs them after every `ExUnit.run/0`, and Mutagen runs ExUnit once
  per pass. In review, a callback that dropped a schema and stopped its
  connection broke the next pass, and the task exited without a report.
- On a mutant timeout, ExUnit's module and test workers survived. ExUnit
  starts them with `spawn_monitor`, so they are not linked to the runner
  task that `terminate_child/2` stops. A surviving worker kept the
  Sandbox checkout, and every later site failed `setup_all`. Those
  failures counted as kills.
- A test helper library such as Mimic starts an empty `:cover_server`.
  Mutagen refused it as a competing coverage session.
- Credentials in host error messages, such as a database URL in an
  `Ecto.InvalidURLError`, reached the report unless the user configured a
  redaction pattern.
- The report writer used `File.write!/2` on a path checked at startup. A
  missing parent directory crashed the write, and a symlink planted during
  the run was followed.
- A selection whose tests were all excluded ran zero tests in coverage and
  baseline. That produced empty coverage and a baseline that could not
  fail.

## Decision

Mutagen prepares the host the way `mix test` does and reports every
startup failure as one JSON document. The contracts are mutagen.cli r14, r16,
and r18 to r23, mutagen.test_selection r3 and r8, mutagen.coverage r1 and
r11, mutagen.mutation_pipeline r5, r14, r21 and r22, and
mutagen.json_schema r11, r14 and r17.

- **Environment rule.** Mutagen uses the rule from `mix test`. The run
  proceeds in `:test` or in any environment named explicitly with
  `MIX_ENV`. An implicit other environment aborts with `invalid_mix_env`
  before compilation. The message gives the corrected command and the
  `preferred_envs` setting. Users who run tests under a custom
  environment, such as `MIX_ENV=ci`, keep that setup.
- **Order.** Parse flags and validate the report path first, so a startup
  failure has a known destination. Then check the environment and refuse
  umbrella roots, run loadpaths and compile, then run runtime config, the
  test alias pre-steps, `app.start --temporary`, `:mutagen_ex` start, and
  each helper once with autorun off. The `run/1` only placement from
  mutagen.decision.preamble_in_run1_only stays.
- **Alias pre-steps.** Entries before the first `test` entry of the
  `test` alias are the project's own test setup, such as `ecto.create`
  and `ecto.migrate`. Mutagen runs them in its VM before the host app
  starts. An alias without a `test` entry has no boundary between setup
  and suite, so Mutagen skips it. `--no-test-alias` opts out.
- **Helper once, after-suite once.** The helper defines the suite's
  configuration, so every pass keeps it. Mutagen still sets the seed,
  `max_cases: 1`, and the filters before each pass, as
  mutagen.decision.serial_execution_and_seed requires. The filters merge
  the helper's include and exclude options, but a helper include never
  widens a line or tag selection. Mutagen takes the after-suite callbacks
  out of ExUnit's configuration and calls each one once at the end of the
  run, including after aborts. A failing callback only changes a result
  that would otherwise succeed.
- **Boot deadline.** Steps after compilation run in a boot process with a
  deadline, 300000 ms by default and set by `--boot-timeout-ms`.
  Compilation is excluded: a cold compile of a large host took 831 s in
  a real-application proof, and a compile error already returns a result. The boot
  process stays alive until the run ends, because Postgrex connections
  stop when their start-link parent exits.
- **Per-site process group.** Each mutant's test run gets a fresh group
  leader. ExUnit's workers inherit it even though they are not linked.
  When a run does not complete normally, Mutagen kills every member and
  waits for each to exit, then drains the serial ExUnit registry. Killing
  by group leader reaches the monitored workers that `terminate_child/2`
  cannot reach.
- **Default redaction.** Built-in patterns for URL userinfo, credential
  keys, and common token prefixes run before user patterns on every string
  the report or stream carries from host code. Startup summaries keep one
  redacted line, and the full diagnostic goes to stderr. Users can add
  patterns but cannot turn the built-in ones off.
- **Safe report writing.** The writer creates missing in-project parents,
  writes an exclusive temporary file, and renames it. It rechecks the
  requested path against the startup result before each step. If a check
  or write fails, the report goes to stdout with a stderr warning, so the
  exit status and the document survive.
- **Empty cover server.** Coverage stops a `:cover_server` that owns no
  compiled or imported modules and proceeds. A server with modules is
  still refused, and the message names `mix test --cover` and helpers
  that compile with `:cover` as likely sources.
- **No tests run.** Coverage and baseline abort with `no_tests_run` when
  ExUnit executed no test, and name the phase, the counts, and the
  filters. A raise, throw, or exit from ExUnit itself aborts with
  `ex_unit_run_failed`. A per-mutant failure carries the site ID. Before
  this change it was classified `:error`. That result blamed the mutant
  for a broken harness.

## Consequences

### Positive

- Ecto, Mox, and alias-provisioned projects run without per-project shims.
- Every startup failure, including a hang, produces one parseable document
  at the requested destination.
- A timed-out mutant no longer holds Sandbox connections or registry
  entries that change the next site's verdict.
- Reports are safer to store as CI artifacts by default.

### Negative

- Running `mix mutagen` in the implicit `dev` environment now fails. The
  README, task help, and changelog give the corrected command.
- Alias pre-steps and the helper run their side effects, such as creating
  and migrating a database, once per Mutagen run.
- A helper that calls `System.halt/1` still ends the VM before Mutagen can
  report.
- Host logger handlers other than the default console handler, and code
  that writes to the original console device directly, keep their own
  destinations. Raw stderr diagnostics are not redacted.
- Processes that change their group leader, or work handed to processes
  that existed before the site, escape the per-site reap. Snapshot taint
  (mutagen.mutation_pipeline.r7) remains the signal for those.
- The BEAM file API has no directory-handle-relative open. A concurrent
  rewrite of the destination's parent directory itself is outside the
  writer's guarantee.

### Earlier decisions

mutagen.decision.runtime_preamble_starts_host_app keeps its core: start
the host application by default, with `--no-host-app` and
`MUTAGEN_NO_HOST_APP` as opt-outs. This decision changes the order around
that step and adds runtime config, alias pre-steps, helpers, and the
deadline. mutagen.decision.serial_execution_and_seed is unchanged.
mutagen.decision.timeout_handling gains `ex_unit_run_failed` and
`no_tests_run` as unrecoverable exits. mutagen.decision.supervision_tree
keeps `terminate_child/2` as the first cancellation step. The group reap
runs after it.
