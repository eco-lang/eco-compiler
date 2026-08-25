#!/usr/bin/env python3
"""Classify multi-member lambda sets as STRUCTURAL or MERGE-INDUCED.

Usage:
    benchmarks/multiset-census.py <off.stderr> <on.stderr>

Reads the `MSET` block that `Monomorphize.renderLssReport` emits under
`ECO_MONO_LSS_REPORT=1` from two arms of ONE corpus, and joins them.

Why this join is valid when a symbol join is not
------------------------------------------------
`MSET` rows are keyed by **ArrowId**, minted by `AssignMVarIds` from the
syntax. It does not depend on any lss flag, so the SAME arrow has the SAME id
in both arms. Symbol names do not (`lambda_N` renumbers when the spec
population shifts — a naive name join across the Run-AE arms reported 1,214
"losses" and 1,199 "gains", all renames). Member IDS are also unstable
(`internMemberKey` assigns in mint order), which is why the rows carry member
KEY strings instead.

The classification
------------------
    structural   k>=2 in BOTH arms      the analysis found genuine alternatives
                                        at this arrow regardless of slot sharing
    merge-induced k>=2 only with sharing ON
                                        the shared slot unioned what per-load
                                        minting kept apart — this is the
                                        population that COSTS dispatch coverage
                                        under a singleton-only consumer
    lost         k>=2 only with sharing OFF
                                        sharing REMOVED members. Expect ~0; a
                                        nonzero count is a soundness smell and
                                        should be investigated, not averaged.

`grew` / `shrank` / `changed` further split the structural rows by whether the
member set itself moved.
"""

import sys
from collections import Counter


def load(path):
    """arrowId -> frozenset(memberKey) for every MSET row."""
    rows = {}
    with open(path, "rb") as fh:
        for raw in fh:
            line = raw.decode("utf-8", "replace").rstrip("\n")
            if not line.startswith("MSET\t"):
                continue
            parts = line.split("\t")
            if len(parts) < 4 or parts[1] == "(none)":
                continue
            rows[int(parts[1])] = frozenset(p for p in parts[3].split("|") if p)
    return rows


def klass(key):
    """The member class a key encodes: l| lambda, g| global, c| ctor, k| kernel.

    A bare numeric key is a RAW source-lambda id: those are minted by
    `Engine.memberIdFor` via `srcLambdaKey` and never enter
    `LssMemberTable.byKey`, so the report cannot name them.
    """
    if "|" in key:
        return key.split("|", 1)[0]
    return "raw" if key.lstrip("?").isdigit() else "?"


def shape(members):
    """A coarse composition label for a set, e.g. 'l+g' or 'l'."""
    return "+".join(sorted({klass(m) for m in members}))


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    off, on = load(sys.argv[1]), load(sys.argv[2])

    both = sorted(set(off) & set(on))
    only_on = sorted(set(on) - set(off))
    only_off = sorted(set(off) - set(on))

    # GUARD. The join is only valid when both arms number ArrowIds the SAME
    # way, which is true for `arrowIdentity` off-vs-on (both mint per
    # occurrence, from a walk that does not depend on the flag) and FALSE the
    # moment the id SOURCE changes — `arrowSolverRoots` allocates over solver
    # roots instead, so every id shifts. The tell is total non-overlap, and it
    # is the same failure a symbol-name join produces (runtime-calls Run AE:
    # 1,214 "losses" and 1,199 "gains", all renames). Refuse rather than
    # report nonsense.
    if off and on and not both:
        print("REFUSING: the two arms share NO arrow ids "
              f"(OFF={len(off)}, ON={len(on)}, overlap=0).")
        print("The ArrowId numbering differs between these arms, so this join is")
        print("meaningless. Valid pairs differ only in `arrowIdentity`; a pair")
        print("differing in `arrowSolverRoots` renumbers every id and cannot be")
        print("joined this way. Compare the aggregate `multisets:` line instead.")
        sys.exit(1)

    same = [a for a in both if off[a] == on[a]]
    grew = [a for a in both if on[a] > off[a]]
    shrank = [a for a in both if on[a] < off[a]]
    changed = [a for a in both if on[a] != off[a] and not (on[a] > off[a] or on[a] < off[a])]

    def mass(arrows, src):
        return sum(len(src[a]) for a in arrows)

    print(f"arrows with |set|>=2   OFF={len(off):>6}   ON={len(on):>6}")
    print()
    print(f"  STRUCTURAL    (both arms)          {len(both):>6}   members {mass(both, on):>7}")
    print(f"      of which identical member sets {len(same):>6}")
    print(f"      grew under sharing             {len(grew):>6}")
    print(f"      shrank under sharing           {len(shrank):>6}")
    print(f"      changed (neither)              {len(changed):>6}")
    print(f"  MERGE-INDUCED (ON only)            {len(only_on):>6}   members {mass(only_on, on):>7}")
    print(f"  LOST          (OFF only)           {len(only_off):>6}   members {mass(only_off, off):>7}"
          + ("   <<< investigate: sharing removed members" if only_off else ""))
    print()

    for name, arrows, src in (("STRUCTURAL", both, on),
                              ("MERGE-INDUCED", only_on, on),
                              ("LOST", only_off, off)):
        if not arrows:
            continue
        print(f"  {name} by |set|:   " +
              " ".join(f"{k}->{v}" for k, v in sorted(Counter(len(src[a]) for a in arrows).items())))
        print(f"  {name} by shape:  " +
              " ".join(f"{k}={v}" for k, v in sorted(Counter(shape(src[a]) for a in arrows).items(),
                                                     key=lambda kv: -kv[1])[:8]))
    print()
    for name, arrows, src in (("STRUCTURAL", both, on), ("MERGE-INDUCED", only_on, on)):
        if not arrows:
            continue
        print(f"  largest {name} sets:")
        for a in sorted(arrows, key=lambda a: -len(src[a]))[:6]:
            print(f"    arrow {a:>7}  k={len(src[a]):<3} {sorted(src[a])}")


main()
