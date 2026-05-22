# terraform/vault — Vault structure (planned)

Manage **Vault's structure** with the `hashicorp/vault` provider. This is the
Terraform side of the standing "Add Vault for secrets management" goal
(replacing the manual `.secrets/` population documented in `CLAUDE.md`).

**Scope: structure, not secret values.**

- Auth methods (OIDC via Authentik, AppRole, userpass), and their roles
- Policies (least-privilege per consumer)
- Secret engines / mounts (e.g. `kv-v2`), PKI if needed

> ⚠️ **Do not put actual secret values in Terraform.** Anything you write via TF
> lands in **state** in cleartext. Manage *structure* here; write the secret
> *values* out-of-band (`vault kv put`, a bootstrap script, or the app itself).

## Prerequisites before this can plan

1. Vault deployed, **initialized and unsealed**.
2. A token with enough policy to manage the above. Provider reads `VAULT_ADDR`
   + `VAULT_TOKEN` from the environment.

```hcl
# providers.tf (when built) — usually configured purely via env vars
provider "vault" {}
```

## Notes

- State here is the most sensitive of all targets → backend + state encryption
  must be sorted before this goes live (see [`../README.md`](../README.md#secrets--state-shared-rules)).
- SSO loop: configure Vault's **OIDC auth method** to trust Authentik
  (`../authentik/`), so humans log into Vault with their SSO identity.

**Status:** placeholder — no resources yet.
