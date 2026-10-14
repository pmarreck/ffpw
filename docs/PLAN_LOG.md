# Plan log

Older completed items retired from `PLAN.md`. Detailed implementation and verification records remain recoverable in Git history through commit `16d90fe`.

- [x] [Completed] Verified the portable macOS release artifact and full build/test path on native hardware. (done 2026-07-27 13:00 EDT; commit `9f08bdb`)
- [x] [Completed] Stopped profile discovery from converting filesystem errors into ordinary sentinel values. (done 2026-07-27 12:58 EDT; commit `23dba94`)
- [x] [Completed] Tested profile-recency selection in both winner directions so directory iteration order cannot pass by chance. (done 2026-07-27 12:58 EDT; commit `23dba94`)
- [x] [Completed] Made `nix build` produce a static, directly runnable Linux artifact and a portable macOS artifact. (done 2026-07-27 12:44 EDT; commit `6f4004a`)
- [x] [Completed] Changed automatic profile selection from directory-name matching to capability and recency. (done 2026-07-27 11:06 EDT; commit `574d7e2`)
- [x] [Completed] Made the build independent of shell glob expansion. (done 2026-07-27 10:51 EDT; commit `eced618`)
- [x] [Completed] Replaced the mutation script's Python dependency with Awk and retained exact replacement checks. (done 2026-07-27 10:51 EDT; commit `eced618`)
- [x] [Completed] Restored ordinary Git branch tracking and repaired project tooling configuration. (done 2026-07-06 10:37 EDT; commit `1347659`)
- [x] [Completed] Added a test-execution meta-control, a synthetic end-to-end key-store test, and mutation checks after a false-green incident. (done 2026-06-26 18:05 EDT; commit `c91b235`)
- [x] [Completed] Fixed the vendored SQLite query failure and made the Zig test step execute every aggregated test. (done 2026-06-01 16:17 EDT; commit `a6d7914`)
