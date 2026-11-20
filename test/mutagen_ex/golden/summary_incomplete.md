**Tests failed on the unmutated code** `test/broken_test.exs`.

**Mutagen has incomplete results.** 3 mutants run · 1 killed · 1 survived · 1 unevaluated · kill rate 50.0% (1/2 evaluated) · 1 changed file · 1 changed function
**What this means.** A survivor means the tests that ran did not notice the change. Check what they assert.

### Notes

- Could not parse the current source in `lib/broken.ex`.
- Changed lines outside runtime mutation sites in `lib/fixture.ex` (1, 3–5).
- 1 mutant timed out.
- 1 result followed a timeout or host state change.
- 1 kill followed a dropped test file and may reflect its effects on the run.
- Escalation tried to load 1 test file that it later dropped.
- Only the JSON results list 1 low-confidence survivor.
