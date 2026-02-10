# ffpw

Read-only Firefox password lookup CLI. Supports Release, Nightly, Developer Edition, and ESR.

## Usage

```
ffpw --host <hostname> [--channel <ch>] [--profile <path>]
```

If no `--channel` or `--profile` is given, auto-detects the Firefox profile.
If multiple profiles exist, you'll be prompted to specify one.

Examples:

```
ffpw --host example.com
ffpw --host example.com --channel nightly
ffpw --host example.com --channel release
ffpw --host example.com --profile ~/Library/Application\ Support/Firefox/Profiles/xyz.default-release
```

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
