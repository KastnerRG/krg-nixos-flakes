# e4e-nas (Synology DSM) — rebuild runbook & config reference

`e4e-nas.ucsd.edu` (`132.239.17.124`, DSM web on `:6021`, admin `:6020`) is the
lab's Synology NAS. Compute hosts mount its SMB shares (`nix/profiles/compute.nix`,
cifs-utils); krg-prod's prometheus blackbox-probes it; it's a trusted host in
[`../nix/networks/trusted.json`](../nix/networks/trusted.json).

**It is being rebuilt clean on the same hardware** — data volumes preserved, DSM
config rebuilt from scratch off the compromised setup, and re-joined to the new
`KRG.LOCAL` Samba AD (it was on the old `KRG.UCSD.EDU` directory, now dead). This
doc is the **rebuild plan + target-state build sheet** (below), plus the detailed
DSM reference (§1–8). The inventory was derived from the DSM config export, which
stays **gitignored** (`*.dss`/`*.sql`) — never commit it.

DSM is a **proprietary appliance** — most of its config has no IaC API, so the
bulk of a rebuild is this runbook, not Terraform. The
[`../terraform/e4e-nas/`](../terraform/e4e-nas/) target manages only what the
provider exposes (Container Manager, packages, scheduled tasks, files, VMs).

> Convention reminder: shared values live once under `nix/` —
> admin keys in [`../nix/keys/admins.json`](../nix/keys/admins.json), trusted
> nets / IPSets in [`../nix/networks/trusted.json`](../nix/networks/trusted.json).
> Mirror those here; don't invent NAS-specific copies.

---

## Rebuild plan (clean DSM, preserve volumes → KRG.LOCAL)

**Methodology:** build the config from scratch using the inventory below. **Do
NOT restore the old `.dss`** — it would drag the breach-era domain join,
QuickConnect, and stale settings right back in. Use the export only as the
checklist of *what* must exist; re-derive the *how* clean.

> ⚠️ **The ACL gotcha — plan around this.** You keep the data but rebuild
> identity, so every file's on-disk ACL references **old-domain SIDs / gids that
> no longer exist**. DSM will re-detect the shared folders on the preserved
> volumes, but their permissions resolve to nothing. So each share needs a
> recursive **"apply to this folder, sub-folders and files"** permission pass
> *after* the `KRG.LOCAL` join (phase 4). This is the bulk of the manual work.

**Phases:**

1. **Pre-reset capture (live box).** Record current per-share permission *intent*
   (who gets read/write) — the binary ACL blobs aren't reliably decodable, so
   screenshot/note it now. Confirm storage-pool health and that a **Hyper Backup**
   exists even though volumes are preserved.
2. **Reset DSM config without reformatting volumes.** Apply the hardened baseline
   (§1, §3 + the settings table below) from minute one: QuickConnect **off**,
   UPnP **off**, default `admin` disabled, key-only SSH, firewall scoped, SMB3,
   FTP off.
3. **Join `KRG.LOCAL`** (§2). Recreate the 21 groups (below); decide per group
   whether access is granted via a local group or the matching AD group.
4. **Recreate the 55 shares** (below) on the preserved volume paths, then
   **re-apply ACLs recursively** per the intent from phase 1. Recreate the NFS
   export (mind the uid note in §2).
5. **Workloads + Terraform.** Recreate the `docker` share's Container Manager
   stacks and bring them under [`../terraform/e4e-nas/containers.tf`](../terraform/e4e-nas/containers.tf);
   model the recycle-bin task in [`scheduler.tf`](../terraform/e4e-nas/scheduler.tf);
   point the provider at the rebuilt box and `tofu apply`.
6. **DR.** Schedule the `.dss` Configuration Backup (§7) now the config is clean.

Effort is concentrated in **phases 3–4** (identity + 55 shares/ACLs).

---

## Target-state inventory (the build sheet)

Derived from the DSM config export. `NetBackup`, `photo`, `web` are auto-created
by their packages and `homes` by the Home service — don't hand-create those.

### Shared folders (55)

**`/volume1` (36):**
`2019.11.wbm-China` (Wild Blue Media China Trip) · `Floods of Lubra` · `admin`
(Administrative Files) · `aye-aye-sleep-monitoring` · `baboons` · `bom_aws`
(Baboons AWS) · `coral-ml` · `coral-tile` · `data_staging` · `fishsense` ·
`flight_operations` · `forest_fear_lab` (E4E FFL Collaborative Share) ·
`hardware_dev` · `harpy_find` · `installers` · `junkyard-fishsense` ·
`labeling_share` · `maestro` · `mangrove` · `maya` · `media` (E4E Media) ·
`nextcloud` · `operations` · `owl-behavior` · `programmatics` · `rct` · `robosub`
· `sio_e4e_mangroves` · `smartfin-mfg` · `temp` · `web_packages` · `zotero`
· *(auto: `NetBackup`, `photo`, `web`, `homes`)*

**`/volume2` (19):**
`2024_kastner_ml_dump` · `2025_kastner_ml_hdd_8tb_dump` · `aid_data` ·
`aid_elephants_interaction` · `aid_nat_geo_coral` · `aid_nat_geo_the_music` ·
`data_archive` (E4E Data Archive) · `data_archive_old` · `docker` *(Container
Manager data — see phase 5)* · `fabricant-prod-share` *(NFS-exported — see below)*
· `fishsense_data` · `fishsense_process_work` · `fsspec_test` · `git-lfs-store` ·
`junkyard_backup` · `label_studio` · `mangrove_meeting_archive` ·
`passive-acoustic-biodiversity` · `rustfs`

