# e4e-nas (Synology DSM) — break-glass / migration runbook

`e4e-nas.ucsd.edu` (`132.239.17.124`, DSM web on `:6021`, admin `:6020`) is the
lab's Synology NAS. Compute hosts mount its SMB shares (`nix/profiles/compute.nix`,
cifs-utils); krg-prod's prometheus blackbox-probes it; it's a trusted host in
[`../nix/networks/trusted.json`](../nix/networks/trusted.json).

**Source of truth has moved to IaC.** Per ADR 0001 the DSM configuration lives
in [`../spec/krg-prod/*.yml`](../spec/krg-prod) and is applied by the
[`synology_*` Ansible roles](../ansible/roles) composed in
[`../ansible/playbooks/synology.yml`](../ansible/playbooks/synology.yml). This
runbook is now **only** the break-glass + one-time migration sheet — things
that don't fit a programmatic surface (the DSM install wizard, hardware swap,
recovery without automation).

## Where each former runbook section lives now

| Former section | Now driven by |
|---|---|
| §1 Admin account, key-only SSH, Telnet off | [`synology_users`](../ansible/roles/synology_users) + [`synology_ssh`](../ansible/roles/synology_ssh) (spec: [`users.yml`](../spec/krg-prod/users.yml), [`ssh.yml`](../spec/krg-prod/ssh.yml)) |
| §2 KRG.LOCAL domain join + idmap reconciliation | [`synology_ad`](../ansible/roles/synology_ad) (spec: [`ad.yml`](../spec/krg-prod/ad.yml)) |
| §3 Firewall + autoblock + QuickConnect/UPnP off | [`synology_security`](../ansible/roles/synology_security) + [`synology_external_access`](../ansible/roles/synology_external_access) (specs: [`security.yml`](../spec/krg-prod/security.yml), [`external-access.yml`](../spec/krg-prod/external-access.yml)) |
| §4 Shared folders + ACLs + recursive stamp | [`synology_shares`](../ansible/roles/synology_shares) + [`synology_acls`](../ansible/roles/synology_acls) (recursive-stamp via `--tags acls-recursive`; specs: [`shares.yml`](../spec/krg-prod/shares.yml), [`acls.yml`](../spec/krg-prod/acls.yml)) |
| §5 Snapshot Replication + Hyper Backup | [`synology_snapshot_replication`](../ansible/roles/synology_snapshot_replication) + [`synology_hyper_backup`](../ansible/roles/synology_hyper_backup) (specs: [`snapshots.yml`](../spec/krg-prod/snapshots.yml), [`hyper-backup.yml`](../spec/krg-prod/hyper-backup.yml)) |
| §6 DSM updates | [`synology_dsm_updates`](../ansible/roles/synology_dsm_updates) (spec: [`dsm-updates.yml`](../spec/krg-prod/dsm-updates.yml)) |
| §7 Periodic `.dss` config backup | [`../terraform/e4e-nas/scheduler.tf`](../terraform/e4e-nas/scheduler.tf) (`weekly_config_backup_export`) |
| §8 Monitoring (SNMP + blackbox) | [`synology_services`](../ansible/roles/synology_services) (SNMP) — blackbox already in [`../nix/docker-compose/krg-prod/prometheus/prometheus.yml`](../nix/docker-compose/krg-prod/prometheus/prometheus.yml) |
| Per-share quotas | [`synology_quotas`](../ansible/roles/synology_quotas) (spec: [`quotas.yml`](../spec/krg-prod/quotas.yml)) |
| DSM web hardening (HSTS / HTTP2 / TLS profile) | [`synology_dsm_web`](../ansible/roles/synology_dsm_web) (spec: [`dsm-web.yml`](../spec/krg-prod/dsm-web.yml)) |
| OEC (Qualys/Trellix) | **Not on DSM** — see [ADR 0006](adr/0006-no-oec-on-dsm.md); replaced by [`synology_security_advisor`](../ansible/roles/synology_security_advisor) |

## Routine apply

```bash
cd ansible
ansible-playbook playbooks/synology.yml --check --diff       # dry run
ansible-playbook playbooks/synology.yml                       # apply
ansible-playbook playbooks/synology.yml --tags export         # drift snapshot only
```

One-shot operations carry their own flags / tags:

