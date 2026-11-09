"""Rewrite a generic-form mo file so op properties `<{...}>` become ordinary attributes `{...}`.

Bytecode written by an MLIR that has no `mo` dialect (eco's LLVM 21 `mlir-opt`) stores an unknown
op's properties as one dictionary, which MAX's reader rejects; as plain attributes MAX rebuilds the
properties itself.

    python3 props_to_attrs.py IN.generic.mlir OUT.generic.mlir
"""
import re
import sys

src, dst = sys.argv[1:3]
out, pending = [], []
for line in open(src).read().split("\n"):
    m = re.search(r" <\{(.*)\}>", line)
    if m:
        props = m.group(1)
        line = line[: m.start()] + line[m.end():]
        if line.rstrip().endswith("({"):  # a region op: its attributes come on the closing line
            out.append(line)
            pending.append(props)
            continue
        i = line.rfind(" : ")
        line = line[:i] + " {" + props + "}" + line[i:]
    elif pending and line.strip().startswith("}) {"):
        line = line.replace("}) {", "}) {" + pending.pop() + ", ", 1)
    out.append(line)
open(dst, "w").write("\n".join(out))
