# Proxy outpost — the authentik_proxy container on krg-prod registers here.
# The outpost token is written to vault and picked up by the compose stack
# via .secrets/authentik_traefik_token.env (AUTHENTIK_TOKEN=<token>).

resource "authentik_outpost" "proxy" {
  name = "authentik Proxy Outpost"
  type = "proxy"

  protocol_providers = [
    authentik_provider_proxy.fishsense_orchestrator.id,
    authentik_provider_proxy.qualcomm_docs.id,
  ]

  config = jsonencode({
    authentik_host          = "https://auth.fabricant.ucsd.edu"
    authentik_host_insecure = false
    log_level               = "info"
  })
}

# The outpost auto-creates a service account user named ak-outpost-<id>.
# Look it up and issue an API token the proxy container uses to authenticate.
data "authentik_user" "proxy_outpost_svc" {
  username = "ak-outpost-${authentik_outpost.proxy.id}"
}

resource "authentik_token" "proxy_outpost" {
  identifier   = "proxy-outpost-token"
  user         = data.authentik_user.proxy_outpost_svc.pk
  intent       = "api"
  expiring     = false
  retrieve_key = true
}
