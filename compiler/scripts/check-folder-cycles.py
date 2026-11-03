#!/usr/bin/env python3
"""Fails when two sibling folders under compiler/src depend on each other.

A folder contains everything beneath it. At every folder, each child (a
subfolder or a module file) is a node, and a child depends on a sibling when
any module inside it imports any module inside the sibling. Any cycle among
siblings is reported. With --merge, Foo.elm counts as part of Foo/.
"""
import os, re, sys
from collections import defaultdict

root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('--') else 'compiler/src'
merge = '--merge' in sys.argv

mods = {}
for d, _, fs in os.walk(root):
    for f in fs:
        if f.endswith('.elm'):
            p = os.path.join(d, f)
            name = os.path.relpath(p, root)[:-4].replace(os.sep, '.')
            src = open(p, encoding='utf-8').read()
            mods[name] = re.findall(r'^import\s+([A-Z][\w.]*)', src, re.M)
mods = {k: [i for i in v if i in mods] for k, v in mods.items()}


def child(parent, mod):
    p = mod.split('.')
    if p[:len(parent)] != parent or len(p) == len(parent):
        return None
    c = p[len(parent)]
    return c + '.elm' if len(p) == len(parent) + 1 and not merge else c


def sccs(nodes, edges):
    index, low, stack, on, out, n = {}, {}, [], set(), [], [0]

    def visit(v):
        index[v] = low[v] = n[0]; n[0] += 1; stack.append(v); on.add(v)
        for w in edges[v]:
            if w not in index:
                visit(w); low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop(); on.discard(w); comp.append(w)
                if w == v:
                    break
            out.append(comp)

    for v in sorted(nodes):
        if v not in index:
            visit(v)
    return out


sys.setrecursionlimit(10000)
dirs = {tuple(m.split('.')[:i]) for m in mods for i in range(len(m.split('.')))}
cycles = 0
for d in sorted(dirs):
    d = list(d)
    edges, example, nodes = defaultdict(set), {}, set()
    for mod, imps in mods.items():
        a = child(d, mod)
        if a is None:
            continue
        nodes.add(a)
        for i in imps:
            b = child(d, i)
            if b is not None and b != a:
                edges[a].add(b)
                example.setdefault((a, b), (mod, i))
    for comp in sccs(nodes, edges):
        if len(comp) > 1:
            cycles += 1
            members = set(comp)
            print(f"cycle in {'/'.join(d) or '.'}/: {', '.join(sorted(comp))}")
            for (a, b), (x, y) in sorted(example.items()):
                if a in members and b in members:
                    print(f"    {a} -> {b}   e.g. {x} imports {y}")
print(f"{cycles} folder cycle(s)")
sys.exit(1 if cycles else 0)
