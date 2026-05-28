# One team per AD group that gets machine-scoped dashboard access.
# grafana_team_external_group maps the OAuth groups claim value → Grafana team,
# so users are auto-assigned at login without manual team management.

resource "grafana_team" "waiter" {
  name = "Waiter"
}

resource "grafana_team_external_group" "waiter" {
  team_id  = grafana_team.waiter.id
  group_id = "Waiter"
}

resource "grafana_team" "kastnerml" {
  name = "KastnerML"
}

resource "grafana_team_external_group" "kastnerml" {
  team_id  = grafana_team.kastnerml.id
  group_id = "KastnerML"
}
