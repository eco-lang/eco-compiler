"""Import graph of the subject program + its packages (for variant B dominators)."""
import os, re, json, glob, collections

SUBJECT = "/tmp/inc-exp/subject/src"
PKGROOT = os.path.expanduser("~/.elm/0.19.1/packages")
ELMJSON = "/tmp/inc-exp/repo/build/compiler/build-kernel/elm.json"
KERNELSRC = "/tmp/inc-exp/repo/eco-kernel-cpp/src"
IMPORT_RE = re.compile(r"^import\s+([A-Z][A-Za-z0-9_.]*)", re.M)


class Imports:
    def __init__(self, c, subject=SUBJECT):
        self.c = c
        self.subject = subject
        deps = json.load(open(ELMJSON))["dependencies"]
        self.pkgdirs = {}
        for sect in ("direct", "indirect"):
            for p, v in deps[sect].items():
                self.pkgdirs[p] = KERNELSRC if p == "eco/kernel" else os.path.join(PKGROOT, p, v, "src")
        for s in c.specs.values():
            if s.pkg not in self.pkgdirs and s.pkg != c.project_pkg and s.pkg != "eco/accessor":
                cands = sorted(glob.glob(os.path.join(PKGROOT, s.pkg, "*", "src")))
                if cands:
                    self.pkgdirs[s.pkg] = cands[-1]
        self.mod_index = collections.defaultdict(list)
        for pkg, root in list(self.pkgdirs.items()) + [(c.project_pkg, subject)]:
            if not root or not os.path.isdir(root):
                continue
            for f in glob.glob(os.path.join(root, "**", "*.elm"), recursive=True):
                self.mod_index[os.path.relpath(f, root)[:-4].replace(os.sep, ".")].append(pkg)
        self.imports_cache = {}
        self.closure_cache = {}
        self.missing_files = set()

    def mod_file(self, pkg, mod):
        root = self.subject if pkg == self.c.project_pkg else self.pkgdirs.get(pkg)
        if not root:
            return None
        f = os.path.join(root, *mod.split(".")) + ".elm"
        return f if os.path.exists(f) else None

    def imports_of(self, pm):
        if pm in self.imports_cache:
            return self.imports_cache[pm]
        pkg, mod = pm.split(":", 1)
        f = self.mod_file(pkg, mod)
        res = set()
        if f is None:
            self.missing_files.add(pm)
        else:
            for m in IMPORT_RE.findall(open(f, encoding="utf-8", errors="replace").read()):
                owners = self.mod_index.get(m, [])
                if not owners:
                    continue
                if pkg in owners:
                    res.add(pkg + ":" + m)
                else:
                    non_proj = [o for o in owners if o != self.c.project_pkg]
                    if pkg == self.c.project_pkg and self.c.project_pkg in owners:
                        res.add(self.c.project_pkg + ":" + m)
                    elif non_proj:
                        res.add(non_proj[0] + ":" + m)
        self.imports_cache[pm] = res
        return res

    def closure(self, pm):
        if pm in self.closure_cache:
            return self.closure_cache[pm]
        seen = set()
        stack = [pm]
        while stack:
            x = stack.pop()
            for y in self.imports_of(x):
                if y not in seen:
                    seen.add(y)
                    stack.append(y)
        self.closure_cache[pm] = seen
        return seen


def member_homes(s):
    """returns (set of module homes, has_unknown)"""
    homes, unknown = set(), False
    for m in s.members:
        _, h = m.split("=", 1)
        if h.startswith("L="):
            homes |= set(h[2:].split("+"))
        elif h in ("kernel", "accessor"):
            pass
        elif h == "unknown":
            unknown = True
        else:
            homes.add(h)
    return homes, unknown


def classify_instance(c, imp, s):
    """returns (dominator or None, pkg_only)"""
    gh = c.home(s) if s.pkg != "eco/accessor" else None
    mh, unk = member_homes(s)
    th = set(s.thomes)
    cands = ({gh} if gh else set()) | th | mh
    dom = None
    for d in sorted(cands):
        cl = imp.closure(d)
        if all(x == d or x in cl for x in cands):
            dom = d
            break
    is_pkg = lambda pm: not c.is_project_mod(pm) and pm != "accessor"
    pkg_only = (gh is None or is_pkg(gh)) and all(is_pkg(x) for x in th | mh) and not unk
    return dom, pkg_only
