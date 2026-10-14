# Profile-recency anomaly

On 2026-07-27, automatic selection briefly chose a year-stale Firefox profile even though a complete profile had a directory modification time about one year newer. Minutes later, unchanged directory times produced the correct result, and the issue did not recur during subsequent verification.

Tests ruled out three hypotheses: macOS failing to stat a directory, SQLite access by ffpw changing the profile directory time, and fixed directory-iteration order satisfying the recency test by chance. Commit `23dba94` removed error-to-zero fallbacks from directory open and stat operations. A future recurrence caused by one of those operations now reports the skipped profile and operating-system error instead of silently ranking it at epoch zero.

No speculative fix is planned without recurrence evidence. If it recurs, capture the warning and relevant profile directory times without exposing profile contents or credentials.
