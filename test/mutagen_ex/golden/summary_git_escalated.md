**Tests failed on the unmutated code** `checks/red_test.exs`.

**Mutagen checked only part of the selected code.** 4 mutants run · 3 killed · 1 survived · 1 unevaluated · kill rate 75.0% · 1 changed file · 5 changed functions

### Check first

- `src/changed_run_fixture/example.ex:6` `ChangedRunFixture.Example.never_called/1`. Selected tests executed none of the in-scope sites (1 mutant, 0 survived, 0 executed).

  ```diff
  - x + 2
  + x - 2
  ```

  Rerun with `MIX_ENV=test mix mutagen --site src/changed_run_fixture/example.ex:42835329c8a1a315d3879a23a7504b21:arith --tests auto --escalate-max-files 40 --since <BASE>`.

### Worth a look

- `src/changed_run_fixture/example.ex:4` `ChangedRunFixture.Example.always_survives/1`. `arith` survived (narrow, module, function).

  ```diff
  - x + 2
  + x - 2
  ```

  Rerun with `MIX_ENV=test mix mutagen --site src/changed_run_fixture/example.ex:9a5955146544391e55768c273a329135:arith --tests auto --escalate-max-files 40 --since <BASE>`.

**What this means.** A survivor means the tests that ran did not notice the change. Check what they assert.

### Notes

- 3 kills followed a dropped test file and may reflect its effects on the run.
- Escalation tried to load 2 test files that it later dropped.
- Skipped 1 test file during escalation (test files failed to load) in `checks/broken_test.exs`.
