# Kernel-Opt 10: MLIR CSE at the M4 slot + project-of-construct folder

**Status: IMPLEMENTATION-READY v3 — 2026-08-10.** (v1 outline → v2 deepening → v3
adversarial verification pass: every load-bearing anchor re-checked against the tree, the
whole census re-derived from a fresh dump, and four executable defects fixed — see the
"corrected in v3" notes inline: the fabricated `eco.array.get` miscompile, the `ecoc -o`
census redirect, the lit-style test design, and the Phase-4 A/B that varied a flag with no
effect on the command it was set on.) Derived from design_docs/kernel-boundary-reduction.md
§9 H2 + a fresh 966,687-line / ~600k-op self-compile corpus scan run 2026-08-10 (see
Evidence). Independent of both kernel censuses — this is IR-shape work, not a per-symbol
boundary item.

## Goal

Make the dialect's purity declarations load-bearing for the first time: **102 of 134**
Ops.td ops carry `[Pure]` (counted 2026-08-10 by the script in Phase 0.1), and today
NOTHING reads them — there is no `createCSEPass()` or `createCanonicalizerPass()` anywhere
under `runtime/src/codegen/` (grep-verified; the sole hits are the M4 removal comment at
EcoPipeline.cpp:88-96). Add (1) nested CSE at the M4 slot and (2) an
`eco.project.*`-of-`eco.construct.*` folder, gated behind (0) the purity audit that CSE
turns from documentation into a correctness dependency.

## Files touched

| File | Change |
| --- | --- |
| `runtime/src/codegen/Ops.td` | `let hasFolder = 1;` on the six project ops (:648, :670, :757, :780, :847, :924). **No purity edits** — Phase 0.1 found no wrongly-`Pure` op (see Evidence; `Eco_ArrayGetOp` at :950 is correctly `[Pure]` because every array writer clones) |
| `runtime/src/codegen/EcoOps.cpp` | New "Projection Folders" section before :1061: one shared guard + six `fold(FoldAdaptor)` impls |
| `runtime/src/codegen/Passes/EcoFoldProject.cpp` | **NEW** — func-nested pass that applies the folders (`eco-fold-project`, env `ECO_MLIR_FOLD`) |
| `runtime/src/codegen/Passes.h` | Declare `createEcoFoldProjectPass()` in the Stage-2 block (after :69) |
| `runtime/src/codegen/CMakeLists.txt` | Add `Passes/EcoFoldProject.cpp` to the `set_source_files_properties` OBJECT_DEPENDS list (:277-305) **and** to `add_mlir_library(EcoPasses …)` (:354+) |
| `runtime/src/codegen/EcoPipeline.cpp` | M4 slot (:96): two `addNestedPass<func::FuncOp>` lines + two static env-gate helpers |
| `test/codegen/fold_project_of_construct.mlir` | **NEW** fixture — semantics unchanged by the fold, incl. the kind=0 aggregate negative case (harness is NOT lit; see 2.5) |
| `test/codegen/cse_pure_dedup.mlir` | **NEW** fixture — duplicate constructs merge without changing observed values; `eco.array.get` around an `eco.array.set` still reads the pre-set array (the invariant Phase 0.1 pins) |

No compiler/ (Elm) file changes. The front-end MLIR output is unchanged by this item.

## Flag & rollback

Backend-only ⇒ env-var gates (per repo rule; Config.elm flags are for compiler emission).

| Flag | Phase 1-3 default | Ship default | Semantics |
| --- | --- | --- | --- |
| `ECO_MLIR_CSE` | **OFF** (unset) | ON | `=1` on, `=0` off, unset = the compiled-in default |
| `ECO_MLIR_FOLD` | **OFF** (unset) | ON | `=1` on, `=0` off, `=census` on + stderr census line |
| `ECO_MLIR_FOLD_BLOCK_LOCAL` | OFF | OFF | `=1` restricts the fold to a same-block construct (C-R1 mitigation) |

Gate helpers live in `EcoPipeline.cpp` (CSE — a stock pass can't self-gate, so it is added
or not at pipeline-construction time) and in `EcoFoldProject.cpp` (folder — self-gates in
`runOnOperation`, mirroring `cmpCaseEnabled()` at EcoCompareCaseRewrite.cpp:74-85).

**Rollback story, cheapest first:** (1) `ECO_MLIR_CSE=0 ECO_MLIR_FOLD=0` — restores the
exact current pipeline, no rebuild; (2) flip the **three** compiled-in defaults back to OFF
(`ecoMlirCseEnabled` / `ecoFoldProjectEnabled` in EcoPipeline.cpp, `foldEnabled` in
EcoFoldProject.cpp) — one line each; (3) delete the two `addNestedPass`
lines at the M4 slot — the folder is then dead code but harmless (nothing calls `fold()`
because no canonicalizer and no other greedy driver runs); (4) full revert = revert the
eight files above. Nothing in this item changes op traits, so no rollback step has to
reason about dialect semantics.

## Evidence

### Verified anchors (2026-08-10, this tree)

- **The M4 slot:** EcoPipeline.cpp:87 `pm.addPass(createEcoListTemplatePass())` (module-
  level), :88-95 the M4 safety comment, **:96 the commented-out
  `pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());`**, :99
  `pm.addPass(eco::createEcoGCPreparePass())` (module-level). Measured M4 effect, quoted
  at :88-89: MLIR phase −~0.5 s, exe +~0.28 %, functional output byte-identical.
- **Ordering claim CONFIRMED.** `EcoGCPrepare` is `OperationPass<ModuleOp>`
  (EcoGCPrepare.cpp:147) and runs at EcoPipeline.cpp:99, i.e. *after* the M4 slot. Root
  operands are appended **only** there: `carrier.setGCRoots(liveRoots)` at
  EcoGCPrepare.cpp:284 and :350 are the only callers in the whole tree (`grep -rn
  setGCRoots runtime/src` returns exactly those two plus Ops.td:45's interface
  declaration); the implementations are the GCRootCarrier block at
  EcoOps.cpp:917-1059 (`CallOp::setGCRoots` at :995-1005 rebuilds the operand vector and
  stamps `eco.gc_roots_count`; `RecordConstructOp::setGCRoots` :965-971 and
  `CustomConstructOp::setGCRoots` :979-985 splice roots after `field_count`/`size`).
- **Front-end safepoint hints are DORMANT — this overturns the outline's worry.**
  `Ops.elm:194-357` does thread `gcRootHints` into the construct operand lists, and
  `Expr.emitSafepointHints` (Expr.elm:113-115) forwards `Ctx.liveEcoValueVars` — but
  **`Context.elm:647-649` returns `[]`** ("Phase 2 probe: return an empty front-end GC
  root hint set"; the conservative Phase-1 body is preserved as a comment at :627-642).
  Empirically confirmed on the shipped self-compile module: `eco.construct.list` /
  `eco.construct.tuple2` / `eco.box` ops carrying a `(%r… : !eco.value…)` root group = **0**,
  and `eco.gc_roots_count` appears **10** times in ~600k defining ops. So construct ops are
  operand-identical when their fields are identical, and **construct ops DO participate in
  CSE**. (Coupling to record: if anyone restores the Phase-1 `liveEcoValueVars` body, every
  construct/box/call gains a distinct operand list and this item's CSE pool collapses to
  the hint-free ops. That flip must re-run Phase 0.)
- **Purity audit RUN, zero findings — including the one that looked like a bug.**
  MLIR's CSE merges memory-effect-free ops **regardless of intervening effects** (only
  read-only ops get the "same block, no side-effecting op in between" treatment), so a
  `[Pure]` op that reads mutable state would become a miscompile the moment CSE is on.
  The suspicious case is `Eco_ArrayGetOp` (Ops.td:950) `[Pure]` next to `Eco_ArraySetOp`
  (:974), which is *not* `[Pure]`; and **31 functions in the self-compile module do
  `array.get` and `array.set` on the same SSA array** (`Array_setHelp_$_*`,
  `Array_insertTailInTree_$_*`). **It is nevertheless sound, and `array.get` must KEEP
  `[Pure]`:** every array writer allocates a fresh array and never touches the operand.
  Verified end to end —
  `ArraySetOpLowering` calls `eco_clone_array` then GEPs/stores into the **clone**
  (EcoToLLVMHeap.cpp:1308-1400, comment "clone array + resolve + GEP + store" at :1305);
  `eco_clone_array` unconditionally `alloc::allocArray(len)` + element copy
  (RuntimeExports.cpp:4637-4678); `eco.array.push` lowers to `elm_array_push_{int,float,
  char,box}` (EcoToLLVMHeap.cpp:1461-1475), all of which go through `copyAndExtendForPush`
  (JsArrayExports.cpp:711-741); `eco.array.slice`/`append_n` likewise allocate. The boxed
  and typed kernel twins copy too (`Elm_Kernel_JsArray_unsafeSet` JsArrayExports.cpp:225-266,
  `copyForUnsafeSet` :888-913). The only in-place `alloc::arrayPush*` calls are on arrays
  allocated one line earlier inside `elm_array_singleton_*` (JsArrayExports.cpp:666-703).
  So there is **no Ops.td change in this item**; the audit's output is the invariant plus a
  regression lock (Phase 0.1 / `cse_pure_dedup.mlir`).
