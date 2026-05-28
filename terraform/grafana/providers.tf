terraform {
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.8.0"
}

provider "vault" {
  address = var.vault_addr
}

# Grafana admin credentials — password read from vault so it never appears in env.
data "vault_kv_secret_v2" "grafana_admin" {
  mount = "secret"
  name  = "krg-prod/grafana-admin"
}

provider "grafana" {
  url  = var.grafana_url
  auth = "admin:${data.vault_kv_secret_v2.grafana_admin.data["password"]}"
}
