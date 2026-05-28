resource "grafana_dashboard" "krg_waiter" {
  folder      = grafana_folder.waiter.uid
  config_json = file("${path.module}/dashboards/krg-waiter.json")
}
