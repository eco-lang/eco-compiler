"""Round 2, A3: does eco-lab/tensor place every op's operands and results on the GPU or the host as
MAX's own Python API does? Learns, per op name, which operand and result positions carry `gpu:` from
MAX's graphs (an inventory dump with generic forms), then checks every op in our GPU graphs.

    compare_gpu_ir.py INVENTORY.txt OURS.mlir ...
"""
import re
import sys


def split_types(text):
    """Top-level comma-separated types: commas inside <>, {} or () do not split."""
    out, depth, cur = [], 0, ""
    for ch in text:
        if ch in "<{(":
            depth += 1
        elif ch in ">})":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


OP = re.compile(r'^\s*(?:%\S+(?:, %\S+)* = )?"([\w.]+)"\(.*\)\s*(?:<\{.*\}>\s*)?(?:\{.*\}\s*)?: \((.*)\) -> (.*)$')


def ops(text):
    for line in text.splitlines():
        m = OP.match(line)
        if not m:
            continue
        name, ins, outs = m.group(1), m.group(2), m.group(3).strip()
        if outs.startswith("(") and outs.endswith(")"):
            outs = outs[1:-1]
        yield name, tuple("gpu:" in t for t in split_types(ins)), tuple("gpu:" in t for t in split_types(outs))


def generic_sections(dump):
    parts = dump.split("--- generic:")
    return [p.split("=" * 20)[0] for p in parts[1:]]


# constants and shapes are placed by what they feed, not by their op name
SKIP = {"mo.constant", "mo.output", "mo.chain.create", "rmo.shape_to_tensor", "mo.graph", "builtin.module"}

# operands of a variadic op all have one placement: compare that, not the arity
VARIADIC = {"rmo.concat", "mo.yield"}


def normal(name, ins, outs):
    return (tuple(sorted(set(ins))), outs) if name in VARIADIC else (ins, outs)


max_patterns = {}
for section in generic_sections(open(sys.argv[1]).read()):
    for name, ins, outs in ops(section):
        if name not in SKIP:
            max_patterns.setdefault(name, set()).add(normal(name, ins, outs))

checked, unknown, bad = 0, set(), []
for path in sys.argv[2:]:
    for name, ins, outs in ops(open(path).read()):
        if name in SKIP:
            continue
        if name not in max_patterns:
            unknown.add(name)
            continue
        checked += 1
        if normal(name, ins, outs) not in max_patterns[name]:
            bad.append(f"{path.split('/')[-1]}: {name}: ours {ins} -> {outs}, MAX {sorted(max_patterns[name])}")
for b in bad[:20]:
    print("MISPLACED", b)
print(f"gpu placement: {checked} ops checked against MAX's ({len(max_patterns)} op names in the inventory), "
      f"{len(bad)} misplaced; not in the inventory: {', '.join(sorted(unknown)) or 'none'}")
sys.exit(1 if bad else 0)
