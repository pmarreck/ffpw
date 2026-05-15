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
          rev = "3d9727e1de92c0b3c32a08bd30d899461a022fd6";
          hash = "sha256-sIHIVmTJZrybBGtWpziwL7Q/ss7jBYqpdxhu2cuERiI=";
        };

        zigPkgCache = pkgs.linkFarm "zig-pkg-cache" [
          {
            name = "N-V-__8AAH-mpwB7g3MnqYU-ooUBF1t99RP27dZ9addtMVXD";
            path = sqlite-amalgamation;
          }
          {
            name = "sqlite-3.48.0-F2R_a6KNDgBvub_w8cyJaHZRy_JFhbUiDxnYfIY2B_SZ";
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

        devShells.default = pkgs.mkShell {
          packages = [
            zigPkg
          ];
        };
      });
}