- **Everything else that CSE touches is immutable by construction.** The dialect states
  "No write barriers needed due to Elm's immutability" (Ops.td:67), and `RCElimination`
  (RCElimination.cpp:44-60) hard-errors on every in-place mutator (`eco.incref/decref/
  decref_shallow/free/reset/reset_ref`) — so records/tuples/customs/cons cells are
  write-once. `eco.load_global`/`eco.store_global` are correctly non-`Pure` (Ops.td:1571,
  :1590) and appear 0 times in the module anyway (`grep -c` on the dump = 0/0). There is no
  closure-field-store op at all: captures are operands of `eco.allocate_closure` /
  `eco.papCreate` / `eco.papCreateGroup`, so `eco.project.closure [Pure]` (Ops.td:1361)
  reads a write-once slot.

### Measured pool (self-compile module, 2026-08-10)

Textual dump — note `ecoc --emit=mlir` prints to **stderr** and ignores `-o`
(`module->dump()`, ecoc.cpp:447-450), so the redirect is `2>`, not `-o`:

```bash
S=/tmp/eco-cse-census; mkdir -p $S
build/runtime/src/codegen/ecoc --emit=mlir \
    build/compiler/build-kernel/bin/eco-compiler.mlir 2>$S/m0.mlir 1>/dev/null   # ~16 s, 82 MB
```
(the shipped `.mlir` is MLIR **bytecode**, magic `ML\xefR\x09eco` — confirmed with
`od -c` — so grep needs this dump or `eco make --text-mlir`, Terminal/Main.elm:296.)
966,687 lines; **600,617 SSA-defining ops** (402,730 pretty-printed + 197,887 generic-form
— `eco.call` 100,077, `eco.papExtend` 43,746, `eco.papCreate` 29,375,
`eco.project.closure` 24,685, `eco.papCreateGroup` 4); 68,932 `func.func`.

**Duplicate pure ops per function** (key = op name + everything right of the `=`, counted
per `func.func`; upper bound — ignores dominance. "same depth" adds print indentation to
the key, a cheap proxy for same region depth). Reproduce with the script in Phase 0.2;
every figure below was re-derived from a fresh dump on 2026-08-10.

| class | total | dup (any depth) | dup (same depth) |
| --- | ---: | ---: | ---: |
| `eco.project.custom` | 65,466 | 23,547 | 17,588 |
| `eco.constant` | 20,967 | 11,817 | 6,218 |
| **`eco.construct.custom`** | 50,371 | **7,697** | 6,095 |
| `eco.project.record` | 22,382 | 4,504 | 2,467 |
| **`eco.construct.list`** | 13,446 | **3,383** | 2,936 |
| `eco.string_literal` | 12,465 | 3,315 | 2,433 |
| `eco.project.tuple2` | 24,638 | 1,985 | 1,468 |
| `eco.get_tag` | 20,387 | 1,615 | 1,057 |
| `eco.project.tuple3` | 4,410 | 1,605 | 1,159 |
| `eco.int.*` | 8,978 | 1,119 | 1,011 |
| **`eco.box`** | 2,953 | **982** | 619 |
| `eco.project.list_tail` / `list_head` | 16,599 | 1,084 | 865 |
| **`eco.construct.tuple2` / `.record` / `.tuple3`** | 13,014 | **559** | 498 |
| others (`unbox`, `make.*`, `bool/char/float.*`) | 5,062 | 420 | 395 |
| **TOTAL** | **281,138** | **63,632 (22.6 %)** | **44,809** |

(The 281,138 denominator excludes `eco.project.closure` — 0 duplicates — and the 257
`eco.string.cmp_order` ops, which also have 0.)

`eco.project.closure` (24,685 ops, printed in generic form) has **0** duplicates — each
closure slot is projected once at entry. Total projections 133,495 + 24,685 = 158,180,
matching the design doc's 158,451 to within drift.

**The allocation-bearing slice is the one that matters**: 7,697 + 3,383 + 982 + 559 =
**12,621 duplicate *allocating* ops** (construct.custom/list/tuple2/tuple3/record + box)
in one self-compile module. That is the K6-shaped lever (retention), not metadata.

**Folder pool.** Projections fed by a same-function construct: **6,372** of 133,495 (4.8 %),
of which **kind-matched** (project.X of construct.X — the only foldable shape) = **5,131
(3.8 %)**: custom/custom 2,591, tuple2/tuple2 1,732, record/record 534, tuple3/tuple3 137,
list_tail/list 77, list_head/list 60. The design doc's "2,965 / 1.9 %" was a low sample;
the real kind-matched pool is ~1.7× larger. (The 1,241 *mismatched* pairs — e.g.
`project.tuple2` of `construct.custom` — are type-legal MLIR but are **not** folded: the
guard below rejects them.)

**The type guard is cheap, not the limiter.** Re-running the same scan with the printed
SSA types compared (construct field type vs projection result type — exactly the guard in
2.2): of 5,101 kind-matched pairs whose type annotations the scanner could parse,
**4,915 (96.4 %) survive**, 124 bail on type (`project.custom` 59, `project.tuple2` 42,
`project.record` 17, `project.list_tail` 4, `project.tuple3` 2 — the kind=0 boxed-aggregate
slots described in 2.2) and 62 fall outside the declared field count. So the realistic
ceiling for the folder is ~4,900 sites *before* dominance/reachability is applied;
dominance, not the guard, is what Phase 2.6's acceptance number has to absorb.

**Block locality is a cost question, not a correctness one.** SSA validity already
guarantees the construct dominates the projection, so the fold is always legal; the
same-depth split only bounds the live-range-extension risk (C-R1).

## Approach

### Phase 0 — purity audit + census (no behaviour change; 0.2 runs after 1+2 land OFF)

**0.1 Purity audit (BLOCKING prerequisite; already run once — re-run before flipping any
default).** Enumerate the `[Pure]` ops and classify each as (a) pure computation,
(b) pure-but-allocating (safe: allocation is not an MLIR memory effect, and dedup/DCE of an
allocation is semantics-preserving under a tracing GC with no observable object identity),
(c) **reads mutable state — MUST lose `Pure`**. Enumeration command (`awk` here is **mawk**,
so no GNU 3-arg `match()` — use python3):

