# Scheduled tasks (Control Panel -> Task Scheduler) as code.
#
# `synology_core_event` (event-/cron-triggered tasks) is handy for jobs DSM has
# no first-class resource for — e.g. exporting the config backup, cert renewal
# hooks, or kicking a Hyper Backup. NOTE: snapshot *schedules* themselves are
# DSM UI settings (see docs/e4e-nas-dsm.md), not a TF resource.
# Docs: https://registry.terraform.io/providers/synology-community/synology/latest/docs/resources/core_event
#
# Live 2026-05-28 (docs/e4e-nas-live-capture/2026-05-28/scheduler-capture.txt):
#   user-visible tasks via `synowebapi SYNO.Core.TaskScheduler list`:
#     id 6   Recycle Bin            type=recycle  enabled  daily 00:00  "Empty all Recycle Bins"  ← REPRODUCE
#     id 3   Auto S.M.A.R.T. Test   type=custom   enabled  monthly                                  DSM-default, skip
#     id 80322000  PowerOff task 0  type=power    disabled one-off                                  stale, drop
#   plus DSM-default system tasks (DSM Auto Update, Security Advisor, Security Scan) that
#   DSM recreates on install — no IaC needed.
#
# TODO: verify the provider's `synology_core_event` attribute names against its registry
# docs and convert the Recycle Bin task below into a working resource.

# resource "synology_core_event" "recycle_bin_clean" {
#   # The single user-config scheduled task on e4e-nas (captured 2026-05-28).
#   # name = "Recycle Bin"
#   # task type "recycle" (Empty all Recycle Bins) — daily 00:00, owner=root, enabled.
#   # Equivalent shell action: `/usr/syno/bin/synocli --recycle-bin --clean`
# }
