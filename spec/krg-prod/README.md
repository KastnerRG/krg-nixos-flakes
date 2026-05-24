# spec/krg-prod — declarative DSM source of truth

The declarative spec for **e4e-nas** (the krg-prod NAS), consumed by the Ansible
`synology_*` roles and their paired `--check` exporters. **Git is the source of
truth; any DSM UI change is drift** (ADR [0001](../../docs/adr/0001-iac-source-of-truth.md)).
See the architecture + standup plan in [`../../docs/krg-prod-iac.md`](../../docs/krg-prod-iac.md).

## Files

| File | Role that consumes it | Status |
|---|---|---|
| `shares.yml` | `synology_shares` | **seeded** from the build sheet (51 managed shares + `s3-data` for Garage) |
| `groups.yml` | `synology_users`/directory | **seeded** (16 groups) — see the AD-vs-local decision below |
| `smb-globals.yml` | `synology_smb` | **seeded** (SMB + hardening deltas) |
| `nfs-exports.yml` | `synology_nfs` | **seeded** (the one export) |
| `users.yml` | `synology_users` | **stub** — local/service accounts only (humans come from AD) |
| `acls.yml` | `synology_shares`/acls | **stub** — capture the grant matrix from the live box |
| `garage.yml` | `garage_config` | **stub** — bucket/key/policy list |

Seeded files came from the build sheet in
[`../../docs/e4e-nas-dsm.md`](../../docs/e4e-nas-dsm.md). The four **auto-created**
shares (`NetBackup`, `photo`, `web`, `homes`) are intentionally **not** managed here.

## Open decisions / TODOs

1. **AD vs local groups** (`groups.yml type:`): recommended **AD groups under
   `OU=E4E`** in KRG.LOCAL (central, fleet-wide), vs local DSM groups. Affects who
   creates them (DC `samba-tool` vs NAS `synogroup`).
2. **`acls.yml`** — the authoritative share→group matrix. **Capture from the live
   NAS** (`synoacltool -get …`) *before* the Mode-2 reset; the config-export ACL
   blobs are keyed to dead old-domain SIDs and unusable. `groups.yml governs:` is an
   inferred starting hint only.
3. **`users.yml`** — the local/service accounts (automation API account,
   break-glass SSH admin).
4. **`garage.yml`** — buckets/keys/policies/quotas.
5. **Per-share DSM flags** (recycle bin, visibility) — confirm exceptions vs the
   live box; `shares.yml defaults:` covers the common case.
6. **Non-SMB service settings** (FTP off, AFP off, SNMPv3, NTP→KRG.LOCAL DC,
   QuickConnect/UPnP off) are noted in `smb-globals.yml` but belong to the
   `synology_base`/`synology_firewall` role vars when those are built.
