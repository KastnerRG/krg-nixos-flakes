# Install & disaster recovery

How to rebuild a KRG machine from nothing. This repo's whole premise is that the
**configuration** is reproducible from git — so recovery is "redeploy the config,
then restore the data." The hard part is knowing **which is which**, and the
machine-specific install gotchas (ZFS-on-root, impermanence, the AD forest).

> **Related:** [fleet-inventory.md](fleet-inventory.md) (what to rebuild) ·
> [troubleshooting.md](troubleshooting.md) (boot-time recovery) ·
> [joining-a-host-to-the-domain.md](joining-a-host-to-the-domain.md) ·
> the topology docs ([waiter](waiter-topology.md), [fabricant](fabricant-topology.md),
> [krg-ldap](krg-ldap-topology.md)).

---

## The one rule: config is reproducible, DATA is not

| Reproducible from git (just redeploy) | Must be restored from a backup / re-created |
|---|---|
| Every NixOS host's full system (flake) | **User homes** (`/home`, served from fabricant NFS) |
| Proxmox host baseline (Ansible) | **`/scratch/krg`** working data (lab scratch) |
| Firewall rules, exporters, packages, services | **AD forest** (`KRG.LOCAL` SAM/Kerberos DB on krg-ldap) |
| ZFS pool *layout* (disko) | **Compose secrets** (`/var/lib/krg/*/​.secrets/`) — see CLAUDE.md |
| `/local` cache *structure* | Anything on a non-snapshotted, non-replicated dataset |

If it's in the right column, deploying the flake will **not** bring it back. Know
where the backup is *before* you need it. Today the only off-host copy is the
**~10.9 TiB waiter backup on fabricant's `rpool/ROOT/pve-1`** (and ZFS auto-snapshots,
which protect against deletion but **not** against losing the pool/host).

ZFS auto-snapshots of `/home` + `scratch-krg` run **on fabricant** via the Ansible
`nfs_server` role (`zfs-auto-snapshot` systemd timers; retention mirrors the NixOS
`krg.zfs.autoSnapshot` — frequent 4 / hourly 168 / daily 14 / weekly 16 / monthly 12).
They are **opt-in** (`--default-exclude`): only datasets with `com.sun:auto-snapshot=
true` are snapshotted, never the PVE root / VM zvols. To restore a deleted file,
`zfs list -t snapshot rpool/nfs/home` on fabricant and copy from `.../.zfs/snapshot/`.

> ⚠️ **Backup gap.** There is no current cross-site/cross-host replication of
> fabricant's NFS datasets (`/home`, `scratch-krg`) or the AD DB. Losing the
> fabricant pool loses user homes. Establishing real backups (e.g. `zfs send` to
> another box / e4e-nas) is tracked work — until then, treat fabricant's pool as a
> single point of data loss.

---

## waiter — ZFS-on-root + impermanence (the detailed one)

waiter is the only box with the destructive ZFS/impermanence install, and it has
**load-bearing gotchas** that bricked earlier attempts. Read
[`disko-config.nix`](../nix/hosts/waiter/disko-config.nix) and
[`impermanence.nix`](../nix/modules/impermanence.nix) alongside this.

### 0. Before you wipe — know what you're destroying
`disko --mode disko` **wipes and repartitions every device** in the config, every
run. It is NOT idempotent. User homes are on **fabricant NFS** (safe), but anything
local — `/scratch/krg`'s NVMe/HDD tiers, `/local` caches — is gone. The cold
scratch tier and `/home` survive on fabricant.

### 1. Identify disks by-id and fill the config
The disko config pins devices by `/dev/disk/by-id/*` (NOT `sdX`/`nvmeXn1`, which
reshuffle). On the target:
```bash
ls -l /dev/disk/by-id/        # nvme-<model>_<serial>, ata-<model>_<serial> / wwn-…
```
Confirm the 4× NVMe and 2× HDD ids in `disko-config.nix` match the hardware.

### 2. Generate hardware config + a unique hostId
```bash
nixos-generate-config --show-hardware-config    # copy ONLY hardware lines (see the file's GOTCHA)
python3 -c "import uuid; print(str(uuid.uuid4())[:8])"   # -> networking.hostId
```
The `hostId` is **load-bearing**: ZFS imports the pool only when the running hostId
matches. Don't change it casually and never reuse it on a second machine
([`zfs.nix`](../nix/modules/zfs.nix) explains the lockout).

### 3. Partition + install
From an installer/rescue environment with the repo checked out:
```bash
# DESTRUCTIVE — wipes every disk in the config:
sudo nix run github:nix-community/disko -- --mode disko ./nix/hosts/waiter/disko-config.nix
# disko's postCreateHook captures nvmepool/root@blank (empty) here — the snapshot
# impermanence rolls back to every boot.

sudo nixos-install --flake ./nix#waiter --no-root-password
```
(Or drive both steps remotely with `nixos-anywhere`.) disko `zpool export`s cleanly
at the end, so the first real boot imports fine.

> On later boots / re-deploys you do **not** re-run `--mode disko` — use
> `disko --mode mount` to just import+mount, or simply
> `nixos-rebuild boot --flake ./nix#waiter`.

### 4. Create the datasets disko won't re-create on a live box
disko is destructive-only, so datasets added *after* the original install aren't
created by a re-run. waiter needs `nvmepool/local` (the `/local` cache) created by
hand (per [`hosts/waiter/default.nix`](../nix/hosts/waiter/default.nix)):
```bash
sudo zfs create -o mountpoint=legacy -o quota=1T \
  -o com.sun:auto-snapshot=false nvmepool/local
```
The `scratch-krg` tiers are created by disko; if you ever add them live, flip
`mountpoint=none → legacy` with `zfs set` (non-destructive).

