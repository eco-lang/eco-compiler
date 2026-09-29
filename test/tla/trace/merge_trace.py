#!/usr/bin/env python3
"""Merge a raw TLA+ trace (per-thread event buffers) into one interleaving.

plans/threaded-gc-tla-verification.md §6.3; test/tla/README.md, "Trace validation".

Input: the raw log written by test/tla/trace/TlaTrace.cpp:
    line 1   {"hdr": {...}}
    then     {"t": thread, "s": seq, "ts": ns, "ev": name, <fields>}   (any order)

The merged order must respect:
  1. per-thread order: the sequence numbers "s" of one thread;
  2. publication: an event with "get": k follows every event with "put": k
     (each may be a string or a list of strings);
  3. clocks: events with "clk": c are ordered by their "tick";
  4. modification order: the RMW events of one location ("rmw": loc, "old", "new")
     are chained by value: each one's "old" is the previous one's "new". The
     chain's first "old" is the location's initial value, inferred from the values
     (or given in the header as "locinit": {loc: value});
  5. reads-from: a load ("rd": loc, "val": v) sits after the write that produced v
     and before the next write of loc.
Where these leave the order open, the merger prefers the smaller timestamp "ts"
(a hint only). Where values repeat (ABA), several chains may fit; the merger
backtracks until it finds one that fits every constraint, and uses it.

Output: the merged log that test/tla/common/TraceLog.tla reads:
    line 1   {"hdr": {<input header>, "threads": [...], "tev": {thread: [indices]},
                      "count": N, "counts": {event: N}, "merge": {...}}}
    then     {"i": index, "t": thread, "n": per-thread index, "ev": name, <fields>,
              "vc": {thread: count}, "nxt": next event name on this thread or "",
              "pk": {thread: index of that thread's first event at or after this one, or 0}}

"vc" is the happens-before the log establishes, as a vector clock: e.vc[v] is how
many of thread v's events must precede e (the transitive closure of 1-5, with 4
and 5 as the chosen chain). A trace spec that matches events in log order uses
"i"; one that admits every order the log allows matches event e of thread u
once every thread v has matched e.vc[v] events.

--keep / --keep-file keep only the named events (after the order is computed, so
orderings through dropped events are kept). Integers outside TLC's 32-bit range
become strings.

Usage:
  merge_trace.py RAW -o OUT [--keep ev1,ev2] [--keep-file FILE]
  merge_trace.py --selftest
"""
import argparse
import heapq
import json
import sys
from collections import defaultdict

INT_MAX = 2**31 - 1
RESERVED = ("t", "s", "ts")
OUTPUT_NAMES = ("i", "n", "vc", "nxt", "pk")     # fields the merger adds


class MergeError(Exception):
    pass


def as_list(v):
    if v is None:
        return []
    return list(v) if isinstance(v, list) else [v]


def _no_dups(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise ValueError(f"field {k!r} twice (a hook used a reserved field name?)")
        d[k] = v
    return d


def load_raw(path):
    hdr = None
    events = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line, object_pairs_hook=_no_dups)
            except json.JSONDecodeError as e:
                raise MergeError(f"{path}:{n}: not JSON: {e}")
            except ValueError as e:
                raise MergeError(f"{path}:{n}: {e}")
            if hdr is None:
                if "hdr" not in obj:
                    raise MergeError(f"{path}:1: the first line must be {{\"hdr\": ...}}")
                hdr = obj["hdr"]
                continue
            for k in ("t", "s", "ev"):
                if k not in obj:
                    raise MergeError(f"{path}:{n}: an event without \"{k}\"")
            for k in OUTPUT_NAMES:
                if k in obj:
                    raise MergeError(f"{path}:{n}: field {k!r} is reserved for the merger")
            events.append(obj)
    if hdr is None:
        raise MergeError(f"{path}: empty")
    return hdr, events


def describe(e):
    extra = {k: v for k, v in e.items() if k not in ("t", "s", "ts", "ev")}
    return f"{e['t']}#{e['s']} {e['ev']} {json.dumps(extra, sort_keys=True)}"


