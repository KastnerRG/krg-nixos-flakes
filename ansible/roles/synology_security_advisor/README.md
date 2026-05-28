# synology_security_advisor

Manage DSM Security Advisor (scheduled vuln/config scan + email notify) on
e4e-nas from
[`spec/krg-prod/security-advisor.yml`](../../../spec/krg-prod/security-advisor.yml).

CROSS-REFERENCE: this is the DSM-native replacement for `oec_qualys_trellix` on
Linux hosts. Same intent — periodic vuln/config scan with email notify on
findings; different mechanism (Synology-curated, matches the appliance threat
model). See `docs/adr/0006-no-oec-on-dsm.md`.

## Coverage

| subcommand | API | model |
|---|---|---|
| `main` | `SYNO.SDS.SecurityScan.Main` v1 (set) | full-object (partial=err 2001) |

The captured scheduled task on the 2026-05-28 NAS triggered
`SYNO.Core.SecurityScan.Operation start`. The schedule itself appears to be
owned by `SecurityScan.Main` (best-known); if a first-apply shows the schedule
keys aren't honored there, fall back to a `SYNO.Core.EventScheduler` entry that
calls `Operation start` — TODO documented in
[`files/apply_security_advisor.py`](files/apply_security_advisor.py).

## Field mapping (best-known; verify on first rig apply)

| Spec field | DSM field |
|---|---|
| `enabled` | `enable` |
| `schedule.day` | `schedule_day` (Sun..Sat) |
| `schedule.hour` | `schedule_hour` |
| `schedule.minute` | `schedule_min` |
| `scan_categories` | `categories` (JSON list) |
| `notify_email_on_finding` | `notify_email` |

If a field name differs on the live box, flip `OUT_KEYS` in the helper.

## Validation

Unit-tested (`files/test_apply_security_advisor.py`): the OK / WOULD-CHANGE /
CHANGED / FAIL contract, full-object preservation of unmanaged keys, check-mode
never-mutates, category-list order invariance. End-to-end on the rig pending
(rig DOWN at build time).
