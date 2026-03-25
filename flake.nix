{
  description = "A package manager for Lua, written in Lua.";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  inputs.lpm.url = "github:Silzinc/lpm-nix?ref=refs/tags/v0.7.2";
  inputs.lpm.inputs.nixpkgs.follows = "nixpkgs";

  outputs =
    { nixpkgs, lpm, ... }:
    let
      forEachSystem =
        fn:
        nixpkgs.lib.genAttrs [
          "aarch64-darwin"
          "aarch64-linux"
          # "x86_64-darwin" # not supported yet
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
              ]
              # inject lpm in the devshell
              ++ [ lpm.packages.${system}.default ];
          };
        }
      );
    };
}
