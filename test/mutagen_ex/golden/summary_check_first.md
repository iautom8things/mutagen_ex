**Mutagen found functions to check first.** 3 mutants run · 0 killed · 3 survived · 0 unevaluated · kill rate 0.0% (0/3 evaluated) · 1 changed file · 1 changed function

### Check first

- `lib/fixture.ex:1` `Fixture.fixture/1`. Every evaluated mutant survived (3 mutants, 3 survived, 3 executed).

  ```diff
  - x + 1
  + x - 1
  ```

  Rerun with `MIX_ENV=test mix mutagen --site lib/fixture.ex:00000000000000000000000000000002:arith --tests auto --escalate-max-files 40 --since bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`.

**What this means.** A survivor means the tests that ran did not notice the change. Check what they assert.
