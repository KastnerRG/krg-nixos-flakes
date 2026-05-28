resource "grafana_dashboard" "krg_waiter" {
  config_json = file("${path.module}/dashboards/krg-waiter.json")
}
