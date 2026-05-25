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


def restore_one(link, keep_cold, verbose):
    """Restore a single archived symlink. Returns True on a successful restore."""
    if not os.path.islink(link):
        if verbose:
            log(f"skip {link}: not an archived file (not a symlink)")
        return False
    target = os.readlink(link)
    if not os.path.isabs(target):
        target = os.path.join(os.path.dirname(link), target)
    target = os.path.realpath(target)
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
    except OSError as e:
        try:
            if os.path.lexists(part):
                os.unlink(part)
        except OSError:
            pass
        log(f"FAILED {link}: {e} (left as-is)")
        return False

    if not keep_cold:
        try:
            os.unlink(target)
        except OSError as e:
            log(f"restored {link} but could not remove cold copy {target}: {e}")
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
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    restored = 0
    failed = 0
    for p in args.paths:
        if os.path.isdir(p) and not os.path.islink(p):
            for link in walk_links(p):
                if restore_one(link, args.keep_cold, args.verbose):
                    restored += 1
        else:
            if restore_one(p, args.keep_cold, args.verbose):
                restored += 1
            elif os.path.islink(p):
                failed += 1
    log(f"done: {restored} restored, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
