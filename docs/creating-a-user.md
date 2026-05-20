# Creating a User (KRG Active Directory)

KRG human accounts live in the **KRG.LOCAL** Samba AD forest, hosted on the
domain controller **krg-ldap**. This runbook covers creating an account and
making it able to log into AD-integrated hosts over SSH.

> Local break-glass admins (`krg-admin`/`e4e-admin`) are a *separate*, host-local
> mechanism defined in `nix/users/admin.nix` — not AD accounts. Keep at least one
> working so you can never be locked out by an AD outage.

All `samba-tool`/`ldbmodify` commands run **on krg-ldap as root** (they edit the
directory database directly). SSH stays **key-only** everywhere (no passwords on
the wire); the password you set below is only used for Kerberos (`kinit`), `sudo`,
console, etc.

## Prerequisites (one-time, already in place)

- The domain controller is provisioned and `samba-ad-dc` is running.
- The target host runs the SSSD AD client (`krg.adClient` — see
  [`nix/modules/sssd-ad-client.nix`](../nix/modules/sssd-ad-client.nix)), with its
  keytab exported (`samba-tool domain exportkeytab /etc/krb5.keytab`). krg-ldap
  itself qualifies; member hosts get this as the SSSD rollout proceeds.
- For SSH keys served from AD: the OpenSSH-LPK **schema extension** has been
  applied once to the forest — see [Appendix: schema extension](#appendix-one-time-schema-extension).

## Steps

### 1. Create the account

```bash
sudo samba-tool user create <username>
# optionally: --given-name="..." --surname="..." --mail-address="...@ucsd.edu"
```

You're prompted for a password. Use a strong one — the domain enforces complexity
and the rebuild this directory replaced was driven by a *dictionary* attack. Do
**not** reuse any old-domain password; old hashes are considered compromised and
are never imported.

### 2. POSIX-enable the account (so Unix hosts can resolve it)

The forest was provisioned `--use-rfc2307`, so SSSD reads the Unix identity
straight from AD. An account with no POSIX attributes won't resolve at all.

Pick uid/gid numbers from a range you manage (≥ 10000, kept unique per user). The
**primary group** needs a `gidNumber` once:

```bash
sudo EDITOR=nano samba-tool group edit "Domain Users"     # add:  gidNumber: 10000
```

Then the user (an editor opens — add these lines):

```bash
sudo EDITOR=nano samba-tool user edit <username>
#   uidNumber: 10001
#   gidNumber: 10000
#   unixHomeDirectory: /home/<username>
#   loginShell: /bin/bash
```

### 3. Grant access to the right hosts

Login is gated per host by `krg.adClient.allowedGroups` (an SSSD `ad_access_filter`
on group membership). Add the user to the group that host allows:

```bash
sudo samba-tool group addmembers "Domain Admins" <username>   # e.g. for the DC
```

krg-ldap (the directory server) only admits **Domain Admins**. Member hosts will
admit whatever group their config names (e.g. a lab-users group) — not the DC.

### 4. Add the user's SSH public key to AD

Requires the [schema extension](#appendix-one-time-schema-extension). The auxiliary
class must be **committed before** the attribute it permits, so this is two
separate modifies — one to attach `ldapPublicKey`, one to set the key:

```bash
USER='<username>'
KEY='ssh-ed25519 AAAA...your-public-key... you@laptop'   # ed25519 only (RSA is rejected)
DN=$(sudo samba-tool user show "$USER" | sed -n 's/^dn: //p' | head -1)

# a. attach the aux class
sudo ldbmodify -H /var/lib/samba/private/sam.ldb <<EOF
dn: $DN
changetype: modify
add: objectClass
objectClass: ldapPublicKey
-
EOF

# b. now sshPublicKey is permitted on the object
sudo ldbmodify -H /var/lib/samba/private/sam.ldb <<EOF
dn: $DN
changetype: modify
add: sshPublicKey
sshPublicKey: $KEY
-
EOF
```

To **rotate** a key later, repeat step (b) with `replace: sshPublicKey` instead of
`add:`. (`$USER` is also a built-in shell variable defaulting to your current
login — make sure it holds the AD username, or just use the literal name.)

### 5. Refresh the cache and verify

```bash
sudo sss_cache -E                              # drop stale negative cache entries
getent passwd <username>                       # ...:10001:10000:...:/home/<username>:/bin/bash
id <username>                                  # groups include the access group
sss_ssh_authorizedkeys <username>              # echoes the key back
```

### 6. Log in

```bash
ssh <username>@<host>          # e.g. krg-ldap.ucsd.edu / 137.110.161.109
```

No directories are pre-created: the key comes from AD, and `pam_mkhomedir` creates
`/home/<username>` on first login.

## Appendix: one-time schema extension

AD ships no SSH-key attribute, so the OpenSSH-LPK schema must be added **once** to
the forest. This is **forest-wide and permanent** — an attribute can't be cleanly
removed from an AD schema afterwards. The attribute must exist and the schema must
reload *before* the class that references it, so it's stepwise:

```bash
# 1. the sshPublicKey attribute
sudo ldbadd -H /var/lib/samba/private/sam.ldb --option="dsdb:schema update allowed"=true <<'EOF'
dn: CN=sshPublicKey,CN=Schema,CN=Configuration,DC=krg,DC=local
objectClass: top
objectClass: attributeSchema
cn: sshPublicKey
attributeID: 1.3.6.1.4.1.24552.500.1.1.1.13
lDAPDisplayName: sshPublicKey
attributeSyntax: 2.5.5.10
oMSyntax: 4
isSingleValued: FALSE
EOF

# 2. reload so the attribute is known
sudo ldbmodify -H /var/lib/samba/private/sam.ldb --option="dsdb:schema update allowed"=true <<'EOF'
dn:
changetype: modify
replace: schemaUpdateNow
schemaUpdateNow: 1
EOF

# 3. the ldapPublicKey auxiliary class (objectClassCategory 3) that permits it
sudo ldbadd -H /var/lib/samba/private/sam.ldb --option="dsdb:schema update allowed"=true <<'EOF'
dn: CN=ldapPublicKey,CN=Schema,CN=Configuration,DC=krg,DC=local
objectClass: top
objectClass: classSchema
cn: ldapPublicKey
governsID: 1.3.6.1.4.1.24552.500.1.1.2.0
lDAPDisplayName: ldapPublicKey
subClassOf: top
objectClassCategory: 3
mayContain: sshPublicKey
EOF

# 4. reload again, then restart so it's fully live
sudo ldbmodify -H /var/lib/samba/private/sam.ldb --option="dsdb:schema update allowed"=true <<'EOF'
dn:
changetype: modify
replace: schemaUpdateNow
schemaUpdateNow: 1
EOF
sudo systemctl restart samba-ad-dc
```

## Troubleshooting

- **`attribute 'sshPublicKey' ... was not found in the schema`** — the schema
  extension hasn't run; do the appendix first.
- **`attribute 'sshPublicKey' ... does not exist in the specified objectclasses`**
  — you tried to add the class and the key in one modify; split into 4a then 4b.
- **`sss_ssh_authorizedkeys` → "Error looking up public keys"** — the host isn't
  running the `sshKeysFromAD` config yet (no SSSD `ssh` responder). Deploy it
  (`git pull && sudo nixos-rebuild switch --flake ./nix#<host>`) and check the
  `services =` line in `/etc/sssd/sssd.conf` includes `ssh`.
- **`getent passwd <username>` empty** — missing/!mismatched POSIX attrs (step 2),
  or stale cache (`sudo sss_cache -E`). The user's `gidNumber` must match a group
  that actually has that `gidNumber`.
