#!/bin/sh
# Every eco-kernel export runs under ECO_KERNEL_GUARD (KernelExports.h). A C++ exception (std::bad_alloc from a
# std::string or vector, a std::runtime_error from a helper) that leaves an `extern "C"` function is undefined
# behaviour and in practice ends in std::terminate with no `[eco-runtime] FATAL` line. The escape itself needs
# allocation fault injection, which has no hook, so this checks coverage.
#
# Every `Eco_Kernel_*` function DEFINITION in eco-kernel-cpp/src/eco-kernel/*Exports.cpp must have a body that is
# one `ECO_KERNEL_GUARD(...)` statement, or carry a `// no-guard: <reason>` waiver on the line before it or inside
# its body. Exit 0 = every export guarded or waived, 1 = some are not.
root=${1:-.}
dir="$root/eco-kernel-cpp/src/eco-kernel"
[ -d "$dir" ] || { echo "no $dir"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found"; exit 2; }
python3 - "$dir" <<'PY'
import glob, os, re, sys
d = sys.argv[1]
defn = re.compile(r'^[A-Za-z_][\w:<>\s\*&]*?\b(Eco_Kernel_\w+)\s*\(([^;{]*?)\)\s*\{', re.M | re.S)
missing = []
for path in sorted(glob.glob(os.path.join(d, '*Exports.cpp'))):
    src = open(path).read()
    for m in defn.finditer(src):
        name = m.group(1)
        i = m.end()          # just after '{'
        depth = 1
        j = i
        while j < len(src) and depth:
            c = src[j]
            if c == '{': depth += 1
            elif c == '}': depth -= 1
            j += 1
        body = src[i:j - 1]
        line = src.count('\n', 0, m.start()) + 1
        prev = src[:m.start()].rstrip('\n').rsplit('\n', 1)[-1]
        # Strip comments, then the body must start with ECO_KERNEL_GUARD.
        code = re.sub(r'//[^\n]*', '', body).strip()
        if code.startswith('ECO_KERNEL_GUARD'):
            continue
        if 'no-guard:' in prev or 'no-guard:' in body:
            continue
        missing.append((os.path.basename(path), line, name))
for f, line, name in missing:
    print(f"unguarded export: {name} ({f}:{line})")
if missing:
    files = sorted({f for f, _, _ in missing})
    print(f"{len(missing)} unguarded export(s) in: {', '.join(files)}")
sys.exit(1 if missing else 0)
PY
