{
  description = "KRG NixOS Flakes - Infrastructure configuration replacing Ansible";

  inputs = {
    # Latest NixOS stable (release branch, not unstable): production rebuilds and
    # the nightly autoUpgrade then only pull backported fixes, not rolling churn.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs, ... }@inputs:
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
      base          = import ./profiles/base.nix;
      docker        = import ./modules/docker.nix;
      users         = import ./modules/users.nix;
      zfs           = import ./modules/zfs.nix;
      nix-ld        = import ./modules/nix-ld.nix;

      compose-stack  = import ./modules/services/compose-stack.nix;
      node-exporter  = import ./modules/services/node-exporter.nix;
      ipmi-exporter  = import ./modules/services/ipmi-exporter.nix;

      samba-ad      = import ./modules/samba-ad.nix;

      firewall           = import ./modules/security/firewall.nix;
      fail2ban           = import ./modules/security/fail2ban.nix;
      oec-qualys-trellix = import ./modules/security/oec-qualys-trellix.nix;

      nvidia = import ./modules/hardware/nvidia.nix;
      fpga   = import ./modules/hardware/fpga.nix;

      xrdp = import ./modules/desktop/xrdp.nix;
    };

    nixosConfigurations = {
      krg-prod  = mkSystem "krg-prod";   # KRG lab-wide production (was "fabricant")
      e4e-prod  = mkSystem "e4e-prod";   # E4E project-specific production
      waiter    = mkSystem "waiter";
      krg-ldap  = mkSystem "krg-ldap";
    };
  };
}