def merge(hdr, events, max_steps=None):
    """Return (order, preds) where order is a list of event indices (into events)
    and preds[u] is the set of must-precede event indices of u (direct edges)."""
    n = len(events)
    by_thread = defaultdict(list)
    for u, e in enumerate(events):
        by_thread[e["t"]].append(u)
    for t, us in by_thread.items():
        us.sort(key=lambda u: events[u]["s"])
        seqs = [events[u]["s"] for u in us]
        if len(set(seqs)) != len(seqs):
            raise MergeError(f"thread {t}: repeated sequence numbers")
        if seqs != list(range(1, len(seqs) + 1)):
            raise MergeError(f"thread {t}: sequence numbers are not 1..{len(seqs)} "
                             f"(events lost?): first gap after {next((a for a, b in zip(seqs, seqs[1:]) if b != a + 1), seqs[0])}")
    pos = {}                                   # event -> 1-based index in its thread
    for t, us in by_thread.items():
        for k, u in enumerate(us, 1):
            pos[u] = k

    preds = [set() for _ in range(n)]
    # 1. per-thread order
    for us in by_thread.values():
        for a, b in zip(us, us[1:]):
            preds[b].add(a)
    # 2. put / get
    puts = defaultdict(list)
    for u, e in enumerate(events):
        for k in as_list(e.get("put")):
            puts[k].append(u)
    warnings = []
    for u, e in enumerate(events):
        for k in as_list(e.get("get")):
            if k not in puts:
                warnings.append(f"no event puts {k!r} (got by {describe(e)})")
            for p in puts.get(k, ()):
                if p != u:
                    preds[u].add(p)
    # 3. clocks
    clocks = defaultdict(list)
    for u, e in enumerate(events):
        if "clk" in e:
            if "tick" not in e:
                raise MergeError(f"{describe(e)}: \"clk\" without \"tick\"")
            clocks[e["clk"]].append(u)
    for c, us in clocks.items():
        us.sort(key=lambda u: events[u]["tick"])
        ticks = [events[u]["tick"] for u in us]
        if len(set(ticks)) != len(ticks):
            raise MergeError(f"clock {c!r}: repeated ticks")
        for a, b in zip(us, us[1:]):
            preds[b].add(a)
    # 4 / 5. locations
    loc_w = defaultdict(list)
    loc_r = defaultdict(list)
    for u, e in enumerate(events):
        if "rmw" in e:
            if "old" not in e or "new" not in e:
                raise MergeError(f"{describe(e)}: \"rmw\" needs \"old\" and \"new\"")
            loc_w[e["rmw"]].append(u)
        if "rd" in e:
            if "val" not in e:
                raise MergeError(f"{describe(e)}: \"rd\" needs \"val\"")
            loc_r[e["rd"]].append(u)
    locinit = dict(hdr.get("locinit", {}))
    for loc in set(loc_w) | set(loc_r):
        if loc in locinit:
            continue
        bal = defaultdict(int)
        for u in loc_w.get(loc, ()):
            bal[json.dumps(events[u]["old"])] += 1
            bal[json.dumps(events[u]["new"])] -= 1
        starts = [v for v, c in bal.items() if c > 0]
        if len(starts) > 1 or any(abs(c) > 1 for c in bal.values()):
            raise MergeError(
                f"location {loc!r}: the logged RMWs do not form one chain (values read "
                f"but never written: {sorted(starts)}): a write of this location is not logged")
        if starts:
            locinit[loc] = json.loads(starts[0])
        elif loc_w.get(loc):
            first = min(loc_w[loc], key=lambda u: events[u].get("ts", 0))
            locinit[loc] = events[first]["old"]
        else:
            first = min(loc_r[loc], key=lambda u: events[u].get("ts", 0))
            locinit[loc] = events[first]["val"]

    # Static acyclicity first: a cycle is an inconsistent log, not a search problem.
    indeg = [len(p) for p in preds]
    succ = [[] for _ in range(n)]
    for u in range(n):
        for p in preds[u]:
            succ[p].append(u)
    ready = [u for u in range(n) if indeg[u] == 0]
    seen = 0
    tmp = list(indeg)
    while ready:
        u = ready.pop()
        seen += 1
        for v in succ[u]:
            tmp[v] -= 1
            if tmp[v] == 0:
                ready.append(v)
    if seen != n:
        stuck = [u for u in range(n) if tmp[u] > 0][:6]
        raise MergeError("the logged order has a cycle; events on it include:\n  " +
                         "\n  ".join(describe(events[u]) for u in stuck))

    # Linearise: a search over the enabled events, smallest timestamp first,
    # backtracking when a value constraint leaves no event enabled.
    def key(u):
        e = events[u]
        return (e.get("ts", 0), e["t"], e["s"])

    def enabled(u, cur):
        e = events[u]
        if "rmw" in e and cur[e["rmw"]] != e["old"]:
            return False
        if "rd" in e and cur[e["rd"]] != e["val"]:
            return False
        return True

    cur = {loc: locinit[loc] for loc in locinit}
    indeg = [len(p) for p in preds]
    avail = sorted((u for u in range(n) if indeg[u] == 0), key=key)
    availset = set(avail)
    order = []
    stack = []            # (u, candidates, index, previous value of its location)
    steps = 0
    backtracks = 0
    limit = max_steps if max_steps is not None else 200 * n + 100000

    def apply(u):
        e = events[u]
        prev = cur.get(e["rmw"]) if "rmw" in e else None
        if "rmw" in e:
            cur[e["rmw"]] = e["new"]
        order.append(u)
        availset.discard(u)
        for v in succ[u]:
            indeg[v] -= 1
            if indeg[v] == 0:
                availset.add(v)
        return prev

    def undo(u, prev):
        e = events[u]
        if "rmw" in e:
            cur[e["rmw"]] = prev
        order.pop()
        for v in succ[u]:
            if indeg[v] == 0:
                availset.discard(v)
            indeg[v] += 1
        availset.add(u)

    while len(order) < n:
        steps += 1
        if steps > limit:
            raise MergeError(f"no consistent interleaving found within {limit} steps "
                             f"({len(order)} of {n} events placed)")
        cands = sorted((u for u in availset if enabled(u, cur)), key=key)
        if cands:
            prev = apply(cands[0])
            stack.append((cands[0], cands, 0, prev))
            continue
        # dead end: backtrack to the last choice point with an untried candidate
        backtracks += 1
        while stack:
            u, cs, i, prev = stack.pop()
            undo(u, prev)
            if i + 1 < len(cs):
                nu = cs[i + 1]
                p2 = apply(nu)
                stack.append((nu, cs, i + 1, p2))
                break
        else:
            blocked = sorted(availset, key=key)[:6]
            raise MergeError(
                "no interleaving satisfies the value constraints; the events that can "
                "never be placed include:\n  " + "\n  ".join(describe(events[u]) for u in blocked))

    # Dynamic edges from the chosen chains.
    index = {u: k for k, u in enumerate(order)}
    dyn = [set() for _ in range(n)]
    for loc in locinit:
        ws = sorted(loc_w.get(loc, ()), key=lambda u: index[u])
        for a, b in zip(ws, ws[1:]):
            dyn[b].add(a)
        for r in loc_r.get(loc, ()):
            before = [w for w in ws if index[w] < index[r]]
            after = [w for w in ws if index[w] > index[r]]
            if before:
                dyn[r].add(before[-1])
            if after:
                dyn[after[0]].add(r)
    allpreds = [preds[u] | dyn[u] for u in range(n)]
    stats = {"events_in": n, "backtracks": backtracks, "warnings": warnings}
    return order, allpreds, pos, stats


