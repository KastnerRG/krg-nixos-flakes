# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Goal

`krg-infra` is the KastnerRG infrastructure monorepo, replacing the old Ansible
infrastructure at [fabricant-prod](https://github.com/KastnerRG/fabricant-prod)
and [waiter](https://github.com/KastnerRG/waiter). It has **two coequal layers**,
split by configuration tool (not by guest/host role — some NixOS machines are
physical):

- **`nix/`** — every machine configured by **NixOS** (the flake): physical hosts
  (waiter) *and* Proxmox VMs (krg-prod, e4e-prod, krg-ldap). Machines are composed
  from profile modules — no per-host playbooks.
- **`ansible/`** — the **Proxmox/Debian hypervisor hosts** those VMs run on.

This whole rebuild is incident-response driven: a Proxmox host's root SSH was
dictionary-attacked. The hypervisors had no config management — `ansible/` closes
that gap (secure + up to date by default), and the old AD (inside the blast
radius) is being rebuilt clean as a new Samba AD forest on krg-ldap.

**Target feature set (from the old Ansible repos):**
- **fabricant-prod**: production services — Traefik, Authentik (SSO), Grafana/Prometheus/Loki, Blackbox, PostgreSQL, Outline, MLflow, Label Studio, node/IPMI exporters, firewall, unattended upgrades. (These are the lab-wide tools now on **krg-prod**; E4E project-specific services go on **e4e-prod**.)
- **waiter**: research/compute at 132.239.95.67 — NVIDIA CUDA + Container Toolkit, FPGA tooling (Vivado, Vitis, Verilator), XRDP+XFCE desktop, Fail2ban, Prometheus (node/DCGM/blackbox via Docker), btrfs snapshots (snapper)

## Common Commands

The flake lives in `nix/`. Run from the repo root with the `./nix` ref shown
below, or `cd nix` and drop the prefix.

```bash
# Validate the flake (Nix syntax + module type checking)
nix flake check ./nix

# Build a system config without deploying
nix build ./nix#nixosConfigurations.krg-prod.config.system.build.toplevel
nix build ./nix#nixosConfigurations.waiter.config.system.build.toplevel

# Inspect a config value
nix eval ./nix#nixosConfigurations.krg-prod.config.networking.hostName

# Deploy to the current machine
sudo nixos-rebuild switch --flake ./nix#krg-prod

# Deploy remotely (new nixos-rebuild: --sudo, not --use-remote-sudo)
nixos-rebuild switch --flake ./nix#krg-prod --target-host krg-admin@krg-prod.ucsd.edu --sudo --ask-sudo-password
nixos-rebuild switch --flake ./nix#waiter   --target-host waiter-admin@132.239.95.67 --sudo --ask-sudo-password

# Update flake inputs (run inside nix/)
cd nix && nix flake update          # or: nix flake update nixpkgs

# Format .nix files
alejandra nix    # or: nixfmt nix

# --- Proxmox hosts (ansible/) ---
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/site.yml --check     # dry run
ansible-playbook playbooks/site.yml
```

## Repository Structure

```
krg-infra/
  CLAUDE.md  README.md  LICENSE  .github/workflows/build.yml
  nix/                             # NixOS machines (physical + Proxmox guests)
    flake.nix                      # inputs + nixosConfigurations (krg-prod, e4e-prod, waiter, krg-ldap)
    keys/admins.json               # SHARED admin SSH keys — read by nix + ansible
    networks/trusted.json          # SHARED trusted nets / Proxmox IPSets — read by nix + ansible + PVE cluster.fw
    modules/
      docker.nix  users.nix  snapper.nix
      samba-ad.nix                 # Samba AD domain controller (samba4Full daemon, krb5.conf, DNS/resolver, AD ports)
      security/{fail2ban,firewall,oec-qualys-trellix}.nix   # firewall is the single switch
      services/{compose-stack,node-exporter,ipmi-exporter}.nix
      hardware/{nvidia,fpga}.nix   desktop/xrdp.nix
    profiles/
      base.nix                     # every host: SSH hardening, auto-upgrade, OEC + fail2ban + node-exporter + in-guest firewall; isVM enables qemu-guest-agent
      server.nix                   # krg-prod / e4e-prod role (docker, compose, ipmi exporter)
      compute.nix                  # waiter role (physical; NVIDIA/FPGA/XRDP/ZFS)
      directory.nix                # krg-ldap role: Samba AD DC (realm KRG.LOCAL)
    hosts/{krg-prod,e4e-prod,waiter,krg-ldap}/{default,hardware-configuration}.nix
    users/admin.nix                # local break-glass admin (krg-admin/e4e-admin); keys from keys/admins.json; human users come from Samba AD
    docker-compose/{krg-prod,waiter}/...   # compose stacks mounted by the flake
  ansible/                         # Proxmox hypervisor hosts (Debian/PVE)
    ansible.cfg  requirements.yml
    inventory/hosts.yml            # the Proxmox hosts (group: proxmox) — currently one host, "fabricant"
    group_vars/{all,proxmox}.yml   # all.yml = generic baseline (keys/trusted nets via the shared files); proxmox.yml = PVE-specific
    playbooks/site.yml             # all hosts → base; proxmox group → proxmox_firewall
    roles/
      base/                        # THE baseline: OS basics (timezone, packages incl tmux, unattended upgrades, sysctl) + composes the security/monitoring roles below (import_role, ordered: krg_admin → ssh_hardening → fail2ban → monitoring → oec)
      krg_admin/                   # key-only sudo krg-admin (mirrors nix/users/admin.nix)
      ssh_hardening/               # disable password auth, root key-only (the breach fix)
      fail2ban/                    # sshd brute-force jail
      monitoring/                  # node + ipmi exporters (systemd) — on every host via base
      oec_qualys_trellix/          # campus-mandated Qualys + Trellix (set oec_installer) — via base
      proxmox_firewall/            # PVE cluster.fw + per-guest <vmid>.fw (proxmox group only, separate play)
```

> **Naming note:** `fabricant` now refers only to the Proxmox **host** (hypervisor,
> in the ansible inventory). The old nix `fabricant` services config was split into
> `krg-prod` (lab-wide tools) and `e4e-prod` (E4E project services).

## Architecture: Key Patterns

### 0. Firewall ownership (defense-in-depth, split by layer)

Each layer owns the firewall concern it's best at, so they don't drift:
- **In-guest NixOS firewall (`krg.firewall`) — on EVERY host, VMs included.** It
  owns *which ports* a service exposes (e.g. `samba-ad.nix` declares the AD port
  set) and gives **fail2ban** a backend (the countermeasure to the dictionary
  attack that drove this rebuild). `profiles/base.nix` sets it `mkDefault true`.
- **Proxmox host firewall (`ansible/`) — additive perimeter.** Owns *which
  sources* may reach a VM, plus containment. Services → `ucsd`/`sealab`; compute
  (waiter) → public SSH (protected by key-only + fail2ban). Does **not** replace
  the in-guest layer.

### 0b. Shared data across layers

Values needed by both nix and ansible live in one file each, under `nix/` (the
flake can only read its own subtree); ansible reads them across the repo:
- `nix/keys/admins.json` — admin SSH public keys (not secret).
- `nix/networks/trusted.json` — trusted nets / Proxmox IPSets + monitoring host.
Edit these, not the per-layer copies.

### 1. NixOS modules vs Docker Compose

Services that were **native systemd** in Ansible (node_exporter, ipmi_exporter) use native NixOS `services.prometheus.exporters.*` modules. Everything else stays as **Docker Compose** stacks managed by `krg.composeStacks`.

The `compose-stack` module runs each stack as a `systemd` oneshot service with `docker compose --project-directory <workingDir> -f <nix-store-path> up -d`. The `--project-directory` flag makes Docker Compose resolve relative volume paths (like `./.secrets/foo.txt`) against the **working directory** (e.g. `/var/lib/krg/krg-prod/`), not the Nix store. The compose files stay read-only in the store; runtime data (databases, secrets, config) lives in the working directory.

### 2. Compose file `include:` and the directory reference pattern

`compose.yml` uses Docker Compose's `include:` directive to pull in sub-stacks. For this to work when the compose files are in the Nix store, the entire `nix/docker-compose/krg-prod/` **directory** must be in the same store path. Always reference the directory, not individual files:

```nix
# In nix/hosts/krg-prod/default.nix — correct pattern
let composeDir = ../../docker-compose/krg-prod; in
{
  krg.composeStacks.krg-prod.composeFiles = [ "${composeDir}/compose.yml" ];
}
# The whole docker-compose/krg-prod/ directory is copied to the store,
# so include: can find compose.authentik.yml etc. alongside compose.yml.
```

### 3. Adding a new machine (NixOS)

1. Run `nixos-generate-config --show-hardware-config` on the target; save as `nix/hosts/<name>/hardware-configuration.nix`
2. Create `nix/hosts/<name>/default.nix` importing the appropriate profile plus any `krg.composeStacks`
3. Add the host to `nix/flake.nix` under `nixosConfigurations`
4. `git add` the new files (a flake only sees git-tracked files), `nix flake check ./nix`, then deploy with `nixos-rebuild switch --flake ./nix#<name> --target-host ...`

## Secrets (Pre-Vault)

Secrets are **not** managed by Nix yet (future: HashiCorp Vault — Bitwarden is no longer used). Before starting each compose stack, manually create the required files in the working directory. Each host's `default.nix` lists required secrets in a comment.

**krg-prod** secrets in `/var/lib/krg/krg-prod/.secrets/`:
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

The `.secrets/` directories are in `.gitignore`.

## Runtime Config Directories

The grafana/prometheus/loki compose services mount config from the working directory. Before starting the krg-prod stack, populate:
- `/var/lib/krg/krg-prod/grafana/` — Grafana config
- `/var/lib/krg/krg-prod/loki/loki-config.yaml` — Loki config
- `/var/lib/krg/krg-prod/loki/promtail-config.yaml` — Promtail config (update to NixOS journal or `/var/log`)
- `/var/lib/krg/krg-prod/prometheus/prometheus.yml` — Prometheus scrape config (still references `fabricant.ucsd.edu` targets — update to the new host DNS)
- `/var/lib/krg/krg-prod/blackbox-exporter/blackbox.yml` — copy from `nix/docker-compose/krg-prod/blackbox-exporter/blackbox.yml`

## Pending Items

- [ ] **DNS/URL migration for krg-prod**: the compose files still serve `*.fabricant.ucsd.edu` (Traefik routes, OIDC URIs) and scrape `fabricant.ucsd.edu` — decide whether to keep or move to a new scheme, then update the compose files + Prometheus targets accordingly.
- [ ] Add SSSD/realmd client integration so hosts authenticate human/lab users against Samba AD (replaces the removed per-host user lists; only `nix/users/admin.nix` break-glass admin stays local). Do NOT import the old domain's password hashes — they're compromised; users get new passwords.
- [ ] Add real SSH public keys to `nix/keys/admins.json` (shared by both layers).
- [ ] Replace placeholder `hardware-configuration.nix` files for the hosts.
- [~] Qualys Cloud Agent + Trellix HX (xagt): nix module `nix/modules/security/oec-qualys-trellix.nix` (enabled for all hosts via `base.nix`); Ansible counterpart `oec_qualys_trellix` role built and composed into the `base` role (runs on every host; set `oec_installer` to the vendor archive, else it no-ops). Installer archive at `/var/lib/krg/oec/oec-qualystrellixinstallers-linux.tgz` (NOT in git — live credentials). **Both sides still need on-box validation.**
- [~] Samba AD domain controller (`krg-ldap`, VMID 100 on the `fabricant` Proxmox host): `nix/modules/samba-ad.nix`, enabled via `nix/profiles/directory.nix` (new forest `KRG.LOCAL`, `SAMBA_INTERNAL` DNS). **Domain provisioning is a one-time on-box `samba-tool domain provision`** (documented in the module). Still needs on-box provisioning + validation.
- [~] Proxmox host hardening (`ansible/`): the `base` role IS the baseline — OS basics + `krg_admin` + `ssh_hardening` + `fail2ban` + `monitoring` (node + ipmi exporters) + `oec_qualys_trellix`, composed in order via `import_role` (secure + up to date + monitored + enrolled by default). `proxmox_firewall` (`cluster.fw` templated from `trusted.json` + per-guest `<vmid>.fw`, e.g. `100.fw` for krg-ldap) is a separate `proxmox`-group play — **it fixes the live cluster.fw finding** (SSH + exporters currently open to `+dc/public`). All roles built; **pending:** fill `inventory/hosts.yml` + real keys/trusted nets + `oec_installer`, then on-box validation (run the playbook).
- [ ] nix in-guest service-SSH restriction (read `ucsd`/`sealab` from `trusted.json` so service hosts restrict 22 in-guest too).
- [ ] TOTP 2FA on the PVE realm; PVE web-UI fail2ban jail (needs `filter.d/proxmox.conf`); PVE patching + persistence hunting (post-breach).
- [ ] Add Vault for secrets management (replacing manual `.secrets/` population).
