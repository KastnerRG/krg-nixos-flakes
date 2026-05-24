{
  description = "krg DSM test rig — libvirt/KVM host module + devShell + (planned) DSM-VM apps. Target: XPEnology DS3622xs+/broadwellnk, DSM 7.3, via the RR loader. Separate from the production flake at ../nix.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      # Import into your laptop's NixOS config to provision the virtualization host.
      nixosModules.libvirt-host = import ./modules/libvirt-host.nix;

      # `nix develop ./test` — everything to drive the rig + the IaC under test, pinned.
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          libvirt # virsh
          qemu_kvm
          opentofu # IaC layer is OpenTofu (ADR 0005)
          ansible
          yq-go
          jq
          garage # garage CLI (garage_config role)
          python3 # drift_exporter dev + the synology API client (pip/poetry, not a nixpkgs pkg)
          nix-prefetch # to compute sha256 for the RR .img / DSM .pat pins
        ];
        shellHook = ''
          echo "krg DSM test rig — virsh / tofu / ansible / yq / garage pinned."
          echo "Next: fill the RR .img + DSM 7.3 .pat pins (see ./README.md), then the dsm-vm app."
        '';
      };

      # apps.dsm-vm / apps.test-pr — PLANNED (milestone 1b/1d).
      # Blocked on the pinned RR loader .img + DSM 7.3 (DS3622xs+) .pat — see README.
      # Will provision a libvirt domain (OVMF + swtpm + a data disk) from the pinned
      # RR image and boot it; first boot is the interactive RR menu + DSM install
      # wizard (the dsm-prod-mirror baseline), after which dsm-pr clones the snapshot.
    };
}
