{
  description = "A package manager for Lua, written in Lua.";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  inputs.lde.url = "github:lde-org/lde-nix";
  inputs.lde.inputs.nixpkgs.follows = "nixpkgs";

  outputs =
    { nixpkgs, lde, ... }:
    let
      forEachSystem =
        fn:
        nixpkgs.lib.genAttrs [
          "aarch64-darwin"
          "aarch64-linux"
          "x86_64-darwin"
          "x86_64-linux"
        ] (system: fn system nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forEachSystem (
        system: pkgs: {
          default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                luajit
                lua-language-server

                # Packages necessary for tests and building
                cmake
                curl
                gnumake
                libxcrypt
                ninja
                openssl
              ]
              # inject lde in the devshell
              ++ [ lde.packages.${system}.default ];
          };
        }
      );
    };
}