### Local groups (21)

Custom (gid): `maya`(65536) · `mangrove`(65537) · `rct`(65538) · `robosub`(65539)
· `acoustic-species-id`(65540) · `aye-aye-sleep`(65541) · `smartfin-mfg`(65542) ·
`baboons`(65543) · `fishsense`(65544) · `Burrowing Owl`(65545) · `leads`(65546) ·
`hardware`(65547) · `floods_of_lubra`(65548) · `e4e`(65549) · `aburto_lab`(65550)
· `research_support`(65551) · `label-studio-admin`(65552) · `minio-admin`(65553).
System (leave): `administrators`(101) · `users`(100) · `http`(1023).

### Services & system settings (current → rebuild target)

| Setting | Current | Rebuild target |
|---|---|---|
| Directory | `KRG.UCSD.EDU` (dead) | **join `KRG.LOCAL`** (§2) |
| SMB service | on | on |
| SMB min protocol | SMB2 | **SMB3** |
| SMB max protocol | `SMB2_10` *(caps at 2.1 — disables SMB3!)* | **SMB3** |
| SMB signing / NTLMv1 | signing on / NTLMv1 off ✓ | keep |
| AFP | off ✓ | keep off |
| FTP (plaintext) | **on** | **off** |
| SFTP | on | only if a client needs it |
| NFS | v4 + minor on, map `nsswitch` | keep; recreate the export below |
| SNMP | off | enable read-only if you want host metrics (§8) |
| NTP server | `fabricant-ldap.krg-ucsd-edu.intranet` (old) | **`fabricant-ldap.ucsd.edu`** (KRG.LOCAL DC) |
| Timezone | Pacific ✓ | keep |
| SSH | on, port 22 | on, key-only (§1); restrict in firewall (§3) |
| Home service | on, includes domain users ✓ | keep (needed for user homes + SSH login) |
| Password min length | 12 ✓ | keep policy |
| DSM update | `hotfix-security`, scheduled ✓ | keep |
| QuickConnect / UPnP | **on** (relay exposes dsm/ssh/file_sharing) | **off** |

Also re-apply the per-share/volume **quotas** from the old policy (the export has
~8,900 quota rows — set them from your records, not enumerable here).

### NFS export

`/volume2/fabricant-prod-share` → client `fabricant-prod.ucsd.edu` (rw). This is
the **one place the winbind-RID vs SSSD-algorithmic uid mismatch bites** (§2) —
verify the numbers line up on the fabricant side.

### Scheduled task

Recycle-bin clean-all (`SYNO.SDS.TaskScheduler.Recycle`) — model in
[`scheduler.tf`](../terraform/e4e-nas/scheduler.tf) as `synology_core_event`.

---

# DSM reference (detailed steps)

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
> - **NFS** is uid/gid-based — the `fabricant-prod-share` export above won't line
>   up with NixOS clients unless you reconcile the id-mapping ranges first.

## 3. Firewall — restrict the management plane

**Control Panel → Security → Firewall** → enable, then per-interface rules
(default-deny at the end). Source allow-lists come from
[`../nix/networks/trusted.json`](../nix/networks/trusted.json) (`ucsd`, `sealab`):

- **DSM web (`:6021`/`:6020`) + SSH (22)**: allow from `ucsd`/`sealab` only.
- **SMB (139/445), NFS (2049)**: allow from compute hosts / the trusted research
  nets.
- **Allow** the krg-prod monitoring host to reach the probed port (it already
  blackbox-probes `:6021`).
- Everything else: **deny**. And turn **QuickConnect + UPnP off** (Control Panel →
  External Access) — they bypass this perimeter via Synology's relay.

This mirrors the Proxmox `cluster.fw`/`host.fw` perimeter pattern in `ansible/`.

## 4. Shared folders + ACLs

1. **Control Panel → Shared Folder**: recreate the shares from the inventory above
   on their preserved volume paths. Enable **Btrfs** (needed for snapshots, §5)
   and recycle bin as desired.
2. Permissions: assign **groups** (local or AD per §2), not individual users, then
   do the recursive **apply to sub-folders and files** pass (the ACL gotcha).
3. **Control Panel → File Services → SMB**: min **and** max protocol SMB3, disable
   SMB1, signing on. NFS only where needed (heed §2's uid note).

## 5. Snapshots & backup

- **Snapshot Replication** package → schedule periodic Btrfs snapshots per share
  (retention policy). This is the NAS analogue of waiter's ZFS auto-snapshots.
- **Hyper Backup** → off-box backup target (another NAS / cloud / rsync) for DR.
- These schedules are DSM settings; Terraform can only *trigger* an ad-hoc run
  via a `synology_core_event` task, not own the schedule.

## 6. DSM updates

**Control Panel → Update & Restore → DSM Update**: keep automatic security/
important updates (`hotfix-security`, already scheduled). Remember updates may
revert SSH-level edits (§1).

## 7. Config backup (the .dss export)

**Control Panel → Update & Restore → Configuration Backup**: export the DSM
config (`.dss`). This is the closest thing to "config as artifact" for the parts
no API touches — the DR source of truth once the rebuild is clean.

> ⚠️ The `.dss` (and any SQL dump of it) can contain hashed credentials + PII —
> **do not commit it to git** (`*.dss`/`*.sql` are gitignored under `terraform/`).
> Store it where other secrets live (the future Vault), not in this repo.
> Automate the export via a `synology_core_event` scheduled task if desired.

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
