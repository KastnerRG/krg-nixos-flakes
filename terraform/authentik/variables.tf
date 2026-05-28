variable "authentik_url" {
  description = "Authentik base URL"
  type        = string
  default     = "https://auth.fabricant.ucsd.edu"
}

variable "authentik_token" {
  description = "Authentik admin API token — store in vault at secret/krg-deploy/authentik-admin-token"
  type        = string
  sensitive   = true
}

variable "vault_addr" {
  description = "OpenBao/Vault address"
  type        = string
  default     = "https://krg-vault.ucsd.edu:8200"
}

variable "ldap_bind_password" {
  description = "Password for the authentik-bind service account in Samba AD (KRG.LOCAL)"
  type        = string
  sensitive   = true
}

# Gate apps whose production URLs aren't finalized yet. Off by default so
# a `tofu apply` doesn't register placeholder callbacks (e.g. localhost) in
# production Authentik.
variable "enable_e4e_roster" {
  description = "Register the E4E Roster OAuth2 app. Leave false until a real callback URL is known."
  type        = bool
  default     = false
}
