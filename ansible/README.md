# krg-infra — Proxmox host management (Ansible)

The **hypervisor** half of the `krg-infra` monorepo. The flake under `nix/`
configures the NixOS machines; this Ansible tree configures the **Proxmox/Debian
hosts** they run on. Goal: **machines secure and up to date by default.**

## Why this exists

A Proxmox host's root SSH was **dictionary-attacked** — that breach drove this
rebuild. The NixOS guests were already hardened, but the hypervisors had **no
config management** and were left at insecure SSH defaults. This tree closes
that gap, reusing the prior `KastnerRG/fabricant-host` setup but refactored into
generic, push-based roles applied to *every* host (it was only ever applied to
one). No Bitwarden — real secrets will live in HashiCorp Vault later.

## Layout

```
ansible/
  ansible.cfg
  requirements.yml            # collections: ansible.posix, community.general
  inventory/
    hosts.yml                 # the Proxmox hosts (group: proxmox) — fill in
    group_vars/               # MUST live next to the inventory so ansible-playbook loads it
      all.yml                 # generic baseline vars (admin keys, timezone, fail2ban, trusted nets)
      proxmox.yml             # PVE-specific vars (firewall IPSets / VM map — with proxmox_firewall)
  playbooks/site.yml          # applies the baseline to all hosts
  roles/
    base/                     # THE baseline — OS basics (timezone, packages incl tmux,
                              #   unattended upgrades, sysctl) + composes the security +
                              #   monitoring stack below (import_role, in order)
    krg_admin/                # break-glass krg-admin (sudo, key-only) — mirrors nix/users/admin.nix
    ssh_hardening/            # disable password auth, root key-only (the breach fix)
    fail2ban/                 # sshd brute-force jail
    monitoring/               # node + ipmi exporters (systemd) — on every host
    oec_qualys_trellix/       # campus-mandated Qualys + Trellix (set oec_installer)
    proxmox_firewall/         # PVE cluster.fw + per-guest <vmid>.fw (proxmox group only)
```

Every host gets the baseline by applying a single role, `base`, which composes
`krg_admin`, `ssh_hardening`, `fail2ban`, `monitoring`, and `oec_qualys_trellix`
in a deliberate order (see `roles/base/tasks/main.yml`). `proxmox_firewall` is the
one perimeter concern that stays a separate, `proxmox`-group-only play in
`site.yml` (it's a hypervisor concern, not an all-hosts default).

Admin SSH keys are **shared** with the NixOS layer — edit `nix/keys/admins.json`
(read by both); do not duplicate keys here.

## Before you run

1. `ansible-galaxy collection install -r requirements.yml`
2. Add the host(s) to `inventory/hosts.yml` (currently: one host, `fabricant`).
3. Set the real ops key(s) in `nix/keys/admins.json` and `krg_trusted_nets` in
   `inventory/group_vars/all.yml`.

> **Anti-lockout:** `ssh_hardening` authorizes your key *before* turning password
> auth off, asserts a key is set, and validates `sshd -t` before restarting (a
> bad config aborts before the restart). Still — keep a Proxmox **console**
> session open the first run and confirm a *new* key-based SSH session works
> before closing your current one.

## Run

```bash
ansible-playbook playbooks/site.yml --check     # dry run
ansible-playbook playbooks/site.yml
```

## Not done yet (next)

The roles are all built and wired in; what remains is real inputs + on-box
validation, not new code:

- **Inputs**: fill `inventory/hosts.yml`, set the real ops key(s) in
  `nix/keys/admins.json` and `krg_trusted_nets`, and point `oec_installer` at the
  local vendor archive (no archive → the OEC step no-ops rather than failing).
- **On-box validation**: confirm `monitoring` (node + ipmi exporters) and
  `oec_qualys_trellix` (Qualys + Trellix enroll/run) on a real PVE host.
- `proxmox_firewall`: `cluster.fw` (IPSets `public`/`sealab`/`ucsd`) + per-guest
  `<vmid>.fw` (krg-ldap = 100). **Tightens SSH + the exporters off `+dc/public`**
  — services → `ucsd`/`sealab`, compute → public SSH, exporters → monitoring host.
- TOTP 2FA on the PVE realm; PVE web-UI fail2ban jail; PVE patching + persistence
  hunting (post-breach).
