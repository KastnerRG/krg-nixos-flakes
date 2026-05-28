# e4e-nas live capture — 2026-05-28 (pre-reset)

Captured via the read-only Section A script ([`scripts`-less; see PR #8 thread] —
`synoshare`/`synogroup`/`synouser` enum+get, SMB/NFS `synowebapi` get, NFS SharePrivilege
`load`, `synoacltool -get`). **Strictly non-mutating.** Authoritative pre-reset snapshot —
the DSM config-export ACL blobs reference dead old-domain SIDs and are NOT a usable source,
so this capture is the only one (ADR 0001, runbook §4).

- Host: `e4e-nas.ucsd.edu` (DSM 7.3.2-86009)
- Live shape: **21 groups · 140 users · 55 shares · 1 NFS export**

## Artifacts in this directory

- [`capture.txt`](capture.txt) — raw delimited stream (the full output)
- [`acls.yml`](acls.yml) — parsed `--list_acl` grants per share (see dead-SID caveat below)
- [`nfs-exports.yml`](nfs-exports.yml) — parsed global NFS + the one export rule

## Findings vs the seeded `spec/krg-prod/`

### Shares — no drift
Spec=52 / live=55. The diff is exactly the documented exceptions:
- **spec-only**: `s3-data` — intentional future (the Garage bucket-data share isn't created yet).
- **live-only**: `NetBackup`, `homes`, `photo`, `web` — the DSM/packages auto-shares the
  spec already lists as "NOT to hand-create" (the drift detector ignores these).

### Groups — no real drift
Spec=15 / live=21. The diff is intentional per `groups.yml`'s comments:
- `burrowing_owl` (spec) vs `Burrowing Owl` (live) — **renamed for AD** (no spaces).
- `label-studio-admin`, `minio-admin` (live only) — **dropped per decision (2026-05-22)**.
- `administrators`, `http`, `users` (live only) — DSM system groups (auto-created).
- `aburto_lab` (live only) — actually IS in `groups.yml` under `collaborator_groups` (a
  separate, third-lab key); the flat diff missed it.

### SMB — one real drift item (security)
| field | live | spec | |
|---|---|---|---|
| `smb_min_protocol` | **1 (SMB1!)** | 3 (SMB3) | **DRIFT — spec hardens; fix on apply** |
| `smb_max_protocol` | 3 (SMB3) | 3 (SMB3) | ok |
| `enable_server_signing` | 1 | 1 | ok |
| `enable_ntlmv1_auth` | false | false | ok |
| `enable_samba` | true | true | ok |
| `workgroup` | `KRG-UCSD-EDU` | n/a (set by AD join) | dead-domain artifact; AD join will reset |

### NFS — confirmed (one tweak)
Single export: `fabricant-prod-share → fabricant-prod.ucsd.edu`. The rule matches the
seeded `nfs-exports.yml` design **except `async: true`** (we'd assumed `false`). The
captured rule is now committed into the spec verbatim (the role's load/save round-trips it).

### ACLs — captured, NOT pasted into `acls.yml`
All 55 shares have grants — captured in [`acls.yml`](acls.yml). **They are NOT pasted into
`spec/krg-prod/acls.yml`** because many references the dead old domain
(`KRG-UCSD-EDU\Engineers for Exploration NAS Admins`, …). Those principals **won't exist
after the Mode-2 reset + KRG.LOCAL join**, so committing them as the desired state would
encode dead SIDs back into the spec.

This file is the **reference** for designing the post-AD-join ACL matrix:
1. Replace dead `KRG-UCSD-EDU\…` group references with their KRG.LOCAL equivalents
   (largely the `groups.yml` set — `maya`, `mangrove`, …, plus `administrators`).
2. Decide whether per-user grants (the many `user:` entries in the `NA` tier — service
   account deny lists) carry over, and to which new user objects.
3. Write the result into `spec/krg-prod/acls.yml`; the `synology_acls` role + the drift
   detector then enforce it.

The recursive on-disk ACL re-apply for preserved share data carrying dead SIDs
(`synoacltool` per share) remains a separate **post-join runbook step**.

### Task Scheduler — only the Recycle Bin is user-config (the rest are DSM defaults)

Captured via [`scheduler-capture.txt`](scheduler-capture.txt) (`synowebapi
SYNO.Core.TaskScheduler list` + `synoschedtask --get`). The two surfaces disagree
on what counts as a task:

- **`synowebapi method=list` (user-visible)** → **3 tasks**:
  | id | name | type | enabled | trigger |
  |---|---|---|---|---|
  | **6** | **Recycle Bin** | recycle | ✓ | daily 00:00 — **action "Empty all Recycle Bins"** |
  | 3 | Auto S.M.A.R.T. Test | custom (SMART) | ✓ | monthly (next 2026-06-13) |
  | 80322000 | PowerOff task 0 | power | ✗ | one-off, stale/disabled |
- **`synoschedtask --get` (everything)** also exposes DSM-default system tasks: DSM
  Auto Update (weekly Sat 02:00), Security Advisor (weekly Wed 04:15), Security Scan
  (monthly), etc. — DSM recreates these on install, so no IaC needed.
- **EventScheduler** → empty (`data: []`); no event-triggered tasks defined.

**IaC implication:** only **Recycle Bin (id 6)** needs explicit reproduction (the
single task the runbook §"Scheduled task" calls out → `synology_core_event` in
[`terraform/e4e-nas/scheduler.tf`](../../../terraform/e4e-nas/scheduler.tf), still a
stub). The PowerOff task is stale and can be dropped on rebuild. S.M.A.R.T. and the
system tasks come back automatically from DSM.
