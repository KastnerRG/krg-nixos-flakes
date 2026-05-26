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
| 1b — pinned RR `.img` + DSM 7.3 `.pat`, libvirt domain, `dsm-vm` app | **wired** — pins in `dsm.nix`, domain in `domains/`, `nix run ./test#dsm-vm`; first boot is the one-time interactive step |
| 1c — VM roles: `dsm-prod-mirror` / `dsm-pr` / `dsm-upgrade` | planned |
| 1d — `test-pr` loop (clone → plan/apply → exporter diff → destroy) | planned |

## 1a — host setup (now)

**Two ways to run — pick one:**

- **Portable (no libvirtd, no NixOS module)** — for a machine *not* managed by this
  repo. Needs only `/dev/kvm` access. On NixOS, add yourself to the `kvm` group in
  *your own* config — `users.users.<you>.extraGroups = [ "kvm" ];` — and nothing else.
- **Via libvirt (managed host / CI)** — import the module into a NixOS config:

  ```nix
  imports = [ inputs.krg-rig.nixosModules.libvirt-host ];
  krg.dsmRig = { enable = true; user = "chris"; };
  ```

  It enables `libvirtd` + KVM + **OVMF** + **swtpm** + `virt-manager`, adds you to
  `libvirtd`/`kvm`, and turns on nested KVM.

Tooling either way:

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

### Run it

```bash
# Portable — direct QEMU, no libvirtd (use this if your machine isn't managed by this repo):
nix run ./test#dsm-vm-qemu [vm-name]   # DSM wizard → http://localhost:5000 | VNC → 127.0.0.1:5900

# Via libvirt (needs the krg.dsmRig module):
nix run ./test#dsm-vm [vm-name]        # default name: dsm-prod-mirror
```

Both materialize a writable copy of the pinned RR loader + a 32 GB data disk and stage
the pinned `.pat`. `dsm-vm-qemu` boots QEMU directly (SeaBIOS + e1000e user-mode net with
a `:5000` host-forward + VNC + serial); `dsm-vm` renders `domains/dsm-vm.xml` and
`virsh define`/`start`s it on `qemu:///system`. Either way: drive the RR menu
(DS3622xs+ / DSM 7.3, install from the staged `.pat`), run the DSM wizard, and snapshot
the baseline.

### Pinned (in `dsm.nix` — bump deliberately)

| Input | Pin |
|---|---|
| RR loader | `26.4.0` (`rr-26.4.0.img.zip`) |
| DSM | `7.3.2-86009` · `DSM_DS3622xs+_86009.pat` (399.61 MB) |

> Pinning both keeps the rig from drifting to a newer DSM than prod — the whole point.
> We **build to** DSM 7.3, and the prod Mode-2 reinstall lands on the same
> `7.3.2-86009`, so test == prod by construction. To move the target, bump the pins
> and recompute `sha256` with `nix-prefetch-url`.

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
