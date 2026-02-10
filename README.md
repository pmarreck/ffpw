# ffpw

Read-only Firefox password lookup CLI. Supports Release, Nightly, Developer Edition, and ESR.

## Usage

```
ffpw <filter> [<filter> ...] [--channel <ch>] [--profile <path>]
```

Each filter is substring-matched against hostname and username (AND'd together).

Examples:

```
ffpw google                  # all logins with "google" in hostname or username
ffpw google admin            # logins matching both "google" AND "admin"
ffpw github --channel nightly
```

Set `FFPW_CHANNEL` to avoid typing `--channel` every time:

```
export FFPW_CHANNEL=nightly
ffpw google
```

Auto-detects profile if only one exists. If multiple profiles are found,
you'll be prompted to specify `--channel` or `--profile`.

## Development

Enter the dev shell:

```
nix develop
```

Build and run:

```
zig build
zig build run -- --help
```

Run tests:

```
bin/test/ffpw_test
```

## Architecture

Pure Zig implementation — no NSS/NSPR dependency. The binary links only against
`/usr/lib/libSystem.B.dylib` on macOS. Just `zig build` produces a fully portable executable.
