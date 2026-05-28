# Default flows — present in every fresh Authentik install, referenced by slug.
# Using data sources avoids re-creating flows that Authentik manages itself.

data "authentik_flow" "default_authorization" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_invalidation" {
  slug = "default-provider-invalidation-flow"
}

# ── OIDC scope mappings ────────────────────────────────────────────────────────

data "authentik_property_mapping_provider_scope" "openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

data "authentik_property_mapping_provider_scope" "email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

data "authentik_property_mapping_provider_scope" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}

# ── LDAP source property mappings ─────────────────────────────────────────────
# Matches the 7 user + 1 group mappings selected in the live LDAP source config.

# Base LDAP mappings
data "authentik_property_mapping_source_ldap" "dn_user_path" {
  managed = "goauthentik.io/sources/ldap/default-dn-user-path"
}

data "authentik_property_mapping_source_ldap" "mail" {
  managed = "goauthentik.io/sources/ldap/default-mail"
}

data "authentik_property_mapping_source_ldap" "name" {
  managed = "goauthentik.io/sources/ldap/default-name"
}

# Active Directory-specific mappings
data "authentik_property_mapping_source_ldap" "ad_given_name" {
  managed = "goauthentik.io/sources/ldap/ms-ad-givenName"
}

data "authentik_property_mapping_source_ldap" "ad_sam_account_name" {
  managed = "goauthentik.io/sources/ldap/ms-ad-sAMAccountName"
}

data "authentik_property_mapping_source_ldap" "ad_sn" {
  managed = "goauthentik.io/sources/ldap/ms-ad-sn"
}

data "authentik_property_mapping_source_ldap" "ad_upn" {
  managed = "goauthentik.io/sources/ldap/ms-ad-userPrincipalName"
}
