# spec/krg-prod — declarative DSM source of truth

The declarative spec for **e4e-nas** (the krg-prod NAS), consumed by the Ansible
`synology_*` roles and their paired `--check` exporters. **Git is the source of
truth; any DSM UI change is drift** (ADR [0001](../../docs/adr/0001-iac-source-of-truth.md)).
See the architecture + standup plan in [`../../docs/krg-prod-iac.md`](../../docs/krg-prod-iac.md).

## Files

Ansible-role-driven (existing `synology_*` roles):

| File | Role that consumes it | Status |
|---|---|---|
| `shares.yml` | `synology_shares` | **seeded** (51 managed shares + `s3-data` for Garage) |
| `groups.yml` | `synology_users`/directory | **seeded** (16 groups) — AD vs local decision below |
| `smb-globals.yml` | `synology_smb` | **confirmed** vs live (SMB3 hardening drift = real) |
| `nfs-exports.yml` | `synology_nfs` | **confirmed** from 2026-05-28 capture (async:true) |
| `users.yml` | `synology_users` | **stub** — local/service accounts only (humans = AD) |
| `acls.yml` | `synology_acls` | **stub** — captured live; needs post-AD-join translation |

Terraform / `synology_api`-driven (new files from the 2026-05-28 capture, **everything-IaC** rule — no runbook for what the webapi can do):

| File | IaC home | Owns |
|---|---|---|
| `dsm-system.yml` | `terraform/e4e-nas/dsm-system.tf` | hostname, NTP, static network (IP/gw/DNS) |
| `dsm-web.yml`    | `terraform/e4e-nas/dsm-web.tf`    | DSM ports, HTTPS/HSTS, HTTP/2, mDNS/SSDP, **TLS profile** |
| `security.yml`   | `terraform/e4e-nas/security.tf`   | firewall (global + profiles + rules), auto-block |
| `services.yml`   | `terraform/e4e-nas/services.tf`   | FTP/FTPS, AFP, SFTP, WebDAV, Rsync, **SNMP v3** |
| `notifications.yml` | `terraform/e4e-nas/notifications.tf` | mail (Gmail OAuth), SMS, push, CMS |
| `app-portal.yml` | `terraform/e4e-nas/app-portal.tf` | per-app portals, reverse-proxy, access control |
| `garage.yml`     | `garage_config` (Ansible)         | buckets/keys/policies/quotas |

Seeded files came from the build sheet in
[`../../docs/e4e-nas-dsm.md`](../../docs/e4e-nas-dsm.md). The four **auto-created**
shares (`NetBackup`, `photo`, `web`, `homes`) are intentionally **not** managed here.
Live capture (off-repo audit, archived locally per
[memory: `krg-infra-no-live-captures`](../../docs/adr/0001-iac-source-of-truth.md))
seeded the spec values above and surfaced these real drift items the spec will fix:

- SMB minimum protocol: live SMB1 → spec SMB3
- DSM HSTS: live off → spec on
- mDNS / SSDP: live on → spec off
- TLS profile: live ≈ Old/Intermediate → spec **Modern**
- SNMP: live off → spec v3 on (Prometheus visibility)
- NTP: live points at dead old-domain DC → spec live source
- Hostname: live `e4e_nas` → spec `e4e-nas` (DNS-valid)

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
