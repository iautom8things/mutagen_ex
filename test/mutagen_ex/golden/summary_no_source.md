**Mutagen found changes worth a look.** 1 mutant run · 0 killed · 1 survived · 0 unevaluated · kill rate 0.0% (0/1 evaluated) · 1 changed file · 1 changed function

### Worth a look

- Line 3. `arith` survived (narrow).
  Rerun with `MIX_ENV=test mix mutagen --site 63c8b316d06c3288d891250d0c5b21ac980985d1bab91af9a68312420c2fa775 --tests auto --escalate --escalate-max-files 40 --since bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --no-source`.

**What this means.** A survivor means the tests that ran did not notice the change. Check what they assert.

### Notes

- File names, function names and excerpts omitted by `--no-source`.