```bash
python3 - <<'EOF'
import re
src=open('runtime/src/codegen/Ops.td').read()
defs=re.findall(r'def (Eco_\w+)\s*:\s*Eco_Op<"([^"]+)"\s*(?:,\s*\[(.*?)\])?\s*>', src, re.S)
pure=[d for d in defs if d[2] and re.search(r'\bPure\b', d[2])]
print("total", len(defs), "pure", len(pure))
for d in defs:
    if not (d[2] and re.search(r'\bPure\b', d[2])): print("  NON-PURE:", d[1])
EOF
```
Result 2026-08-10: **134 ops, 102 `[Pure]`**; the 32 non-`[Pure]` ops are `case joinpoint
jump crash expect dbg type_table array.{set,empty,singleton,push,slice,append_n}
string.from_{int,float} call papExtend allocate allocate_ctor allocate_string
allocate_closure global load_global store_global incref decref decref_shallow free reset
reset_ref to_heap make.closure`.

**Class-(c) findings: NONE.** The two things that had to be checked, and the checks:

1. *Does anything write a container that a `[Pure]` op reads?* The only heap-reading pure
   ops are `project.{custom,record,tuple2,tuple3,list_head,list_tail,closure}`, `get_tag`,
   `unbox`, `from_heap`, `array.get`, `array.length`. The only writers in the dialect are
   `array.set`, `array.push`, `array.slice`, `array.append_n`, `store_global`, `to_heap` —
   and **all of the array ones clone** (chased to the runtime in Evidence), `store_global`
   writes globals that no pure op reads (`eco.load_global` is non-`Pure`), and `to_heap`
   writes a freshly allocated box. Re-run the scan that surfaces the risky *shape* (expect
   **31** functions; `Array_setHelp_$_*` / `Array_insertTailInTree_$_*`) and confirm the
   conclusion has not changed by re-reading `ArraySetOpLowering`:

   ```bash
   python3 - <<'EOF'
   import re
   fn=re.compile(r'^\s*func\.func.*?@([A-Za-z0-9_$.]+)')
   g=re.compile(r'= eco\.array\.get (%[A-Za-z0-9_]+)\[')
   s=re.compile(r'eco\.array\.set (%[A-Za-z0-9_]+)\[')
   cur=None; gets=set(); hits=set()
   for line in open('/tmp/eco-cse-census/m0.mlir'):
       m=fn.match(line)
       if m: cur=m.group(1); gets=set(); continue
       mg=g.search(line);  ms=s.search(line)
       if mg: gets.add(mg.group(1))
       if ms and ms.group(1) in gets: hits.add(cur)
   print(len(hits))
   EOF
   grep -n 'clone array + resolve + GEP + store' runtime/src/codegen/Passes/EcoToLLVMHeap.cpp
   grep -n 'alloc::allocArray' runtime/src/allocator/RuntimeExports.cpp   # inside eco_clone_array
   ```
   **Guard invariant to record in this file and in `cse_pure_dedup.mlir`:** *if any
   `eco.array.*` writer is ever changed to mutate in place (a plausible future
   `array.push` optimisation), `Eco_ArrayGetOp` and `Eco_ArrayLengthOp` MUST drop `[Pure]`
   for `[MemoryEffects<[MemRead]>]` in the same commit* — `SideEffectInterfaces.td` is
   already included at Ops.td:15, and MLIR's CSE then merges read-only ops only within one
   block with no intervening side-effecting op, which is exactly the needed semantics.

2. *Can a `[Pure]` op trap, so that CSE's DCE of a dead one would delete an observable
   crash?* No. The only candidates are `int.div` / `int.modby` / `int.remainderby`, and all
   three are total by construction: the lowerings select a safe divisor and return 0 for a
   zero divisor (`IntDivOpLowering` EcoToLLVMArith.cpp:57-81, `IntModByOpLowering` :83-131),
   matching the Elm semantics stated in Ops.td:1754-1812. Float ops are IEEE-total.

Record the resulting table (op → class) in this file before Phase 1 flips anything.

**0.2 CSE / fold volume census.** *Sequencing (this is not a pre-code step):* the static
upper bounds are already measured in Evidence and are what justify starting; 0.2 measures
the **dynamic, dominance-surviving** volume and therefore runs only once Phases 1 and 2 are
implemented **default-OFF**, driven by `ECO_MLIR_CSE=1 ECO_MLIR_FOLD=…`. Its GO/NO-GO
verdict gates Phase 3 onward and, ultimately, the Phase-5 flip — not the writing of the
code. Two mechanisms, in order of preference.

*Primary — MLIR pass statistics.* `eco-boot-native` calls `registerPassManagerCLOptions()`
(eco-boot.cpp:529) and `applyPassManagerCLOptions(pm)` (:362), so the stock flags work.
MLIR's CSE pass declares `num-cse'd` and `num-dce'd`
(`/opt/llvm-mlir/include/mlir/Transforms/Passes.h.inc:1917-1918`).

```bash
B=build/runtime/src/codegen/eco-boot-native
IN=build/compiler/build-kernel/bin/eco-compiler.mlir
ECO_MLIR_CSE=1 ECO_MLIR_FOLD=census $B --lowering-stats --mlir-pass-statistics \
    -O 2 --parallel-opt=dev -o /tmp/cse-probe $IN 2>&1 | tee /tmp/cse-census.txt
grep -E "num-cse'd|num-dce'd" /tmp/cse-census.txt        # CSE volume
grep '\[eco-fold-project\]' /tmp/cse-census.txt          # folder volume (see 2.3)
```

*Fallback — textual op-count diff across the slot.* If statistics are noisy under the
parallel nested pipeline, dump the IR on either side. **Bracket the slot with the two
MODULE passes that surround it**, not with `cse` itself: `--mlir-print-ir-after` on a
func-nested pass fires once per function (~64k prints, interleaved across threads unless
you also pass `--mlir-disable-threading`), whereas `eco-list-template` (module,
EcoListTemplate.cpp:296-300) and `eco-gc-prepare` (module, EcoGCPrepare.cpp:146-152) each
print the whole module exactly once. `eco-gc-prepare` neither creates nor erases ops — it
only sets root operands/attrs (grep for `erase|create<` in EcoGCPrepare.cpp returns
nothing) — so it is a faithful "after the slot" snapshot for op *counts*.

```bash
E=build/runtime/src/codegen/ecoc
IN=build/compiler/build-kernel/bin/eco-compiler.mlir
# ecoc prints IR to stderr; the trailing module->dump() is LLVM-dialect, so it
# contributes no `eco.*` lines and cannot double-count.
ECO_MLIR_CSE=0 ECO_MLIR_FOLD=0 $E --emit=mlir-llvm --mlir-disable-threading \
    --mlir-print-ir-after=eco-list-template $IN >/dev/null 2>/tmp/at-m4.mlir
ECO_MLIR_CSE=1 ECO_MLIR_FOLD=1 $E --emit=mlir-llvm --mlir-disable-threading \
    --mlir-print-ir-after=eco-gc-prepare  $IN >/dev/null 2>/tmp/after-slot.mlir
for op in eco.construct.custom eco.construct.list eco.construct.tuple2 \
          eco.construct.record eco.box eco.project.custom eco.project.record \
          eco.project.tuple2 eco.constant eco.string_literal eco.get_tag; do
  printf '%-26s %8s -> %8s\n' "$op" \
    "$(grep -c "= $op " /tmp/at-m4.mlir)" "$(grep -c "= $op " /tmp/after-slot.mlir)"
done
```
(These dumps are ~100 MB each on the full module and `--mlir-disable-threading` makes the
run serial — a few minutes. Use a single package or a `test/elm` program if that is too
slow; the ratios hold.)

*Duplicate-pool re-derivation (the script the Evidence table cites).* Run against
`$S/m0.mlir` from the Evidence dump:

```bash
python3 - <<'EOF'
import re, collections
PURE=set("""eco.get_tag eco.construct.list eco.project.list_head eco.project.list_tail
eco.construct.tuple2 eco.construct.tuple3 eco.project.tuple2 eco.project.tuple3
eco.construct.record eco.project.record eco.construct.custom eco.project.custom
eco.array.get eco.array.length eco.string_literal eco.box eco.unbox eco.constant
eco.from_heap eco.make.tuple2 eco.make.tuple3 eco.make.record eco.make.custom
eco.make.cons eco.make.closure_env""".split())
PP=("eco.int.","eco.float.","eco.bool.","eco.char.")
d=re.compile(r'^(\s*)%[A-Za-z0-9_:#]+ = ("?)([A-Za-z_][A-Za-z0-9_.]*)\2(.*)$')
tot=collections.Counter(); dup=collections.Counter(); same=collections.Counter()
seen=collections.Counter(); seend=collections.Counter()
for line in open('/tmp/eco-cse-census/m0.mlir'):
    if re.match(r'^\s*func\.func', line):
        seen=collections.Counter(); seend=collections.Counter(); continue
    m=d.match(line)
    if not m: continue
    ind,_,op,rest=m.groups()
    if not (op in PURE or op.startswith(PP)): continue
    tot[op]+=1
    k=(op,rest.strip());  k2=(op,len(ind),rest.strip())
    if seen[k]:  dup[op]+=1
    if seend[k2]: same[op]+=1
    seen[k]+=1;  seend[k2]+=1
print("TOTAL", sum(tot.values()), sum(dup.values()), sum(same.values()))
for o in sorted(tot, key=lambda x:-dup[x])[:20]: print(f"{o:28s} {tot[o]:7d} {dup[o]:7d} {same[o]:7d}")
EOF
```

**Acceptance / decision point.**
- **GO** if CSE eliminates ≥ 5,000 ops **and** ≥ 2,000 of them are allocating ops
  (`construct.*` + `box`). Rationale: 12,621 is the static upper bound; half of it is a
  reasonable dominance-survival rate, and the allocating slice is the only one with a
  retention story. Measure "allocating" with the fallback op-count diff above — the
  `num-cse'd` statistic is not broken down by op class.
- **NO-GO-CSE** if allocating eliminations < 500: keep only the folder (Phase 2), skip
  Phase 1, and document "the `Pure` traits were declared for a future that didn't arrive".
- Phase 0.1 produces no code change of its own (audit output only), so there is nothing to
  land independently — but its table and guard invariant must be written down either way.

### Phase 1 — CSE at the M4 slot

**1.1 The insertion.** EcoPipeline.cpp, replacing the dead comment line at :96. Context
shown so the diff is unambiguous:

```cpp
    pm.addPass(eco::createEcoListTemplatePass());              // :87  (module-level)
    // M4/4b (measured): the func-level canonicalizer here was removed. …   :88-95
    // pm.addNestedPass<func::FuncOp>(createCanonicalizerPass());           :96 (keep)

    // Kernel-opt-10 (M4 slot). Two func-nested passes, so they merge into ONE
    // parallel sweep over the ~64k functions (see the note at :121-124). They
    // MUST stay before EcoGCPrepare (:99): that pass appends root operands to
    // carrier ops (EcoOps.cpp:917-1059), after which "structurally identical"
    // ops differ by root set and CSE would either miss every merge or (worse)
    // merge ops with different root sets. Running here is also GC-safe by the
    // M4 argument at :90-95 — fewer/earlier pure ops can only make liveness
    // MORE conservative, and over-rooting is the safe direction.
    //
    // kernel-opt-12 ordering rule, reproduced verbatim as that plan requires:
    // purity consumers MAY run anywhere in buildEcoToEcoPipeline or in
    // buildEcoToLLVMPipeline up to and including THIS slot, and nowhere
    // after it — `eco.cse_safe` is stripped by EcoGCPrepare precisely here.
    if (ecoFoldProjectEnabled())
        pm.addNestedPass<func::FuncOp>(eco::createEcoFoldProjectPass());
    if (ecoMlirCseEnabled())
        pm.addNestedPass<func::FuncOp>(createCSEPass());

    // (kernel-opt-09, if landed, inserts its MODULE-level
    //  createEcoMarkGCLeafCallsPass() HERE — after this pair, immediately
    //  before EcoGCPrepare. Keep that order: a module pass between the two
    //  func-nested passes above would split their single parallel sweep.)

    // Stage 2.5: GC preparation …                                          :98
    pm.addPass(eco::createEcoGCPreparePass());                            // :99
```

`createCSEPass()` needs no new include — `mlir/Transforms/Passes.h` is already included at
EcoPipeline.cpp:25, `using namespace mlir;` at :30, and `MLIRTransforms` is already in
`ECO_ECOPASSES_MLIR_LIBS` (CMakeLists.txt:348).

**1.2 The gate helpers**, added just above `buildEcoToLLVMPipeline` in EcoPipeline.cpp
(needs `#include <cstdlib>`), mirroring EcoCompareCaseRewrite.cpp:74-85:

```cpp
// Kernel-opt-10 kill switches. Default OFF during bring-up; flip the
// `kDefaultOn` constants to true once the Phase-4 gates are green.
static bool envSwitch(const char *name, bool defaultOn) {
    const char *e = ::getenv(name);
    if (!e || !*e) return defaultOn;
    return !(e[0] == '0' && e[1] == '\0');
}
static bool ecoMlirCseEnabled()     { return envSwitch("ECO_MLIR_CSE",  false); }
static bool ecoFoldProjectEnabled() { return envSwitch("ECO_MLIR_FOLD", false); }
```

The folder pass ALSO self-gates on `ECO_MLIR_FOLD` (belt and braces: `EcoRunner`-driven
in-process tests and any future direct pass-pipeline invocation get the same answer as
`ecoc`); the pipeline-level check just avoids paying the walk when off. Note `createCSEPass()`
is an `OperationPass<>` (`CSEBase : ::mlir::OperationPass<>`, Passes.h.inc:1878-1919), which
is what makes `addNestedPass<func::FuncOp>` legal for it.

**1.3 Acceptance.** `ECO_MLIR_CSE=1` produces a working `eco-compiler-boot` that
self-compiles to a byte-identical `.mlir` (see Gates); `num-cse'd` ≥ Phase-0's GO
threshold; `ECO_MLIR_CSE=1 ECO_MLIR_FOLD=0 build/test/test --filter codegen` is green
including the new `test/codegen/cse_pure_dedup.mlir`.

### Phase 2 — project-of-construct folder

**2.1 ODS.** Add one line to each of the six project ops (they are all single-result, so
ODS emits `::mlir::OpFoldResult fold(FoldAdaptor adaptor);` — same shape as
`ArithOps.h.inc:1320`):

| def | Ops.td | container accessor | index accessor |
| --- | ---: | --- | --- |
| `Eco_ListHeadOp` | 648 | `getList()` | — (operand 0 of construct) |
| `Eco_ListTailOp` | 670 | `getList()` | — (operand 1 of construct) |
| `Eco_Tuple2ProjectOp` | 757 | `getTuple()` | `getField()` |
| `Eco_Tuple3ProjectOp` | 780 | `getTuple()` | `getField()` |
| `Eco_RecordProjectOp` | 847 | `getRecord()` | `getFieldIndex()` |
| `Eco_CustomProjectOp` | 924 | `getContainer()` | `getFieldIndex()` |

Two ODS details that bite if missed: (a) `Eco_ListHeadOp`/`Eco_ListTailOp` name their
single result `$head`/`$tail`, so there is no `getResult`-named accessor from ODS —
`getResult()` comes from the `OneResult` trait and is what the sketch below uses;
(b) every index/count accessor is an `I64Attr`, so ODS returns **`uint64_t`**
(`getField()`, `getFieldIndex()`, `getSize()`, `getFieldCount()`). Pass them through
`static_cast<int64_t>` at the call sites — the guard's `index < 0` arm only exists to
catch the wrap of an absurd unsigned value.

