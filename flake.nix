{
  description = "Firefox Nightly password lookup CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
		table-src = {
			url = "github:pmarreck/tsv_to_ansi_table/aa7cdef0cad4dab6c33a3188ed723faba5436ff1";
			flake = false;
		};
		utf8proc-src = {
			url = "github:JuliaStrings/utf8proc/v2.11.3";
			flake = false;
		};
		random-src = {
			url = "github:pmarreck/random/76ada4a2d6259569f901985b08d8d5ad10f45059";
			flake = false;
		};
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, table-src, utf8proc-src, random-src }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Pin Zig 0.16.0 explicitly via zig-overlay so we don't drift with nixpkgs.
        zigPkg = zig-overlay.packages.${system}."0.16.0";

        # Pre-fetch SQLite amalgamation (transitive dep of zig-sqlite).
        sqlite-amalgamation = pkgs.fetchzip {
          url = "https://www.sqlite.org/2025/sqlite-amalgamation-3490200.zip";
          sha256 = "sha256-zw9D86WTkqQlZIKcu2z808+4mc11bqct4GLnQsavDRw=";
          stripRoot = true;
        };

        # Fork of vrischmann/zig-sqlite (patched for Zig 0.16) — used by ffpw.
        zig-sqlite-src = pkgs.fetchgit {
          url = "https://github.com/pmarreck/zig-sqlite.git";
          rev = "0f5271e40efa3961d5e345a0153c2310cbb506d3";
          hash = "sha256-GFLe/tAGaOYtUT6lBwwC2/fTVBJHfGK8q8Vy/5GxaVo=";
        };

        zigPkgCache = pkgs.linkFarm "zig-pkg-cache" [
          {
            name = "N-V-__8AAH-mpwB7g3MnqYU-ooUBF1t99RP27dZ9addtMVXD";
            path = sqlite-amalgamation;
          }
          {
            name = "sqlite-3.48.0-F2R_a2-kDgDvM19xx3e7DI2HswNlObGgB4JwMIImJISU";
            path = zig-sqlite-src;
          }
			{
				name = "tsv_to_ansi_table-0.1.0-mnR1jtj0AQCQjkZRqNXTG-slLHW-upTNrDD37LIYHY3A";
				path = table-src;
			}
			{
				name = "N-V-__8AACywKABFCj0r_Y-jIWsk9ahy10zlk78hjn6S-39g";
				path = utf8proc-src;
			}
			{
				name = "random-0.4.0-dyRyrJ6FCQA374i2644KvuGmR-iz0ob8pUigAxNVL0WD";
				path = random-src;
			}
        ];

        # Make the build target EXPLICIT rather than relying on Zig's native
        # detection, which inside the Nix sandbox silently resolved to musl and
        # produced a *dynamically* linked musl binary — one whose interpreter
        # (/lib/ld-musl-x86_64.so.1) exists on neither NixOS nor a typical glibc
        # distro. build.zig links statically whenever the ABI is musl, so on
        # Linux this yields a genuinely portable, interpreter-free binary.
        #
        # macOS gets no target flag: Apple ships no static libSystem and forbids
        # fully static executables, so its portable form is the native dynamic
        # build against /usr/lib/libSystem.B.dylib, present on every Mac.
        zigTargetFlag = pkgs.lib.optionalString pkgs.stdenv.isLinux
          "-Dtarget=${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-musl";

        # Darwin needs the SDK for libSystem headers (sqlite3.c pulls in libc).
        darwinInputs = pkgs.lib.optionals pkgs.stdenv.isDarwin [ pkgs.apple-sdk ];
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "ffpw";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [ zigPkg ] ++ darwinInputs;

          dontConfigure = true;
          dontFixup = true;

          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

            zig build \
              --system ${zigPkgCache} \
              ${zigTargetFlag} \
              -Doptimize=ReleaseFast \
              --color off

            # The artifact must be self-contained. On Linux a leftover INTERP
            # segment means the static link silently did not happen.
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
            if readelf -l zig-out/bin/ffpw 2>/dev/null | grep -q INTERP; then
              echo "ffpw is dynamically linked; expected a static musl binary" >&2
              readelf -l zig-out/bin/ffpw | grep -A1 INTERP >&2
              exit 1
            fi
            ''}
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp zig-out/bin/ffpw $out/bin/
          '';

          meta = with pkgs.lib; {
            description = "Firefox Nightly password lookup CLI";
            license = licenses.mit;
            platforms = platforms.unix;
            mainProgram = "ffpw";
          };
        };

        # `checks.test` builds the test binary via the same offline package
        # cache and explicit target as `packages.default`. Linux checks reject
        # a dynamic artifact before running the binary directly.
        checks.test = pkgs.stdenv.mkDerivation {
          pname = "ffpw-test";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ zigPkg ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

            # Compile the test binary offline (same zigPkgCache as the package).
            zig build test-compile \
              --system ${zigPkgCache} \
              ${zigTargetFlag} \
              -Doptimize=Debug \
              --color off

            bin="$(find zig-out/test-bins -type f -perm -u+x | head -1)"
            [ -n "$bin" ] || { echo "no test binary produced"; exit 1; }

            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
			if readelf -l "$bin" | grep -q INTERP; then
				echo "META-CONTROL: test binary is dynamic; expected static Linux executable" >&2
				exit 1
			fi
            ''}

			runout="$("$bin" 2>&1)"; rc=$?
            printf '%s\n' "$runout"

            # META-CONTROL (MFIC): a green is trustworthy only if the harness
            # actually RAN and ran EVERY authored test. The Zig runner prints
            # "i/N name...OK" per test; N is the executed total. Assert: the
            # binary passed (rc==0 — it exits non-zero on any failure), tests
            # actually ran (N>0 — catches a compile-only false green), and N
            # equals the number of `test` blocks authored across src/ — which
            # catches a file silently dropped from main.zig's test aggregator
            # (the omission that hid the broken sqlite path for ~5 weeks).
            [ "$rc" -eq 0 ] || { echo "META-CONTROL: test binary exited $rc"; exit 1; }
            authored="$(cat src/*.zig | grep -cE '^test ')"
            total="$(printf '%s\n' "$runout" | grep -oE '^[0-9]+/[0-9]+ ' | head -1 | sed 's#.*/##; s# ##')"
            [ -n "$total" ] || total=0
            echo "meta-control: authored=$authored executed=$total"
            [ "$total" -gt 0 ] || { echo "META-CONTROL: no tests executed (compile-only false green)"; exit 1; }
            [ "$total" -eq "$authored" ] || { echo "META-CONTROL: executed $total but $authored authored — a file is missing from main.zig's test aggregator"; exit 1; }
            echo "meta-control OK: all $total authored tests executed and passed"
          '';
          installPhase = ''
            mkdir -p $out
            echo "tests passed" > $out/result
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = [
            zigPkg
          ];
        };
      });
}
