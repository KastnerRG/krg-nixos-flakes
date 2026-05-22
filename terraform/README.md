# terraform/ — the OpenTofu layer

The third config layer of `krg-infra`, alongside `nix/` (NixOS machines) and
`ansible/` (Proxmox hypervisors). This layer manages things driven through a
**Terraform/Web-API provider** rather than NixOS or Ansible — appliances and
running services that expose their config over an API.

Use **OpenTofu** (`tofu`), not HashiCorp Terraform: FOSS, in nixpkgs
(`nix run nixpkgs#opentofu`), and native state encryption (see below).

## Layout: one root module per target

Each target is its **own root module** in its own subdirectory — its own
`tofu init`, its own **state**, its own credentials, its own `apply`. They are
**not** combined into one config: different providers, lifecycles, blast radii,
and secrets. A NAS `apply` must not be able to touch Vault's state.

| Target | Provider | Manages | Status |
|---|---|---|---|
| [`e4e-nas/`](e4e-nas/) | `synology-community/synology` | Synology DSM: Container Manager, packages, tasks, files, VMs (+ runbook for the rest) | **built (scaffold)** |
| [`authentik/`](authentik/) | `goauthentik/authentik` | Authentik **SSO config**: applications, OAuth2/OIDC + proxy providers, flows/stages, groups | planned |
| [`vault/`](vault/) | `hashicorp/vault` | Vault **structure**: auth methods, policies, secret engines/mounts | planned |

> `authentik/` and `vault/` manage the *configuration of* services that are
> **deployed elsewhere** (Authentik is a compose stack on krg-prod; Vault is the
> future secrets store). Terraform owns their objects, not their deployment.
> Each needs the service running + an API token before it can plan — see each
> subdir's README.

## Secrets & state (shared rules)

- Credentials per target: `terraform.tfvars` (gitignored) or `TF_VAR_*` env vars.
- **State holds secrets** and is **local for now** — the top-level
  `.gitignore` keeps `*.tfstate*` and `*.tfvars` out of git for every target.
  We will migrate to a remote backend ("start local and we'll migrate it").
- Vault/Authentik state is especially sensitive (tokens, possibly secret
  values), so sort out a backend + state encryption **before** those go live.
- **State encryption** (OpenTofu): the `encryption` block can't read variables,
  so supply it via the `TF_ENCRYPTION` env var to keep the passphrase out of the
  repo:

  ```bash
  export TF_ENCRYPTION='
  key_provider "pbkdf2" "k" { passphrase = "'"$TOFU_STATE_PASSPHRASE"'" }
  method "aes_gcm" "m"      { keys = key_provider.pbkdf2.k }
  state { method = method.aes_gcm.m }
  plan  { method = method.aes_gcm.m }
  '
  ```

## Shared source of truth

Targets read the same shared JSON the other layers do (don't duplicate values):

```hcl
locals {
  trusted = jsondecode(file("${path.module}/../../nix/networks/trusted.json"))
  admins  = jsondecode(file("${path.module}/../../nix/keys/admins.json"))
}
```
