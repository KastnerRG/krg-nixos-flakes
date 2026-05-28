# Read the OIDC credentials written by the authentik workspace.
data "vault_kv_secret_v2" "grafana_oidc" {
  mount = "secret"
  name  = "krg-prod/grafana-oidc"
}

# Configure Grafana generic OAuth SSO via Authentik.
# Role mapping: KRG Admins → GrafanaAdmin, everyone else → Viewer.
# Grafana evaluates role_attribute_path as JMESPath against the userinfo claims;
# Authentik includes `groups` in the profile scope.
resource "grafana_sso_settings" "authentik" {
  provider_name = "generic_oauth"

  oauth2_settings {
    name              = "Authentik"
    client_id         = data.vault_kv_secret_v2.grafana_oidc.data["client_id"]
    client_secret     = data.vault_kv_secret_v2.grafana_oidc.data["client_secret"]
    auth_url          = "${var.authentik_url}/application/o/authorize/"
    token_url         = "${var.authentik_url}/application/o/token/"
    api_url           = "${var.authentik_url}/application/o/userinfo/"
    scopes            = "openid email profile"
    role_attribute_path = "contains(groups[*], 'KRG Admins') && 'GrafanaAdmin' || 'Viewer'"
    allow_sign_up     = true
    use_pkce          = true
    use_refresh_token = true
  }
}
