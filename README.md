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

Build the release artifact:

```
./build
# Equivalent Nix entry point:
nix build
```

Both commands update Nix's `result` link. The tracked relative symlink
`bin -> result/bin` makes the resulting `bin/ffpw` available through the
project's PATH entry. On Linux this is the statically linked musl build.

For native development builds:

```
nix develop -c zig build
```

Run tests:

```
./test
```

## Architecture

Pure Zig implementation with no NSS/NSPR dependency. The canonical Nix build is
fully static on Linux. On macOS it links only against Apple's system-provided
`/usr/lib/libSystem.B.dylib`; Apple does not provide a static `libSystem`.
