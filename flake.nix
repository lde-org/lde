{
  description = "A package manager for Lua, written in Lua.";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs =
    { self, nixpkgs, ... }:
    let
      # GENERATED VERSION CONTROL - BEGIN
      releaseTag = "v0.7.1";
      platform_attrs = {
        "aarch64-darwin" = {
          url = "https://github.com/codebycruz/lpm/releases/download/v0.7.1/lpm-macos-aarch64";
          sha256 = "0z8gpc17j9wqywd3i335bg4wv6fnpaqahxyg8q529cxrs2lc6nn7";
        };
        "aarch64-linux" = {
          url = "https://github.com/codebycruz/lpm/releases/download/v0.7.1/lpm-linux-aarch64";
          sha256 = "0zhn7n1gsl23q5w5zymjrfb1969wn5lsm3svskzx7aq7wq52i9rx";
        };
        "x86_64-linux" = {
          url = "https://github.com/codebycruz/lpm/releases/download/v0.7.1/lpm-linux-x86-64";
          sha256 = "01ijw9j7k5b7f5c9s8i3260kzagpgr3gic5y6pjbw2ffffkcdfby";
        };
      };
      # GENERATED VERSION CONTROL - END
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
      packages = forEachSystem (
        system: pkgs: {
          default = pkgs.stdenv.mkDerivation {
            name = "lpm";
            version = releaseTag;
            src = pkgs.fetchurl platform_attrs.${system};
            phases = [ "installPhase" ];
            installPhase = ''
              install -D "$src" "$out/bin/lpm"
            '';
          };
        }
      );

      devShells = forEachSystem (
        system: pkgs: {
          default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                luajit
                stylua
                lua-language-server
              ]
              # inject lpm in the devshell
              ++ [ self.packages.${system}.default ];
          };
        }
      );
    };
}
