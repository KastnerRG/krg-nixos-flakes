# krg-infra docs

Operator-facing documentation for the KRG infrastructure. Architecture and
build/deploy basics live in the top-level [README](../README.md),
[nix/README](../nix/README.md), [ansible/README](../ansible/README.md), and
[CLAUDE.md](../CLAUDE.md); the runbooks and references here are the "how do I
actually operate / recover this" layer.

## Runbooks

| Doc | When you need it |
|---|---|
| [disaster-recovery.md](disaster-recovery.md) | Rebuild a host (or the whole fleet) from bare metal; what's reproducible vs. what must be restored from backup |
| [joining-a-host-to-the-domain.md](joining-a-host-to-the-domain.md) | One-time AD domain join (NixOS member / Debian / the DC) |
| [creating-a-user.md](creating-a-user.md) | Create a `KRG.LOCAL` account and grant it login / GPU access |
| [troubleshooting.md](troubleshooting.md) | Symptom-first recovery for the gotchas this fleet has hit (boot freeze, AD/login, scratch, ZFS) |

## Reference

| Doc | What it covers |
|---|---|
| [fleet-inventory.md](fleet-inventory.md) | Every host — IP, role, VMID, hypervisor — plus the Prometheus monitoring map |
| [waiter-topology.md](waiter-topology.md) | waiter storage (ZFS/impermanence) + network diagrams |
| [scratch-greenfield.md](scratch-greenfield.md) | waiter `/scratch` ZFS-native design (replaced autotier): pools/vdevs, the NFS overflow + `scratch-restore`, how to operate it |
| [fabricant-topology.md](fabricant-topology.md) | fabricant (Proxmox) storage + NFS + firewall diagrams |
| [krg-ldap-topology.md](krg-ldap-topology.md) | krg-ldap (AD DC) storage + network diagrams |

> Topology and monitoring diagrams are [Mermaid](https://mermaid.js.org/) and render
> inline on GitHub.
