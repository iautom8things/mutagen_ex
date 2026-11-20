**Mutagen found changes worth a look.** 4 mutants run · 0 killed · 4 survived · 0 unevaluated · kill rate 0.0% · 1 changed file · 4 changed functions

### Worth a look

- `lib/fixture.ex:2` `Fixture.fixture_2/1`. `arith` survived (narrow).

  ```diff
  - x + 1
  + x - 1
  ```

  Rerun with `MIX_ENV=test mix mutagen --site lib/fixture.ex:00000000000000000000000000000002:arith --tests auto --escalate-max-files 40 --since bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`.

- `lib/fixture.ex:3` `Fixture.fixture_3/1`. `arith` survived (narrow).

  ```diff
  - x + 1
  + x - 1
  ```

  Rerun with `MIX_ENV=test mix mutagen --site lib/fixture.ex:00000000000000000000000000000003:arith --tests auto --escalate-max-files 40 --since bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`.

2 additional high-confidence survivors in the JSON.

**What this means.** A survivor means the tests that ran did not notice the change. Check what they assert.
