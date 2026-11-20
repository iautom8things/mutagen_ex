**Mutagen checked only part of the selected code.** 3 mutants run · 0 killed · 3 survived · 2 unevaluated · kill rate 0.0% · 1 changed file · 5 changed functions

### Check first

- `src/changed_run_fixture/example.ex:5` `ChangedRunFixture.Example.newly_covered/1`. Selected tests executed none of the in-scope sites (1 mutant, 0 survived, 0 executed).

  ```diff
  - x + 2
  + x - 2
  ```

  Rerun with `MIX_ENV=test mix mutagen --site src/changed_run_fixture/example.ex:8f7c759c724c3bf10264b21069e71f80:arith --tests auto --escalate-max-files 40 --since <BASE>`.

- `src/changed_run_fixture/example.ex:6` `ChangedRunFixture.Example.never_called/1`. Selected tests executed none of the in-scope sites (1 mutant, 0 survived, 0 executed).

  ```diff
  - x + 2
  + x - 2
  ```

  Rerun with `MIX_ENV=test mix mutagen --site src/changed_run_fixture/example.ex:42835329c8a1a315d3879a23a7504b21:arith --tests auto --escalate-max-files 40 --since <BASE>`.

### Worth a look

- `src/changed_run_fixture/example.ex:2` `ChangedRunFixture.Example.module_pick/1`. `arith` survived (narrow).

  ```diff
  - x + 2
  + x - 2
  ```

  Rerun with `MIX_ENV=test mix mutagen --site src/changed_run_fixture/example.ex:1a0e2c8663f33b65a0173e0f51774771:arith --tests auto --escalate-max-files 40 --since <BASE>`.

- `src/changed_run_fixture/example.ex:3` `ChangedRunFixture.Example.function_pick/1`. `arith` survived (narrow).

  ```diff
  - x + 2
  + x - 2
  ```

  Rerun with `MIX_ENV=test mix mutagen --site src/changed_run_fixture/example.ex:d46937e19f4789aa058cbbe9dea4d143:arith --tests auto --escalate-max-files 40 --since <BASE>`.

- `src/changed_run_fixture/example.ex:4` `ChangedRunFixture.Example.always_survives/1`. `arith` survived (narrow).

  ```diff
  - x + 2
  + x - 2
  ```

  Rerun with `MIX_ENV=test mix mutagen --site src/changed_run_fixture/example.ex:9a5955146544391e55768c273a329135:arith --tests auto --escalate-max-files 40 --since <BASE>`.

**What this means.** A survivor means the tests that ran did not notice the change. Check what they assert.
