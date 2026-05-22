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

    serverIp = mkOption {
      type        = types.nullOr types.str;
      default     = null;
      example      = "137.110.161.109";
      description = ''
        IP of `server`, pinned in /etc/hosts so a member host can resolve the DC
        without depending on it for DNS. Also lets this module render a usable
        krb5.conf on hosts that aren't the DC. Null = rely on existing DNS.
      '';
    };

    isDomainController = mkOption {
      type        = types.bool;
      default     = false;
      description = ''
        This host IS the DC (shares the box with samba-ad). Disables SSSD machine-
        account password rotation + dynamic DNS updates (the DC must not rotate its
        own account), and yields krb5.conf to the samba-ad module. Members leave
        this false so their machine password rotates normally.
      '';
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

    sudoGroups = mkOption {
      type        = types.listOf types.str;
      default     = [ ];
      example     = [ "Domain Admins" ];
      description = ''
        AD groups whose members get sudo (PASSWORD required — AD users have a
        password, unlike the key-only break-glass admin which is NOPASSWD). Separate
        from allowedGroups: allowedGroups gates who may log IN, sudoGroups gates who
        may escalate. Empty = no AD group gets sudo (only the local break-glass admin).
        Names with spaces (e.g. "Domain Admins") are escaped for sudoers automatically.
      '';
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

    gpoAccessControl = mkOption {
      type        = types.enum [ "disabled" "permissive" "enforcing" ];
      default     = "disabled";
      description = ''
        SSSD ad_gpo_access_control. SSSD's default (enforcing) fetches Group Policy
        from sysvol every login; against a Samba AD DC that errors and an error
        under enforcing becomes a denial ("Access denied … System error"). We gate
        access with the memberOf filter (allowedGroups), not GPOs, so default to
        disabled. Use permissive (log only) or enforcing if you adopt GPOs.
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
        # NixOS has no /bin/bash — a login shell must be a real path (store bash)
        # or sshd rejects the account pre-auth: "shell /bin/bash does not exist".
        default_shell = ${pkgs.bashInteractive}/bin/bash

        [pam]
        ${optionalString cfg.sshKeysFromAD "\n[ssh]\n"}
        [domain/${cfg.realm}]
        id_provider = ad
        auth_provider = ad
        access_provider = ad
        chpass_provider = ad
        # Gate access via the memberOf filter below, not GPOs (GPO fetch errors
        # against Samba AD and would deny everyone with a "System error").
        ad_gpo_access_control = ${cfg.gpoAccessControl}
        ad_domain = ${cfg.domain}
        ${optionalString (cfg.server != null) "ad_server = ${cfg.server}"}
        krb5_realm = ${cfg.realm}
        # uid/gid source: SID-derived id-mapping (automatic) vs RFC2307 attributes.
        ldap_id_mapping = ${if cfg.idMapping then "True" else "False"}
        use_fully_qualified_names = false
        cache_credentials = true
        krb5_store_password_if_offline = true
        fallback_homedir = /home/%u
        default_shell = ${pkgs.bashInteractive}/bin/bash
        ${optionalString cfg.isDomainController ''
          # This host IS the DC — never let SSSD rotate its machine-account
          # password or push DNS updates.
          ad_maximum_machine_account_password_age = 0
          dyndns_update = false''}
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

    # Sudo for AD admin groups (PASSWORD required — distinct from the key-only
    # break-glass admin's NOPASSWD rule in users/admin.nix). Group names with spaces
    # like "Domain Admins" must be escaped for sudoers (%Domain\ Admins); NixOS's
    # security.sudo.extraRules would NOT escape them, so build the lines here.
    security.sudo.extraConfig = mkIf (cfg.sudoGroups != [ ]) ''
      # krg.adClient.sudoGroups — AD groups granted sudo (password required).
      ${concatMapStringsSep "\n"
        (g: "%${builtins.replaceStrings [ " " ] [ "\\ " ] g} ALL=(ALL:ALL) ALL")
        cfg.sudoGroups}
    '';

    # kinit/klist for domain users.
    environment.systemPackages = [ pkgs.krb5 ];

    # Resolve the DC without depending on it for DNS (member hosts). On the DC this
    # is its own name→IP, harmless. mkDefault so a host can override.
    networking.hosts = mkIf (cfg.server != null && cfg.serverIp != null)
      { ${cfg.serverIp} = mkDefault [ cfg.server ]; };

    # Every domain member uses the AD DC as its PRIMARY DNS by default. This is
    # required, not just tidy: SSSD's own (c-ares) resolver queries the servers in
    # resolv.conf directly and does NOT consult the /etc/hosts pin above, so unless
    # the DC is a real nameserver the member cannot resolve krg-ldap.krg.local (the
    # internal krg.local zone) and SSSD flaps offline — which breaks logins for any
    # not-yet-cached (i.e. brand-new) user with a bare "Permission denied (publickey)".
    # The DC runs SAMBA_INTERNAL DNS and forwards non-AD queries upstream
    # (samba-ad.nix dnsForwarder), so it resolves everything; mkBefore keeps it ahead
    # of a host's site fallback resolvers. NOT applied on the DC itself (it owns its
    # resolver via samba-ad.nix) nor when serverIp is null (SRV autodiscovery, which
    # then relies on DNS that already serves krg.local).
    networking.nameservers = mkIf (!cfg.isDomainController && cfg.serverIp != null)
      (mkBefore [ cfg.serverIp ]);

    # krb5.conf for member hosts (the DC's samba-ad module renders its own at normal
    # priority, so mkDefault here yields on the DC and applies on members). KDC is
    # pinned to `server`, resolved via the /etc/hosts entry above.
    environment.etc."krb5.conf".text = mkDefault ''
      [libdefaults]
          default_realm = ${cfg.realm}
          dns_lookup_realm = false
          dns_lookup_kdc = ${if cfg.server != null then "false" else "true"}
          rdns = false
      ${optionalString (cfg.server != null) ''
        [realms]
            ${cfg.realm} = {
                kdc = ${cfg.server}
                admin_server = ${cfg.server}
            }

        [domain_realm]
            .${cfg.domain} = ${cfg.realm}
            ${cfg.domain} = ${cfg.realm}''}
    '';
  };
}
