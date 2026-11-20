**Tests failed on the unmutated code** `checks/red_test.exs`.

**Mutagen checked only part of the selected code.** 4 mutants run · 3 killed · 1 survived · 1 unevaluated · kill rate 75.0% · 1 changed file · 5 changed functions

### Check first

- `src/gate_fixture/example.ex:6` `GateFixture.Example.never_called/1`. Selected tests executed none of the in-scope sites (1 mutant, 0 survived, 0 executed).

  ```diff
  - x + 2
  + x - 2
  ```

  Rerun with `MIX_ENV=test mix mutagen --site src/gate_fixture/example.ex:dab159fa6e04209b0670e10554a66ea8:arith --tests auto --escalate-max-files 40 --since <BASE>`.

### Worth a look

- `src/gate_fixture/example.ex:4` `GateFixture.Example.always_survives/1`. `arith` survived (narrow, module, function).

  ```diff
  - x + 2
  + x - 2
  ```

  Rerun with `MIX_ENV=test mix mutagen --site src/gate_fixture/example.ex:bf8a4c3fc49954ee819d9d01407b4fd5:arith --tests auto --escalate-max-files 40 --since <BASE>`.

**What this means.** A survivor means the tests that ran did not notice the change. Check what they assert.

### Notes

- 3 kills followed a dropped test file and may reflect its effects on the run.
- Escalation tried to load 2 test files that it later dropped.
- Skipped 1 test file during escalation (test files failed to load) in `checks/broken_test.exs`.
