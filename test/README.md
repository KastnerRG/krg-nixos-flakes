# test/ — DSM test rig

A declarative XPEnology DSM rig on the dev laptop, to validate IaC changes (DSM CLI
syntax, Web API responses, Ansible idempotency, Garage config) **before** they touch
the production NAS. Self-contained flake — the production flake is `../nix`.

**Target:** XPEnology **DS3622xs+ / `broadwellnk`, DSM 7.3**, via the **RR** loader
(RROrg/rr) in libvirt. Why this model and not a literal DS3617xs: RR supports
`broadwellnk` on 7.3, whereas native `broadwell` (DS3617xs) is poorly supported and
`bromolow` (DS3615xs, Ivy-Bridge-era) is dropped at 7.3. The DSM CLI surface we test
is model-agnostic, so the model mismatch is fine — and the rig never tests the real
box's storage/fans anyway (see [`../docs/krg-prod-iac.md`](../docs/krg-prod-iac.md)).

## Status

| Sub-milestone | State |
|---|---|
| 1a — libvirt/KVM/OVMF/swtpm host module + devShell | **done** (this commit) |
| 1b — pinned RR `.img` + DSM 7.3 `.pat`, libvirt domain, `dsm-vm` app | **next** — needs the pins below |
| 1c — VM roles: `dsm-prod-mirror` / `dsm-pr` / `dsm-upgrade` | planned |
| 1d — `test-pr` loop (clone → plan/apply → exporter diff → destroy) | planned |

## 1a — host setup (now)

Import the module into your laptop's NixOS config:

```nix
# laptop configuration.nix (or its flake)
imports = [ inputs.krg-rig.nixosModules.libvirt-host ];
krg.dsmRig = { enable = true; user = "chris"; };
```

It enables `libvirtd` + KVM + **OVMF** (UEFI) + **swtpm** (TPM) + `virt-manager`,
adds your user to `libvirtd`/`kvm`, and turns on nested KVM. Then:

```bash
nix develop ./test     # virsh, tofu, ansible, yq, garage, nix-prefetch — all pinned
```

## 1b — the DSM VM (next; honest workflow)

**RR is semi-interactive — it builds the loader at runtime in its own TinyCore
environment.** So Nix does *not* produce a headless "bootable DSM image" derivation;
instead Nix **pins the inputs** (the RR `.img` and the DSM `.pat`) and **defines the
libvirt domain**, and the *first* boot is a one-time manual step:

1. Boot the pinned RR `.img` → RR menu → pick **DS3622xs+** / **DSM 7.3** → it patches
   the loader with the `.pat` → reboot → **DSM install wizard**.
2. Snapshot that as the **`dsm-prod-mirror`** baseline.
3. `dsm-pr` VMs **clone** the snapshot (no re-running RR) — that part is automatable.

### Pins to fill (the blocker for 1b)

Compute these in the devShell (`nix-prefetch-url <url>`), then wire them into the
`dsm-vm` app + domain:

- **RR loader release** — pick a specific `RROrg/rr` release (don't track latest);
  record version + the `.img.zip` URL + `sha256`.
- **DSM 7.3 `.pat` for DS3622xs+** — the `DSM_DS3622xs+_<build>.pat` from Synology's
  archive; record URL + `sha256`. (Must be the **DS3622xs+** image, matching the
  emulated model — not DS3617xs.)

> Pinning both keeps the rig from silently drifting to a newer DSM than prod — which
> is the whole point. Confirm prod's exact DSM 7.3 build (Control Panel → Info Center)
> and pin the rig to match.

## 1c / 1d — VM roles + test loop (planned)

- **`dsm-prod-mirror`** — long-lived; refreshed nightly from a drift-export of the
  real NAS.
- **`dsm-pr`** — ephemeral per PR: clone the mirror snapshot → `tofu plan` +
  `ansible-playbook --check --diff` → apply → exporter playbooks → structural diff vs
  `../spec/krg-prod/` → pass/fail → destroy.
- **`dsm-upgrade`** — occasional: DSM minor update first, then full IaC apply, to
  catch upgrade-induced breakage.

CI runs the same loop on a self-hosted KVM runner (GitHub-hosted runners lack nested
virt).
