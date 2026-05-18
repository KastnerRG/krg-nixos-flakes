{
  description = "KRG NixOS Flakes - Infrastructure configuration replacing Ansible";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs, nixpkgs-stable, ... }@inputs:
  let
    system = "x86_64-linux";

    mkSystem = hostname: nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs; };
      modules = [
        { _module.args.self = self; }
        ./hosts/${hostname}/default.nix
      ];
    };
  in {
    nixosModules = {
      base          = import ./modules/base.nix;
      docker        = import ./modules/docker.nix;
      users         = import ./modules/users.nix;
      zfs           = import ./modules/zfs.nix;
      nix-ld        = import ./modules/nix-ld.nix;

      compose-stack  = import ./modules/services/compose-stack.nix;
      node-exporter  = import ./modules/services/node-exporter.nix;
      ipmi-exporter  = import ./modules/services/ipmi-exporter.nix;

      firewall           = import ./modules/security/firewall.nix;
      fail2ban           = import ./modules/security/fail2ban.nix;
      oec-qualys-trellix = import ./modules/security/oec-qualys-trellix.nix;

      nvidia = import ./modules/hardware/nvidia.nix;
      fpga   = import ./modules/hardware/fpga.nix;

      xrdp = import ./modules/desktop/xrdp.nix;
    };

    nixosConfigurations = {
      fabricant = mkSystem "fabricant";
      waiter    = mkSystem "waiter";
    };
  };
}
