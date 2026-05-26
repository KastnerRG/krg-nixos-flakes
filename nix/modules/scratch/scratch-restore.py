"""scratch-restore — pull an archived /scratch file back to fast local storage.

The overflow job (scratch-overflow) demotes cold files to NFS and leaves a symlink
in their place. This is the self-service inverse: give it the symlink (or a directory
to do every archived file underneath), and it copies the data back from NFS, verifies
it (size + full sha256), and atomically replaces the symlink with the real file. No
admin needed.

Run it as yourself — the restored file ends up owned by you (it was your file). An
admin running it as root preserves the original owner. By default the now-redundant
NFS copy is removed AFTER the local copy is verified (so cold storage doesn't keep
orphans); pass --keep-cold to leave it.
"""
import argparse
import hashlib
import os
import shutil
import sys

COPY_CHUNK = 8 * 1024 * 1024


def log(msg):
    print(f"scratch-restore: {msg}", flush=True)


def copy_and_hash(src, dst):
    # Both ends opened O_NOFOLLOW: a symlink swapped in at either path after our
    # earlier realpath/stat (restore may run as root) is refused, not followed.
    h = hashlib.sha256()
    n = 0
    src_fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW)
    dst_fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(src_fd, "rb") as fi, os.fdopen(dst_fd, "wb") as fo:
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
    try:
        fd = os.open(path, os.O_DIRECTORY)
    except OSError:
        return
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def under_any(path, roots):
    return any(path == r or path.startswith(r + os.sep) for r in roots)


def restore_one(link, allowed_roots, keep_cold, verbose):
    """Restore a single archived symlink. Returns True on a successful restore."""
    if not os.path.islink(link):
        if verbose:
            log(f"skip {link}: not an archived file (not a symlink)")
        return False
    target = os.readlink(link)
    if not os.path.isabs(target):
        target = os.path.join(os.path.dirname(link), target)
    target = os.path.realpath(target)
    # Containment: /scratch is writable by lab members, so a planted symlink could
    # point anywhere. We copy FROM and (by default) unlink the target — running as
    # root that could delete an arbitrary file. Only act on targets that resolve
    # inside a configured cold area.
    if not under_any(target, allowed_roots):
        log(f"REFUSE {link}: target {target} is outside the cold area(s) "
            f"{allowed_roots} — not an archived scratch file (suspicious symlink?)")
        return False
    if not os.path.isfile(target):
        log(f"skip {link}: archive target missing or not a file "
            f"({target}) — is NFS mounted?")
        return False

    tst = os.stat(target)
    part = link + ".scratch-restoring"
    try:
        if os.path.lexists(part):
            os.unlink(part)
        src_sha, n = copy_and_hash(target, part)
        if n != tst.st_size or sha256_of(part) != src_sha:
            os.unlink(part)
            log(f"FAILED {link}: verification mismatch (left as-is)")
            return False
        shutil.copystat(target, part)
        if os.geteuid() == 0:  # admin restore: preserve the original owner
            os.chown(part, tst.st_uid, tst.st_gid)
        os.replace(part, link)  # atomically replace the symlink with the real file
        fsync_dir(os.path.dirname(link))  # make the local rename durable
    except OSError as e:
        try:
            if os.path.lexists(part):
                os.unlink(part)
        except OSError:
            pass
        log(f"FAILED {link}: {e} (left as-is)")
        return False

    if not keep_cold:
        # Only remove the cold copy if it is STILL byte-for-byte what we just restored
        # (guard against a concurrent write to the cold file during the copy). If it
        # changed, keep it and warn rather than risk deleting newer data.
        try:
            tst2 = os.stat(target)
            unchanged = (tst2.st_ino, tst2.st_size, tst2.st_mtime_ns,
                         tst2.st_ctime_ns) == (tst.st_ino, tst.st_size,
                                               tst.st_mtime_ns, tst.st_ctime_ns)
        except OSError:
            unchanged = False
        if unchanged:
            try:
                os.unlink(target)
                fsync_dir(os.path.dirname(target))  # make the cold deletion durable
            except OSError as e:
                log(f"restored {link} but could not remove cold copy {target}: {e}")
        else:
            log(f"restored {link} but cold copy {target} changed during restore — "
                f"kept it (rerun with the file idle to reclaim NFS space)")
    log(f"restored {link} ({tst.st_size} bytes)")
    return True


def walk_links(root):
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            p = os.path.join(dirpath, name)
            if os.path.islink(p):
                yield p


def main():
    ap = argparse.ArgumentParser(
        description="Restore archived /scratch files (symlinks) to local storage.")
    ap.add_argument("paths", nargs="+", help="archived file(s) or directories to restore")
    ap.add_argument("--keep-cold", action="store_true",
                    help="keep the NFS copy after restoring (default: remove it)")
    ap.add_argument("--cold-root", action="append", default=[], metavar="DIR",
                    help="allowed cold-area root a symlink target must resolve under "
                         "(repeatable). Defaults to $SCRATCH_COLD_ROOTS (colon-separated).")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    # Build the set of allowed cold roots (flags + env), realpath'd for comparison.
    roots = list(args.cold_root)
    roots += [r for r in os.environ.get("SCRATCH_COLD_ROOTS", "").split(":") if r]
    allowed_roots = sorted({os.path.realpath(r) for r in roots})
    if not allowed_roots:
        log("no cold-area root configured — set $SCRATCH_COLD_ROOTS or pass "
            "--cold-root DIR (refusing to follow/delete arbitrary symlink targets)")
        return 2

    restored = 0
    failed = 0
    for p in args.paths:
        if os.path.isdir(p) and not os.path.islink(p):
            for link in walk_links(p):
                if restore_one(link, allowed_roots, args.keep_cold, args.verbose):
                    restored += 1
                else:
                    # every link under the dir is an archived file we meant to restore
                    failed += 1
        else:
            if restore_one(p, allowed_roots, args.keep_cold, args.verbose):
                restored += 1
            elif os.path.islink(p):
                failed += 1
    log(f"done: {restored} restored, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
