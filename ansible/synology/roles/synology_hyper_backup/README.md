# synology_hyper_backup

Declarative DSM Hyper Backup jobs on e4e-nas from
[`spec/e4e-nas/hyper-backup.yml`](../../../spec/e4e-nas/hyper-backup.yml).
This is the OFF-BOX DR layer (runbook §5) — snapshots are local recovery, this
is the "room burned" copy.

Declarative list sync by job `name` (same model as `synology_app_portal`):
create new, update drifted, delete extras. Empty desired list → all live jobs
deleted.

## Coverage

| subcommand | API | model |
|---|---|---|
| `jobs` | `SYNO.SDS.Backup.Client.Task` v1 (list/create/update/delete) | declarative list by name |

## Bootstrap secrets

Destination passwords/keys live OUTSIDE the spec (per-job). Supply at runtime:

    ansible-playbook playbooks/synology.yml -e @secrets-hb.yml

Where `secrets-hb.yml` is:

    hyper_backup_secrets:
      critical-shares-offbox: <password-or-key>

The helper SKIPS creating any job marked `encrypt: true` that lacks a secret —
better to skip than create a job without a key.

## Field mapping (best-known; verify on first rig apply)

| Spec field | DSM field |
|---|---|
| `name` | `task_name` |
| `destination.type` | `dest_type` |
| `destination.host` | `dest_host` |
| `destination.path` | `dest_path` |
| `sources` | `source_shares` |
| `schedule.daily` | `schedule_time` |
| `schedule.retain_versions` | `retention_count` |
| `encrypt` | `enable_encryption` |
| `enabled` | `enable_task` |

Flip `OUT_KEYS` in
[`files/apply_hyper_backup.py`](files/apply_hyper_backup.py) on drift.

## Open decision: destination

Currently no jobs declared — the spec is a schema-only stub. Open question in
plan.md "Open decisions": rsync target on krg-prod? S3 (Garage)? External NAS?
Pick one, populate `jobs:`, provide `hyper_backup_secrets`, apply.

## Validation

Unit-tested (`files/test_apply_hyper_backup.py`): OK / WOULD-CHANGE / CHANGED /
FAIL contract, create-update-delete classification, check-mode never-mutates,
encrypted-without-secret skip, sources-list order invariance, empty-spec is
no-op. End-to-end on the rig pending.
