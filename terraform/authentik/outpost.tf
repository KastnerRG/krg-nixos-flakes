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

# The outpost auto-creates a service account user (ak-outpost-<id>) and token.
# Retrieve the token from Admin → Outposts → <outpost> → "View token" after apply,
# then store it manually:
#   bao kv put secret/krg-prod/authentik-outpost-token token=<value>
# The proxy container reads it via AUTHENTIK_TOKEN in authentik_traefik_token.env.
