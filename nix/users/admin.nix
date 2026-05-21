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

  # Break-glass CONSOLE password (SHA-512 crypt hash), committed DELIBERATELY.
  # WHY committed: SSH is key-only (the breach fix in base.nix), so without a
  # console password NOBODY can authenticate at the physical console when SSH /
  # network / AD is down — which is exactly when the local break-glass admin is
  # the only way in. A hash in the repo is still offline-crackable, so the
  # password MUST be a strong passphrase. Rotate / set with:
  #   nix-shell -p mkpasswd --run 'mkpasswd -m sha-512'
  # and paste the resulting "$6$...$..." string below. Accounts not listed here
  # stay password-less (console-locked, key-only SSH) until a hash is added.
  adminHashedPasswords = {
    krg-admin = "$6$xN2bY970ga7B435W$1jEkD8f/EKPKqxKMhjekzBKTrDKPPM9WdWLQagkgAOMDokADfvDMvc9n5gzI0H2XBY2rvXVRAaaSYAV2SoGyZ1";
    # e4e-admin = "$6$...";   # add when e4e-prod needs console break-glass
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
      # Home OFF /home: the break-glass admin must work when /home is a network
      # mount (e.g. waiter mounts /home from NFS via krg.nfsHome). A /home/<admin>
      # home would be shadowed by that mount and unavailable whenever the NFS
      # server is down — defeating the break-glass guarantee. /var/lib/<account>
      # is local and always present (persist it if a host runs impermanence).
      home           = "/var/lib/${account}";
      # null for accounts without a hash above -> console-locked, SSH key-only.
      hashedPassword = adminHashedPasswords.${account} or null;
    };
  };
}
