# waiter — storage & network topology

Reference diagrams for **waiter**, the KRG research/compute box (physical, AMD
Threadripper PRO 7985WX, 137.110.161.67). Everything here is derived from the
flake — the authoritative sources are linked inline; if the diagrams and the
`.nix` ever disagree, the `.nix` wins.

- Host config: [`nix/hosts/waiter/default.nix`](../nix/hosts/waiter/default.nix)
- Disk layout: [`nix/hosts/waiter/disko-config.nix`](../nix/hosts/waiter/disko-config.nix)
- Bootloader/hardware: [`nix/hosts/waiter/hardware-configuration.nix`](../nix/hosts/waiter/hardware-configuration.nix)
- Compute profile: [`nix/profiles/compute.nix`](../nix/profiles/compute.nix) → [`base`](../nix/profiles/base.nix)

> **Related:** [fabricant](fabricant-topology.md) · [krg-ldap](krg-ldap-topology.md).
> Mermaid diagrams render inline on GitHub. `fabricant` = the Proxmox **hypervisor**
> (137.110.161.98) that serves NFS and hosts the `krg-ldap` AD DC VM
> (137.110.161.109); `krg-prod` (137.110.161.106) runs Prometheus.

---

## Storage

waiter is **ZFS-on-root with an impermanent (erase-your-darlings) root**: every
boot `nvmepool/root` is rolled back to its empty `@blank` snapshot, so durable
state must live either on a non-rolled-back dataset (`/nix`, `/persist`,
`/tools`, `/var/lib/docker`, `/local`) or be bind-mounted back from `/persist`.
User data lives **off the box** — `/home` over NFS and `/scratch/krg` tiered down
to NFS — so the rollback never touches it.

### Physical → pools → datasets

```mermaid
flowchart TB
  subgraph disks["Physical devices"]
    direction LR
    nv["4× Crucial T700 4TB NVMe<br/>(PCIe)"]
    hd["2× Seagate 16TB SATA HDD"]
    zr["zram<br/>50% RAM, zstd<br/>(swap — no on-disk swap)"]
  end

  subgraph parts["Partitioning (GPT, by-id)"]
    esp["4× 2 GiB vfat ESP<br/>(one per NVMe, independent)"]
    nvz["4× ZFS partitions<br/>(rest of each NVMe)"]
    hdz["2× whole-disk ZFS partitions"]
  end

  nv --> esp
  nv --> nvz
  hd --> hdz

  esp --> grub["GRUB mirroredBoots<br/>/boot · /boot-1 · /boot-2 · /boot-3<br/>EFI fallback BOOTX64.EFI on each<br/>→ boots from any surviving NVMe"]

  nvz --> nvmepool["<b>nvmepool</b> — RAIDZ1 (1 parity)<br/>ashift=12 · autotrim · zstd · atime=off"]
  hdz --> hddpool["<b>hddpool</b> — mirror<br/>ashift=12 · zstd · atime=off"]

  subgraph nvds["nvmepool datasets (legacy mounts)"]
    direction TB
    d_root["root → <b>/</b><br/>⟲ rolled back to @blank every boot"]
    d_nix["nix → /nix<br/>(never rolled back)"]
    d_persist["persist → /persist<br/>(durable · autosnap all cadences)"]
    d_tools["tools → /tools<br/>(vendor binaries · autosnap)"]
    d_docker["docker → /var/lib/docker<br/>(off rollback · autosnap off)"]
    d_local["local → /local<br/>(krg.localCache · off rollback · quota 1T)"]
    d_skrg["scratch-krg<br/>(autotier NVMe tier · 1M recsize)<br/>quota 8T / 2T reserved"]
    d_se4e["scratch-e4e<br/>(mountpoint=none — reserved)"]
  end

  subgraph hdds["hddpool datasets"]
    direction TB
    h_skrg["scratch-krg<br/>(autotier HDD tier · 1M recsize)<br/>quota 10T / 4T reserved"]
    h_se4e["scratch-e4e<br/>(mountpoint=none — reserved)"]
  end

  nvmepool --> d_root & d_nix & d_persist & d_tools & d_docker & d_local & d_skrg & d_se4e
  hddpool --> h_skrg & h_se4e

  d_persist -.->|"bind-mounts state back into /"| d_root
```

**`/persist` → `/` bind mounts** (what survives the rollback — see
[`modules/impermanence.nix`](../nix/modules/impermanence.nix)):
`/var/log`, `/var/lib/nixos` (uid/gid map), `/var/lib/systemd`,
`/var/lib/fail2ban` (ban DB), `/var/lib/sss` (SSSD offline cache),
`/var/lib/krg` (compose working dir + secrets + monitoring data),
`/var/lib/autotier` (tier popularity DB), `/root`, `/etc/nixos`,
`/var/lib/krg-admin` (break-glass home); files `/etc/machine-id`, the SSH host
keys, `/etc/krb5.keytab` (AD membership).

