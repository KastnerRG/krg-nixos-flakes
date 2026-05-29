# synology_security

Manage DSM **firewall + auto-block** on e4e-nas from
[`spec/krg-prod/security.yml`](../../../spec/krg-prod/security.yml). Git is truth;
UI = drift.

## Coverage

| subcommand | API | spec section |
|---|---|---|
| `firewall` | `SYNO.Core.Security.Firewall` (enable + profile name) | `firewall:` |
| `fw-conf`  | `SYNO.Core.Security.Firewall.Conf` (port_check) | `firewall.port_check` |
| `autoblock`| `SYNO.Core.Security.AutoBlock` (attempts / within_mins / expire_day / enable) | `auto_block:` |

All full-object set (partial = err 2001). GET → overlay → SET on drift.

## Out of scope (capture gaps — TODO)

- **Firewall rule list** — `SYNO.Core.Security.Firewall.Rules load` errored 120 on the
  live box; need the correct param shape (likely `profile_name=` or a different key)
  before encoding rules.
- **Firewall profile detail** — `Firewall.Profile get` errored 120; same.
- **Geoip** — `Firewall.Geoip get` errored 114.
- **Auto-block allow/deny lists** — `AutoBlock.Rules download` errored 5100; need the
  right `listType=` value. Spec's `allow_list_ref` points at `trusted.json` for DRY.

Each needs one more rig-side probe to confirm params, then a subcommand here.

## Validation

Unit tests cover the three subcommands' full lifecycle. End-to-end on the rig pending.
