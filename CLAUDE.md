# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Goal

This repo is a NixOS flake framework replacing the KastnerRG Ansible infrastructure at [fabricant-prod](https://github.com/KastnerRG/fabricant-prod) and [waiter](https://github.com/KastnerRG/waiter). New VMs are configured by combining profile modules — no per-host playbooks.

**What the old Ansible repos did (the target feature set):**
- **fabricant-prod**: production services on fabricant.ucsd.edu — Traefik, Authentik (SSO), Grafana/Prometheus/Loki, Blackbox Exporter, PostgreSQL, Outline, MLflow, Label Studio, node/IPMI exporters, UFW firewall, unattended upgrades
- **waiter**: research/compute machines at 132.239.95.67 — NVIDIA CUDA + Container Toolkit, FPGA tooling (Vivado, Vitis, Verilator), XRDP+XFCE desktop, Fail2ban, UFW, Prometheus (node/DCGM/blackbox via Docker), btrfs snapshots (snapper), user management (100+ lab users)

## Common Commands

```bash
# Validate the entire flake (Nix syntax + module type checking)
nix flake check

# Build a system config without deploying
nix build .#nixosConfigurations.fabricant.config.system.topLevel
nix build .#nixosConfigurations.waiter.config.system.topLevel

# Inspect a config value
nix eval .#nixosConfigurations.fabricant.config.networking.hostName

# Deploy to the current machine
sudo nixos-rebuild switch --flake .#fabricant

# Deploy remotely over SSH
nixos-rebuild switch --flake .#fabricant --target-host fabricant-admin@fabricant.ucsd.edu --use-remote-sudo
nixos-rebuild switch --flake .#waiter --target-host waiter-admin@132.239.95.67 --use-remote-sudo

# Update all flake inputs
nix flake update

# Update a single input
nix flake update nixpkgs

# Format all .nix files
alejandra .    # or: nixfmt .
```

## Repository Structure

```
flake.nix                        # inputs + nixosConfigurations outputs
modules/
  base.nix                       # timezone, SSH hardening, sysctl, auto-upgrade, nix settings
  docker.nix                     # Docker CE + daemon config (metrics, Loki driver, NVIDIA runtime)
  users.nix                      # user/SSH key management module with option types
  snapper.nix                    # btrfs snapshot schedules (root, home, docker-volumes)
  security/
    fail2ban.nix                 # fail2ban SSH protection with incrementing bans
    firewall.nix                 # NixOS firewall wrapper (replaces UFW); supports monitoring-only ports
  services/
    compose-stack.nix            # Generic systemd service that runs a docker compose project
    node-exporter.nix            # Native Prometheus node exporter (fabricant; waiter uses Docker)
    ipmi-exporter.nix            # Native Prometheus IPMI exporter (fabricant only)
  hardware/
    nvidia.nix                   # NVIDIA driver (open), CUDA, container toolkit, cuda group GID 65533
    fpga.nix                     # Verilator, GTKWave, Vivado system libs, license server env var
  desktop/
    xrdp.nix                     # XRDP + XFCE (waiter remote desktop)
profiles/
  server.nix                     # fabricant role: docker+loki, node/ipmi exporters, firewall 80/443
  compute.nix                    # waiter role: NVIDIA, FPGA, XRDP, fail2ban, snapper, Node.js
hosts/
  fabricant/
    default.nix                  # fabricant-specific: compose stack, networking
    hardware-configuration.nix   # REPLACE with nixos-generate-config output
  waiter/
    default.nix                  # waiter-specific: static IP, monitoring compose stack
    hardware-configuration.nix   # REPLACE with nixos-generate-config output
users/
  fabricant-users.nix            # fabricant-admin, fs-services, sf-services
  waiter-users.nix               # waiter-admin + template for 100+ lab users
docker-compose/
  fabricant/
    compose.yml                  # Traefik + `include:` for all sub-stacks
    compose.authentik.yml        # Authentik SSO + PostgreSQL
    compose.grafana.yml          # Grafana, Loki, Promtail, Prometheus, Blackbox
    compose.label-studio.yml     # Label Studio + PostgreSQL
    compose.mlflow.yml           # MLflow + PostgreSQL (OIDC via Authentik)
    compose.outline.yml          # Outline wiki + PostgreSQL + Redis
    blackbox-exporter/blackbox.yml
  waiter/
    compose.yml                  # node_exporter, dcgm_exporter, blackbox_exporter
    blackbox-exporter/blackbox.yml
```

## Architecture: Two Key Patterns

### 1. NixOS modules vs Docker Compose

Services that were **native systemd** in Ansible (node_exporter, ipmi_exporter) use native NixOS `services.prometheus.exporters.*` modules. Everything else stays as **Docker Compose** stacks managed by `krg.composeStacks`.

The `compose-stack` module runs each stack as a `systemd` oneshot service with `docker compose --project-directory <workingDir> -f <nix-store-path> up -d`. The `--project-directory` flag makes Docker Compose resolve relative volume paths (like `./.secrets/foo.txt`) against the **working directory** (e.g. `/var/lib/krg/fabricant/`), not the Nix store. The compose files themselves stay read-only in the store, but all runtime data (databases, secrets, config) lives in the working directory.

### 2. Compose file `include:` and the directory reference pattern

`compose.yml` uses Docker Compose's `include:` directive to pull in sub-stacks. For this to work when the compose files are in the Nix store, the entire `docker-compose/fabricant/` **directory** must be in the same store path. Always reference the directory, not individual files:

```nix
# In hosts/fabricant/default.nix — correct pattern
let composeDir = ../../docker-compose/fabricant; in
{
  krg.composeStacks.fabricant.composeFiles = [ "${composeDir}/compose.yml" ];
}
# The whole docker-compose/fabricant/ directory is copied to the store,
# so include: can find compose.authentik.yml etc. alongside compose.yml.
```

### 3. Adding a new machine

1. Run `nixos-generate-config --show-hardware-config` on the target; save as `hosts/<name>/hardware-configuration.nix`
2. Create `hosts/<name>/default.nix` importing the appropriate profile plus any `krg.composeStacks`
3. Add the host to `flake.nix` under `nixosConfigurations`
4. Add any machine-specific users under `users/`
5. `nix flake check` locally, then deploy with `nixos-rebuild switch --flake .#<name> --target-host ...`

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
- `/var/lib/krg/fabricant/loki/promtail-config.yaml` — Promtail config (note: the Ansible log path no longer applies; update to NixOS journal or `/var/log`)
- `/var/lib/krg/fabricant/prometheus/prometheus.yml` — Prometheus scrape config
- `/var/lib/krg/fabricant/blackbox-exporter/blackbox.yml` — copy from `docker-compose/fabricant/blackbox-exporter/blackbox.yml`

## Pending Items

- [ ] Populate `users/waiter-users.nix` from `waiter_users.yaml` (100+ lab users with SSH keys and hashed passwords)
- [ ] Add real SSH public keys to `users/fabricant-users.nix`
- [ ] Replace placeholder `hardware-configuration.nix` files for both hosts
- [ ] Wire up Qualys Cloud Agent and Trellix (xagt) — no nixpkgs package exists; requires manual installer or a custom derivation using the binary from the original repo
- [ ] Add sops-nix for secrets management (replacing manual `.secrets/` population)
- [ ] Review `promtail-config.yaml` — the old Ansible deploy log path is no longer relevant