```tablegen
def Eco_CustomProjectOp : Eco_Op<"project.custom", [Pure]> {
  …
  let assemblyFormat = "$container `[` $field_index `]` attr-dict `:` type($container) `->` type($result)";
  let hasFolder = 1;      // kernel-opt-10: fold project-of-construct
}
```

**2.2 The folders**, in a new section of EcoOps.cpp inserted immediately before the
`Value-level Aggregate Op Verifiers` banner at :1061 (i.e. after the GCRootCarrier block
ends at :1059). `using namespace mlir; using namespace eco;` are already in force (:18-19).

```cpp
//===----------------------------------------------------------------------===//
// Projection Folders (kernel-opt-10)
//===----------------------------------------------------------------------===//
//
// eco.project.X %c[i]  where %c = eco.construct.X(... , f_i, ...)   ==>   f_i
//
// Legality: heap aggregates are write-once. The dialect states "No write
// barriers needed due to Elm's immutability" (Ops.td:67) and RCElimination
// hard-errors on every in-place mutator (RCElimination.cpp:44-60). The one
// mutable container, ElmArray, is not reachable through these ops.
//
// This fold returns an EXISTING value and never builds IR — the only thing a
// fold() is allowed to do. Dominance is free: the field is an operand of a
// defining op that already dominates the projection.
//
// The guard demands EXACT SSA type equality. The construct verifiers tie the
// 2-bit slot kind to the field's SSA type (EcoOps.cpp:355-394 for Custom,
// :419-467 for Record) — BUT a kind=0 (boxed) slot legally accepts an
// aggregate-typed or i1 operand which the construct lowering boxes via
// eco.to_heap. There the projected !eco.value is NOT the operand, so the
// fold must bail. Type equality is exactly that test.

/// Shared guard: index in range for the DECLARED field count (never into the
/// root suffix that EcoGCPrepare may append later) and types identical.
static Value foldConstructedField(ValueRange fields, int64_t declaredCount,
                                  int64_t index, Type resultTy) {
  if (index < 0 || index >= declaredCount) return {};
  if (static_cast<int64_t>(fields.size()) < declaredCount) return {};
  Value f = fields[index];
  if (f.getType() != resultTy) return {};
  return f;
}

OpFoldResult CustomProjectOp::fold(FoldAdaptor) {
  auto ctor = getContainer().getDefiningOp<eco::CustomConstructOp>();
  if (!ctor) return {};
  // getSize()/getFieldIndex()/getFieldCount()/getField() are I64Attr => uint64_t.
  return foldConstructedField(ctor.getFields(),
                              static_cast<int64_t>(ctor.getSize()),
                              static_cast<int64_t>(getFieldIndex()),
                              getResult().getType());
}

OpFoldResult RecordProjectOp::fold(FoldAdaptor) {
  auto ctor = getRecord().getDefiningOp<eco::RecordConstructOp>();
  if (!ctor) return {};
  return foldConstructedField(ctor.getFields(),
                              static_cast<int64_t>(ctor.getFieldCount()),
                              static_cast<int64_t>(getFieldIndex()),
                              getResult().getType());
}

OpFoldResult Tuple2ProjectOp::fold(FoldAdaptor) {
  auto ctor = getTuple().getDefiningOp<eco::Tuple2ConstructOp>();
  if (!ctor) return {};
  SmallVector<Value, 2> fields{ctor.getA(), ctor.getB()};
  return foldConstructedField(fields, 2, static_cast<int64_t>(getField()),
                              getResult().getType());
}

OpFoldResult Tuple3ProjectOp::fold(FoldAdaptor) {
  auto ctor = getTuple().getDefiningOp<eco::Tuple3ConstructOp>();
  if (!ctor) return {};
  SmallVector<Value, 3> fields{ctor.getA(), ctor.getB(), ctor.getC()};
  return foldConstructedField(fields, 3, static_cast<int64_t>(getField()),
                              getResult().getType());
}

OpFoldResult ListHeadOp::fold(FoldAdaptor) {
  auto ctor = getList().getDefiningOp<eco::ListConstructOp>();
  if (!ctor) return {};
  // head_unboxed/head_kind are redundant here: type equality already implies
  // the slot kind, because ListConstructOp derives head_kind from the head
  // operand's SSA type (Ops.elm:200-205).
  SmallVector<Value, 1> f{ctor.getHead()};
  return foldConstructedField(f, 1, 0, getResult().getType());
}

OpFoldResult ListTailOp::fold(FoldAdaptor) {
  auto ctor = getList().getDefiningOp<eco::ListConstructOp>();
  if (!ctor) return {};
  SmallVector<Value, 1> f{ctor.getTail()};        // tail is always !eco.value
  return foldConstructedField(f, 1, 0, getResult().getType());
}
```

Value-level aggregates (`eco.make.tuple2` feeding `eco.project.tuple2` on an
`!eco.tuple2<…>`) are OUT of v1 scope: `getDefiningOp<Tuple2ConstructOp>()` returns null
for them, so they are silently skipped. 1,021 `eco.make.*` ops exist; revisit only if
Phase 0 shows they matter.

**2.3 The driver pass.** MLIR's CSE pass does **not** run folders, and re-adding the
canonicalizer is precisely the ~0.5 s M4 regression. So a minimal linear walk:
`runtime/src/codegen/Passes/EcoFoldProject.cpp` (new), modelled on
`EcoGCLivenessAudit.cpp:31-40` (func-nested `PassWrapper`) and
`EcoCompareCaseRewrite.cpp:276-315` (collect-then-mutate + census print):

```cpp
//===- EcoFoldProject.cpp - Fold eco.project.* of eco.construct.* ---------===//
#include "../EcoDialect.h"
#include "../EcoOps.h"
#include "../Passes.h"

#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>

using namespace mlir;
using namespace ::eco;

namespace {

bool foldEnabled() {
    static const bool on = [] {
        const char *e = ::getenv("ECO_MLIR_FOLD");
        if (!e || !*e) return false;                 // Phase 1-3 default: OFF
        return !(e[0] == '0' && e[1] == '\0');
    }();
    return on;
}
bool foldCensus() {
    const char *e = ::getenv("ECO_MLIR_FOLD");
    return e && llvm::StringRef(e) == "census";
}
bool blockLocalOnly() {
    const char *e = ::getenv("ECO_MLIR_FOLD_BLOCK_LOCAL");
    return e && *e && !(e[0] == '0' && e[1] == '\0');
}

struct EcoFoldProjectPass
    : public PassWrapper<EcoFoldProjectPass, OperationPass<func::FuncOp>> {
    MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(EcoFoldProjectPass)

    StringRef getArgument() const override { return "eco-fold-project"; }
    StringRef getDescription() const override {
        return "Fold eco.project.* of a dominating eco.construct.* to the "
               "constructed field operand";
    }

    void runOnOperation() override {
        if (!foldEnabled()) return;
        func::FuncOp func = getOperation();
        if (func.isExternal()) return;

        SmallVector<Operation *> dead;
        unsigned folded = 0, skippedNonLocal = 0;

        // `Operation::walk` defaults to POST-order over regions, but within a
        // block it still visits ops in program order — which is all the chain
        // case needs: `%b = project(%a); %c = project(%b)` sees %b already
        // RAUW'd to the construct's field when %c is visited, so a chain
        // collapses in one sweep. Erasure is deferred (`dead`) so the walk is
        // never invalidated; RAUW during a walk is legal because it only
        // rewrites operands of not-yet-visited ops.
        func.walk([&](Operation *op) {
            if (!isa<CustomProjectOp, RecordProjectOp, Tuple2ProjectOp,
                     Tuple3ProjectOp, ListHeadOp, ListTailOp>(op))
                return;
            if (blockLocalOnly()) {
                Operation *def = op->getOperand(0).getDefiningOp();
                if (!def || def->getBlock() != op->getBlock()) {
                    ++skippedNonLocal;
                    return;
                }
            }
            SmallVector<OpFoldResult, 1> results;
            if (failed(op->fold(results)) || results.size() != 1) return;
            auto v = dyn_cast_if_present<Value>(results[0]);
            if (!v) return;
            op->getResult(0).replaceAllUsesWith(v);
            dead.push_back(op);
            ++folded;
        });

        for (Operation *op : dead) op->erase();

        if (foldCensus() && folded)
            llvm::errs() << "[eco-fold-project] fn=" << func.getName()
                         << " folded=" << folded
                         << " skipped_nonlocal=" << skippedNonLocal << "\n";
    }
};

} // namespace

std::unique_ptr<Pass> eco::createEcoFoldProjectPass() {
    return std::make_unique<EcoFoldProjectPass>();
}
```

