# Troubleshooting & known issues

Symptom-first recovery guide for the gotchas this fleet has actually hit — the
ones that otherwise live only in code comments and tribal memory. Each entry is
**Symptom → Cause → Fix**. For full rebuilds see
[disaster-recovery.md](disaster-recovery.md); for the AD join see
[joining-a-host-to-the-domain.md](joining-a-host-to-the-domain.md).

> **First instinct on any NixOS host:** you can almost always roll back. Pick an
> earlier generation at the GRUB menu, or `nixos-rebuild --rollback switch`. The
> break-glass `krg-admin` (local, key-only, home off `/home`) logs in even when AD
> and NFS are down — keep it working.

---

## Boot / early boot

### Box hangs at "Create System Files and Directories" or switch-root (waiter)
**Symptom:** waiter freezes early in boot; console shows *"Refusing to run in
unsupported environment where /usr/ is not populated"*, and it bricks **every**
generation (not just the new one).
**Cause:** impermanence rolls the root back to the empty `@blank`; systemd 258's
PID1 hard-checks that `/usr` is populated and freezes before tmpfiles can create
`/usr/bin/env`. ([`impermanence.nix`](../nix/modules/impermanence.nix) normally
reseeds it in initrd — this bites if that unit is missing/broken.)
**Fix / recovery:**
1. At GRUB, edit the entry and add `boot.debug1mounts` (drops to a shell after
   `/sysroot` is mounted).
2. Recreate the link so PID1's check passes:
   `mkdir -p /sysroot/usr/bin && ln -s /nix/var/nix/profiles/system/sw/bin/env /sysroot/usr/bin/env` (any valid `env` target works — even a dangling link satisfies the check), then continue boot.
3. Once up, redeploy current `main` so the `populate-usr-bin-env` initrd unit is
   present again.

### `zpool` won't import after a reboot / "pool was previously in use from another system"
**Symptom:** box won't boot; root pool fails to import.
**Cause:** `forceImportRoot/All = false` ([`zfs.nix`](../nix/modules/zfs.nix)) — the
pool imports only when the running `networking.hostId` matches the one that last
had it. A changed hostId, or a pool that wasn't cleanly exported (power loss), locks
it out.
**Fix:** from a rescue/installer environment, `zpool import -f nvmepool` (and
`hddpool`). Then make the running hostId match the committed one. **Prevention:**
always `zpool export -a` before rebooting during an install, and treat the committed
hostId as load-bearing (never edit casually, never reuse on another box).

---

## AD / login

### AD sudo "rejected", journald blind, SSSD offline — right after a deploy
**Symptom:** AD users suddenly can't `sudo` ("authentication rejected"), the journal
looks empty/discontinuous. Hit 2026-05-22 when the 04:00 auto-upgrade pulled a
pre-merge `main`.
**Cause:** the deployed generation was **missing the `/persist` bind units**, so
`/etc/krb5.keytab`, `/etc/machine-id`, and the SSH host-key binds were torn down →
SSSD goes offline, journald loses its stable machine-id.
**Fix:** redeploy current `main` (which has the persist binds).
**Recovery gotcha:** do **not** pre-copy files into `/etc` to "help" — the bind
mount refuses to mount over a non-empty file. Let the persist units own them.

### Brand-new AD user gets "Permission denied (publickey)" (cached users are fine)
**Symptom:** an existing/recently-logged-in user works, but a *new* AD user is
rejected at the key stage.
**Cause:** SSSD is flapping **offline** because it can't resolve `krg.local`. SSSD's
own resolver reads `/etc/resolv.conf` directly and **ignores** the `/etc/hosts` pin
— so unless the DC is a real nameserver, `krg-ldap.krg.local` won't resolve.
**Fix:** ensure the DC is the **primary** resolver. The module sets this
(`networking.nameservers` `mkBefore [ serverIp ]`,
[`sssd-ad-client.nix`](../nix/modules/sssd-ad-client.nix)); verify on the box:
```bash
head -1 /etc/resolv.conf            # should be: nameserver 137.110.161.109 (krg-ldap)
host -t SRV _ldap._tcp.krg.local    # must resolve
systemctl restart sssd
```
(Distinct from a missing **join** — a *deployed-but-unjoined* host shows the same
error; see [joining-a-host-to-the-domain.md](joining-a-host-to-the-domain.md).)

### All AD users denied with "network home is not mounted" (waiter)
**Symptom:** AD logins refused with a message about `/home` not being mounted;
`krg-admin` still works.
**Cause:** **working as designed.** fabricant (NFS) is down, so `/home` (a `nofail`
mount) didn't mount; the login gate ([`nfs-home.nix`](../nix/modules/nfs-home.nix))
denies AD users rather than letting `pam_mkhomedir` create an ephemeral home that
the next reboot would wipe.
**Fix:** bring fabricant/NFS back, then **mount `/home` explicitly** — the `nofail`
mount does **not** auto-mount on later access:
```bash
sudo mount /home          # or reboot once fabricant is up
mountpoint -q /home && echo ok
```

