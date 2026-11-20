# Releasing mutagen_ex

1. Set the version in `mix.exs` and update the README examples. Regenerate
   the reporter fixtures with
   `REGEN=1 mix test test/mutagen_ex/json_reporter_golden_test.exs`.
   Date the changelog section for the release and leave an empty Unreleased
   section for the next change.
2. Run the checks below from a clean checkout of the release commit. The
   integration suite needs a local Postgres user that can create databases.

   ```sh
   mix deps.get
   mix format --check-formatted
   MIX_ENV=test mix compile --warnings-as-errors
   mix test --seed 0
   mix test --only e2e_slow --seed 0
   mix test.integration --seed 0
   mix spec.validate --strict
   mix spec.check --base origin/main
   mix hex.build
   mix hex.build --unpack
   mix docs --warnings-as-errors
   mix hex.publish --dry-run
   ```

3. Inspect the unpacked files and verify an audit and a changed-code run
   in scratch projects with the unpacked dependency and with a locally
   built archive. Check that the release PR passed CI and the release
   commit is on main.
4. From that commit run `mix hex.publish`. Confirm the version and file
   list at the prompt. Verify both README installation methods from Hex.
   Hex allows 24 hours to revert the first release of a new package and
   one hour for later releases. After that the published version is permanent.
   [Hex publishing rules](https://hexdocs.pm/hex/Mix.Tasks.Hex.Publish.html#module-reverting-a-package)
5. Set `version=X.Y.Z` to the published version. Tag the published commit
   with `git tag -a "v$version" -m "Release $version"` and run
   `git push origin "v$version"`. Create the GitHub release from that
   tag with the matching changelog section as its release notes.
