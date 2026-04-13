{
  description = "Firefox Nightly password lookup CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Pre-fetch Zig build.zig.zon dependencies for sandboxed builds
        zig-sqlite-src = pkgs.fetchgit {
          url = "https://github.com/vrischmann/zig-sqlite";
          rev = "c1a5f2720bad283f870df77b41430bd461bb9182";
          hash = "sha256-r/vBuCu7lYDKXn1KGbCzz3f7gPqLVultm8y/s/LSZa8=";
        };
        sqlite-amalgamation = pkgs.fetchzip {
          url = "https://www.sqlite.org/2025/sqlite-amalgamation-3490200.zip";
          sha256 = "sha256-zw9D86WTkqQlZIKcu2z808+4mc11bqct4GLnQsavDRw=";
          stripRoot = true;
        };

        zigPkgCache = pkgs.linkFarm "zig-pkg-cache" [
          {
            name = "sqlite-3.48.0-F2R_a9eODgDPCO5CDptJHZINZSIn48IFVIWUhuxxwGTb";
            path = zig-sqlite-src;
          }
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

          nativeBuildInputs = [ pkgs.zig_0_15 ];

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
            pkgs.zig_0_15
          ];
        };
      });
}