`Operation::fold(SmallVectorImpl<OpFoldResult>&)` is the no-constant-operands overload at
`/opt/llvm-mlir/include/mlir/IR/Operation.h:737`.

**2.4 Registration checklist** (verified against how `createEcoListCursorPass` is wired):

1. `runtime/src/codegen/Passes/EcoFoldProject.cpp` — definition (above).
2. `runtime/src/codegen/Passes.h` — declaration in the Stage-2 block, after :69:
   ```cpp
   /// Folds eco.project.* of a dominating eco.construct.* to the constructed
   /// field operand. Func-nested; runs at the M4 slot before EcoGCPrepare.
   /// No-op unless ECO_MLIR_FOLD is set.
   std::unique_ptr<mlir::Pass> createEcoFoldProjectPass();
   ```
3. `runtime/src/codegen/CMakeLists.txt` — add `Passes/EcoFoldProject.cpp` to **both** the
   `set_source_files_properties(… PROPERTIES OBJECT_DEPENDS "${ECO_TABLEGEN_OUTPUTS};…")`
   list (:277-305) and `add_mlir_library(EcoPasses …)` (:354+).
4. `runtime/src/codegen/EcoPipeline.cpp` — the `addNestedPass` line from 1.1.
5. No `RuntimeSymbols.cpp` / `KernelExports.h` entry: this item exports no runtime symbol.

Every driver (`ecoc.cpp:198`, `eco-boot.cpp:379`, `EcoRunner.cpp:190`,
`EcoNativeDriver.cpp:107`) funnels through `buildEcoToLLVMPipeline`, so one insertion
covers AOT, JIT and the unified `eco` binary.

**2.5 Tests. `test/codegen` is NOT lit — do not write lit syntax.** The harness is
`test/codegen/CodegenIsolatedTest.hpp`: `parseEmitMode` (:88-111) scans the file for the
FIRST `// RUN:` line and extracts **only** `-emit=<mode>`; everything else on that line
(`%ecoc`, `%s`, `%FileCheck`, extra flags, a second RUN line) is decoration and is
ignored. `-emit=jit` runs in-process via `EcoRunner` (`runJITTest` :198-235); every other
mode shells out as `ecoc <file> -emit=<mode>` with stdout+stderr merged
(`runSubprocessTest` :237-256). Discovery is a plain glob of `test/codegen/*.mlir`
(:292-306). Supported directives (test/CheckPatterns.hpp:1-38): `CHECK`, `CHECK-NOT`,
`CHECK-DAG`, `CHECK-LABEL`, `CHECK-SAME`, `CHECK-NEXT`, with `{{regex}}` inside a pattern.
**There is no `--check-prefix` and no per-test environment**, so a fixture cannot turn the
flags on by itself. Two consequences:

- The fixtures assert **semantics**, which must be identical flag-off and flag-on. That is
  the property worth locking; volume is proved by the census, not by a fixture.
- Until the Phase-5 flip, run them with the flags exported:
  `ECO_MLIR_CSE=1 ECO_MLIR_FOLD=1 build/test/test --filter codegen`. After the flip the
  default path covers them, and `ECO_MLIR_CSE=0 ECO_MLIR_FOLD=0 build/test/test --filter
  codegen` is the off-leg check.

Fixtures (model them on `test/codegen/project_all_indices.mlir`, which prints
`[eco.dbg] <value>` per projection):

- **`test/codegen/fold_project_of_construct.mlir`** — `// RUN: %ecoc %s -emit=jit 2>&1 |
  %FileCheck %s`. One `eco.construct.custom` with a boxed field, an unboxed `i64` field and
  a `!eco.tuple2<…>` field in a kind=0 slot; project all three and `eco.dbg` each.
  `// CHECK: [eco.dbg] <expected>` per field. The tuple2 field is the **negative case**:
  the fold must bail on type mismatch (construct operand `!eco.tuple2<…>`, projection result
  `!eco.value`) and the heap load must still produce the boxed value. Add
  `eco.project.list_head`/`list_tail` of an `eco.construct.list` with an unboxed `i64` head
  to cover the two list folders and the head_kind path.
- **`test/codegen/cse_pure_dedup.mlir`** — same RUN shape. (a) Two textually identical
  `eco.construct.custom` ops whose projections are printed: values must be unchanged
  whether or not CSE merged the allocations. (b) The Phase-0.1 guard: `%v0 = eco.array.get
  %a[%i]`, then `%a2 = eco.array.set %a[%i] = <new>`, then `%v1 = eco.array.get %a[%i]` and
  `%v2 = eco.array.get %a2[%i]` — `%v0 == %v1 == old` and `%v2 == new`. This fails loudly
  the day someone makes an array writer mutate in place while `array.get` is still `[Pure]`.

**`test/codegen/project_all_indices.mlir` is a free pre-existing regression lock**: it is a
pure project-of-construct chain over five indices and must still print `10 20 30 40 50`
with the folder on.

Run with `TEST_FILTER=codegen cmake --build build --target full`.

**2.6 Acceptance.** `[eco-fold-project]` census total ≥ 2,000 folds on the self-compile
module (static pool 5,131; the type guard removes only ~4 % of it — measured in Evidence —
so this threshold is really a dominance/reachability budget); both new fixtures green in
both legs; `num-dce'd` rises by at least the number of constructs whose last projection was
folded.

### Phase 3 — compile-time budget

`eco-boot-native --lowering-stats` prints two sorted tables to **stderr**
(`LoweringStats::print`, LoweringStats.cpp:134-148): "Phases (wall clock):" and
"MLIR passes (wall clock, may overlap with phases):", each row `name / time / % / calls`.
The rows that matter:

- Phase row **`MLIR lowering pipeline`** (scope opened at eco-boot.cpp:677) — this is the
  number the M4 note's "−~0.5 s" refers to. **Budget: the CSE + fold pair must cost
  ≤ 0.5 s of it** (i.e. must not give back more than M4 bought).
- Pass rows **`CSE`** (the stock pass overrides `getName()` to the literal `"CSE"`,
  Passes.h.inc:1894) and **`(anonymous namespace)::EcoFoldProjectPass`** — `PassWrapper`
  reports `llvm::getTypeName<PassT>()` (Pass.h:474), which for an anonymous-namespace
  struct is the qualified form, exactly as the existing rows print
  (`(anonymous namespace)::EcoGCPreparePass`, `(anonymous namespace)::EcoListTemplatePass`).
  Names longer than 44 chars are truncated with `...` (LoweringStats.cpp:118-120); this one
  is 40, so it prints in full. Attribution is via `pass->getName()` at LoweringStats.cpp:188.
  `--lowering-stats` already defaults to **on** (`cl::init(true)`, eco-boot.cpp:233-236);
  passing it explicitly is harmless.

