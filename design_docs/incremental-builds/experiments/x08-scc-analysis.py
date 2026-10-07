import sys, collections
sys.path.insert(0, '/tmp/inc-exp/results/x12')
sys.setrecursionlimit(1000000)
from census_lib import Census
c = Census('/tmp/inc-exp/results/x12/census/base1.tsv')
specs = c.specs
ids = sorted(specs)
idx = {s: i for i, s in enumerate(ids)}
N = len(ids)
out = [[] for _ in range(N)]
for s in ids:
    for r in specs[s].refs:
        if r in idx and r != s:
            out[idx[s]].append(idx[r])

def tarjan(n, adj):
    index = [-1]*n; low = [0]*n; onst = [False]*n; st = []; comps = []; cnt = 0
    for v0 in range(n):
        if index[v0] != -1: continue
        stack = [(v0, 0)]
        index[v0] = low[v0] = cnt; cnt += 1; st.append(v0); onst[v0] = True
        while stack:
            v, i = stack[-1]
            if i < len(adj[v]):
                stack[-1] = (v, i+1)
                w = adj[v][i]
                if index[w] == -1:
                    index[w] = low[w] = cnt; cnt += 1; st.append(w); onst[w] = True
                    stack.append((w, 0))
                elif onst[w]:
                    low[v] = min(low[v], index[w])
            else:
                stack.pop()
                if stack:
                    u = stack[-1][0]; low[u] = min(low[u], low[v])
                if low[v] == index[v]:
                    comp = []
                    while True:
                        w = st.pop(); onst[w] = False; comp.append(w)
                        if w == v: break
                    comps.append(comp)
    return comps

def home(i): return c.home(specs[ids[i]])
inst, req = c.requesters()
def owners(i):
    s = specs[ids[i]]
    if s.sid in inst:
        r = req.get(s.sid)
        return frozenset(r) if r else frozenset([c.home(s)])
    return frozenset([c.home(s)])

def report(name, adj):
    comps = tarjan(N, adj)
    nontriv = [k for k in comps if len(k) > 1 or (k[0] in adj[k[0]])]
    big = max(comps, key=len)
    multi_def = [k for k in nontriv if len({home(i) for i in k}) > 1]
    multi_own = [k for k in nontriv if len(set().union(*[owners(i) for i in k])) > 1]
    cost = sum(specs[i].cost + 1 for i in ids)
    print(f"[{name}] SCCs={len(comps)} nontrivial={len(nontriv)} largest={len(big)} specs "
          f"({100*sum(specs[ids[i]].cost+1 for i in big)/cost:.1f}% cost, spanning {len({home(i) for i in big})} def-modules)")
    print(f"   nontrivial SCCs spanning >1 definition module: {len(multi_def)} "
          f"(specs {sum(len(k) for k in multi_def)}); spanning >1 requester-owner: {len(multi_own)} (specs {sum(len(k) for k in multi_own)})")
    return comps, multi_def, multi_own

print("specs", N, "edges", sum(len(a) for a in out))
comps, md, mo = report("calls/refs (caller->callee)", out)
# examples of cross-module SCCs
for k in sorted(md, key=len, reverse=True)[:5]:
    mods = collections.Counter(home(i) for i in k)
    print("   e.g. size", len(k), dict(mods.most_common(4)))
# symmetric closure: callee->caller facts + caller->callee facts on the same call edges
und = [list(set(a)) for a in out]
for v in range(N):
    for w in out[v]:
        und[w].append(v)
report("calls + reverse (bidirectional facts on every call edge)", und)
# module-level graph
mod_edges = collections.defaultdict(set)
for v in range(N):
    for w in out[v]:
        a, b = home(v), home(w)
        if a != b: mod_edges[a].add(b)
mods = sorted({home(i) for i in range(N)})
mi = {m: j for j, m in enumerate(mods)}
madj = [[mi[b] for b in mod_edges[m]] for m in mods]
mc = tarjan(len(mods), madj)
mnt = [k for k in mc if len(k) > 1]
print(f"[module graph by definition home] modules={len(mods)} nontrivial SCCs={len(mnt)} sizes={sorted([len(k) for k in mnt], reverse=True)[:10]}")
for k in sorted(mnt, key=len, reverse=True)[:3]:
    print("   e.g.", [mods[j] for j in k][:12])

# Variant-A copy graph: an instance is copied per requesting module; a caller in owner o
# references its own owner's copy of an instance callee, or the home copy of a non-instance.
nodes = {}
def nid(sid, o):
    k = (sid, o)
    if k not in nodes: nodes[k] = len(nodes)
    return nodes[k]
for sid in ids:
    for o in (req[sid] if sid in inst else {c.home(specs[sid])}):
        nid(sid, o)
cadj = collections.defaultdict(list)
for (sid, o), v in list(nodes.items()):
    for r in specs[sid].refs:
        if r not in specs or r == sid: continue
        if r in inst:
            oo = o if o in req[r] else None
            if oo is None:
                # caller's owner not among r's requesters: falls back to r's first requester
                oo = sorted(req[r])[0]
            w = nid(r, oo)
        else:
            w = nid(r, c.home(specs[r]))
        cadj[v].append(w)
M = len(nodes)
adj = [cadj[v] for v in range(M)]
inv = {v: k for k, v in nodes.items()}
cc = tarjan(M, adj)
nt = [k for k in cc if len(k) > 1]
cross = [k for k in nt if len({inv[v][1] for v in k}) > 1]
print(f"[variant-A copy graph] nodes={M} nontrivial SCCs={len(nt)} largest={max(len(k) for k in cc)} SCCs spanning >1 owner module: {len(cross)} (nodes {sum(len(k) for k in cross)})")
for k in sorted(cross, key=len, reverse=True)[:5]:
    print("   e.g. size", len(k), collections.Counter(inv[v][1] for v in k).most_common(4), [specs[inv[v][0]].gname for v in k][:6])

print("--- edges between owners inside cross-owner SCCs")
for k in cross:
    ks = set(k)
    for v in k:
        sid, o = inv[v]
        for w in adj[v]:
            if w in ks and inv[w][1] != o:
                s2 = specs[inv[w][0]]
                print(f"   {o.split(':')[1]}::{specs[sid].gname} [{('inst' if sid in inst else 'home')}] -> {inv[w][1].split(':')[1]}::{s2.gname} [{('inst' if s2.sid in inst else 'home')}] home={c.home(s2).split(':')[1]} req={sorted(m.split(':')[1] for m in req.get(s2.sid, []))[:4]}")