### AD user can log in but can't use the GPU (`/dev/nvidia*` permission denied)
**Symptom:** login works, `nvidia-smi` / CUDA fails with permission denied.
**Cause:** GPU device access is gated on the local `cuda` group (gid 65533), not a
login group. AD users can't be placed in a fixed-GID local group, so a `cuda-group-sync`
unit bridges the **"GPU Users"** AD group into `cuda` on boot + every 10 min
([`nvidia.nix`](../nix/modules/hardware/nvidia.nix)). After a `switch` there's a
≤10-min gap, or the user isn't in "GPU Users".
**Fix:**
```bash
sudo systemctl start cuda-group-sync     # apply immediately
getent group cuda                        # confirm the user is now a member
```
If still empty, add the user to the **"GPU Users"** AD group (separate from login
access) — see [creating-a-user.md](creating-a-user.md). Note: an emptied/unresolvable
AD group is treated fail-*safe* (membership left unchanged) — only a group that
resolves-but-is-empty revokes.

---

## Scratch (autotier) — waiter `/scratch/krg`

### `nixos-rebuild switch` killed jobs / dropped open files under /scratch
**Symptom:** running jobs using `/scratch/krg` die or get EIO during/after a deploy.
**Cause:** `switch` bounces the `autotier-krg` unit; its `ExecStop` runs
`fusermount3 -u`, tearing down the **whole** `/scratch` FUSE namespace — killing
in-flight tier moves and every open `/scratch` fd. (Fix `restartIfChanged = false`
is tracked in [`scratch.nix`](../nix/modules/scratch.nix) work.)
**Fix / avoid:** don't `switch` while scratch is in active use; prefer
`nixos-rebuild boot` + a scheduled reboot, or restart `autotier-krg` deliberately
during a quiet window.

### Every write to /scratch fails with EACCES (for all lab members)
**Symptom:** `ls`/`cd` work, but creating any file under `/scratch/krg` fails.
**Cause:** autotier's FUSE *create* path drops supplementary groups, so a `2770`
group-only tier root is untraversable on create.
**Fix:** tier roots must be **`2771`** (the `o+x` grants traverse without the group;
no `o+r`, so isolation holds). The module sets this; verify:
```bash
stat -c '%a %G' /srv/scratch-tiers/{nvme,hdd,nfs}/krg   # want 2771
```

### /scratch fills up / cold data never demotes
**Symptom:** the NVMe tier hits 100% though a quota was set.
**Cause:** autotier misparses a percent quota written **with a space** (`85 %` →
8500%), so the demotion watermark never trips.
**Fix:** write quotas with **no space** (`85%`). The module normalizes this
(`normQuota`), so this only bites if a tier quota is edited by hand on-box.

---

## Storage / hardware

### waiter `sdb` (ata3) SATA link errors in dmesg
**Symptom:** recurring SATA bus/link errors for `sdb` (an `hddpool` mirror leg),
since 2026-05-22.
**Status:** **letting it ride** — `hddpool` is ONLINE with 0 errors, only ephemeral
scratch lives there, and its mirror twin (`sde`) is healthy. The box can't be
physically serviced right now.
**Cautions:** do **not** scrub a flapping disk (a scrub hammers it). The escalation
**gap**: `smartd` is not enabled, so there's no proactive failure alert — pool-health
is only surfaced via the node_exporter textfile collector ([`zfs.nix`](../nix/modules/zfs.nix)).
Watch `zpool status hddpool`; if the twin degrades, the mirror is at risk.

---

## Security agents (OEC: Qualys + Trellix)

### `oec-install` doesn't enroll on NixOS
**Symptom:** the OEC oneshot runs but Qualys/Trellix don't come up.
**Cause:** the vendor archive ships **unpatched Ubuntu binaries** that assume an
FHS layout; the current NixOS module runs them under `nix-ld`/`envfs`, which doesn't
fully satisfy them — this path is **not yet validated on-box**.
**Notes:** the installer archive (live credentials, **gitignored**) must sit at
`/var/lib/krg/oec/oec-qualystrellixinstallers-linux.tgz`. Force a reinstall by
removing the sentinel `/var/lib/krg/oec/.installed` and rebuilding (see the OEC
section of [nix/README.md](../nix/README.md)). On Debian/PVE the Ansible
`oec_qualys_trellix` role is the counterpart (set `oec_installer`).