def vector_clocks(events, order, allpreds, pos):
    vc = [None] * len(events)
    for u in order:
        c = {}
        for p in allpreds[u]:
            for t, k in vc[p].items():
                if c.get(t, 0) < k:
                    c[t] = k
            tp = events[p]["t"]
            if c.get(tp, 0) < pos[p]:
                c[tp] = pos[p]
        vc[u] = c
    return vc


def clamp(v):
    if isinstance(v, bool) or not isinstance(v, int):
        if isinstance(v, list):
            return [clamp(x) for x in v]
        if isinstance(v, dict):
            return {k: clamp(x) for k, x in v.items()}
        return v
    return v if -INT_MAX <= v <= INT_MAX else str(v)


def build_output(hdr, events, order, allpreds, pos, stats, keep=None):
    vc = vector_clocks(events, order, allpreds, pos)
    threads_all = sorted({e["t"] for e in events})
    kept = [u for u in order if keep is None or events[u]["ev"] in keep]
    keptset = set(kept)
    # kept prefix counts per thread: kp[t][c] = kept events among t's first c events
    by_thread = defaultdict(list)
    for u in sorted(range(len(events)), key=lambda u: (events[u]["t"], events[u]["s"])):
        by_thread[events[u]["t"]].append(u)
    kp = {}
    for t, us in by_thread.items():
        acc = [0]
        for u in us:
            acc.append(acc[-1] + (1 if u in keptset else 0))
        kp[t] = acc
    threads = [t for t in threads_all if kp[t][-1] > 0]
    tev = {t: [] for t in threads}
    lines = []
    nxt = {}
    for t, us in by_thread.items():
        ks = [u for u in us if u in keptset]
        for a, b in zip(ks, ks[1:]):
            nxt[a] = events[b]["ev"]
    for i, u in enumerate(kept, 1):
        e = events[u]
        t = e["t"]
        tev[t].append(i)
        out = {"i": i, "t": t, "n": kp[t][pos[u]], "ev": e["ev"]}
        for k, v in e.items():
            if k in RESERVED or k == "ev":
                continue
            out[k] = clamp(v)
        out["vc"] = {v: kp[v][vc[u].get(v, 0)] for v in threads}
        out["nxt"] = nxt.get(u, "")
        lines.append(out)
    ahead = {t: 0 for t in threads}
    for l in reversed(lines):
        ahead[l["t"]] = l["i"]
        l["pk"] = dict(ahead)
    h = dict(hdr)
    h["threads"] = threads
    h["tev"] = tev
    h["count"] = len(kept)
    counts = {}
    for l in lines:
        counts[l["ev"]] = counts.get(l["ev"], 0) + 1
    h["counts"] = counts
    h["merge"] = {"events_in": stats["events_in"], "events_kept": len(kept),
                  "backtracks": stats["backtracks"]}
    return h, lines


