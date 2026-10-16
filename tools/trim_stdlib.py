#!/usr/bin/env python3
"""Trim the Python standard library bundled in the app to the files the reader imports.

    trim_stdlib.py STDLIB_DIR KEEP_FILE

KEEP_FILE lists, one per line, the standard library .py files (relative to STDLIB_DIR) that a run of the app's own workload imported:
reader/stdlib_keep.txt, made by the build's simulator run from `phone_bridge.loaded` (the run writes demo-modules.txt). With no KEEP_FILE
nothing is removed and the build says so, which is how the first measurement is made. Everything else under STDLIB_DIR is removed except
lib-dynload (the extension modules; each is a separate framework file the app already signs) and the few files named in ALWAYS.

ALWAYS is picked, not measured: the reader imports these only when an error has to be printed, which a normal run does not do, and a
missing one would turn a printable error into an ImportError. They are a few small files.
"""
import os
import sys

ALWAYS = {"traceback.py", "linecache.py", "tokenize.py", "token.py", "keyword.py"}


def size(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        total += sum(os.path.getsize(os.path.join(root, f)) for f in files if os.path.exists(os.path.join(root, f)))
    return total


def main(stdlib, keep_file):
    if not os.path.isdir(stdlib):
        print("trim_stdlib: no standard library at %s; nothing to do" % stdlib)
        return 0
    if not os.path.exists(keep_file):
        print("trim_stdlib: no %s; standard library left whole (%.1f MB)" % (keep_file, size(stdlib) / 1e6))
        return 0
    keep = {line.strip() for line in open(keep_file) if line.strip()} | ALWAYS
    before = size(stdlib)
    kept = removed = 0
    for root, dirs, files in os.walk(stdlib, topdown=True):
        rel_root = os.path.relpath(root, stdlib)
        if rel_root == "lib-dynload" or rel_root.startswith("lib-dynload" + os.sep):
            dirs[:] = []
            continue
        for f in files:
            rel = os.path.normpath(os.path.join(rel_root, f))
            if rel in keep:
                kept += 1
            else:
                os.remove(os.path.join(root, f))
                removed += 1
    for root, dirs, files in os.walk(stdlib, topdown=False):
        if root != stdlib and not os.listdir(root):
            os.rmdir(root)
    missing = sorted(k for k in keep if not os.path.exists(os.path.join(stdlib, k)) and k not in ALWAYS)
    print("trim_stdlib: kept %d files, removed %d; %.1f MB -> %.1f MB" % (kept, removed, before / 1e6, size(stdlib) / 1e6))
    if missing:
        print("trim_stdlib: listed but not found (%d): %s" % (len(missing), ", ".join(missing[:10])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