| dataset | mount | pool | rolled back? | snapshots |
|---|---|---|---|---|
| `nvmepool/root` | `/` | nvmepool (raidz1) | **yes, → `@blank`** | off |
| `nvmepool/nix` | `/nix` | nvmepool | no | off |
| `nvmepool/persist` | `/persist` | nvmepool | no | all cadences |
| `nvmepool/tools` | `/tools` | nvmepool | no | all cadences |
| `nvmepool/docker` | `/var/lib/docker` | nvmepool | no | off |
| `nvmepool/local` | `/local` | nvmepool | no | off (quota 1T) |
| `nvmepool/scratch-krg` | autotier NVMe tier | nvmepool | no | daily/weekly/monthly |
| `hddpool/scratch-krg` | autotier HDD tier | hddpool | no | daily/weekly/monthly |

### Logical view — what users see (`/home`, `/scratch`, `/local`)

```mermaid
flowchart LR
  user(("AD user<br/>session"))

  subgraph waiter["waiter (local)"]
    home["/home/&lt;user&gt;<br/>(NFS mount, AD home)"]
    scratch["/scratch/krg<br/><b>autotier FUSE</b> — one merged namespace<br/>owned by 'Kastner Research Group' (2771)<br/>per-user /scratch/krg/&lt;user&gt;"]
    local["/local/&lt;user&gt;<br/>node-local NVMe cache (0700)<br/>~/.vscode-server, ~/.cursor-server (symlinks)<br/>XDG_CACHE_HOME, HF_HOME, torch, conda-pkgs, npm"]
  end

  subgraph tiers["/scratch/krg tiers (fastest first, auto hot/cold)"]
    direction TB
    t1["① NVMe — nvmepool/scratch-krg<br/>/srv/scratch-tiers/nvme/krg · cap 85%"]
    t2["② HDD — hddpool/scratch-krg<br/>/srv/scratch-tiers/hdd/krg · cap 90%"]
    t3["③ NFS (fabricant) — 137.110.161.98:/srv/nfs/scratch-krg<br/>/srv/scratch-tiers/nfs/krg · overflow 100%"]
  end

  user --> home
  user --> scratch
  user --> local

  scratch --> t1
  t1 -->|"demote cold ▼ / promote hot ▲"| t2
  t2 -->|"demote cold ▼ / promote hot ▲"| t3

  home -.->|"NFSv4.2 (hard,nofail,nconnect=4)"| fab[("fabricant<br/>137.110.161.98<br/>rpool/nfs/home<br/>→ /srv/nfs/home")]
  t3 -.->|"NFSv4.2 no_root_squash"| fab
  local --> nvmepool[("nvmepool/local<br/>(pure NVMe, no FUSE/NFS)")]
```

Notes:
- **`/scratch/krg`** is one [autotier](../nix/modules/scratch.nix) FUSE namespace
  that keeps the working set on NVMe and drains cold files NVMe → HDD → fabricant
  NFS (daily pass). It **fails closed**: if the NFS cold tier is down the
  `autotier-krg` unit won't start (so it never demotes onto the impermanent root).
- **`/home`** is a plain `nofail` NFSv4.2 mount ([`nfs-home.nix`](../nix/modules/nfs-home.nix)),
  pinned to fabricant by IP so it never waits on DNS. A PAM **login gate** denies
  any AD user whose home is under `/home` while that mount is down — closing the
  impermanence data-loss window. Break-glass `krg-admin` (home `/var/lib/krg-admin`)
  is unaffected and keeps the box recoverable.
- **`/local`** ([`local-cache.nix`](../nix/modules/local-cache.nix)) is the
  deliberately boring counterpart: pure local NVMe for hot, watch-heavy,
  regenerable state that has no business on NFS. The symlink is never created over
  an existing real `~/.vscode-server`.

### Python environments (uv, poetry, pip)

A virtualenv is thousands of small files that get `stat`/`open`-ed constantly and
watched by your editor — exactly the workload NFS is worst at (and inotify doesn't
cross NFS, so watchers fall back to polling). Venvs are also fully regenerable from
a lockfile, so they belong on node-local **`/local`**, not the network `/home`.
`krg.localCache` already points the package **caches** (`XDG_CACHE_HOME`, `HF_HOME`,
…) at `/local/<you>/.cache`; where the **venv** lands depends on the tool:

- **poetry — already on `/local`.** Poetry stores venvs *out of project* under its
  cache dir, which follows `XDG_CACHE_HOME`, so they live in
  `/local/<you>/.cache/pypoetry/virtualenvs/`. Just don't turn on in-project venvs
  (`poetry config virtualenvs.in-project` should be `false`, the default; `true`
  puts `.venv` back on NFS).
- **pip / `python -m venv`** — the download cache is already on `/local`; create the
  environment itself there, e.g. `python -m venv /local/$(id -un)/venvs/myproj`.
