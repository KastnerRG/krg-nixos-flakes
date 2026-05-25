"""scratch-overflow — demote the coldest /scratch files to NFS to relieve capacity.

Greenfield scratch design (docs/scratch-greenfield.md): /scratch lives on a striped
HDD pool fronted by NVMe ARC/L2ARC, so ZFS handles hot/cold for READS by itself.
This job handles CAPACITY only: when the pool fills past --high percent, it moves the
least-recently-accessed files to a cold NFS area, replacing each local file with a
symlink to its NFS copy (the path keeps working, reads just go over the network),
until the pool drops below --low percent. A self-service `scratch-restore` pulls a
file back to fast local storage.

FAIL-CLOSED BY CONSTRUCTION — this is the whole point of writing it carefully:
a local file is only ever unlinked AFTER its NFS copy is fully written, fsynced,
and verified (size + full sha256). If the cold area is not mounted, or any copy/
verify step fails, the local file is left exactly as it was. We never trust a
half-written cold copy. Run as root (the NFS export is no_root_squash) so the cold
copy preserves each file's owner/group/mode.

The krg.scratch overflow systemd timer invokes this; it is safe to run by hand,
and --dry-run reports what it WOULD move without touching anything.
"""
import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import time

COPY_CHUNK = 8 * 1024 * 1024  # 8 MiB streaming copy/hash buffer
ARCHIVE_DIR = ".scratch-overflow"  # per-scratch state dir (manifest), root-owned
NOTE_NAME = "WHERE-IS-MY-DATA.txt"  # breadcrumb dropped at the scratch root


def log(msg):
    print(f"scratch-overflow: {msg}", flush=True)


def die(msg, code=1):
    log(f"ERROR: {msg}")
    sys.exit(code)


def pool_bytes(zpool, pool):
    """(size, alloc, free) in bytes for the pool, via `zpool list -Hp`."""
    r = subprocess.run(
        [zpool, "list", "-Hp", "-o", "size,alloc,free", pool],
        capture_output=True, text=True)
    if r.returncode != 0:
        die(f"`zpool list {pool}` failed: {r.stderr.strip()}")
    try:
        size, alloc, free = (int(x) for x in r.stdout.split())
    except ValueError:
        die(f"could not parse `zpool list` output: {r.stdout!r}")
    return size, alloc, free


def capacity_pct(size, free):
    if size <= 0:
        return 0.0
    return 100.0 * (size - free) / size


def copy_and_hash(src, dst):
    """Stream src -> dst computing src's sha256 in one pass. Returns (sha, nbytes)."""
    h = hashlib.sha256()
    n = 0
    with open(src, "rb") as fi, open(dst, "wb") as fo:
        while True:
            buf = fi.read(COPY_CHUNK)
            if not buf:
                break
            fo.write(buf)
            h.update(buf)
            n += len(buf)
        fo.flush()
        os.fsync(fo.fileno())
    return h.hexdigest(), n


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for buf in iter(lambda: f.read(COPY_CHUNK), b""):
            h.update(buf)
    return h.hexdigest()


