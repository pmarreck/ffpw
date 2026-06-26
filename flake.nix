{
  description = "Firefox Nightly password lookup CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
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
        ];
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "ffpw";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [ zigPkg ];

          dontConfigure = true;
          dontFixup = true;

          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

            zig build \
              --system ${zigPkgCache} \
              -Doptimize=ReleaseFast \
              --color off
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

        # `checks.test` builds the test binary via the same offline
        # --system zigPkgCache as `packages.default`, then on Linux re-spawns
        # it through Nix's actual dynamic linker (Zig 0.16 bakes an FHS
        # loader path that doesn't exist in the Nix build sandbox). Mirrors
        # the pattern used in c0/libjxlz.
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
              -Doptimize=Debug \
              --color off

            bin="$(find zig-out/test-bins -type f -perm -u+x | head -1)"
            [ -n "$bin" ] || { echo "no test binary produced"; exit 1; }

            # Run the compiled test binary. On Linux, Zig 0.16 bakes an FHS
            # loader path absent in the sandbox, so re-spawn through Nix's
            # dynamic linker; macOS runs it directly.
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
            DL="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
            runout="$("$DL" "$bin" 2>&1)"; rc=$?
            ''}
            ${pkgs.lib.optionalString (!pkgs.stdenv.isLinux) ''
            runout="$("$bin" 2>&1)"; rc=$?
            ''}
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
