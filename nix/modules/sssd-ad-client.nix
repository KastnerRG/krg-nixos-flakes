# SSSD-based Active Directory client: makes a host RESOLVE (NSS) and AUTHORIZE
# (PAM) Samba AD users, so people log in with their KRG.LOCAL accounts instead of
# local users. Pairs with modules/samba-ad.nix (the DC) and is written to be
# reusable on member hosts (waiter, krg-prod) later — not DC-specific.
#
# Identity uses RFC2307 POSIX attributes (uidNumber/gidNumber/unixHomeDirectory/
# loginShell) read straight from AD — the DC was provisioned `--use-rfc2307` — so
# `ldap_id_mapping = false`. An account with no POSIX attrs simply won't resolve.
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
#   1. Kerberos keytab for the host at /etc/krb5.keytab. On the DC:
#        sudo samba-tool domain exportkeytab /etc/krb5.keytab
#        sudo chmod 600 /etc/krb5.keytab
#      (On a member host this comes from a domain join instead.)
#   2. POSIX-enable each login account + its primary group in AD. e.g.:
#        sudo samba-tool group edit "Domain Users"   # add: gidNumber: 10000
#        sudo samba-tool user  edit <username>        # add: uidNumber: 10000
#                                                     #      gidNumber: 10000
#                                                     #      unixHomeDirectory: /home/<username>
#                                                     #      loginShell: /bin/bash
#   3. Plant the SSH key for the first login (key-only auth, so it must exist
#      before the home dir does — pre-create it as root, ed25519 per base.nix):
#        sudo install -d -m700 /home/<username>/.ssh
#        printf '%s\n' '<ed25519 pubkey>' | sudo tee /home/<username>/.ssh/authorized_keys
#        sudo chown -R <uid>:<gid> /home/<username>
#        sudo chmod 600 /home/<username>/.ssh/authorized_keys
#   4. Verify, then SSH in:
#        getent passwd <username>          # resolves via sss
#        id <username>                     # shows uid/gid/groups (incl. domain admins)
#        sudo sssctl user-checks <username> -s sshd   # access + PAM evaluation
#
# ── Extra prerequisite when sshKeysFromAD = true ────────────────────────────────
# AD has no SSH-key attribute, so extend the schema ONCE with the OpenSSH-LPK
# attribute `sshPublicKey` (forest-wide + permanent — deliberate). On the DC:
#
#   cat > /tmp/sshpubkey.ldif <<'EOF'
#   dn: CN=sshPublicKey,CN=Schema,CN=Configuration,DC=krg,DC=local
#   objectClass: top
#   objectClass: attributeSchema
#   cn: sshPublicKey
#   attributeID: 1.3.6.1.4.1.24552.500.1.1.1.13
#   lDAPDisplayName: sshPublicKey
#   attributeSyntax: 2.5.5.10
#   oMSyntax: 4
#   isSingleValued: FALSE
#
#   dn: CN=ldapPublicKey,CN=Schema,CN=Configuration,DC=krg,DC=local
#   objectClass: top
#   objectClass: classSchema
#   cn: ldapPublicKey
#   governsID: 1.3.6.1.4.1.24552.500.1.1.2.0
#   lDAPDisplayName: ldapPublicKey
#   subClassOf: top
#   objectClassCategory: 3
#   mayContain: sshPublicKey
#   EOF
#   sudo ldbadd -H /var/lib/samba/private/sam.ldb /tmp/sshpubkey.ldif \
#        --option="dsdb:schema update allowed"=true
#   printf 'dn:\nchangetype: modify\nadd: schemaUpdateNow\nschemaUpdateNow: 1\n-\n' | \
#     sudo ldbmodify -H /var/lib/samba/private/sam.ldb --option="dsdb:schema update allowed"=true
#   sudo systemctl restart samba-ad-dc
#
# Then store the key on the account (replaces step 3's ~/.ssh planting):
#   sudo samba-tool user edit <username>     # add: objectClass: ldapPublicKey
#                                            #      sshPublicKey: ssh-ed25519 AAAA... you@laptop
#   sudo sss_cache -E
#   sss_ssh_authorizedkeys <username>        # must echo the key back before SSHing
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
        # RFC2307: read POSIX uid/gid/home/shell from AD; don't SID-map.
        ldap_id_mapping = false
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
