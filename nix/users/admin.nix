# Baseline administrative account present on every KRG machine.
# Each host gets exactly one default admin — krg-admin (KastnerRG) or
# e4e-admin (Engineers for Exploration) — selected via `krg.adminAccount`.
# Requires modules/users.nix to be imported on the host.
{ config, lib, ... }:
with lib;
let
  account = config.krg.adminAccount;

  # Canonical SSH keys per team admin. Add teammates' keys to the right list.
  adminKeys = {
    krg-admin = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF2Z7LbaDPTNkdnuvFivXTUx8X9gU0ZyWrrYBH7KSmG3 chris@chris-laptop"
    ];
    e4e-admin = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF2Z7LbaDPTNkdnuvFivXTUx8X9gU0ZyWrrYBH7KSmG3 chris@chris-laptop"
      # Add additional E4E admin SSH public keys here.
    ];
  };
in {
  options.krg.adminAccount = mkOption {
    type        = types.enum [ "krg-admin" "e4e-admin" ];
    default     = "krg-admin";
    description = "Which baseline administrator account this machine gets.";
  };

  config = {
    krg.users.users.${account} = {
      description    = "Baseline administrator (${account})";
      groups         = [ "wheel" ];
      sudoNoPassword = true;
      authorizedKeys = adminKeys.${account};
    };
  };
}
