#!/usr/bin/env python3
"""Wide-object census over TEXT MLIR (ecoc --emit=mlir FILE > out.txt 2>&1).

Reports (plans/wide-object-tail-kind-words-phase-0.md, step 0.4):
  papCreate  : arity histogram buckets <=20, 21..25, 26..63, >63; num_captured > 25
  papExtend  : newarg count > 25
  construct.custom : size > 24
  construct.record : field_count > 26 with an eco.box-defined operand at index >= 26
                     (a primitive boxed by the 26-slot record cap)
"""
import re, sys, collections
text = open(sys.argv[1]).read()
c = collections.Counter()
for m in re.finditer(r'"eco\.papCreate"\(([^)]*)\)[^{<]*[{<]+([^}>]*)', text):
    attrs = m.group(2)
    a = re.search(r'\barity = (\d+)', attrs); n = re.search(r'num_captured = (\d+)', attrs)
    if not a: continue
    ar = int(a.group(1)); nc = int(n.group(1)) if n else 0
    c['papCreate total'] += 1
    c['papCreate arity <=20' if ar <= 20 else 'papCreate arity 21..25' if ar <= 25 else
      'papCreate arity 26..63' if ar <= 63 else 'papCreate arity >63'] += 1
    if nc > 25: c['papCreate num_captured >25'] += 1
    if ar > 25:
        f = re.search(r'function = (@[\w$#.]+)', attrs)
        print(f"  wide papCreate: arity={ar} num_captured={nc} {f.group(1) if f else '?'}")
for m in re.finditer(r'"eco\.papExtend"\(([^)]*)\)', text):
    ops = [o for o in m.group(1).split(',') if o.strip()]
    c['papExtend total'] += 1
    if len(ops) - 1 > 25: c['papExtend operands >25 (incl. gc roots)'] += 1
for m in re.finditer(r'"?eco\.construct\.custom"?\(([^)]*)\)[^{]*\{([^}]*)\}', text):
    s = re.search(r'\bsize = (\d+)', m.group(2))
    if s and int(s.group(1)) > 24: c['construct.custom size >24'] += 1
for fn in re.split(r'\n\s*func\.func ', text):          # SSA names are per function
    box_defs = set(re.findall(r'(%[\w#]+) = "?eco\.box"?', fn))
    for m in re.finditer(r'"?eco\.construct\.record"?\(([^)]*)\)[^{]*\{([^}]*)\}', fn):
        fc = re.search(r'field_count = (\d+)', m.group(2))
        if not fc: continue
        n = int(fc.group(1)); ops = [o.strip() for o in m.group(1).split(',')]
        if n > 26:
            c['construct.record field_count >26'] += 1
            if any(o in box_defs for o in ops[26:n]): c['construct.record boxed primitive at >=26'] += 1
for k in sorted(c): print(f"{k}: {c[k]}")
