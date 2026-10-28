{
  description = "zapret-nix — Declarative NixOS module and Nix package for Zapret DPI bypass";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          package = pkgs.callPackage ./nix/package.nix { };
        in
        {
          default = package;
          zapret-nix = package;
          zapret = package;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkg = self.packages.${system}.default;
        in
        {
          default = {
            type = "app";
            program = "${pkg}/bin/zapret";
            meta.description = "Zapret DPI bypass init script wrapper";
          };
          zapret-nix = {
            type = "app";
            program = "${pkg}/bin/zapret";
            meta.description = "Zapret DPI bypass init script wrapper";
          };
          zapret = {
            type = "app";
            program = "${pkg}/bin/zapret";
            meta.description = "Zapret DPI bypass init script wrapper";
          };
          blockcheck = {
            type = "app";
            program = "${pkg}/bin/blockcheck";
            meta.description = "Zapret interactive DPI bypass strategy discovery tool";
          };
        }
      );

      formatter = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.nixfmt-tree
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              nixfmt
              statix
              deadnix
            ];
          };
        }
      );

      nixosModules = {
        default =
          { pkgs, lib, ... }:
          {
            imports = [ ./nix/module.nix ];
            services.zapret.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.default;
          };
        zapret-nix = self.nixosModules.default;
        zapret = self.nixosModules.default;
      };

      overlays = {
        default = final: _prev: {
          zapret-nix = final.callPackage ./nix/package.nix { };
          zapret = final.callPackage ./nix/package.nix { };
        };
        zapret-nix = self.overlays.default;
        zapret = self.overlays.default;
      };

      # The VM test is x86_64-only: running it for aarch64 would require
      # emulating the guest on the build host.
      checks.x86_64-linux = {
        default =
          let
            pkgs = nixpkgs.legacyPackages.x86_64-linux;
          in
          pkgs.testers.runNixOSTest (import ./nix/test.nix { inherit self; });

        package = self.packages.x86_64-linux.default;
      };
    };
}