```bash
# Initial AD join (Domain Admin password, never stored)
ansible-playbook playbooks/synology.yml -e ad_join_password='<pass>'

# Post-AD-join one-shot: stamp share-root ACLs down the tree
# (runbook §4 "the bulk of the manual work" — runbook → IaC)
ansible-playbook playbooks/synology.yml --tags acls-recursive

# Hyper Backup with destination secrets (per-job password/key)
ansible-playbook playbooks/synology.yml -e @secrets-hb.yml
```

---

# Break-glass only (things automation CANNOT do)

These are the genuinely-unscriptable steps that remain. Everything else above
is IaC.

## Initial DSM install (one-time, post-Mode-2 reset)

1. Reset to DSM install with **volumes preserved** (Mode 2 — front-panel reset
   button × 2; *not* Mode 1, which reformats).
2. Walk the DSM install wizard in a browser at `http://<box>:5000`:
   - Pick a hostname (`e4e-nas`) and DSM admin password (one-time bootstrap;
     `synology_users` will replace it).
   - Confirm the volumes are auto-detected (they should — Mode 2 leaves them).
   - Pick the timezone (`America/Los_Angeles`).
3. Log in once via the browser to clear the welcome dialogs and the
   "QuickConnect setup" prompt (do NOT enable QuickConnect —
   `synology_external_access` will assert it off, but it's tidier to skip
   here).
4. Switch into `synology` group in inventory; first
   `ansible-playbook playbooks/synology.yml --check --diff` to confirm the
   baseline run is sane, then apply. The IaC takes over from here.

## Hardware swap / recovery

If the chassis dies and the disks move to a new DS3617xs (or compatible)
chassis:
1. Insert the disks in the same slot order.
2. Power on; DSM offers to migrate. Accept.
3. Re-run the install wizard's "migrate" path.
4. Re-apply the IaC (`ansible-playbook playbooks/synology.yml`).

Bare-metal recovery without disks (rare) uses the most recent `.dss`
configuration backup from the off-box destination (driven by
[`../terraform/e4e-nas/scheduler.tf`](../terraform/e4e-nas/scheduler.tf)). The
`.dss` is sensitive — see the gitignore note in the periodic-backup section.

## DSM major-update post-action

A DSM major upgrade (e.g. 7.3 → 7.4) can revert:
- the sshd_config drop-in written by [`synology_ssh`](../ansible/roles/synology_ssh)
  (DSM regenerates `/etc/ssh/sshd_config.d/` on some upgrades),
- and potentially `/etc/hosts` pins added by [`synology_ad`](../ansible/roles/synology_ad).

After a DSM major upgrade, re-run the playbook (idempotent — no-drift re-run
is cheap, reverted drop-ins are re-asserted in one shot):

```bash
ansible-playbook playbooks/synology.yml
```

## The ACL-SID-mismatch migration (one-time, post-AD-rebuild)

Preserved-volume files carry the old `KRG.UCSD.EDU` SIDs. After the new
`KRG.LOCAL` AD has the users + groups populated:

1. Update [`spec/krg-prod/acls.yml`](../spec/krg-prod/acls.yml) — translate the
   captured live ACLs to KRG.LOCAL principals.
2. `ansible-playbook playbooks/synology.yml` — applies share-level grants.
3. Flip `defaults.apply_recursive: true` in the acls spec (or per-share flag).
4. `ansible-playbook playbooks/synology.yml --tags acls-recursive` — runs the
   recursive `synoacltool -reset -R` pass.

The recursive stamp is gated behind `--tags acls-recursive` so it doesn't
re-walk every share on routine applies.

## Things we deliberately do NOT do

- **No OEC (Qualys/Trellix) on DSM** — see [ADR 0006](adr/0006-no-oec-on-dsm.md).
  DSM-native equivalents handle the same intent.
- **No `.dss` restore for the rebuild** — would drag the breach-era directory
  and stale settings back in. Used the `.dss` only as a checklist while
  populating the IaC; rebuilds always re-derive clean from `spec/`.
- **No QuickConnect, UPnP, AFP, FTP, or Telnet** — asserted off by
  `synology_external_access` / `synology_services` / `synology_ssh`. Don't
  re-enable in the UI — `synology_*` roles will revert.

## Sensitive-artifact discipline

- The `.dss` config backup contains hashed credentials and PII. **Never commit**
  (`*.dss` is gitignored under `terraform/`). Off-box destination is the only
  storage.
- Live captures (`synowebapi --exec ... method=get` output, `synoshare
  --list_acl`, etc.) live in `~/krg-captures/<host>/<date>/` — **off the
  public repo**.
- Memory rule: see [`krg-infra-no-live-captures`](../).
