# PLAN

Remaining work is ordered by priority. Older completions are in `docs/PLAN_LOG.md`; detailed evidence remains in Git history. Purpose and success criteria live in `INTENT.md`.

## Active

- [ ] Show each matching login's password-set and last-used timestamps in a safe table, preserving complete credentials even when the table exceeds terminal width, while keeping ffpw standalone and statically linked on Linux. (implementation green; awaiting visual approval before exact multi-width/color snapshots)

## Follow-ups

- [ ] Investigate the profile-recency anomaly only if its warning instrumentation captures a recurrence. (context: docs/plan_context/profile-recency-anomaly.md)
- [ ] Make PKCS#7 padding validation constant-time if ffpw ever decrypts attacker-supplied ciphertext on demand.

## Recent completions

- [x] Added focused parser coverage for explicit profile paths, channels, mixed filters, and the 16-filter boundary, fixing cleanup after parse failures. (done 2026-10-27 21:29 EDT)
- [x] Made the Linux Nix test executable static, rejected dynamic test artifacts, and removed the dynamic-loader relaunch. (done 2026-10-27 21:27 EDT)
- [x] Added tested one-line `--about` output with compile-target identity and preserved nonzero rejection of unknown options. (done 2026-10-23 20:43 EDT; commit `d6d7952`)
- [x] Recorded the deferred-internationalization decision from `ffpw-i18n-scope` revision 1 in `RULES.md` and reconciled project intent. (done 2026-10-23 20:15 EDT; commit `d6d7952`)
- [x] Added isolated missing-row and malformed-private-key-blob tests and preserved the precise malformed-blob classification after trying every candidate row. (done 2026-10-14 16:18 EDT; commit `15cb737`)
- [x] Removed the shell alias that forced an implicit Firefox channel while preserving explicit `--channel` behavior. (done 2026-09-06 11:48 EDT; dotfiles commit `99d3362`, recorded here by `16d90fe`)
- [x] Prevented Nix test builds from replacing the PATH-facing release result. (done 2026-08-28 15:05 EDT; commit `bb31b9e`)
- [x] Made the flake-built release artifact available through `bin/ffpw`. (done 2026-08-20 11:29 EDT; commit `ae005a4`)
