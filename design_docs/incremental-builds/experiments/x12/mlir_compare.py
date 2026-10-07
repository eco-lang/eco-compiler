#!/usr/bin/env python3
"""Ground-truth check of the census fingerprints against the emitted (text) MLIR.

Usage: mlir_compare.py <base.mlir> <base.tsv> <edit.mlir> <edit.tsv> [out.json]

Splits each text MLIR module into top-level ops, groups them per spec
(func + its __eco_caf global + the lambda funcs it owns), and compares baseline
vs edit two ways:
  raw  : by symbol name, op text byte-identical (today's identity);
  norm : by census stable key, after renaming spec symbols to stable keys,
         lambda symbols to (owner key, ordinal) and `_tail_<n>` to ordinals.
Then reports, per stable key, agreement between 'norm MLIR changed' and
'census fp changed'.
"""
import sys, re, json, hashlib, collections
from census_lib import Census

SPEC_RE = re.compile(r"([A-Za-z0-9_]+?)_\$_(\d+)")
LAM_RE = re.compile(r"\b([A-Za-z0-9_]+?_lambda_\d+|_tail_[A-Za-z0-9_]*?_\d+)(?![0-9]|_[0-9])")
SPEC_SYM = re.compile(r"^(?:__eco_caf\$)?([A-Za-z0-9_]+?_\$_(\d+))(\$.*)?$")
OWNED_SYM = re.compile(r"^([A-Za-z0-9_]+?_lambda_\d+|_tail_[A-Za-z0-9_]*?_\d+)(\$.*)?$")
SYM_RE = re.compile(r'sym_name = "([^"]+)"')


def parse_ops(path):
    ops = []  # (sym or None, text)
    cur = []
    with open(path) as f:
        for line in f:
            if line.startswith('  "') and not cur:
                cur = [line]
                if line.rstrip().endswith("({"):
                    continue
                m = SYM_RE.search(line)
                ops.append((m.group(1) if m else None, line))
                cur = []
            elif cur:
                cur.append(line)
                if line.startswith("  })"):
                    m = SYM_RE.search(line)
                    ops.append((m.group(1) if m else None, "".join(cur)))
                    cur = []
    return ops


def h(s):
    return hashlib.sha1(s.encode()).hexdigest()[:16]


def group(path, census):
    ops = parse_ops(path)
    sid_key = {sid: s.key for sid, s in census.specs.items()}
    keyh = {sid: "K" + h(k) for sid, k in sid_key.items()}
    by_sym = {}
    for sym, text in ops:
        if sym:
            by_sym[sym] = text
    # spec symbol -> sid
    spec_ops = {}
    owned_ops = collections.defaultdict(list)
    for sym in by_sym:
        m = SPEC_SYM.match(sym)
        if m and int(m.group(2)) in sid_key:
            spec_ops.setdefault(int(m.group(2)), []).append(sym)
            continue
        m = OWNED_SYM.match(sym)
        if m:
            owned_ops[m.group(1)].append(sym)
    # lambda ownership: BFS from spec ops in sid order
    lam_name = {}
    lam_owner = {}
    queue = collections.deque()
    for sid in sorted(spec_ops):
        for sym in sorted(spec_ops[sid]):
            queue.append((sid, keyh[sid], by_sym[sym]))
    while queue:
        sid, prefix, text = queue.popleft()
        ords = 0
        for lam in LAM_RE.findall(text):
            if lam not in lam_name and lam in owned_ops:
                lam_name[lam] = f"{prefix}/L{ords}"
                lam_owner[lam] = sid
                ords += 1
                for osym in sorted(owned_ops[lam]):
                    queue.append((sid, lam_name[lam], by_sym[osym]))

    def norm(text):
        text = SPEC_RE.sub(lambda m: keyh.get(int(m.group(2)), m.group(0)), text)
        return LAM_RE.sub(lambda m: lam_name.get(m.group(1), "LAM?"), text)

    groups_raw = collections.defaultdict(list)   # sym-based (today's identity)
    groups_norm = collections.defaultdict(list)  # stable key
    unowned = 0
    for sym, text in ops:
        if sym is None:
            continue
        m = SPEC_SYM.match(sym)
        mo = OWNED_SYM.match(sym)
        if m and int(m.group(2)) in sid_key:
            sid = int(m.group(2))
        elif mo and mo.group(1) in lam_owner:
            sid = lam_owner[mo.group(1)]
        else:
            unowned += 1
            groups_norm["<other>:" + sym].append(norm(text))
            groups_raw["<other>:" + sym].append(text)
            continue
        groups_norm[sid_key[sid]].append(norm(text))
        groups_raw[census.specs[sid].sym].append(text)
    return ({k: h("".join(sorted(v))) for k, v in groups_norm.items()},
            {k: h("".join(sorted(v))) for k, v in groups_raw.items()},
            {"ops": len(ops), "lambdas": len(lam_name), "unowned_ops": unowned}, by_sym)


bm, bc, em, ec = sys.argv[1:5]
bcen, ecen = Census(bc), Census(ec)
bn, br, bstat, _ = group(bm, bcen)
en, er, estat, _ = group(em, ecen)
keys = set(bn) | set(en)
mlir_dirty = {k for k in keys if bn.get(k) != en.get(k)}
raw_dirty = {k for k in set(br) | set(er) if br.get(k) != er.get(k)}
spec_keys = {k for k in keys if not k.startswith("<other>:")}
fp_dirty = set()
for k in set(bcen.by_key) | set(ecen.by_key):
    a, b = bcen.by_key.get(k), ecen.by_key.get(k)
    if a is None or b is None or a.fp != b.fp:
        fp_dirty.add(k)
fpn_dirty = set()
for k in set(bcen.by_key) | set(ecen.by_key):
    a, b = bcen.by_key.get(k), ecen.by_key.get(k)
    if a is None or b is None or a.fpn != b.fpn:
        fpn_dirty.add(k)
md = mlir_dirty & spec_keys
res = {
    "base": bstat, "edit": estat,
    "mlir_norm_dirty_spec_groups": len(md),
    "mlir_norm_dirty_other_ops": len(mlir_dirty - spec_keys),
    "mlir_raw_dirty_symbol_groups": len(raw_dirty),
    "census_fp_dirty": len(fp_dirty), "census_fpn_dirty": len(fpn_dirty),
    "both": len(md & fp_dirty), "mlir_only": len(md - fpn_dirty), "fp_only": len(fp_dirty - md),
    "mlir_only_vs_fp": len(md - fp_dirty),
    "sample_mlir_only": sorted(md - fpn_dirty)[:15],
    "sample_fp_only": sorted(fp_dirty - md)[:15],
    "sample_other_dirty": sorted(mlir_dirty - spec_keys)[:15],
    "dirty_modules_mlir_norm": len({(ecen.by_key.get(k) or bcen.by_key.get(k)).pkg + ":" + (ecen.by_key.get(k) or bcen.by_key.get(k)).mod for k in md}),
}
print(json.dumps(res, indent=1))
if len(sys.argv) > 5:
    json.dump(res, open(sys.argv[5], "w"), indent=1)