def fsync_dir(path):
    fd = os.open(path, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def gather_candidates(scratch, min_atime, skip_prefixes):
    """Regular, non-symlink files under scratch not accessed since min_atime."""
    cands = []
    for root, dirs, files in os.walk(scratch, topdown=True):
        # never descend into the state dir
        dirs[:] = [d for d in dirs if os.path.join(root, d) + os.sep
                   not in skip_prefixes]
        for name in files:
            p = os.path.join(root, name)
            if any(p.startswith(pref) for pref in skip_prefixes):
                continue
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if not stat.S_ISREG(st.st_mode):  # symlinks/dirs/sockets -> skip
                continue
            if st.st_size == 0:
                continue
            if st.st_atime > min_atime:  # recently accessed -> too hot to move
                continue
            cands.append((st.st_atime, st.st_size, p))
    # coldest first; for equal atime, bigger first (frees space in fewer moves)
    cands.sort(key=lambda t: (t[0], -t[1]))
    return cands


def archive_one(path, scratch, cold, manifest_fp, dry_run):
    """Copy path -> cold, verify, then atomically replace path with a symlink.

    Returns bytes freed (the file size) on success, 0 on skip/failure. NEVER
    unlinks the local file unless the cold copy verified.
    """
    rel = os.path.relpath(path, scratch)
    dest = os.path.join(cold, rel)
    try:
        st = os.stat(path)  # re-stat (TOCTOU): the walk may be stale
    except OSError:
        return 0
    size = st.st_size

    if dry_run:
        log(f"would archive {rel} ({size} bytes) -> {dest}")
        return size

    part = dest + ".part"
    try:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        src_sha, nbytes = copy_and_hash(path, part)
        if nbytes != size:
            # source changed under us mid-copy — bail, leave local untouched
            os.unlink(part)
            log(f"skip {rel}: size changed during copy ({size}->{nbytes})")
            return 0
        # verify the cold copy independently by re-reading it
        if sha256_of(part) != src_sha:
            os.unlink(part)
            log(f"skip {rel}: checksum mismatch after copy (NOT removed locally)")
            return 0
        # preserve owner/group (root + no_root_squash) and mode/times
        os.chown(part, st.st_uid, st.st_gid)
        shutil.copystat(path, part)
        os.replace(part, dest)  # atomic publish of the verified cold copy
        fsync_dir(os.path.dirname(dest))
    except OSError as e:
        # any failure: clean the partial, leave the local file in place
        try:
            if os.path.exists(part):
                os.unlink(part)
        except OSError:
            pass
        log(f"skip {rel}: {e} (local file left intact)")
        return 0

    # cold copy is durable + verified — now swap the local file for a symlink.
    link_tmp = path + ".scratch-archived"
    try:
        if os.path.lexists(link_tmp):
            os.unlink(link_tmp)
        os.symlink(dest, link_tmp)
        os.replace(link_tmp, path)  # atomically frees the local file's blocks
    except OSError as e:
        try:
            if os.path.lexists(link_tmp):
                os.unlink(link_tmp)
        except OSError:
            pass
        log(f"archived {rel} to NFS but FAILED to swap symlink: {e} "
            f"(cold copy kept at {dest}; local file intact)")
        return 0

    manifest_fp.write(json.dumps({
        "ts": int(time.time()),
        "path": path,
        "dest": dest,
        "size": size,
        "sha256": src_sha,
        "atime": int(st.st_atime),
    }) + "\n")
    manifest_fp.flush()
    log(f"archived {rel} ({size} bytes) -> {dest}")
    return size


NOTE_TEXT = """\
Some files under this scratch directory have been moved to network storage (NFS)
to free up fast local space. They are the files that had not been read recently.

A moved file now appears as a SYMLINK pointing into {cold}.
Reading it still works exactly as before — the data is just served over the
network, so it is slower. Nothing has been lost.

To pull a file (or a whole directory) back to fast local storage:

    scratch-restore PATH [PATH ...]

Anything you are actively using will stay local; only cold files get moved.
This is automatic and reversible — you never need to ask an admin.
"""


def main():
    ap = argparse.ArgumentParser(description="Demote cold /scratch files to NFS.")
    ap.add_argument("--pool", required=True, help="ZFS pool to measure (e.g. scratchpool)")
    ap.add_argument("--scratch", required=True, help="scratch mountpoint (e.g. /scratch/krg)")
    ap.add_argument("--cold", required=True, help="cold NFS mountpoint (e.g. /srv/scratch-cold/krg)")
    ap.add_argument("--high", type=float, default=85.0, help="start moving above this pool %% full")
    ap.add_argument("--low", type=float, default=75.0, help="stop moving below this pool %% full")
    ap.add_argument("--min-age-days", type=float, default=14.0,
                    help="never move a file accessed within this many days")
    ap.add_argument("--zpool", default="zpool", help="zpool binary (PATH by default)")
    ap.add_argument("--dry-run", action="store_true", help="report only; touch nothing")
    args = ap.parse_args()

    # FAIL-CLOSED: refuse to run unless both ends are real mountpoints. If the cold
    # NFS area is not mounted we must NOT move anything (and the systemd unit also
    # guards this via RequiresMountsFor). If scratch isn't mounted there's nothing
    # to do and we must not walk the bare mountpoint dir.
    if not os.path.ismount(args.scratch):
        log(f"{args.scratch} is not mounted; nothing to do")
        return 0
    if not os.path.ismount(args.cold):
        die(f"cold area {args.cold} is not mounted — refusing to archive (fail-closed)")
    if not (0 < args.low < args.high <= 100):
        die(f"need 0 < low ({args.low}) < high ({args.high}) <= 100")

    size, alloc, free = pool_bytes(args.zpool, args.pool)
    pct = capacity_pct(size, free)
    log(f"pool {args.pool}: {pct:.1f}% full (high={args.high} low={args.low})")
    if pct < args.high:
        log("below high-water mark; nothing to do")
        return 0

    # bytes to free to reach the low-water mark
    target_free = size * (1.0 - args.low / 100.0)
    to_free = max(0, int(target_free - free))
    log(f"need to free ~{to_free} bytes to reach {args.low}%")

    state_dir = os.path.join(args.scratch, ARCHIVE_DIR)
    skip_prefixes = {state_dir + os.sep, os.path.join(args.scratch, NOTE_NAME)}
    min_atime = time.time() - args.min_age_days * 86400.0
    cands = gather_candidates(args.scratch, min_atime, skip_prefixes)
    if not cands:
        log("no eligible cold files (all too recent or already archived)")
        return 0

    if args.dry_run:
        manifest_fp = open(os.devnull, "w")
    else:
        os.makedirs(state_dir, exist_ok=True)
        os.chmod(state_dir, 0o750)
        manifest_fp = open(os.path.join(state_dir, "manifest.jsonl"), "a")

    freed = 0
    moved = 0
    try:
        for _atime, _size, path in cands:
            if freed >= to_free:
                break
            got = archive_one(path, args.scratch, args.cold, manifest_fp, args.dry_run)
            if got:
                freed += got
                moved += 1
    finally:
        manifest_fp.close()

    if not args.dry_run and moved:
        try:
            with open(os.path.join(args.scratch, NOTE_NAME), "w") as f:
                f.write(NOTE_TEXT.format(cold=args.cold))
        except OSError:
            pass
        size, alloc, free = pool_bytes(args.zpool, args.pool)
        log(f"done: moved {moved} files, freed ~{freed} bytes; "
            f"pool now {capacity_pct(size, free):.1f}% full")
    else:
        log(f"done: {'would free' if args.dry_run else 'freed'} ~{freed} bytes "
            f"across {moved} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
