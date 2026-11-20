#!/usr/bin/env python3
"""List the single-constructor types declared in Elm modules that import a kernel module.

Such a type is either a kernel-opaque type (a dummy constructor whose runtime values the kernel
produces, e.g. `type Bytes = Bytes`, `type JsArray a = JsArray a`) or a wrapper the kernel may
build (e.g. `Time.Posix`). Compiler.IR.Kernel.Visibility must list every one of them in
`opaque` or `byName`, or in `checkedSafe` with a reason; this script fails when one is missing.

Usage: check-kernel-opaque.py [--list] PACKAGE_ROOT...   (default: ~/.eco/*/packages, compiler/kernel-overrides)
"""
import os, re, sys, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VIS = os.path.join(ROOT, "compiler/src/Compiler/IR/Kernel/Visibility.elm")

def package_of(path):
    m = re.search(r"/packages/([^/]+)/([^/]+)/[^/]+/src/", path)
    return f"{m.group(1)}/{m.group(2)}" if m else None

def scan(roots):
    found = set()
    for root in roots:
        for path in glob.glob(os.path.join(root, "**/*.elm"), recursive=True):
            pkg = package_of(path)
            if pkg is None:
                continue
            try:
                src = open(path, encoding="utf-8").read()
            except OSError:
                continue
            if not re.search(r"^import\s+(Elm|Eco)\.Kernel\.", src, re.M):
                continue
            mod = re.search(r"^(?:port\s+|effect\s+)?module\s+([\w.]+)", src, re.M)
            if not mod:
                continue
            # `type Name vars = Ctor args` with exactly one constructor (no `|` before the next
            # top-level declaration).
            for m in re.finditer(r"^type\s+(?!alias)(\w+)([^=]*)=(.*?)(?=^\S)", src, re.M | re.S):
                body = re.sub(r"--.*", "", m.group(3))
                body = re.sub(r"\{-.*?-\}", "", body, flags=re.S)
                if "|" in body:
                    continue
                found.add((f"{pkg}:{mod.group(1)}", m.group(1)))
    return found

def listed():
    src = open(VIS, encoding="utf-8").read()
    return set(re.findall(r'\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)', src))

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    roots = args or glob.glob(os.path.expanduser("~/.eco/*/packages"))
    found = scan(roots)
    if "--list" in sys.argv:
        for home, name in sorted(found):
            print(f'( "{home}", "{name}" )')
        return 0
    missing = sorted(found - listed())
    for home, name in missing:
        print(f"missing from Visibility.elm: ( \"{home}\", \"{name}\" )")
    return 1 if missing else 0

if __name__ == "__main__":
    sys.exit(main())