def write(path, h, lines):
    with open(path, "w") as f:
        f.write(json.dumps({"hdr": clamp(h)}, separators=(",", ":")) + "\n")
        for l in lines:
            f.write(json.dumps(l, separators=(",", ":")) + "\n")


def run(raw, out, keep=None):
    hdr, events = load_raw(raw)
    order, allpreds, pos, stats = merge(hdr, events)
    h, lines = build_output(hdr, events, order, allpreds, pos, stats, keep)
    write(out, h, lines)
    return h, lines, stats


# ---------------------------------------------------------------- self-test
def _ev(t, s, ts, ev, **kw):
    d = {"t": t, "s": s, "ts": ts, "ev": ev}
    d.update(kw)
    return d


def selftest():
    fails = []

    def check(name, cond):
        if not cond:
            fails.append(name)

    # put/get beats a misleading timestamp
    evs = [_ev("a", 1, 50, "launch", put="L1"), _ev("b", 1, 10, "start", get="L1"),
           _ev("b", 2, 20, "scan"), _ev("a", 2, 30, "work")]
    order, preds, pos, st = merge({}, evs)
    names = [evs[u]["ev"] for u in order]
    check("put/get", names.index("launch") < names.index("start"))
    h, lines = build_output({}, evs, order, preds, pos, st)
    scan = next(l for l in lines if l["ev"] == "scan")
    check("vc through put", scan["vc"] == {"a": 1, "b": 1})

    # an RMW chain whose timestamps lie: the values decide
    evs = [_ev("a", 1, 30, "x", rmw="w", old=0, new=1), _ev("b", 1, 10, "y", rmw="w", old=1, new=3),
           _ev("c", 1, 20, "z", rmw="w", old=3, new=7)]
    order, preds, pos, st = merge({}, evs)
    check("chain order", [evs[u]["ev"] for u in order] == ["x", "y", "z"])

    # ABA: 0->1 (a), 1->0 (b), 0->1 (b), 1->2 (a): needs backtracking or a lucky order
    evs = [_ev("a", 1, 1, "a1", rmw="w", old=0, new=1), _ev("a", 2, 2, "a2", rmw="w", old=1, new=2),
           _ev("b", 1, 3, "b1", rmw="w", old=1, new=0), _ev("b", 2, 4, "b2", rmw="w", old=0, new=1)]
    order, preds, pos, st = merge({"locinit": {"w": 0}}, evs)
    got = [evs[u]["ev"] for u in order]
    check("ABA chain", got == ["a1", "b1", "b2", "a2"])
    check("ABA backtracked", st["backtracks"] >= 1)

    # reads-from: a load of 1 sits between the write of 1 and the next write
    evs = [_ev("a", 1, 1, "w1", rmw="w", old=0, new=1), _ev("a", 2, 2, "w2", rmw="w", old=1, new=2),
           _ev("b", 1, 0, "r1", rd="w", val=1)]
    order, preds, pos, st = merge({}, evs)
    check("reads-from", [evs[u]["ev"] for u in order] == ["w1", "r1", "w2"])
    h, lines = build_output({}, evs, order, preds, pos, st)
    w2 = next(l for l in lines if l["ev"] == "w2")
    check("reads-from vc", w2["vc"] == {"a": 1, "b": 1})

    # clocks
    evs = [_ev("a", 1, 9, "p", clk="m", tick=2), _ev("b", 1, 1, "q", clk="m", tick=1)]
    order, preds, pos, st = merge({}, evs)
    check("clock", [evs[u]["ev"] for u in order] == ["q", "p"])

    # a broken chain (an unlogged write) is an error
    evs = [_ev("a", 1, 1, "x", rmw="w", old=0, new=1), _ev("b", 1, 2, "y", rmw="w", old=3, new=7)]
    try:
        merge({}, evs)
        check("broken chain rejected", False)
    except MergeError:
        pass

    # a cycle is an error
    evs = [_ev("a", 1, 1, "x", get="k2", put="k1"), _ev("b", 1, 2, "y", get="k1", put="k2")]
    try:
        merge({}, evs)
        check("cycle rejected", False)
    except MergeError:
        pass

    # keep: orderings through dropped events survive
    evs = [_ev("a", 1, 1, "noise", put="k"), _ev("a", 2, 2, "keep1"), _ev("b", 1, 0, "hop", get="k"),
           _ev("b", 2, 5, "keep2")]
    order, preds, pos, st = merge({}, evs)
    h, lines = build_output({}, evs, order, preds, pos, st, keep={"keep1", "keep2"})
    k2 = next(l for l in lines if l["ev"] == "keep2")
    check("keep vc", k2["vc"] == {"a": 0, "b": 0} and k2["n"] == 1)
    check("keep count", h["count"] == 2 and h["threads"] == ["a", "b"])
    k1 = next(l for l in lines if l["ev"] == "keep1")
    check("keep nxt", k1["nxt"] == "")
    check("keep pk", lines[0]["pk"] == {"a": lines[0]["i"] if lines[0]["t"] == "a" else 2,
                                        "b": lines[0]["i"] if lines[0]["t"] == "b" else 2})

    # big integers become strings
    check("clamp", clamp(2**40) == str(2**40) and clamp(5) == 5)

    if fails:
        print("merge_trace selftest FAILED: " + ", ".join(fails))
        return 1
    print("merge_trace selftest: ok")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("raw", nargs="?")
    ap.add_argument("-o", "--out")
    ap.add_argument("--keep", help="comma-separated event names to keep (default: all)")
    ap.add_argument("--keep-file", help="a file of event names to keep, whitespace-separated")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if not args.raw or not args.out:
        ap.error("RAW and -o OUT are required")
    keep = None
    if args.keep:
        keep = set(args.keep.split(","))
    if args.keep_file:
        with open(args.keep_file) as f:
            words = [w for line in f for w in line.split("#", 1)[0].split()]
        keep = (keep or set()) | set(words)
    try:
        h, lines, stats = run(args.raw, args.out, keep)
    except MergeError as e:
        print(f"merge_trace: {e}", file=sys.stderr)
        return 1
    for w in stats["warnings"][:10]:
        print(f"merge_trace: warning: {w}", file=sys.stderr)
    print(f"merge_trace: {stats['events_in']} events from {len(h['threads'])} thread(s) -> "
          f"{h['count']} kept, {stats['backtracks']} backtrack(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