### 5. Deploy with `boot`, not `switch` — and migrate state FIRST
With impermanence, the **first** activation must seed `/persist` *before* the first
rollback, or that first reboot wipes the state you just created. Migrate the live
bits into `/persist` (keytab, SSH host keys, `/etc/machine-id`,
`/var/lib/{nixos,sss,krg}`, the break-glass admin home `/var/lib/krg-admin`), then:
```bash
sudo nixos-rebuild boot --flake ./nix#waiter    # NOT switch — switch errors on existing persist files
sudo zpool export -a                            # clean export so the pinned hostId imports next boot
sudo reboot
```
> Deploying a generation that is *missing* the persist bind units (e.g. an old
> commit) tears down `/etc/krb5.keytab` + machine-id + ssh-key binds and breaks AD
> sudo + journald — see [troubleshooting.md](troubleshooting.md). Always deploy
> current `main`.

### 6. Re-join the domain + restore data
- **Domain join:** [joining-a-host-to-the-domain.md](joining-a-host-to-the-domain.md)
  (Case 1). The keytab then persists.
- **`/home`:** nothing to restore on waiter — it's an NFS mount from fabricant.
  Just confirm it mounts (`mountpoint -q /home`); the login gate keeps AD users out
  until it does.
- **`/scratch/krg`:** the cold tier lives on fabricant; local tiers refill as
  autotier promotes. No manual restore.

### 7. Validate
```bash
zpool status                       # both pools ONLINE
systemctl --failed                 # 0 failed units
mountpoint -q /home && echo home-ok
ls /scratch/krg                    # autotier FUSE mounted
nvidia-smi                         # GPU/driver up
```
Reboot once more and re-check — impermanence is only proven across a reboot (root
returns to `@blank`, `/persist` binds reappear).

---

## krg-ldap — rebuild the AD domain controller

krg-ldap is a plain ext4 NixOS VM, so the **OS** is a normal redeploy; the
**forest** is the data.

1. Recreate the VM (VMID 100 on fabricant), deploy the config:
   `nixos-rebuild switch --flake ./nix#krg-ldap` (or install fresh, then deploy).
   The `samba-ad-dc` service stays **inactive** until a domain exists
   (`ConditionPathExists=/var/lib/samba/private/sam.ldb`), so a fresh box won't
   crash-loop.
2. **Restore vs. re-provision the forest** — these are different outcomes:
   - *Restore* `/var/lib/samba` + `/etc/samba/smb.conf` from a backup → same forest,
     same SIDs, existing users keep working. **Preferred if you have a backup.**
   - *Re-provision* (`samba-tool domain provision …`, see
     [`samba-ad.nix`](../nix/modules/samba-ad.nix)) → a **brand-new forest**: new
     SIDs, so every member must re-join and all users are re-created. This is the
     clean-rebuild path (it's how the breached domain was abandoned).
3. Export the keytab + set the DNS forwarder, start the daemon, validate — all in
   [joining-a-host-to-the-domain.md](joining-a-host-to-the-domain.md) (Case 3) and
   the provisioning notes in `samba-ad.nix`.

> **SPOF reminder:** while krg-ldap is down, only SSSD-cached logins + local
> break-glass admins work fleet-wide. A second DC is tracked in CLAUDE.md.

---

## fabricant — rebuild the Proxmox hypervisor

1. Reinstall Proxmox VE, restore (or recreate) the `rpool` ZFS pool.
2. Bring it under config: `cd ansible && ansible-playbook playbooks/site.yml`
   (baseline + firewall + `nfs_server`/`zfs_limits`). See [ansible/README.md](../ansible/README.md).
3. Join it to the domain ([Case 2](joining-a-host-to-the-domain.md)).
4. Re-create the VMs (krg-ldap, …) and restore their disks from backup.
5. **Restore the NFS data** — `rpool/nfs/home` and `rpool/nfs/scratch-krg` — from a
   backup if the pool was lost. If the pool survived, the exports come back as soon
   as the dataset + `host.fw` 2049 rule are reapplied.

---

## krg-prod / e4e-prod — rebuild a services host

1. Recreate the VM, deploy: `nixos-rebuild switch --flake ./nix#krg-prod`.
2. **Re-create secrets + runtime config** by hand (compose stacks won't start
   without them): `/var/lib/krg/krg-prod/.secrets/*` and the grafana/loki/prometheus
   config dirs. The required files are listed in `CLAUDE.md` ("Secrets" + "Runtime
   Config Directories"). *(Pre-Vault: there is no automated secret restore yet.)*
3. Restore stateful service volumes (Postgres, Grafana, etc.) under
   `/var/lib/krg/krg-prod/` from backup.
4. Join the domain; start the compose stacks.

---

## Quick reference

```bash
# NixOS, on the box
sudo nixos-rebuild switch --flake ./nix#<host>
sudo nixos-rebuild boot   --flake ./nix#<host>   # impermanent hosts (waiter)
nixos-rebuild list-generations                   # roll back: select an older generation at GRUB

# NixOS, remote (new nixos-rebuild → --sudo, not --use-remote-sudo)
nixos-rebuild switch --flake ./nix#<host> --target-host <admin>@<fqdn> --sudo --ask-sudo-password

# Proxmox host
cd ansible && ansible-playbook playbooks/site.yml --check && ansible-playbook playbooks/site.yml

# ZFS sanity
zpool status; zpool import           # -f only if you KNOW the hostId story (see zfs.nix)
zfs list -t snapshot | grep @blank   # waiter: the impermanence rollback target
```
