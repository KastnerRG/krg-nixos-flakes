resource "authentik_group" "krg_admins" {
  name         = "KRG Admins"
  is_superuser = true
}
