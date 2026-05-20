# krg-infra — Proxmox host management (Ansible)

This is the **hypervisor** half of the `krg-infra` monorepo. The NixOS flake at
the repo root configures the **guests** (VMs); this Ansible tree configures the
**Proxmox VE hosts** they run on.

## Why this exists

A Proxmox host's root SSH was **dictionary-attacked** — that breach is what
drove this whole rebuild. The flake had already hardened the guests (key-only,
ed25519-only, no root login, fail2ban), but the hypervisors had **no config
management** and were left at insecure SSH defaults. This tree closes that gap.

## Layout

```
ansible/
  ansible.cfg
  requirements.yml            # collections: ansible.posix, community.general
  inventory/hosts.yml         # the Proxmox hosts (fill in)
  group_vars/proxmox.yml      # admin SSH keys, trusted nets, fail2ban knobs
  playbooks/harden.yml        # applies the hardening roles
  roles/
    krg_admin/                # break-glass krg-admin (sudo, key-only) — mirrors NixOS users/admin.nix
    proxmox_ssh_hardening/    # disable password auth, root key-only (the breach fix)
    proxmox_fail2ban/         # brute-force banning (sshd jail)
```

`krg_admin` runs first so a named, key-capable sudo admin exists before SSH
locks down. Once you've confirmed you can SSH in as `krg-admin` and `sudo`, you
can tighten further: set `ansible_user: krg-admin` (with `become: true`) in the
inventory and `proxmox_ssh_permit_root: "no"` to stop direct root SSH entirely.

## Before you run

1. `ansible-galaxy collection install -r requirements.yml`
2. Add the rebuilt hosts to `inventory/hosts.yml`.
3. In `group_vars/proxmox.yml`, set **`proxmox_admin_ssh_keys`** to the real ops
   key(s) and **`krg_trusted_nets`** to your admin/VPN subnets. The example key
   is a placeholder.

> **Anti-lockout:** the SSH role authorizes your key *before* it turns password
> auth off, asserts at least one key is set, and validates `sshd -t` before
> restarting (a bad config aborts before the restart). Still — keep a Proxmox
> **console** session open the first time and confirm a *new* key-based SSH
> session works before closing your current one.

## Run

```bash
ansible-playbook playbooks/harden.yml --check     # dry run
ansible-playbook playbooks/harden.yml
```

## What it does NOT do yet (next roles)

- **Proxmox firewall** (`host.fw` source-restricting SSH/`8006` to trusted nets,
  plus per-guest `<vmid>.fw`). This is the hypervisor "perimeter" layer that
  pairs with the in-guest NixOS firewall (which owns service ports + fail2ban).
- TOTP 2FA on the PVE realm; PVE patching; post-compromise persistence hunting.
- PVE web-UI fail2ban jail (needs a `filter.d/proxmox.conf` — see `jail.local`).
