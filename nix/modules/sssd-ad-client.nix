# SSSD-based Active Directory client: makes a host RESOLVE (NSS) and AUTHORIZE
# (PAM) Samba AD users, so people log in with their KRG.LOCAL accounts instead of
# local users. Pairs with modules/samba-ad.nix (the DC) and is written to be
# reusable on member hosts (waiter, krg-prod) later — not DC-specific.
#
# By default uid/gid are auto-mapped from each user's AD SID (`idMapping = true`,
# SSSD's `ldap_id_mapping`) — deterministic and identical across all SSSD hosts, so
# no per-user uidNumber/gidNumber is ever set. Home dir and shell come from
# fallback_homedir/default_shell. Set `idMapping = false` to instead read RFC2307
# attributes from AD (then every account needs uidNumber/gidNumber/home/shell).
#
# SSH stays KEY-ONLY (the base.nix hardening that closed the breach): SSSD supplies
# identity + the account/session phases (incl. home-dir creation), NOT a password
# prompt. Public keys live in the user's ~/.ssh/authorized_keys (created on first
# login), unless `sshKeysFromAD` is on (served from AD via sss_ssh_authorizedkeys).
#
# Access control uses SSSD's ad_access_filter (memberOf), not sshd AllowGroups,
# because default AD group names contain spaces ("Domain Admins") which AllowGroups
# can't express. Local users (krg-admin) are unaffected: PAM uses pam_sss with
# user_unknown=ignore, and NSS resolves files before sss.
#
# Deploying this BEFORE the runtime prerequisites is safe — SSSD just runs offline
# and local key login keeps working; AD users resolve once the steps below are done.
#
# ── Runtime prerequisites (stateful, NOT expressible in Nix) ────────────────────
# Deploying this module only wires NSS/PAM/sshd; per-host and per-user setup is
# manual and lives in the runbook (kept in one place so it can't drift):
#   * Per host: export a Kerberos keytab to /etc/krb5.keytab (on the DC:
#       `samba-tool domain exportkeytab /etc/krb5.keytab`; on members, a join).
#   * Per user: POSIX attrs (uidNumber/gidNumber/unixHomeDirectory/loginShell),
#       group membership for access, and — when sshKeysFromAD = true — the
#       one-time OpenSSH-LPK schema extension plus the user's sshPublicKey.
#   See ../../docs/creating-a-user.md for the exact commands.
{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.krg.adClient;
  baseDN = concatMapStringsSep "," (c: "DC=${c}") (splitString "." cfg.domain);
  # memberOf filter for the named groups (default container CN=Users).
  groupFilter = optionalString (cfg.allowedGroups != [ ])
    "(|${concatMapStringsSep "" (g: "(memberOf=CN=${g},CN=Users,${baseDN})") cfg.allowedGroups})";
  effectiveFilter = if cfg.accessFilter != null then cfg.accessFilter else groupFilter;
in {
  options.krg.adClient = {
    enable = mkEnableOption "SSSD Active Directory client (log in as AD users)";

    realm = mkOption {
      type        = types.str;
      default     = "KRG.LOCAL";
      description = "AD Kerberos realm (uppercase).";
    };

    domain = mkOption {
      type        = types.str;
      default     = "krg.local";
      description = "AD DNS domain (lowercase).";
    };

    server = mkOption {
      type        = types.nullOr types.str;
      default     = null;
      description = "Pin a specific DC as ad_server. Null = DNS SRV autodiscovery.";
    };

    allowedGroups = mkOption {
      type        = types.listOf types.str;
      default     = [ ];
      example     = [ "Domain Admins" ];
      description = ''
        Restrict login to members of these AD groups (matched by memberOf under
        CN=Users). Empty = any enabled domain account may log in. Built into
        ad_access_filter, which (unlike sshd AllowGroups) handles names with
        spaces. Groups in a custom OU need the raw `accessFilter` instead.
      '';
    };

    accessFilter = mkOption {
      type        = types.nullOr types.str;
      default     = null;
      description = "Raw ad_access_filter; overrides allowedGroups when set.";
    };

    idMapping = mkOption {
      type        = types.bool;
      default     = true;
      description = ''
        Auto-assign POSIX uid/gid algorithmically from each user's AD SID
        (ldap_id_mapping) — deterministic and identical across SSSD hosts, so no
        per-user uidNumber/gidNumber is ever set. Set false to read RFC2307
        attributes from AD instead (then every account needs uidNumber, gidNumber,
        unixHomeDirectory and loginShell, or it won't resolve).
      '';
    };

    sshKeysFromAD = mkOption {
      type        = types.bool;
      default     = false;
      description = ''
        Serve SSH authorized keys from AD via sss_ssh_authorizedkeys (keys stored
        in the sshPublicKey attribute). Requires extending the Samba AD schema with
        that attribute first. When false, keys come from ~/.ssh/authorized_keys.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.sssd = {
      enable                       = true;
      sshAuthorizedKeysIntegration = cfg.sshKeysFromAD;
      config = ''
        [sssd]
        config_file_version = 2
        services = nss, pam${optionalString cfg.sshKeysFromAD ", ssh"}
        domains = ${cfg.realm}

        [nss]
        fallback_homedir = /home/%u
        default_shell = /bin/bash

        [pam]
        ${optionalString cfg.sshKeysFromAD "\n[ssh]\n"}
        [domain/${cfg.realm}]
        id_provider = ad
        auth_provider = ad
        access_provider = ad
        chpass_provider = ad
        ad_domain = ${cfg.domain}
        ${optionalString (cfg.server != null) "ad_server = ${cfg.server}"}
        krb5_realm = ${cfg.realm}
        # uid/gid source: SID-derived id-mapping (automatic) vs RFC2307 attributes.
        ldap_id_mapping = ${if cfg.idMapping then "True" else "False"}
        use_fully_qualified_names = false
        cache_credentials = true
        krb5_store_password_if_offline = true
        fallback_homedir = /home/%u
        default_shell = /bin/bash
        # This host is (or shares the box with) the DC — never let SSSD rotate the
        # machine-account password or push DNS updates.
        ad_maximum_machine_account_password_age = 0
        dyndns_update = false
        ${optionalString cfg.sshKeysFromAD "ldap_user_ssh_public_key = sshPublicKey"}
        ${optionalString (effectiveFilter != "") "ad_access_filter = ${effectiveFilter}"}
      '';
    };

    # Enforce the access filter for key-based SSH: pam_sss runs in the account
    # phase as [default=bad success=ok user_unknown=ignore] — denies non-permitted
    # AD users while leaving local users (krg-admin) to fall through to pam_unix.
    security.pam.services.sshd.sssdStrictAccess = true;

    # SSSD supplies identity, not the home directory — create it on first login.
    security.pam.services.sshd.makeHomeDir  = true;
    security.pam.services.login.makeHomeDir = true;

    # kinit/klist for domain users. On the DC, /etc/krb5.conf is already rendered
    # by modules/samba-ad.nix; member hosts must provide one (e.g. security.krb5).
    environment.systemPackages = [ pkgs.krb5 ];
  };
}
