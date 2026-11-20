**Mutagen checked only part of the selected code.** 3 mutants run · 0 killed · 3 survived · 2 unevaluated · kill rate 0.0% · 1 changed file · 5 changed functions

### Check first

- `src/gate_fixture/example.ex:5` `GateFixture.Example.newly_covered/1`. Selected tests executed none of the in-scope sites (1 mutant, 0 survived, 0 executed).

  ```diff
  - x + 2
  + x - 2
  ```

  Rerun with `MIX_ENV=test mix mutagen --site src/gate_fixture/example.ex:c7eaa19069074b1282d2d3d83a1e974d:arith --tests auto --escalate-max-files 40 --since <BASE>`.

- `src/gate_fixture/example.ex:6` `GateFixture.Example.never_called/1`. Selected tests executed none of the in-scope sites (1 mutant, 0 survived, 0 executed).

  ```diff
  - x + 2
  + x - 2
  ```

  Rerun with `MIX_ENV=test mix mutagen --site src/gate_fixture/example.ex:dab159fa6e04209b0670e10554a66ea8:arith --tests auto --escalate-max-files 40 --since <BASE>`.

### Worth a look

- `src/gate_fixture/example.ex:2` `GateFixture.Example.module_pick/1`. `arith` survived (narrow).

  ```diff
  - x + 2
  + x - 2
  ```

  Rerun with `MIX_ENV=test mix mutagen --site src/gate_fixture/example.ex:68473d13b48c0156cab8d1931ca78885:arith --tests auto --escalate-max-files 40 --since <BASE>`.

- `src/gate_fixture/example.ex:3` `GateFixture.Example.function_pick/1`. `arith` survived (narrow).

  ```diff
  - x + 2
  + x - 2
  ```

  Rerun with `MIX_ENV=test mix mutagen --site src/gate_fixture/example.ex:dfc37f255b1707c29356593b8e52ce66:arith --tests auto --escalate-max-files 40 --since <BASE>`.

- `src/gate_fixture/example.ex:4` `GateFixture.Example.always_survives/1`. `arith` survived (narrow).

  ```diff
  - x + 2
  + x - 2
  ```

  Rerun with `MIX_ENV=test mix mutagen --site src/gate_fixture/example.ex:bf8a4c3fc49954ee819d9d01407b4fd5:arith --tests auto --escalate-max-files 40 --since <BASE>`.

**What this means.** A survivor means the tests that ran did not notice the change. Check what they assert.
