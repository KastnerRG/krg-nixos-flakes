# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Goal

`krg-infra` is the KastnerRG infrastructure monorepo, replacing the old Ansible
infrastructure at [fabricant-prod](https://github.com/KastnerRG/fabricant-prod)
and [waiter](https://github.com/KastnerRG/waiter). It has **two coequal layers**,
split by configuration tool (not by guest/host role — some NixOS machines are
physical):

- **`nix/`** — every machine configured by **NixOS** (the flake): physical hosts
  (waiter) *and* Proxmox VMs (fabricant, krg-ldap). Machines are composed from
  profile modules — no per-host playbooks.
- **`ansible/`** — the **Proxmox/Debian hypervisor hosts** those VMs run on.

This whole rebuild is incident-response driven: a Proxmox host's root SSH was
dictionary-attacked. The hypervisors had no config management — `ansible/` closes
that gap (SSH hardening + fail2ban + a key-only `krg-admin`), and the old AD
(inside the blast radius) is being rebuilt clean as a new Samba AD forest on
krg-ldap.

**Target feature set (from the old Ansible repos):**
- **fabricant-prod**: production services on fabricant.ucsd.edu — Traefik, Authentik (SSO), Grafana/Prometheus/Loki, Blackbox Exporter, PostgreSQL, Outline, MLflow, Label Studio, node/IPMI exporters, firewall, unattended upgrades
- **waiter**: research/compute at 132.239.95.67 — NVIDIA CUDA + Container Toolkit, FPGA tooling (Vivado, Vitis, Verilator), XRDP+XFCE desktop, Fail2ban, Prometheus (node/DCGM/blackbox via Docker), btrfs snapshots (snapper)

## Common Commands

The flake lives in `nix/`. Run from the repo root with the `./nix` ref shown
below, or `cd nix` and drop the prefix.

```bash
# Validate the flake (Nix syntax + module type checking)
nix flake check ./nix

# Build a system config without deploying
nix build ./nix#nixosConfigurations.fabricant.config.system.build.toplevel
nix build ./nix#nixosConfigurations.waiter.config.system.build.toplevel

# Inspect a config value
nix eval ./nix#nixosConfigurations.fabricant.config.networking.hostName

# Deploy to the current machine
sudo nixos-rebuild switch --flake ./nix#fabricant

# Deploy remotely over SSH
nixos-rebuild switch --flake ./nix#fabricant --target-host fabricant-admin@fabricant.ucsd.edu --use-remote-sudo
nixos-rebuild switch --flake ./nix#waiter --target-host waiter-admin@132.239.95.67 --use-remote-sudo

# Update flake inputs (run inside nix/)
cd nix && nix flake update          # or: nix flake update nixpkgs

# Format .nix files
alejandra nix    # or: nixfmt nix

# --- Proxmox hosts (ansible/) ---
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/harden.yml --check     # dry run
ansible-playbook playbooks/harden.yml
```

## Repository Structure

```
krg-infra/
  CLAUDE.md  README.md  LICENSE  .github/workflows/build.yml
  nix/                             # NixOS machines (physical + Proxmox guests)
    flake.nix                      # inputs + nixosConfigurations outputs
    modules/
      docker.nix                   # Docker CE + daemon config (metrics, Loki driver, NVIDIA runtime)
      users.nix                    # user/SSH key management module with option types
      snapper.nix                  # btrfs snapshot schedules
      samba-ad.nix                 # Samba AD domain controller (samba4Full daemon, krb5.conf, DNS/resolver, AD ports)
      security/
        fail2ban.nix               # fail2ban SSH protection
        firewall.nix               # NixOS firewall wrapper (single switch); monitoring-only ports
      services/
        compose-stack.nix          # systemd service that runs a docker compose project
        node-exporter.nix          # Prometheus node exporter (on by default via base.nix; waiter uses Docker)
        ipmi-exporter.nix          # Prometheus IPMI exporter (fabricant only)
      hardware/{nvidia,fpga}.nix
      desktop/xrdp.nix             # XRDP + XFCE (waiter)
    profiles/
      base.nix                     # every host: SSH hardening, auto-upgrade, OEC + fail2ban + node-exporter + in-guest firewall; isVM enables qemu-guest-agent
      server.nix                   # fabricant role
      compute.nix                  # waiter role (physical)
      directory.nix                # krg-ldap role: Samba AD DC (realm KRG.LOCAL)
    hosts/{fabricant,waiter,krg-ldap}/{default,hardware-configuration}.nix
    users/admin.nix                # local break-glass admin (krg-admin/e4e-admin); human users come from Samba AD
    docker-compose/{fabricant,waiter}/...   # compose stacks mounted by the flake
  ansible/                         # Proxmox hypervisor hosts (Debian/PVE)
    ansible.cfg  requirements.yml
    inventory/hosts.yml            # the Proxmox hosts (group: proxmox)
    group_vars/proxmox.yml         # admin SSH keys, trusted nets, fail2ban knobs
    playbooks/harden.yml
    roles/
      krg_admin/                   # key-only sudo krg-admin (mirrors nix/users/admin.nix)
      proxmox_ssh_hardening/       # disable password auth, root key-only (the breach fix)
      proxmox_fail2ban/            # sshd brute-force jail
```

## Architecture: Key Patterns

### 0. Firewall ownership (defense-in-depth, split by layer)

Each layer owns the firewall concern it's best at, so they don't drift:
- **In-guest NixOS firewall (`krg.firewall`) — on EVERY host, VMs included.** It
  owns *which ports* a service exposes (e.g. `samba-ad.nix` declares the AD port
  set) and gives **fail2ban** a backend (the direct countermeasure to the
  dictionary attack that drove this rebuild). `profiles/base.nix` sets it
  `mkDefault true`.
- **Proxmox host firewall (`ansible/`) — additive perimeter.** It owns *which
  sources* may reach a VM, plus containment if a guest is compromised. It does
  **not** replace the in-guest layer.

### 1. NixOS modules vs Docker Compose

Services that were **native systemd** in Ansible (node_exporter, ipmi_exporter) use native NixOS `services.prometheus.exporters.*` modules. Everything else stays as **Docker Compose** stacks managed by `krg.composeStacks`.

The `compose-stack` module runs each stack as a `systemd` oneshot service with `docker compose --project-directory <workingDir> -f <nix-store-path> up -d`. The `--project-directory` flag makes Docker Compose resolve relative volume paths (like `./.secrets/foo.txt`) against the **working directory** (e.g. `/var/lib/krg/fabricant/`), not the Nix store. The compose files stay read-only in the store; runtime data (databases, secrets, config) lives in the working directory.

### 2. Compose file `include:` and the directory reference pattern

`compose.yml` uses Docker Compose's `include:` directive to pull in sub-stacks. For this to work when the compose files are in the Nix store, the entire `nix/docker-compose/fabricant/` **directory** must be in the same store path. Always reference the directory, not individual files:

```nix
# In nix/hosts/fabricant/default.nix — correct pattern
let composeDir = ../../docker-compose/fabricant; in
{
  krg.composeStacks.fabricant.composeFiles = [ "${composeDir}/compose.yml" ];
}
# The whole docker-compose/fabricant/ directory is copied to the store,
# so include: can find compose.authentik.yml etc. alongside compose.yml.
```

### 3. Adding a new machine (NixOS)

1. Run `nixos-generate-config --show-hardware-config` on the target; save as `nix/hosts/<name>/hardware-configuration.nix`
2. Create `nix/hosts/<name>/default.nix` importing the appropriate profile plus any `krg.composeStacks`
3. Add the host to `nix/flake.nix` under `nixosConfigurations`
4. `nix flake check ./nix` locally, then deploy with `nixos-rebuild switch --flake ./nix#<name> --target-host ...`

## Secrets (Pre-sops-nix)

Secrets are **not** managed by Nix yet. Before starting each compose stack, manually create the required files in the working directory. Each host's `default.nix` lists required secrets in a comment.

**fabricant** secrets in `/var/lib/krg/fabricant/.secrets/`:
- `authentik_postgres_admin_password.txt`
- `authentik_admin_password.env` (`AUTHENTIK_SECRET_KEY=...` and `AUTHENTIK_POSTGRESQL__PASSWORD=...`)
- `authentik_traefik_token.env`
- `gf_admin_password.txt`
- `label_studio_admin_password_pg.env`
- `postgres_admin_password.txt`
- `outline_secrets.env`
- `mlflow.env` (`POSTGRES_PASSWORD`, `OIDC_*` variables)

**waiter** secrets in `/var/lib/krg/waiter/.secrets/`:
- `gf_admin_password.txt`

The `.secrets/` directories are in `.gitignore`. When sops-nix is added later, these file paths stay the same — sops-nix just populates them at activation time.

## Runtime Config Directories

The grafana/prometheus/loki compose services mount config from the working directory. Before starting the fabricant stack, populate:
- `/var/lib/krg/fabricant/grafana/` — Grafana config
- `/var/lib/krg/fabricant/loki/loki-config.yaml` — Loki config
- `/var/lib/krg/fabricant/loki/promtail-config.yaml` — Promtail config (update to NixOS journal or `/var/log`)
- `/var/lib/krg/fabricant/prometheus/prometheus.yml` — Prometheus scrape config
- `/var/lib/krg/fabricant/blackbox-exporter/blackbox.yml` — copy from `nix/docker-compose/fabricant/blackbox-exporter/blackbox.yml`

## Pending Items

- [ ] Add SSSD/realmd client integration so hosts authenticate human/lab users against Samba AD (replaces the removed per-host user lists; only `nix/users/admin.nix` break-glass admin stays local). Do NOT import the old domain's password hashes — they're compromised; users get new passwords.
- [ ] Add real SSH public keys to the break-glass admin in `nix/users/admin.nix` and to `ansible/group_vars/proxmox.yml`
- [ ] Replace placeholder `hardware-configuration.nix` files for both hosts
- [~] Qualys Cloud Agent + Trellix HX (xagt): implemented in `nix/modules/security/oec-qualys-trellix.nix`, enabled for all hosts via `base.nix`. Runs the proprietary `.deb` binaries under nix-ld. The `oec-install` one-shot service extracts to `/opt/fireeye` + `/usr/local/qualys` and enrolls on first boot. Place the installer archive at `/var/lib/krg/oec/oec-qualystrellixinstallers-linux.tgz` (NOT in the Nix store — live credentials). **Still needs on-box validation.**
- [~] Samba AD domain controller (`krg-ldap`, VMID 100): implemented in `nix/modules/samba-ad.nix`, enabled via `nix/profiles/directory.nix` (new forest, realm `KRG.LOCAL` / workgroup `KRG`, `SAMBA_INTERNAL` DNS). Installs `samba4Full`, runs the combined `samba` daemon as `systemd` service `samba-ad-dc`, frees port 53 (disables systemd-resolved, resolver → `127.0.0.1` + fallback), renders `/etc/krb5.conf`, and opens the AD DC port set in the in-guest `krg.firewall` (active — defense-in-depth; Proxmox adds the source-restricting perimeter). **The domain is NOT created by Nix** — after first deploy, run the one-time `samba-tool domain provision` documented at the bottom of `samba-ad.nix`, then `systemctl start samba-ad-dc`. Still needs on-box provisioning + validation.
- [~] Proxmox host hardening (`ansible/`): `krg_admin` + `proxmox_ssh_hardening` + `proxmox_fail2ban` roles built. **Pending:** fill in `inventory/hosts.yml`, real admin keys + `krg_trusted_nets` in `group_vars/proxmox.yml`, then run `playbooks/harden.yml`. Next role: the Proxmox **perimeter firewall** (`host.fw` restricting 22/8006 to trusted nets + per-guest `<vmid>.fw`, e.g. `100.fw` for krg-ldap).
- [ ] TOTP 2FA on the PVE realm; PVE web-UI fail2ban jail (needs `filter.d/proxmox.conf`); PVE patching + persistence hunting (post-breach)
- [ ] Add sops-nix for secrets management (replacing manual `.secrets/` population)
- [ ] Review `promtail-config.yaml` — the old Ansible deploy log path is no longer relevant
