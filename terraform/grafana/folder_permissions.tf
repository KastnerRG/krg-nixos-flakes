# Restrict each folder to its corresponding team.
# Domain Admins are GrafanaAdmin at the org level so they bypass these entirely.
# A user in multiple teams sees all their teams' folders.

resource "grafana_folder_permission" "waiter" {
  folder_uid = grafana_folder.waiter.uid
  permissions {
    type       = "team"
    team_id    = grafana_team.waiter.id
    permission = "View"
  }
}

resource "grafana_folder_permission" "kastnerml" {
  folder_uid = grafana_folder.kastnerml.uid
  permissions {
    type       = "team"
    team_id    = grafana_team.kastnerml.id
    permission = "View"
  }
}