- **uv — needs a per-project nudge.** uv's cache is on `/local`, **but uv creates the
  project env at `.venv` inside the project dir**, which on your NFS home means the
  venv lands on NFS. uv has no global "put venvs on /local" switch, so redirect it
  **per project**:

  ```bash
  rm -rf .venv                                                   # remove the NFS one
  export UV_PROJECT_ENVIRONMENT="/local/$(id -un)/venvs/$(basename "$PWD")"
  uv sync
  ```

  Make it stick for that project by putting the `export` in a [direnv](https://direnv.net/)
  `.envrc`, or by symlinking the venv (uv follows the link, and your editor still
  finds `./.venv`):

  ```bash
  d="/local/$(id -un)/venvs/$(basename "$PWD")"; mkdir -p "$d"; ln -s "$d" .venv
  ```

**Why bother — the hardlink trap.** uv hardlinks packages from its cache into the
venv, and hardlinks can't span filesystems. A `/local` cache + an NFS `.venv` makes
uv fall back to copying every file (slower, and it prints `Failed to hardlink files;
falling back to full copy`). Putting the venv on `/local` alongside the cache
restores fast, hardlinked installs.

**Caveats.** `/local` is *not* snapshotted or backed up
([disaster-recovery.md](disaster-recovery.md)) — fine for a venv (recreate with
`uv sync` / `poetry install`), but keep your **source** in `/home`. And don't set a
*fleet-wide* `UV_PROJECT_ENVIRONMENT`: a single static path forces every uv project
to share one venv (constant re-syncs; corruption with two concurrent shells), so
this stays a per-project setting by design.

---

## Network

waiter is **physical with a public UCSD IP** — there is no Proxmox perimeter in
front of it (that layer only guards VMs). Its single defense layer is the in-guest
nftables firewall ([`krg.firewall`](../nix/modules/security/firewall.nix)) plus
key-only SSH and fail2ban. SSH is intentionally open to the world (compute hosts
serve researchers from anywhere); RDP and the monitoring ports are restricted.

```mermaid
flowchart TB
  net(("Internet /<br/>UCSD campus"))
  mon[("krg-prod<br/>137.110.161.106<br/>Prometheus")]

  subgraph wn["waiter — eno1np0 · 137.110.161.67/24 · gw 137.110.161.1"]
    direction TB
    fw["nftables firewall (krg.firewall)<br/>+ fail2ban sshd jail (ignore: loopback, sealab)"]
    subgraph svcs["listening services"]
      direction LR
      ssh["sshd :22<br/>key-only · ed25519-only"]
      rdp["xrdp :3389<br/>(only if FPGA/XRDP on — currently OFF)"]
      m_node["node-exporter :9100"]
      m_ipmi["ipmi-exporter :9290"]
      m_dkr["docker metrics :9323"]
      m_cli["prometheus client :9000"]
      m_dcgm["DCGM exporter :9400 (Docker, GPU)"]
    end
  end

  ad[("krg-ldap (DC)<br/>137.110.161.109<br/>realm KRG.LOCAL")]
  fab[("fabricant<br/>137.110.161.98<br/>NFS exports")]
  ext(("github / nix cache"))

  net -->|"TCP 22 (open to all)"| fw
  net -->|"TCP 3389 — UCSD nets only, when enabled"| fw
  mon -->|"scrape 9100/9290/9323/9000/9400<br/>(source-restricted to krg-prod)"| fw
  fw --> svcs

  wn -->|"AD/SSSD: Kerberos, LDAP, SSH keys from AD<br/>+ primary DNS for krg.local zone"| ad
  wn -->|"NFSv4.2: /home + /scratch cold tier"| fab
  wn -->|"nightly auto-upgrade (flake) + builds"| ext
```

### Inbound rules

| port | service | exposure | source |
|---|---|---|---|
| 22/tcp | SSH | **open to all** | any (key-only ed25519 + fail2ban) |
| 3389/tcp | XRDP | only when `krg.fpga.enable` (currently **off**) | UCSD nets (`rdpSources`) |
| 9100/tcp | node-exporter | monitoring | `krg-prod` only |
| 9290/tcp | ipmi-exporter | monitoring | `krg-prod` only |
| 9323/tcp | docker metrics | monitoring | `krg-prod` only |
| 9000/tcp | prometheus client | monitoring | `krg-prod` only |
| 9400/tcp | DCGM GPU exporter | monitoring | `krg-prod` only |

Monitoring source = `trusted.json` `monitoring_host` (137.110.161.106). Trusted
nets (`ucsd`/`sealab`/`ops`) live in
[`nix/networks/trusted.json`](../nix/networks/trusted.json), shared with the
Ansible layer.

### Outbound dependencies

| target | purpose | how |
|---|---|---|
| `krg-ldap` 137.110.161.109 | AD membership: login, SSH keys, sudo, internal DNS | SSSD (Kerberos/LDAP); DC pinned as **primary nameserver** |
| `fabricant` 137.110.161.98 | `/home` + `/scratch/krg` cold tier | NFSv4.2 (`hard,nofail,nconnect=4`) |
| `132.239.0.252`, `8.8.8.8`, `1.1.1.1` | fallback DNS (after the DC) | resolv.conf |
| github / nix binary cache | nightly `system.autoUpgrade` (04:00) + builds | https |

> **SPOF:** every login depends on the single `krg-ldap` DC; the SSSD offline
> cache + local `krg-admin` are the only continuity if it's down. A second DC is a
> tracked follow-up (see `CLAUDE.md` pending items).
