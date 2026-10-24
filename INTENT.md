# Intent

## Purpose and users

ffpw is a read-only command-line utility for people who keep credentials in Firefox and want fast local lookup by hostname or username.

## Desired outcomes

- A flake build produces a directly runnable `ffpw` for the current supported macOS or Linux platform and exposes it through the project `bin/` directory.
- Linux release artifacts are statically linked; macOS release artifacts depend only on Apple-provided system libraries.
- Automatic profile selection chooses a complete Firefox password store by capability and recency. Explicit profile or channel selection remains authoritative and reports precise failures.
- Lookups are deterministic, preserve UTF-8 data, and never modify the Firefox profile.

## Scope and non-goals

The current product reads local Firefox `logins.json` and `key4.db` data on macOS and Linux. It supports explicit Release, Beta, Nightly, Developer Edition, and ESR channel selection plus name-agnostic automatic discovery. Writing credentials, syncing profiles, remote lookup, and browser automation are outside the current scope.

Internationalization is deferred while ffpw remains an owner-only utility. Revisit it when the tool is distributed beyond its current owner or a multilingual user requests localization; the durable decision is recorded in `RULES.md`.

## Success evidence

`./test` is the complete acceptance entry point. It runs every authored Zig test, isolated CLI tests, and build-path controls. `nix build` must produce a runnable release, and the Linux package check must reject an interpreter-dependent artifact. Tests use synthetic profiles and must never query a real credential store.

Current work is ordered in `PLAN.md`.
