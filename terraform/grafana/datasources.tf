resource "grafana_data_source" "prometheus" {
  name = "Prometheus"
  type = "prometheus"
  uid  = "de0e1fh1fk35sc"
  url  = "http://prometheus:9090"

  json_data_encoded = jsonencode({
    httpMethod     = "POST"
    prometheusType = "Prometheus"
  })
}
