# Waiter compute node user accounts (from waiter_users.yaml)
#
# To convert the existing waiter_users.yaml to this format run:
#   python3 scripts/convert_users.py waiter_users.yaml
# and merge the output here.
#
# User field reference:
#   hashedPassword — SHA-512 hash (openssl passwd -6 or mkpasswd --method=SHA-512)
#   expires        — informational only (NixOS does not enforce account expiry natively)
#   groups         — additional groups beyond krg.users.defaultGroups (docker, cuda, rdp_users)
{ ... }: {
  krg.users = {
    # All waiter users get docker + cuda + rdp_users by default (set in compute profile)
    defaultGroups = [ "docker" "cuda" "rdp_users" ];

    users = {
      # ── Faculty / Staff ──────────────────────────────────────────────────
      waiter-admin = {
        description    = "Waiter deployment administrator";
        groups         = [ "wheel" ];
        sudoNoPassword = true;
        authorizedKeys = [
          # Add waiter-admin SSH public key here
        ];
      };

      # ── Example lab member entry — copy this pattern for each user ───────
      # username = {
      #   description    = "Full Name";
      #   groups         = [];          # extra groups beyond defaultGroups
      #   hashedPassword = "$6$...";    # SHA-512 hash from waiter_users.yaml
      #   expires        = "YYYY-MM-DD";
      #   authorizedKeys = [
      #     "ssh-ed25519 AAAA... user@host"
      #   ];
      #   sudoAllowCommands = [];       # specific commands, or set sudoNoPassword
      # };

      # ── Populate the rest from waiter_users.yaml ─────────────────────────
    };
  };
}
