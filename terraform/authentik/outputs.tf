# Non-secret outputs — client_ids are safe to display.
# Secrets are written directly to vault in vault_secrets.tf, not output here.

output "grafana_client_id" {
  value = authentik_provider_oauth2.grafana.client_id
}

output "outline_client_id" {
  value = authentik_provider_oauth2.outline.client_id
}

output "mlflow_client_id" {
  value = authentik_provider_oauth2.mlflow.client_id
}

