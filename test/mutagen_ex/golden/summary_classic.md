**Mutagen found changes worth a look.** 2 mutants run · 1 killed · 1 survived · 0 unevaluated · kill rate 50.0% (1/2 evaluated)

### Worth a look

- `lib/fixture.ex:3` `Fixture.fixture/1`. `arith` survived (narrow).

  ```diff
  - x + 1
  + x - 1
  ```

  Rerun with `MIX_ENV=test mix mutagen --site lib/fixture.ex:00000000000000000000000000000003:arith --tests auto --escalate --escalate-max-files 40`.

**What this means.** A survivor means the tests that ran did not notice the change. Check what they assert.
