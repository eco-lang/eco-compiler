"""x12 census parsing + unit-rule models (shared by analyze_x1.py / analyze_x2.py)."""
import os, re, json, collections

PROJECT_TOPS = {"API", "Builder", "Codec", "Common", "Compiler", "Control", "Data", "Mlir",
                "System", "Terminal", "Text", "Utils"}
K = 24

Spec = collections.namedtuple("Spec", "sid sym key coll pkg mod gname kind nglob lss cost nodes lambdas fp fpn fpraw thomes members refs")


class Census:
    def __init__(self, path):
        self.path = path
        self.specs = {}
        self.roots = []
        with open(path) as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                p = line.split("\t")
                if p[0] == "R":
                    self.roots = [int(x) for x in [p[1], p[2]] if x != "-"] + [int(x) for x in p[3].split()]
                elif p[0] == "S":
                    s = Spec(int(p[1]), p[2], p[3], int(p[4]), p[5], p[6], p[7], p[8], int(p[9]), p[10] == "1",
                             int(p[11]), int(p[12]), int(p[13]), p[14], p[15], p[16],
                             [x for x in p[17].split(",") if x], [x for x in p[18].split(",") if x],
                             [int(x) for x in p[19].split()])
                    self.specs[s.sid] = s
        self.poly = {}
        pp = path + ".poly"
        if os.path.exists(pp):
            with open(pp) as f:
                for line in f:
                    q = line.rstrip("\n").split("\t")
                    if len(q) == 5 and q[0] == "P":
                        self.poly[q[1] + ":" + q[2] + "." + q[3]] = int(q[4])
        self.by_key = {s.key: s for s in self.specs.values()}
        assert len(self.by_key) == len(self.specs), "stable key collision after disambiguation"
        self.sid2key = {s.sid: s.key for s in self.specs.values()}
        self.project_pkg = self._guess_project_pkg()
        # referrers
        self.referrers = collections.defaultdict(set)
        for s in self.specs.values():
            for r in s.refs:
                if r in self.specs and r != s.sid:
                    self.referrers[r].add(s.sid)

    def _guess_project_pkg(self):
        c = collections.Counter(s.pkg for s in self.specs.values() if s.mod.split(".")[0] in PROJECT_TOPS or s.mod == "Prelude")
        return c.most_common(1)[0][0]

    def home(self, s):
        return s.pkg + ":" + s.mod

    def is_project_mod(self, pkgmod):
        if ":" not in pkgmod:
            return False
        pkg, mod = pkgmod.split(":", 1)
        return pkg == self.project_pkg and (mod.split(".")[0] in PROJECT_TOPS or mod == "Prelude")

    def is_project(self, s):
        return self.is_project_mod(self.home(s))

    def global_str(self, s):
        if s.pkg == "eco/accessor":
            return "accessor:" + s.gname
        return s.pkg + ":" + s.mod + "." + s.gname

    def poly_decl(self, s):
        """None if the global has no annotation in the typed graph."""
        return self.poly.get(self.global_str(s))

    def is_instance(self, s):
        """Instance criterion (documented in the report):
        - accessors are always instances (they belong to no module);
        - extern/manager nodes never are (no code);
        - ctor/enum nodes are when the ctor is used at >1 type or its key
          mentions a type from another module;
        - otherwise an instance iff the declared annotation has free type
          variables, OR the spec key is LSS-keyed (an argument arrow carries a
          known lambda set), OR the global has >1 spec.
        """
        return self.instance_reason(s) != "none"

    def instance_reason(self, s):
        if s.pkg == "eco/accessor":
            return "accessor"
        if s.kind in ("extern", "mgr"):
            return "none"
        if s.kind in ("ctor", "enum"):
            # constructors of a parameterised type: instance when used at >1
            # type or when its key mentions a type from another module
            if s.nglob > 1:
                return "ctor-multi"
            if any(h != self.home(s) for h in s.thomes):
                return "ctor-foreign-arg"
            return "none"
        pd = self.poly_decl(s)
        if pd is not None and pd > 0:
            return "poly"
        if s.lss:
            return "lss"
        if s.nglob > 1:
            return "multi"
        return "none"

    def requesters(self):
        """Variant A: requesting-module sets. Root requesters are the home
        modules of non-instance specs; instances inherit the requesters of
        their referrers (fixpoint). An instance with no referrers (a root)
        is requested by its own home."""
        inst = {sid for sid, s in self.specs.items() if self.is_instance(s)}
        req = {sid: set() for sid in inst}
        work = collections.deque(sorted(inst))
        inq = set(work)
        while work:
            sid = work.popleft()
            inq.discard(sid)
            new = set()
            for r in self.referrers.get(sid, ()):
                rs = self.specs[r]
                if r in inst:
                    new |= req[r]
                else:
                    new.add(self.home(rs))
            if not self.referrers.get(sid) or sid in self.roots:
                new.add(self.home(self.specs[sid]))
            if not new <= req[sid]:
                req[sid] |= new
                for c in self.specs[sid].refs:
                    if c in inst and c not in inq:
                        work.append(c)
                        inq.add(c)
        # instances never reached by propagation (only referenced from instances
        # in a cycle with no root) fall back to their own home
        for sid in inst:
            if not req[sid]:
                req[sid].add(self.home(self.specs[sid]))
        return inst, req


def ucost(s):
    # lowering-cost proxy per spec: inliner cost of the body + 1 per symbol
    return s.cost + 1


def raw_ident(s):
    """Today's identity: the symbol name plus the body as it reaches MLIR,
    where references to other specs are spelled with their raw SpecId.
    (The census fpRaw column additionally hashes raw LSS member ids and
    closure-kind ids; those do not reach the MLIR bytecode -- e5/e6/e9 give
    byte-identical bytecode -- so it is NOT used.)"""
    return (s.sym, s.fp, tuple(sorted(s.refs)))


def range_units(c, k=K, raw=True):
    """Today's slicing model: contiguous SpecId ranges, k equal-cost ranges.
    Returns list of frozensets of (identity, fingerprint)."""
    sids = sorted(c.specs)
    total = sum(ucost(c.specs[s]) for s in sids)
    units = [[] for _ in range(k)]
    acc = 0
    for sid in sids:
        s = c.specs[sid]
        idx = min(k - 1, int(acc * k / total)) if total else 0
        units[idx].append(raw_ident(s) if raw else (s.key, s.fp))
        acc += ucost(s)
    return [frozenset(u) for u in units]


def range_unit_costs(c, k=K):
    sids = sorted(c.specs)
    total = sum(ucost(c.specs[s]) for s in sids)
    costs = [0] * k
    acc = 0
    for sid in sids:
        s = c.specs[sid]
        idx = min(k - 1, int(acc * k / total)) if total else 0
        costs[idx] += ucost(s)
        acc += ucost(s)
    return costs, total


def module_units(c):
    """(iii) definition-module units: unit name -> {key: fp}."""
    u = collections.defaultdict(dict)
    for s in c.specs.values():
        u[c.home(s)][s.key] = s.fp
    return u


def owner_units(c):
    """(iv) requester ownership, variant A: non-instances in their home's
    unit; each instance copied into every requesting module's unit."""
    inst, req = c.requesters()
    u = collections.defaultdict(dict)
    for s in c.specs.values():
        if s.sid in inst:
            for m in req[s.sid]:
                u[m][s.key] = s.fp
        else:
            u[c.home(s)][s.key] = s.fp
    return u


def unit_cost_dict(c, units):
    out = {}
    for name, members in units.items():
        out[name] = sum(ucost(c.by_key[k]) for k in members)
    return out
