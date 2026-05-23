# krg-infra

KastnerRG infrastructure, as code. Two coequal layers, split by configuration
tool (not guest-vs-host — some NixOS machines are physical):

| Layer | Path | Manages | Tool |
|---|---|---|---|
| NixOS machines | [`nix/`](nix/) | every NixOS machine — physical (waiter) **and** Proxmox VMs (krg-prod, e4e-prod, krg-ldap) | Nix flake |
| Hypervisors | [`ansible/`](ansible/) | the Proxmox/Debian hosts those VMs run on | Ansible |

- Building/deploying NixOS machines: [`nix/README.md`](nix/README.md)
- Hardening the Proxmox hosts: [`ansible/README.md`](ansible/README.md)
- Operator runbooks + topology/inventory: [`docs/`](docs/README.md)
- Architecture + agent guidance: [`CLAUDE.md`](CLAUDE.md)

## Context

This repo is an incident-response rebuild: a Proxmox host's root SSH was
dictionary-attacked. The NixOS guests were already hardened, so `ansible/` brings
the hypervisors under the same baseline (key-only SSH, fail2ban, `krg-admin`),
and the breached Active Directory is being rebuilt clean as a new Samba AD forest
on krg-ldap.
