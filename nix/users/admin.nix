# Baseline administrative account present on every KRG machine.
# Each host gets exactly one default admin — krg-admin (KastnerRG) or
# e4e-admin (Engineers for Exploration) — selected via `krg.adminAccount`.
# Requires modules/users.nix to be imported on the host.
{ config, lib, ... }:
with lib;
let
  account = config.krg.adminAccount;

  # Canonical SSH keys per team admin — single source of truth shared with the
  # Ansible layer. Edit nix/keys/admins.json (public keys, not secret); both the
  # flake (here) and Ansible (ansible/group_vars) read that same file.
  adminKeys = builtins.fromJSON (builtins.readFile ../keys/admins.json);
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
