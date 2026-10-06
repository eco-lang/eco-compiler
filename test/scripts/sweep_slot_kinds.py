#!/usr/bin/env python3
"""Phase 3D fixture sweep (plans/wide-object-tail-kind-words-phase-3.md, 3D.4).

Rewrites the old u64 kind bitmaps on eco.construct.custom / eco.construct.record /
eco.papCreate / eco.papExtend / eco.papCreateGroup / eco.to_heap into `slot_kinds =
array<i8: ...>` in every test/codegen/*.mlir fixture. Tuple2/Tuple3/list attributes are untouched.

Per op occurrence it:
  1. finds the op's attribute dict and its trailing functional type `: (T0, T1, ...) -> R`;
  2. computes the slot count S (custom: `size`; record: `field_count`; papCreate: `num_captured`;
     papExtend: #operands - 1 - eco.gc_roots_count);
  3. derives kinds from operand types 0..S-1 (papExtend: 1..S): i64->1, f64->2, i16->3, else 0;
  4. decodes the old bitmap and REPORTS any disagreement (a fixture that was deliberately
     inconsistent is a negative test and must be rewritten by hand, never silently);
  5. replaces `<attr> = N[ : i64]` with `slot_kinds = array<i8: k0, ..., kS-1>`
     (`array<i8>` when S == 0), unless the dict already has slot_kinds (then the old attr is
     just deleted).
Comment lines are never edited; they are listed for manual rewording.

A second pass (--add-missing, run after the bitmap rewrite) gives every
construct.custom / construct.record / papCreate / papExtend occurrence that has no
`slot_kinds` one derived from its operand types (the old attributes were optional and
DefaultValued, so many fixtures carried none; from Phase 3D slot_kinds is required).

Usage:  sweep_slot_kinds.py [--write] [--add-missing] FILE...   (default: dry run, prints a report)
Exit 1 if any disagreement or unparsable occurrence is found.
"""
import re
import sys

OPS = {
    "eco.construct.custom": ("unboxed_bitmap", "size", 0),
    "eco.construct.record": ("unboxed_bitmap", "field_count", 0),
    "eco.papCreate": ("unboxed_bitmap", "num_captured", 0),
    "eco.papExtend": ("newargs_unboxed_bitmap", None, 1),
    "eco.to_heap": ("unboxed_bitmap", None, None),   # attr only deleted (lowering derives)
}
KIND = {"i64": 1, "f64": 2, "i16": 3}
OP_RE = re.compile(r'"?(eco\.[A-Za-z_.0-9]+)"?')