```bash
B=build/runtime/src/codegen/eco-boot-native
IN=build/compiler/build-kernel/bin/eco-compiler.mlir
for r in 1 2; do
  for leg in off on; do                                  # interleaved: the machine drifts
    case $leg in off) E="ECO_MLIR_CSE=0 ECO_MLIR_FOLD=0";; on) E="ECO_MLIR_CSE=1 ECO_MLIR_FOLD=1";; esac
    env $E $B --lowering-stats -O 2 --parallel-opt=dev \
        -o /tmp/probe-$leg-$r $IN >/tmp/lower-$leg-$r.txt 2>&1
  done
done
grep -hE '^  (MLIR lowering pipeline|CSE |\(anonymous namespace\)::EcoFoldProjectPass)' \
     /tmp/lower-*.txt
```

**Decision point.**
- Cost ≤ 0.5 s **and** Phase 4 shows a wall win ⇒ ship default-ON.
- Cost ≤ 0.5 s **and** wall FLAT ⇒ ship default-ON only if exe size does not regress
  (`ls -l` on the Stage-7b ELF) — smaller/cleaner IR plus an exercised purity path is worth
  a neutral trade, and it de-risks every future folder. Record it as a FLAT-but-kept.
- Cost > 0.5 s ⇒ drop CSE to the folder only (the folder is a single linear walk and must
  cost ≪ 0.1 s), re-measure, and if still over budget, NO-GO with the numbers recorded.

### Phase 4 — retention + wall A/B

**Read this before copying any recipe: the flags are BACKEND flags.** `eco-compiler make
--output=<x>.mlir` is a front-end-only run (Stage 7a, compiler/CMakeLists.txt:466-490) — it
emits MLIR and never enters `buildEcoToLLVMPipeline`, so setting `ECO_MLIR_CSE` /
`ECO_MLIR_FOLD` on *that* command changes nothing. What the flags change is the **machine
code of the binary**. So: build two Stage-7b ELFs from the *same* `eco-compiler-boot.mlir`,
one per leg, then race them on an identical, flag-free workload. GC counters come from the
exit banner (`ENABLE_GC_STATS` is ON for every non-Release preset, CMakeLists.txt:102-116).

```bash
cd /work
B=build/runtime/src/codegen/eco-boot-native
M=build/compiler/build-kernel/bin/eco-compiler-boot.mlir

# 1. Two binaries, identical input MLIR, differing only in the M4-slot passes.
ECO_MLIR_CSE=0 ECO_MLIR_FOLD=0 $B $M -o /tmp/ecoc-off
ECO_MLIR_CSE=1 ECO_MLIR_FOLD=1 $B $M -o /tmp/ecoc-on
ls -l /tmp/ecoc-off /tmp/ecoc-on          # exe-size delta for the Phase-3 decision point

# 2. Race them, interleaved, flag-free (the env must NOT be set here).
cd /work/build/compiler/build-kernel
for r in 1 2; do
  for leg in off on; do
    rm -rf eco-stuff                                     # cold: no artifact cache
    /usr/bin/time -v /tmp/ecoc-$leg make --optimize \
        --kernel-package eco/compiler \
        --local-package eco/kernel=/work/eco-kernel-cpp \
        --output=bin/ab-$leg-$r.mlir /work/compiler/src/Terminal/Main.elm \
        > /tmp/wall-$leg-$r.txt 2>&1
  done
done
grep -E 'Elapsed \(wall|Maximum resident' /tmp/wall-*.txt
grep -E 'Objects allocated|Objects promoted|Minor GC cycles|Major GC cycles' /tmp/wall-*.txt
# 3. Correctness: both legs must emit the SAME front-end MLIR.
cmp bin/ab-off-1.mlir bin/ab-on-1.mlir && echo "outputs identical"
```
(`Objects allocated:` is GCStats.cpp:917, `Minor GC cycles:` :926, `Objects promoted:` :934,
`Major GC cycles:` :1033 — all on **stdout**, which the redirect above captures.)

**Record:** wall, RSS, majors, minors, objects allocated, objects promoted, exe size, and
the `cmp` result. Per C-R1, a rise in *promoted* objects with flat allocation is the
live-range-stretch signature — respond with `ECO_MLIR_FOLD_BLOCK_LOCAL=1` (rebuild
`/tmp/ecoc-on` with it set) and re-measure.

### Phase 5 — default-on flip

Flip `envSwitch(..., false)` → `true` in both gate helpers (and in
`EcoFoldProject.cpp::foldEnabled`), keeping `=0` as the documented kill switch. Re-run the
full gate set once after the flip (the defaults are what ship).

## Traps & risks

- **A wrongly-`Pure` op becomes a miscompile the moment CSE reads them.** 102 declarations
  had never been exercised before this item. Today the audit is clean (Phase 0.1) — but it
  is clean *because* every `eco.array.*` writer clones, which is an implementation choice,
  not a dialect rule. The failure mode is silent: MLIR's CSE merges memory-effect-free ops
  regardless of intervening effects, so a future in-place `array.push`/`array.set` would
  turn the 31 `Array_setHelp_$_*` / `Array_insertTailInTree_$_*` functions into stale
  reads that the E2E array tests would *probably* catch. `cse_pure_dedup.mlir` is the
  cheap lock; re-run the Phase-0.1 audit whenever an array op's lowering changes.
- **Root-set divergence.** Any CSE **after** EcoGCPrepare would see carrier ops with
  appended roots (EcoOps.cpp:917-1059) and could merge ops with different root sets. The
  M4-slot placement (before EcoPipeline.cpp:99) is the whole defense. **Do not move the
  pass later.** Note the direction of safety: CSE only ever *removes* later allocations by
  forwarding an earlier dominating result, so allocation sites can only disappear — root
  sets computed afterwards can only shrink where the allocation itself is gone.
- **Hint dormancy is load-bearing and reversible.** `Context.elm:647-649` returning `[]` is
  what lets constructs CSE at all. Restoring the Phase-1 hint body (commented at :627-642)
  would make every construct/box/call operand-unique and silently gut this item. If the
  EcoGCLivenessAudit ever forces that restore, re-run Phase 0 before trusting any number
  here.
- **C-R1 live-range stretch (the K5 anti-prior).** A merge or a fold that spans a
  definition body replaces a cheap rematerialization with a long live range → more roots,
  more retention. K5's construction-time interning analogue was +18.3 % and reverted. MLIR
  CSE is dominance-scoped, not distance-scoped. Mitigations, in order:
  `ECO_MLIR_FOLD_BLOCK_LOCAL=1` (folder only, one-line guard, already in the sketch); then
  folder-only / CSE-off; then a block-local CSE variant. The 44,809 same-depth duplicates
  (of 63,632, i.e. 70 %) bound how much of the pool survives a strictly local policy.
- **Fold across blocks is legal, not free.** SSA validity already guarantees dominance, so
  correctness never depends on block locality — the concern is purely that a folded field
  now lives from the construct to the projection's use. Measure via `Objects promoted`, not
  by reasoning.
- **Compile-time regression.** M4 deleted the canonicalizer to save ~0.5 s. Both new passes
  are `addNestedPass<func::FuncOp>` precisely so they merge into one parallel sweep across
  the ~64k functions (EcoPipeline.cpp:121-124). Do not "just re-add the canonicalizer" to
  get folding — that is the measured regression, and the greedy driver would also run every
  upstream arith/scf pattern we deliberately dropped.
- **Statistics vs. parallelism.** `--mlir-pass-statistics` aggregates across the nested
  parallel pipeline; `--lowering-stats` pass rows are wall-clock sums across threads
  (LoweringStats.cpp:156-189) and can exceed the phase total. Compare pass rows leg-to-leg,
  never as a fraction of wall.
- **Stale-anchor drift.** The design doc cites EcoPipeline.cpp:90 / 84-87 / 115-118; this
  tree has the slot at :96, the safety argument at :90-95, the merge note at :121-124.
  It also cites 158,451 projections (that count includes the 24,685 `eco.project.closure`
  ops) and 2,965 foldable pairs (the kind-matched pool is 5,131). Corrected above.
  kernel-opt-12 quotes the old 2,965 figure at its :358 — that plan is not ours to edit;
  do not "reconcile" by reverting this one.
