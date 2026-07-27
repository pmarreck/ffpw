# ffpw — Plan / TODO

## Current state (2026-07-27, first session on thelio-nixos)

**GREEN.** `./test` prints `31/31 authored tests executed` + CLI + build-script
suites; `./mutate` prints `6/6 caught`. Warm `./test` is ~1.7s (a cold Zig cache
costs ~40s once, for the test binary + sqlite3 C lib).

**Thelio is now the primary dev box** (Mac reachable over Tailscale, passwordless
ssh). This clone was 4 commits behind origin and on a detached HEAD from the jj
era; `yolo` is now a normal git branch tracking `origin/yolo`. jj is abandoned
(LLM impedance mismatch) — use plain git. Tag `rescue/pre-sync-b390c0f` parks the
pre-sync commit whose content was verified already present upstream.

**Open — needs Peter's call:**
- [ ] `nix build` emits a **dynamically-linked musl** binary
      (interp `/lib/ld-musl-x86_64.so.1`, which does not exist on NixOS), so the
      artifact `./build` installs into `zig-out/bin/` cannot execute locally;
      `bin/ffpw` only works because it falls back to a native `zig build`. CI
      papers over this by re-spawning through an explicit loader (`"$DL" "$bin"`).
      Recommendation: make the nix build **statically** linked musl — then it runs
      anywhere, CI drops the loader dance, and `./build`'s install is genuinely
      usable. Alternative: force a native/glibc nix build.
- [ ] Add a `./build` control asserting the installed binary actually *executes*
      (same spirit as the PATH-shadow control) so this class cannot recur silently.

**Next steps (optional, nothing blocking):**
- Extend the e2e key4 test with missing-`nssPrivate`-row and corrupted-blob
  branches (happy path + wrong-password already covered).
- `main.zig` arg-parsing tests (profile *selection* is now covered; the flag
  parser still is not).
- Two fleet proposals are with Einstein (LLMsend, `~/inbox/2026-06-26-*`):
  (a) test-harness false-green sweep, (b) PATH-shadow control as a standard.
  No ffpw action pending on either.

## Completed

- [x] **Profile selection is capability-based, not name-based** (2026-07-27
      11:00 EST). Reported: `ffpw amazon.com` → "Missing logins.json in profile
      directory." Root cause: selection matched directory-name SUFFIXES in a
      fixed order (release, nightly, dev, esr, then legacy "default"), so it
      locked onto a stale `rbbm52p1.default-nightly` (key4.db present,
      logins.json absent) and never considered the live Firefox **Beta** profile
      `b5y7l11v.default`. `beta` was not even in the Channel enum. Fixed by
      splitting the policy out as a pure `pickProfile`/`isEligible` over
      `ProfileCandidate` facts: auto-detection now qualifies a profile by
      CAPABILITY (must hold both logins.json and key4.db) rather than by name, so
      it is channel- and naming-agnostic; ties go to the most recently modified
      profile; an explicit `--channel` still wins outright so its error stays
      precise. Discloses on stderr when it picks among >1 usable profile. Added
      `beta`. 6 tests written FIRST as a classifier over candidate SETS — 5 failed
      red on real behavior (`expected 1, found 0` = it chose Nightly) before the
      fix. 2 new mutants; `./mutate` 6/6.
- [x] **`./build` no longer depends on shell globbing** (2026-07-27 10:52 EST).
      Peter's shells run `set -f` (noglob), which propagates into scripts, so
      `install -m755 result/bin/* zig-out/bin/` left the pattern literal and the
      nix output never reached `zig-out/bin`. Replaced with `find -L … -exec
      install`. Test runs the REAL `./build` against a stubbed `nix` with globbing
      both OFF and ON — the pair matters, since a glob-dependent script passes the
      globbing-ON case.
- [x] **`./mutate` de-Pythoned** (2026-07-27 10:58 EST). It shelled out to
      `python3` for its literal find/replace — unavailable in the dev shell and
      against project policy — silently scoring 0/4 UNAPPLIED. Reimplemented in
      awk (strings passed via ENVIRON so awk does no escape processing), still
      asserting the needle occurs exactly once.
- [x] **Repo/tooling repair on thelio** (2026-07-27). Detached HEAD → `yolo`
      tracking origin; 4 unfetched commits pulled; `AGENTS.md` was committed as an
      ABSOLUTE symlink into a stale macOS path (dangling on every Linux box) →
      repointed relative; `.codescan/config.ini` pointed at port **11435** where
      nothing listens (ollama is on 11434), so semantic search was silently dead →
      adopted validate's config + weights.toml and reindexed.

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
