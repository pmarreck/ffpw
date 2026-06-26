# ffpw — Plan / TODO

## Completed

- [x] **Quality recovery after the false-green incident** (2026-06-26). Three
      controls so the green is trustworthy and the incident class can't recur:
      (1) **meta-control** in `./test` *and* CI (`flake.nix` checks.test) — asserts
      the harness actually ran AND executed every authored test (executed count ==
      `^test` count across src/); catches both a compile-only test step and a file
      dropped from main.zig's aggregator. (2) **end-to-end golden test**
      (`key4.zig`) — forges a synthetic key4.db with real PBES2 blobs and asserts
      `KeyStore.open` returns the exact known master key (external oracle) + rejects
      a wrong password; this is the full product path that the May regression broke.
      (3) **`./mutate`** — mutation harness that injects known faults and confirms
      `./test` goes red for each (currently 4/4 caught). Fleet-wide risk (shared
      scaffold) handed to Einstein via LLMsend for a cross-project sweep.
- [x] **Fix sqlite false-green + bump vendored zig-sqlite** (2026-06-18). The
      high-level zig-sqlite query API hit a Zig 0.16 comptime mis-lowering
      (`query.zig getQuery()` returned a slice into a by-value comptime struct
      field → query string came back all-spaces → every `prepare()`/`exec()`
      failed with `EmptyQuery`). ffpw vendored the pre-fix commit, so
      `KeyStore.open`'s entire sqlite path was **broken** — and CI never noticed
      because no test exercised `prepare`. Two compounding false-greens hid it:
      (1) `build.zig`'s `test` step depended on the test *compile* step, never an
      `addRunArtifact`, so `zig build test` compiled but never *ran* the tests;
      (2) `main.zig`'s test aggregator listed only `crypto`/`der`, silently
      excluding `key4`/`login_decrypt` suites. Fixed all three: added a real run
      step, completed the aggregator, bumped `sqlite` dep to
      `pmarreck/zig-sqlite@0f5271e4` (build.zig.zon + flake.nix rev/hash/linkFarm).
      New regression test (`key4.zig`) runs the exact nssPrivate `prepare` query
      and asserts real bytes; mutation-bite-verified. Added a `./test` runner.

## Open follow-ups (from fleet code review 2026-06-01)

These were raised by the code-review subagents and are deferred (larger effort or
judgment calls) — the higher-priority findings from that review are already fixed
(deriveKey panic, profile-path leak, dead CBC/DER code, fromString, plus new
DER-negative and login_decrypt tests).

### Test coverage gaps still open
- [x] `key4.zig KeyStore.open` full-flow test (2026-06-26). Synthetic key4.db
      e2e test covers correct-password happy path + wrong-password rejection. Could
      still add: missing `nssPrivate` row, corrupted ASN.1 blob (lower priority now
      the happy path + a negative branch are pinned).
- [ ] `main.zig` CLI driver has no unit tests. Add tests for arg parsing
      (`--profile`, `--master-password`, `--json`, unknown flags, unknown profile
      names) so refactors can't silently change CLI behavior.

### Judgment-call / won't-fix-for-now
- [ ] `crypto.zig pkcs7Unpad` short-circuits on the first byte mismatch (not
      constant-time). Flagged as a padding-oracle timing surface. **Deferred:** ffpw
      decrypts the user's own data with the user's own master key and is not a
      decryption oracle exposed to an attacker, so there is no remote party to time
      the side channel. Revisit if ffpw ever grows a mode that decrypts
      attacker-supplied ciphertext on demand.
- [ ] `main.zig parseArgs` is a long `else if` chain. Could become a comptime
      `{flag, handler}` table driven by `inline for`. Cosmetic; current code is clear.
