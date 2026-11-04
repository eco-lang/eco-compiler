#!/bin/sh
# No C `bool` at the kernel ABI (REP_ABI_001): a Bool crosses it as an `!eco.value` (the embedded True/False
# HPointer constant, passed as HPtr/uint64_t). The compiler passes the boxed constant word, so a C `bool`
# parameter would read only its low byte. Scans the KernelExports.h headers and every *Exports.cpp of the three
# kernel libraries for `Elm_Kernel_`/`Eco_Kernel_`/`EcoSystem_` declarations naming `bool` in the return type or
# parameters. Exit 0 = clean, 1 = found.
root=${1:-.}
command -v python3 >/dev/null 2>&1 || { echo "python3 not found"; exit 2; }
python3 - "$root" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
files = [os.path.join(root, 'elm-kernel-cpp/src/KernelExports.h'),
         os.path.join(root, 'eco-kernel-cpp/src/eco-kernel/KernelExports.h')]
for sub in ('elm-kernel-cpp/src', 'eco-kernel-cpp/src', 'system-kernel-cpp/src'):
    files += glob.glob(os.path.join(root, sub, '**', '*Exports.cpp'), recursive=True)
files = [f for f in files if os.path.isfile(f)]
if not files:
    print('no export sources found'); sys.exit(2)
# A declaration: start of line, a return type, the export name, its parameter list.
decl = re.compile(r'^[ \t]*((?:[\w:<>\*&]+[ \t]+)+?)\**[ \t]*\b((?:Elm_Kernel|Eco_Kernel|EcoSystem)_\w+)\s*\(([^)]*)\)',
                  re.M)
bad = []
for path in sorted(set(files)):
    src = open(path).read()
    src = re.sub(r'//[^\n]*', '', src)   # comments mention bool in prose
    for m in decl.finditer(src):
        ret, name, params = m.group(1), m.group(2), m.group(3)
        if re.search(r'\breturn\b', ret):
            continue                      # a call, not a declaration
        if re.search(r'\bbool\b', ret) or re.search(r'\bbool\b', params):
            line = src.count('\n', 0, m.start()) + 1
            bad.append(f"{os.path.relpath(path, root)}:{line}: {ret.strip()} {name}({' '.join(params.split())})")
for b in bad:
    print('C bool at the kernel ABI: ' + b)
sys.exit(1 if bad else 0)
PY
