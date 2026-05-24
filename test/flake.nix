{
  description = "krg DSM test rig — libvirt/KVM host module, devShell, and the dsm-vm app. Target: XPEnology DS3622xs+/broadwellnk, DSM 7.3.2-86009, via RR loader 26.4.0. Separate from the production flake at ../nix.";

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
          nix-prefetch # recompute sha256 when bumping the RR .img / DSM .pat pins
        ];
        shellHook = ''
          echo "krg DSM test rig — virsh / tofu / ansible / yq / garage pinned."
          echo "Boot a DSM VM:  nix run ./test#dsm-vm [vm-name]   (see ./README.md)"
        '';
      };

      # `nix run ./test#dsm-vm [name]` — provision + boot a DSM rig VM from the pinned
      # RR loader + DSM .pat (see dsm.nix). First boot is the interactive RR menu + DSM
      # wizard → snapshot the dsm-prod-mirror baseline; dsm-pr later clones it.
      packages.${system}.dsm-vm = import ./dsm.nix { inherit pkgs; };

      apps.${system}.dsm-vm = {
        type = "app";
        program = "${self.packages.${system}.dsm-vm}/bin/dsm-vm";
      };
    };
}
