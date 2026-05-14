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

        # Pre-fetch SQLite amalgamation (transitive dep of vendored zig-sqlite).
        # The zig-sqlite wrapper itself is vendored at ./vendor-zig-sqlite as a
        # path dep (see build.zig.zon) and patched for Zig 0.16.
        sqlite-amalgamation = pkgs.fetchzip {
          url = "https://www.sqlite.org/2025/sqlite-amalgamation-3490200.zip";
          sha256 = "sha256-zw9D86WTkqQlZIKcu2z808+4mc11bqct4GLnQsavDRw=";
          stripRoot = true;
        };

        zigPkgCache = pkgs.linkFarm "zig-pkg-cache" [
          {
            name = "N-V-__8AAH-mpwB7g3MnqYU-ooUBF1t99RP27dZ9addtMVXD";
            path = sqlite-amalgamation;
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

        devShells.default = pkgs.mkShell {
          packages = [
            zigPkg
          ];
        };
      });
}
