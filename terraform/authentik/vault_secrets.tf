# Write generated OIDC client secrets into vault so downstream services
# (Grafana compose, Outline secrets.env) can read them without manual copy-paste.
# The grafana/ Terraform workspace reads grafana-oidc from here.

resource "vault_kv_secret_v2" "grafana_oidc" {
  mount = "secret"
  name  = "krg-prod/grafana-oidc"
  data_json = jsonencode({
    client_id     = authentik_provider_oauth2.grafana.client_id
    client_secret = authentik_provider_oauth2.grafana.client_secret
    issuer_url    = "${var.authentik_url}/application/o/grafana/"
  })
}

resource "vault_kv_secret_v2" "outline_oidc" {
  mount = "secret"
  name  = "krg-prod/outline-oidc"
  data_json = jsonencode({
    client_id     = authentik_provider_oauth2.outline.client_id
    client_secret = authentik_provider_oauth2.outline.client_secret
    issuer_url    = "${var.authentik_url}/application/o/outline/"
  })
}

resource "vault_kv_secret_v2" "mlflow_oidc" {
  mount = "secret"
  name  = "krg-prod/mlflow-oidc"
  data_json = jsonencode({
    client_id     = authentik_provider_oauth2.mlflow.client_id
    client_secret = authentik_provider_oauth2.mlflow.client_secret
    issuer_url    = "${var.authentik_url}/application/o/mlflow/"
  })
}

resource "vault_kv_secret_v2" "outpost_token" {
  mount = "secret"
  name  = "krg-prod/authentik-outpost-token"
  data_json = jsonencode({
    token = authentik_token.proxy_outpost.key
  })
}
