# LDAP source: federate Authentik with the KRG Samba AD (realm KRG.LOCAL).
# AD accounts log in to all Authentik-integrated apps via SSO.
#
# TLS: StartTLS with no cert verification for now — Samba CA cert not yet
# imported into Authentik. Upgrade to full LDAPS + cert verify once the CA
# is imported (see docs/joining-a-host-to-the-domain.md).
resource "authentik_source_ldap" "samba_ad" {
  name    = "KRG Samba AD"
  slug    = "krg-samba-ad"
  enabled = true

  server_uri = "ldap://fabricant-ldap.ucsd.edu"
  start_tls  = true

  bind_cn       = "CN=authentik-bind,CN=Users,DC=KRG,DC=LOCAL"
  bind_password = var.ldap_bind_password
  base_dn       = "DC=KRG,DC=LOCAL"

  additional_user_dn  = "CN=Users"
  additional_group_dn = "CN=Groups"

  user_object_filter      = "(objectClass=person)"
  group_object_filter     = "(objectClass=group)"
  group_membership_field  = "member"
  object_uniqueness_field = "objectSid"

  # 7 user property mappings — matches the live source config (screenshot).
  property_mappings = [
    data.authentik_property_mapping_source_ldap.dn_user_path.id,
    data.authentik_property_mapping_source_ldap.mail.id,
    data.authentik_property_mapping_source_ldap.name.id,
    data.authentik_property_mapping_source_ldap.ad_given_name.id,
    data.authentik_property_mapping_source_ldap.ad_sam_account_name.id,
    data.authentik_property_mapping_source_ldap.ad_sn.id,
    data.authentik_property_mapping_source_ldap.ad_upn.id,
  ]

  # 1 group property mapping — matches the live source config.
  property_mappings_group = [
    data.authentik_property_mapping_source_ldap.name.id,
  ]

  sync_users          = true
  sync_users_password = false
  sync_groups         = true
}
