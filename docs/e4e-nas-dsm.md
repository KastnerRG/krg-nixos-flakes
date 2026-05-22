# e4e-nas (Synology DSM) — config runbook

`e4e-nas.ucsd.edu` (`132.239.17.124`, DSM web on `:6021`) is the lab's Synology
NAS. Compute hosts mount its SMB shares (`nix/profiles/compute.nix`, cifs-utils);
krg-prod's prometheus blackbox-probes it; it's a trusted host in
[`../nix/networks/trusted.json`](../nix/networks/trusted.json).

DSM is a **proprietary appliance** — most of its config has no IaC API. The
[`../terraform/e4e-nas/`](../terraform/e4e-nas/) target manages what the community provider
exposes (Container Manager, packages, scheduled tasks, files, VMs). **This
runbook covers everything else** — the DSM UI settings that survive DSM updates,
where SSH-level edits do not. Work top-to-bottom for a fresh box.

> Convention reminder: shared values live once under `nix/` —
> admin keys in [`../nix/keys/admins.json`](../nix/keys/admins.json), trusted
> nets / IPSets in [`../nix/networks/trusted.json`](../nix/networks/trusted.json).
> Mirror those here; don't invent NAS-specific copies.

---

## 1. Admin account + SSH hardening (the breach fix, applied to the NAS)

This whole rebuild started with a dictionary attack on an exposed root SSH. Apply
the same hygiene here:

1. **Control Panel → User & Group**: create an administrators-group account
   (e.g. `krg-admin`) with a strong unique password. This is also the Terraform
   API account (`dsm_user`).
2. **Disable the built-in `admin` and `guest`** accounts.
3. **Control Panel → Terminal & SNMP**: enable SSH only if needed; **disable
   Telnet**. DSM's SSH listens on 22 by default — consider moving it and/or
   restricting it in the firewall (§3).
4. **Key-only SSH** for the admin: drop your key from
   [`../nix/keys/admins.json`](../nix/keys/admins.json) into
   `~/.ssh/authorized_keys` for that user (perms `700` dir / `600` file). Note:
   DSM's UI has no "disable password auth" toggle; editing `/etc/ssh/sshd_config`
   works but **a DSM update can revert it** — re-verify after every DSM upgrade.
5. SSH login also requires the **homes** service enabled (Control Panel → User &
   Group → Advanced → User Home).

## 2. Join the Samba AD domain (`KRG.LOCAL`) — identity

Make AD users/groups govern NAS access, consistent with the rest of the fleet
(`krg.adClient` on NixOS, `ad_client` in Ansible; DC = `fabricant-ldap.ucsd.edu`).

1. Ensure the NAS resolver points at the DC for `KRG.LOCAL` (Control Panel →
   Network → General → DNS = the krg-ldap DC). AD join fails without working
   SRV/DNS resolution.
2. **Control Panel → Domain/LDAP → Join** → Domain: `KRG.LOCAL`, DNS server =
   the DC, supply a join account with rights. DSM uses **winbind**.
3. After join, AD users/groups appear under User & Group; assign them share
   permissions in §4.

> ⚠️ **ID-mapping mismatch — read before exporting NFS.** DSM/winbind maps AD
> identities with **RID** mapping by default; the rest of the fleet (SSSD) uses
> **algorithmic** mapping. The same AD user therefore gets **different uid/gid**
> on the NAS vs on Linux clients.
> - **SMB/CIFS** (what compute mounts today) enforces by SID, so this is fine.
> - **NFS** is uid/gid-based — if you ever NFS-export from this NAS, the numbers
>   won't line up with NixOS clients. Either keep NAS file access SMB-only, or
>   reconcile the id-mapping ranges first.

## 3. Firewall — restrict the management plane

**Control Panel → Security → Firewall** → enable, then per-interface rules
(default-deny at the end). Source allow-lists come from
[`../nix/networks/trusted.json`](../nix/networks/trusted.json) (`ucsd`, `sealab`):

- **DSM web (`:6021`) + SSH**: allow from `ucsd`/`sealab` only.
- **SMB (139/445), NFS (2049) if used**: allow from compute hosts / the trusted
  research nets.
- **Allow** the krg-prod monitoring host to reach the probed port (it already
  blackbox-probes `:6021`).
- Everything else: **deny**.

This mirrors the Proxmox `cluster.fw`/`host.fw` perimeter pattern in `ansible/`.

## 4. Shared folders + ACLs

1. **Control Panel → Shared Folder**: create/confirm the shares compute mounts.
   Enable **Btrfs** (needed for snapshots, §5) and recycle bin as desired.
2. Permissions: assign **AD groups** (from §2), not individual local users.
   Document which AD group maps to which share.
3. **Control Panel → File Services → SMB**: set min protocol SMB3, disable SMB1,
   enable signing. Enable NFS only if a client needs it (and heed §2's uid note).

## 5. Snapshots & backup

- **Snapshot Replication** package → schedule periodic Btrfs snapshots per share
  (retention policy). This is the NAS analogue of waiter's ZFS auto-snapshots.
- **Hyper Backup** → off-box backup target (another NAS / cloud / rsync) for DR.
- These schedules are DSM settings; Terraform can only *trigger* an ad-hoc run
  via a `synology_core_event` task, not own the schedule.

## 6. DSM updates

**Control Panel → Update & Restore → DSM Update**: enable automatic security/
important updates (the "secure + up to date by default" posture). Remember
updates may revert SSH-level edits (§1).

## 7. Config backup (the .dss export)

**Control Panel → Update & Restore → Configuration Backup**: export the DSM
config (`.dss`). This is the closest thing to "config as artifact" for the parts
no API touches.

> ⚠️ The `.dss` can contain hashed credentials — **do not commit it to git.**
> Store it where other secrets live (e.g. the `/var/lib/krg/.../.secrets` pattern
> or the future Vault), not in this repo. Automate the export via a
> `synology_core_event` scheduled task if desired.

## 8. Monitoring (already in place)

krg-prod's prometheus blackbox-probes `https://e4e-nas.ucsd.edu:6021/`
(`nix/docker-compose/krg-prod/prometheus/prometheus.yml`). For host metrics,
enable **SNMP** (Control Panel → Terminal & SNMP) and add an SNMP exporter
target, or install a node_exporter via Container Manager.

---

## What lives in Terraform vs here

| Concern | Where |
|---|---|
| Admin account, SSH, firewall, AD join, shares/ACLs, SMB/NFS, snapshots, DSM update, config backup | **this runbook** (DSM UI) |
| Container Manager stacks, packages, scheduled tasks, file provisioning, VMs | [`../terraform/e4e-nas/`](../terraform/e4e-nas/) |
| Anything with a DSM Web API but no typed resource | `terraform/e4e-nas/` via the generic `synology_api` resource |
