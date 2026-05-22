{
  description = "KRG NixOS Flakes - Infrastructure configuration replacing Ansible";

  inputs = {
    # Latest NixOS stable (release branch, not unstable): production rebuilds and
    # the nightly autoUpgrade then only pull backported fixes, not rolling churn.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    # Declarative disk partitioning/formatting (waiter's ZFS layout). Pin its
    # nixpkgs to ours so disko's lib matches the system being built.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # "Erase your darlings" — bind-mounted /persist state over an ephemeral root.
    # Pin its nixpkgs to ours (same as disko) so it doesn't drag in a second
    # nixpkgs at nixos-unstable — keeps the whole flake on the pinned stable tree.
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
      impermanence  = import ./modules/impermanence.nix;

      compose-stack  = import ./modules/services/compose-stack.nix;
      node-exporter  = import ./modules/services/node-exporter.nix;
      ipmi-exporter  = import ./modules/services/ipmi-exporter.nix;

      samba-ad      = import ./modules/samba-ad.nix;
      ad-client     = import ./modules/sssd-ad-client.nix;

      firewall           = import ./modules/security/firewall.nix;
      fail2ban           = import ./modules/security/fail2ban.nix;
      oec-qualys-trellix = import ./modules/security/oec-qualys-trellix.nix;

      nvidia = import ./modules/hardware/nvidia.nix;
      fpga   = import ./modules/hardware/fpga.nix;

      xrdp = import ./modules/desktop/xrdp.nix;
    };

    nixosConfigurations = {
      krg-prod    = mkSystem "krg-prod";    # KRG lab-wide production (was "fabricant")
      e4e-prod    = mkSystem "e4e-prod";    # E4E project-specific production
      waiter      = mkSystem "waiter";
      krg-ldap    = mkSystem "krg-ldap";
      krg-deploy  = mkSystem "krg-deploy"; # Ansible control node + OpenTofu
    };
  };
}
