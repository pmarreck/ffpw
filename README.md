# ffpw

Read-only Firefox Nightly password lookup CLI.

## Usage

```
ffpw --host <hostname> [--profile <path>]
```

Examples:

```
ffpw --host example.com
ffpw --host example.com --profile ~/Library/Application\ Support/Firefox/Profiles/xyz.default-nightly
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

## Portable Bundle (macOS)

macOS does not support fully static linking, and NSS is not a system library.
To run `ffpw` without `nix develop`, build a relocatable bundle (binary + dylibs):

```
./bin/ffpw-dist
./dist/bin/ffpw --host example.com
```
