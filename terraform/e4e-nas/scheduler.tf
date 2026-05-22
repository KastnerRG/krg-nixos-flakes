# Scheduled tasks (Control Panel -> Task Scheduler) as code.
#
# `synology_core_event` (event-/cron-triggered tasks) is handy for jobs DSM has
# no first-class resource for — e.g. exporting the config backup, cert renewal
# hooks, or kicking a Hyper Backup. NOTE: snapshot *schedules* themselves are
# DSM UI settings (see docs/e4e-nas-dsm.md), not a TF resource.
# Docs: https://registry.terraform.io/providers/synology-community/synology/latest/docs/resources/core_event
#
# Template COMMENTED OUT — verify attribute names against the resource docs.

# resource "synology_core_event" "nightly_config_backup" {
#   name    = "nightly-config-backup"
#   # cron-style schedule + a script run as root; see docs.
# }
