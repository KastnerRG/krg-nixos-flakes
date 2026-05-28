# Read the OIDC credentials written by the authentik workspace.
data "vault_kv_secret_v2" "grafana_oidc" {
  mount = "secret"
  name  = "krg-prod/grafana-oidc"
}

# Configure Grafana generic OAuth SSO via Authentik.
# Role mapping: Domain Admins → GrafanaAdmin, everyone else → Viewer.
# (Domain Admins comes through LDAP sync from Samba AD verbatim; the
#  Authentik-only "KRG Admins" group is a separate is_superuser marker for
#  Authentik admin access, not propagated as a Grafana role.)
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
    # Domain Admins get full admin; everyone else is a Viewer with folder-level restrictions.
    role_attribute_path   = "contains(groups[*], 'Domain Admins') && 'GrafanaAdmin' || 'Viewer'"
    groups_attribute_path = "groups"
    allow_sign_up         = true
    use_pkce              = true
    use_refresh_token     = true
  }
}
