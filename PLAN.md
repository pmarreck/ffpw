# PLAN

Remaining work is ordered by priority. Older completions are in `docs/PLAN_LOG.md`; detailed evidence remains in Git history. Purpose and success criteria live in `INTENT.md`.

## Awaiting owner decision

- [ ] Record the `ffpw-i18n-scope` revision 1 decision in `RULES.md`, then add tested `--about` output and preserve nonzero rejection of unknown options.

## Follow-ups

- [ ] Make the Nix `checks.test` executable static on Linux and remove its dynamic-loader workaround after native and sandboxed checks stay green.
- [ ] Add focused parser coverage for profile, channel, filter limits, and unknown profile names.
- [ ] Investigate the profile-recency anomaly only if its warning instrumentation captures a recurrence. (context: docs/plan_context/profile-recency-anomaly.md)
- [ ] Make PKCS#7 padding validation constant-time if ffpw ever decrypts attacker-supplied ciphertext on demand.

## Recent completions

- [x] Added isolated missing-row and malformed-private-key-blob tests and preserved the precise malformed-blob classification after trying every candidate row. (done 2026-10-14 16:18 EDT; commit `15cb737`)
- [x] Removed the shell alias that forced an implicit Firefox channel while preserving explicit `--channel` behavior. (done 2026-09-06 11:48 EDT; dotfiles commit `99d3362`, recorded here by `16d90fe`)
- [x] Prevented Nix test builds from replacing the PATH-facing release result. (done 2026-08-28 15:05 EDT; commit `bb31b9e`)
- [x] Made the flake-built release artifact available through `bin/ffpw`. (done 2026-08-20 11:29 EDT; commit `ae005a4`)
