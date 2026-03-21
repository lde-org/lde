{
  description = "A package manager for Lua, written in Lua.";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  inputs.systems.url = "github:nix-systems/default";
  inputs.flake-utils = {
    url = "github:numtide/flake-utils";
    inputs.systems.follows = "systems";
  };

  outputs =
    { nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Nixpkgs static builds always use musl
        target = "libluajit-linux-x86-64-musl";
        libluajit = pkgs.pkgsStatic.luajit;

        lpm = pkgs.stdenv.mkDerivation {
          pname = "lpm";
          # NOTE: This will have to be updated when the version changes
          version = "0.7.1";
          src = ./.;

          nativeBuildInputs = [
            pkgs.luajit
            libluajit
          ];
          buildPhase = ''
            tmpdir="$out/tmp"
            # Cache expected by the lua program
            cachedir="$tmpdir/luajit-cache/${target}"

            mkdir -p "$(dirname "$cachedir")"
            ln -s "${libluajit}" "$cachedir"

            cd packages/lpm
            TMPDIR="$tmpdir" BOOTSTRAP=1 LPM_PLATFORM_LIBC=musl luajit ./src/init.lua compile --outfile lpm
          '';
          installPhase = ''
            mkdir -p "$out/bin"
            cp lpm "$out/bin"
            rm -rf "$out/tmp"
          '';
        };
      in
      {
        packages.default = lpm;

        devShells.default = pkgs.mkShell {
          packages =
            with pkgs;
            [
              luajit
              stylua
              lua-language-server
            ]
            #(Silzinc) NOTE: I'm not sure about bootstraping lpm like that,
            # since the result changes with the commit. Is it necessary to develop lpm itself?
            # Once the commit is merged, I will try fetching this lpm from a version on github.
            ++ [ lpm ];
        };
      }
    );
}