def split_types(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "<(":
            depth += 1
        elif ch in ">)":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def find_dict(txt, start):
    """Return (open, close) indices of the first top-level {...} at/after start."""
    i = txt.find("{", start)
    if i < 0:
        return None
    depth = 0
    for j in range(i, len(txt)):
        if txt[j] == "{":
            depth += 1
        elif txt[j] == "}":
            depth -= 1
            if depth == 0:
                return i, j
    return None


def operand_types(txt, after):
    m = re.compile(r":\s*\(([^)]*(?:\([^)]*\)[^)]*)*)\)\s*->").search(txt, after)
    return split_types(m.group(1)) if m else None


def int_attr(d, name):
    m = re.search(r"\b" + re.escape(name) + r"\s*=\s*(-?\d+)", d)
    return int(m.group(1)) if m else None


def process(path, write):
    txt = open(path).read()
    problems, edits, comments = [], [], []
    for m in re.finditer(r"\b(unboxed_bitmaps?|newargs_unboxed_bitmap)\s*=\s*(-?\d+|\[[^\]]*\])(\s*:\s*i64)?", txt):
        ls = txt.rfind("\n", 0, m.start()) + 1
        line = txt[ls:txt.find("\n", m.start())]
        if line.lstrip().startswith("//"):
            comments.append((txt.count("\n", 0, m.start()) + 1, line.strip()))
            continue
        ops = list(OP_RE.finditer(txt, 0, m.start()))
        op = ops[-1].group(1) if ops else "?"
        lineno = txt.count("\n", 0, m.start()) + 1
        if op not in OPS and op != "eco.papCreateGroup":
            continue  # tuple2/tuple3 etc. keep their attribute
        if op == "eco.papCreateGroup":
            problems.append((lineno, op, "papCreateGroup: rewrite by hand (per-sibling ArrayAttr)"))
            continue
        attr, count_attr, skip = OPS[op]
        if m.group(1) != attr:
            problems.append((lineno, op, f"unexpected attribute {m.group(1)}"))
            continue
        dspan = find_dict(txt, ops[-1].end())
        d = txt[dspan[0]:dspan[1] + 1] if dspan else ""
        if op == "eco.to_heap":
            edits.append((m.start(), m.end(), None))
            continue
        tys = operand_types(txt, dspan[1] if dspan else m.end())
        if tys is None:
            problems.append((lineno, op, "no functional type found"))
            continue
        if count_attr:
            n = int_attr(d, count_attr)
        else:
            roots = int_attr(d, "eco.gc_roots_count") or 0
            n = len(tys) - 1 - roots
        if n is None or n < 0:
            problems.append((lineno, op, f"slot count unknown ({count_attr})"))
            continue
        slot_tys = tys[skip:skip + n]
        kinds = [KIND.get(t, 0) for t in slot_tys]
        old = int(m.group(2))
        decoded = [(old >> (2 * i)) & 3 for i in range(n)]
        if decoded != kinds or (n < 32 and old >> (2 * n)):
            problems.append((lineno, op, f"bitmap {old} decodes to {decoded}, operand types give {kinds}"))
            continue
        new = "slot_kinds = array<i8" + (": " + ", ".join(map(str, kinds)) if kinds else "") + ">"
        edits.append((m.start(), m.end(), None if "slot_kinds" in d else new))
    if write and not problems:
        for s, e, new in sorted(edits, reverse=True):
            if new is None:
                # delete the attribute and one adjacent comma
                pre = txt[:s].rstrip()
                if pre.endswith(","):
                    txt = pre[:-1] + txt[e:]
                else:
                    post = txt[e:]
                    txt = txt[:s] + re.sub(r"^\s*,\s*", "", post, count=1)
            else:
                txt = txt[:s] + new + txt[e:]
        open(path, "w").write(txt)
    return problems, edits, comments


ADD_OPS = {
    "eco.construct.custom": ("size", 0),
    "eco.construct.record": ("field_count", 0),
    "eco.papCreate": ("num_captured", 0),
    "eco.papExtend": (None, 1),
}
ADD_RE = re.compile(r'"?(eco\.(?:construct\.custom|construct\.record|papCreateGroup|papCreate|papExtend))"?(?=[\s(])')


def match_paren(txt, i):
    """txt[i] == '(' -> index of the matching ')'."""
    depth = 0
    for j in range(i, len(txt)):
        if txt[j] == "(":
            depth += 1
        elif txt[j] == ")":
            depth -= 1
            if depth == 0:
                return j
    return -1


def add_missing(path, write):
    txt = open(path).read()
    problems, edits = [], []
    for m in ADD_RE.finditer(txt):
        op = m.group(1)
        ls = txt.rfind("\n", 0, m.start()) + 1
        if txt[ls:m.start()].lstrip().startswith("//") or op not in ADD_OPS:
            continue
        lineno = txt.count("\n", 0, m.start()) + 1
        p0 = txt.find("(", m.end())
        p1 = match_paren(txt, p0) if p0 >= 0 else -1
        if p1 < 0:
            problems.append((lineno, op, "no operand list"))
            continue
        k = p1 + 1
        while k < len(txt) and txt[k] in " \t\n":
            k += 1
        has_dict = k < len(txt) and txt[k] == "{"
        if has_dict:
            dspan = find_dict(txt, k)
            d = txt[dspan[0]:dspan[1] + 1]
            after = dspan[1]
        else:
            d, after = "", p1
        if "slot_kinds" in d:
            continue
        tys = operand_types(txt, after)
        if tys is None:
            problems.append((lineno, op, "no functional type found"))
            continue
        count_attr, skip = ADD_OPS[op]
        if count_attr:
            n = int_attr(d, count_attr)
        else:
            n = len(tys) - 1 - (int_attr(d, "eco.gc_roots_count") or 0)
        if n is None or n < 0:
            problems.append((lineno, op, "slot count unknown"))
            continue
        kinds = [KIND.get(t, 0) for t in tys[skip:skip + n]]
        sk = "slot_kinds = array<i8" + (": " + ", ".join(map(str, kinds)) if kinds else "") + ">"
        if has_dict:
            inner = d[1:-1].strip()
            new = "{" + sk + "}" if not inner else "{" + sk + ", " + d[1:].lstrip()
            edits.append((dspan[0], dspan[1] + 1, new))
        else:
            edits.append((p1 + 1, p1 + 1, " {" + sk + "}"))
    if write and not problems:
        for s0, e0, new in sorted(edits, reverse=True):
            txt = txt[:s0] + new + txt[e0:]
        open(path, "w").write(txt)
    return problems, edits


def main():
    write = "--write" in sys.argv
    files = [a for a in sys.argv[1:] if not a.startswith("--")]
    bad = 0
    if "--add-missing" in sys.argv:
        for f in files:
            problems, edits = add_missing(f, write)
            if edits or problems:
                print(f"{f}: {len(edits)} slot_kinds added, {len(problems)} problem(s)")
            for ln, op, why in problems:
                print(f"  PROBLEM {f}:{ln} {op}: {why}")
                bad += 1
        sys.exit(1 if bad else 0)
    for f in files:
        problems, edits, comments = process(f, write)
        if edits or problems or comments:
            print(f"{f}: {len(edits)} rewrite(s), {len(problems)} problem(s), {len(comments)} comment mention(s)")
        for ln, op, why in problems:
            print(f"  PROBLEM {f}:{ln} {op}: {why}")
            bad += 1
        for ln, text in comments:
            print(f"  COMMENT {f}:{ln}: {text[:100]}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
