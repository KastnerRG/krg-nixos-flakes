output "krg_deploy_role_id" {
  description = "AppRole role_id for krg-deploy (non-secret, safe to store)"
  value       = vault_approle_auth_backend_role.krg_deploy.role_id
}

output "krg_prod_role_id" {
  description = "AppRole role_id for krg-prod (non-secret, safe to store)"
  value       = vault_approle_auth_backend_role.krg_prod.role_id
}