- **The tooling is not what it looks like.** Three traps that cost real time:
  (a) `ecoc --emit=mlir` writes to **stderr** and silently ignores `-o` (ecoc.cpp:447-450);
  (b) `awk` on this image is **mawk**, so GNU 3-arg `match($0, re, arr)` is a syntax error —
  every census script here is python3 for that reason;
  (c) `test/codegen` is a bespoke harness, not lit (see 2.5).
- **`ecoc` dumps are large and `--mlir-print-ir-after` is worse.** The self-compile module
  is 13 MB of bytecode → 82 MB of text; a func-nested `--mlir-print-ir-after` fires ~64k
  times and interleaves across threads unless `--mlir-disable-threading` is added (which
  serialises the run). Prefer pass statistics; bracket with module passes if you must dump;
  use a single `test/elm` program if disk or time is tight.

## Dependencies

- **None among siblings.** Independent of kernel-opt-07 (facts table) — the `Pure` traits
  already exist in Ops.td, and this item adds no `eco.gc_leaf` / `eco.callee_gc_leaf` /
  `eco.cse_safe` consumer.
- **Interaction, not dependency:** kernel-opt-13 (mono CSE) deduplicates upstream in the
  Elm pipeline; whatever it catches shrinks this item's pool. Run Phase 0 *after* 13 lands
  if both are in flight, so the census reflects the real residual.
- **kernel-opt-12 (`eco.cse_safe`) — hand-off in both directions.** Its per-call attr is a
  *different* channel (Elm-level call CSE): it is a discardable unit attr on `eco.call`
  with merge-only semantics, stripped by EcoGCPrepare (that plan's 3.5, EcoGCPrepare.cpp
  Step-4 loop), and it never licenses motion after EcoGCPrepare. **Nothing in this item
  reads it**, and it does not replace the `eco.gc_leaf` declaration attr. Two concrete
  obligations: (i) reproduce opt-12's ordering rule verbatim in the M4-slot comment — done
  in 1.1; (ii) landing this item unblocks opt-12's deferred fixture
  `test/codegen/call_purity_cse_merge.mlir`, which its author gated on "until kernel-opt-10
  lands a CSE pass". Note that once opt-12 is on, an `eco.cse_safe`-stamped call and an
  unstamped otherwise-identical call will NOT merge (MLIR CSE hashes the full attribute
  dictionary) — expected, not a defect.
- **kernel-opt-09 (GCPrepare barrier relaxation) — pipeline-order contract.** That item adds
  a MODULE-level `createEcoMarkGCLeafCallsPass()` immediately before
  `createEcoGCPreparePass()` (EcoPipeline.cpp:99), stamping the call-local
  `eco.callee_gc_leaf` derived from the callee decl's single `eco.gc_leaf` attr. Whichever
  lands second must keep the order **fold → CSE (both func-nested) → mark (module) →
  EcoGCPrepare (module)**: a module pass wedged between the two func-nested passes splits
  their single parallel sweep, and running CSE *after* the marking pass is still correct but
  pointlessly hashes one extra attr. This item emits and consumes no `eco.gc_leaf` /
  `eco.callee_gc_leaf`, and there is no separate `eco.kernel_cannot_gc` attr anywhere.
- **Adjacency to kernel-opt-01:** that item changes what the front-end emits for cons
  chains; it does not change the hint situation (hints are dormant), but it does change the
  `construct.list` population, so re-run the Phase-0 census if 01 lands first.
- External: none. Effort M.

## Expected impact

Honest framing: this is the K6-shaped bet — deleting duplicate *work* and duplicate
*allocations*, not metadata. Statepoint/metadata-only removal has measured wall-FLAT four
consecutive times; the movers were retention and deleted per-op work (inline nursery
−9.6 %, CAF memoization −11.7 %, `$cap`-inlining −14.5 %, K6 hash-consing −5.07 %).

The v1 outline called the pool "thin"; the measured scan says otherwise: **63,632 duplicate
pure ops (22.6 %)** with **12,621 of them allocating**, plus **5,131** kind-matched
project-of-construct pairs (of which ~4,915 survive the type guard). Those are static upper
bounds — dominance will cut them, and the 44,809 same-depth figure is the pessimistic floor.

Realistic outcomes, in descending likelihood:
(a) **small wall win** (~1-3 %) if merged/dead constructs actually reduce promotion —
    watch `Objects promoted`, which is where K6's −5.07 % came from;
(b) **FLAT wall + smaller IR + exercised purity machinery** — worth keeping if compile time
    is neutral, because it de-risks every future folder and canonicalization;
(c) **regression via C-R1** — longer live ranges, more roots, more promotion; mitigated by
    the block-local switch, and if that does not recover it, NO-GO.
A trivial-pool NO-GO is now unlikely on the numbers, but a *compile-time* NO-GO is live.

## Gates

- **Full E2E:** `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`, then
  `grep -E 'FAILED|failed|[0-9]+/[0-9]+' /tmp/test_output.txt`. Never `check` (stale
  `.mlir`). Run ONCE; grep the file for anything further.
- **Heap-validate suite** — the GC-safety gate for pre-GCPrepare IR changes (over-rooting
  is safe; under-rooting is what this catches):
  ```bash
  cmake --preset build -B /work/build-val -DECO_HEAP_VALIDATE=ON
  cmake --build /work/build-val --target full 2>&1 | tee /tmp/val_output.txt
  ```
  Must reach the current green count with zero validation reports. Never time under
  `ECO_HEAP_VALIDATE`.
- **Bootstrap.** `cmake --build build --target bootstrap 2>&1 | tee /tmp/bootstrap.txt`
  (target defined at compiler/CMakeLists.txt:1026). This item is **backend-only**, so the
  correct expectation is stronger than "a new fixed point":
  1. Stage 4b (JS fixed point, `eco-boot-2.js == eco-boot-3.js`, compiler/CMakeLists.txt:371-382)
     — unaffected, must pass.
  2. **`eco-compiler-boot.mlir` must be BYTE-IDENTICAL to the pre-change file.** Stage 7a
     (compiler/CMakeLists.txt:466-490) is Stage 6's binary emitting MLIR; this item changes
     that binary's machine code but not its semantics, so its output must not move. This is
     the strongest available correctness signal for a CSE/fold change:
     ```bash
     cp build/compiler/build-kernel/bin/eco-compiler-boot.mlir /tmp/boot-baseline.mlir  # BEFORE
     cmp /tmp/boot-baseline.mlir build/compiler/build-kernel/bin/eco-compiler-boot.mlir  # AFTER
     ```
     A difference here means the new backend miscompiled the compiler — investigate, do not
     rebaseline.
  3. Stage 8c (`eco-compiler-boot` vs `eco-compiler-boot-2`, byte-equal ELFs on Linux;
     `.mlir` equality on macOS/Windows — compiler/CMakeLists.txt:566-586) must pass. The
     ELF bytes legitimately differ from the *previous* fixed point's binaries (different
     codegen); that is the "new fixed point", and it is expected.
- **Wall A/B** — Phase 4 recipe: two Stage-7b binaries from one `.mlir`, raced flag-free and
  interleaved 2×2, with `Major GC cycles`, `Minor GC cycles`, `Objects allocated`,
  `Objects promoted` and RSS recorded per run (GC-trigger lottery), plus `cmp` on the two
  legs' emitted `.mlir`.
- **Item-specific numbers recorded in this file:** Phase-0 purity-audit table (op → class);
  `num-cse'd` / `num-dce'd`; `[eco-fold-project] folded=` total; per-op-class before/after
  counts across the M4 slot; `MLIR lowering pipeline` and `CSE` /
  `(anonymous namespace)::EcoFoldProjectPass` timing deltas against the M4 ~0.5 s budget;
  Stage-7b ELF size delta.
