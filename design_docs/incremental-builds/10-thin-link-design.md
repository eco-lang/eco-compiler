# 10: Thin linking: which summaries, which solves, which slices

**Status:** design, 2026-10-06. It comes from three read-only code investigations: the LSS settles,
the GlobalOpt and codegen-entry facts, and the back-end facts. It builds on 08 (catalogue ids
F-*, G-*, B-*) and 09 (§4.2: the thin-link pattern). Nothing here has been implemented or measured
unless stated.

## 1. The pattern

The pattern is ThinLTO's, adapted to the compiler's phases:
- **Per-unit phase:** each unit runs a phase on its own code and emits a compact **summary** of the
  facts other units' decisions depend on.
- **Thin link:** a global step reads every unit's summary and **solves** the fact. It is cheap
  (milliseconds) and is recomputed in full every build.
- **Slice and re-run:** each unit gets its **slice**, i.e. only the answers its own later work
  reads. It re-runs that later work only if the slice's hash changed (early cutoff).

**Why the link is recomputed in full rather than incrementally.** Each solve takes 10-40 ms over
summaries of a few MB. Incrementalizing the link would add complexity for no measurable gain. The
incrementality is in the **units**: per-unit phases are cached by input hash, and post-link work
by (input artifact hash, slice hash).

**There are three link points, one per place an up/sideways relation (09) survives requester
ownership:**

```
per unit:   mono drain ──► summary S1
                              │
                    ═══ TL1: settles + taint (Prune close) ═══
                              ▼
per unit:   settle-apply ─► Prune close ─► inline ─► staging ─► graph3 ─► summary S2a
                              │
                    ═══ TL2a: AbiCloning escaping-member join ═══
                              ▼
per unit:   stamp/devirt ─► CallInfo ─► final graph ─► summary S2b (sret let-sites)
                    ═══ TL2b: sret OR ═══  ─► per-unit sret greatest fixpoint (import order)
per unit:   summary S2c (psplit clauses)
                    ═══ TL2c: psplit least fixpoint (Jacobi, exact) ═══
                              ▼
per unit:   codegen ─► MLIR ─► back-end stage 1 (eco passes … EcoToLLVM … TailConversions) ─► summary S3
                    ═══ TL3: reach ─► eligibility ─► cap solve ─► gc-free ─► $sat masks ═══
                              ▼
per unit:   back-end stage 2 (apply ─► translate ─► hoisting ─► RS4GC ─► -O2 ─► emit)  ─► link
```

**Ordering.** No link's output feeds back into the summary it was solved from. Across rebuilds, a
slice change can cascade forward, for example an AbiCloning slice change alters a unit's sret
sites. That is a cut-off chain, not a cycle.

## 2. Common mechanics

- **Stable content keys everywhere.**
  - **Specs:** global + widened creation key.
  - **Members:** the `LssMemberTable` content-key string (`g|`, `c|`, `k|`, `a|`, `p|`, `l|`), with
    `l|raw` replaced by (defining global, lambda index within the definition).
  - **Symbols:** stable names (03).
  - Hashes are 64-bit, with a side table back to the string. No summary carries discovery-order
    ints.
- **The stamp.** Every config switch that changes a fact's meaning is part of every cache key, for
  example:
  - `sretFresh`, `psplitParams`, `constThunks`;
  - `veq`, list chunks;
  - cap-hoisting K;
  - the kernel fact table.

  A stamp change invalidates everything.
- **Slices are projections.** A unit receives only what its code can distinguish. Example (TL3): a
  foreign callee's cap fact is projected to `Covered n | Zero | Other`, because that is all
  `contrib`, Phase D and §2.6(b) can tell apart. A foreign callee going from "budget 48,
  uncovered" to ⊤ therefore dirties nobody.
- **Read-set validation, where the slice isn't known in advance** (TL1's homes table). The unit
  records which entries it read last time and re-runs if any of those changed. This is the
  Salsa/Shake pattern.
- **Validate twin.** Concatenate the per-unit artifacts, run today's whole-program pass, and
  require zero diffs against the thin-link facts (or a documented superset where a rule
  intentionally changes).

## 3. TL1: after monomorphization (settles and number taint)

### 3.1 What the settles feed (the key finding)

The four settles (`MonoSolver/Monomorphize.elm:187-190`) rewrite only **registry types**
(`reverseMapping`). They never touch nodes, translation, Prune reachability, layouts (`ctorShapes`
comes from nodes) or codegen (which reads only global names).

Settled rows reach generated code at exactly **one place**: AbiCloning's post-settle devirt
`matchSpec` exact test `specType == calleeType` (`GlobalOpt/AbiCloning.elm:3089`). There, a
settled callee row is compared against the site's unsettled type to pick a unique match among
layout-equal specs. Borrow, MapTemplate and PAP-global use `eqLayout`, which ignores annotations.

**Consequences:**
- TL1 sits **between per-unit mono and per-unit AbiCloning**. Inlining and Staging can proceed in
  parallel with it.
- **Measure first.** Run AbiCloning against pre-settle and post-settle rows and count the E9.5
  decisions that differ. If the difference is negligible, have `matchSpec` compare pre-settle rows.
  The settles then become a report-only census, and **TL1 for settles is not needed at all**.

### 3.2 Summary S1 (per unit, after drain, before any settle)

| Record | Content | Self-compile size (estimate) |
|---|---|---|
| `ctorRows` | per ctor/box spec the unit owns that has ≥1 function position: `(specKey, ctorGlobal, row : MonoType)`. Annotations as `LSet`/`LPartial` member-key sets; `LVar`/`LTop` as tags only. | ~11k rows (7,186 ctor + 3,894 box; ≤ ×1.32 with copies). 0.3-1 MB |
| `flexMarks` | every ctor spec key the unit's items marked flex, **including keys owned by other units** (the requester sets the mark: `Translate.elm:3153`) | a few thousand keys |
| `homes` | per lambda member key: `{arity?, cells: relPath → {top, var, sets?}}` from `lambdaHomesOf` over the unit's nodes. Every member with a closure must be present, even with empty cells. | 31,751 member ids (~5,749 with arrow results). ~0.5 MB |
| `taintHarvest` | canonical type-variable keys `(home module, solver-root index)` resolved to Number in the unit's items | ~50 keys |
| `residualVars` | residual `CEcoValue` vars in the unit's nodes and rows | ~7k |

### 3.3 Solve

**1. Ctor settles (`settleVarCtorRows`, then `settleCtorRows`) over the union of `ctorRows`.**
- Deduplicate copies by spec key; X7 found them annotation-identical.
- Union the flex marks.
- **Two deliberate changes to today's behaviour:**
  - **Key var-ctor cells by constructor *global*, not by name.** Today's name key (`:377-381`)
    couples 190 unrelated constructors that share names (4,573 rows). It is not load-bearing: the
    design note specifies (global, path) cells, and the global key is a strict refinement. Use it
    in clean builds too, so clean and incremental agree.
  - **Make the ⊤-heal fold order-free.** Today `settleCtorRows` folds in SpecId order, its shape
    comes from the lowest-SpecId row, and `enrichAnno` is not commutative: `(LTop, LPartial) → ⊤`
    but `(LPartial, LTop) → LPartial`. One ordering of ⊤ / `LPartial ys` / `LSet zs` rows heals to
    `LSet zs`, dropping the known inhabitants `ys`. That looks like the false-singleton class
    (**unverified; worth a check in the clean compiler regardless of incrementality**). Replace it
    with cells keyed by (global, shape-tagged path) holding `{sets, partials, hasPartial}`.

**2. Homes:** a per-member commutative merge (`varCellMerge` plus arity agreement).

**3. Taint:** T = static super vars ∪ ⋃ `taintHarvest`.

**One pass, no iteration.** The ctor settles read only rows and flex marks. Homes come from nodes,
which nothing writes. The remaining settles (successors, then var-lambda, then successors) are
row-local given fixed ctor rows and homes, so they run inside each unit.

**Cost:** two linear sweeps over ~11k rows plus a merge over ~32k member entries. Milliseconds.

### 3.4 Slice, cutoff, re-run

**Slice(U):**
- healed rows for U's own ctor specs;
- the homes entries U reads during var-lambda (read-set validated; or broadcast the ~0.5 MB
  table);
- `T ∩ residualVars(U)`.

**Re-run on change:**
- U's **settle-apply** (cheap).
- Then **AbiCloning** for U, *and* for every unit whose E9.5 read set compared against one of U's
  rows. An importer's site can target U's exported home-owned spec. So AbiCloning's cutoff key must
  include its read set: target global → (spec key, row hash).
- A taint-slice change instead re-runs U's **Prune close** and everything after it, because node
  types change. It never re-runs translation.

### 3.5 Number taint: only partly linkable

`superTable` is read in two ways:
- **During translation, which cannot be linked.** It stamps CNumber vs CEcoValue residuals
  (`Store.elm:2896`), decides number-multi eligibility (`Translate.elm:5484`), and decides kernel
  licences (`Engine.elm:2876`). Linking it here would need a mono-level fixpoint (taint changes
  keys, keys change harvests).
  - **Deterministic replacement:** read static ∪ the *import closure's* published harvests ∪ the
    unit's own, in canonical order. X7: 204 of 258 number-multi reads are cross-owner; 0 licence
    decisions flip.
- **By Prune's final close, which can be linked exactly.** Use summary S1's harvest and residuals.
  On the self-compile this matters for 2-3 residual vars.

**Cleaner fix:** stop harvesting callee annotation variables (X7 option 3). That removes the
upward flow; its soundness needs checking against the ListConcatMap ABI class.

## 4. TL2: GlobalOpt and codegen-entry facts

### 4.1 Interface facts that need no thin link (publish downward)

| Fact | Treatment |
|---|---|
| Signatures; CallInfo inputs (callee node kind, source arity, body stage arities, polymorphic return) | Published from the callee unit's post-staging graph |
| Constructor, null-cons and const-ctor tables; layouts | Interface |
| Constant-thunk verdict + folded body (≤ 24 nodes) | Interface, cut off by hash |
| BytesFusion final bodies of encoder/decoder specs | Interface (down-body) |
| Kernel gc-leaf | Pinned: a function of the symbol (`KernelFacts.gcLeafEligible`). The CGEN_038 ABI equality check moves to link time. |
| `$clo`/`$cap` existence | Emitted for every capturing closure; no decision |
| Post-inline liveness | Contract: prune per unit from main, ports, flags and **all exposed definitions**; strip at link. An optional global reachability (9 ms) is useful only to filter AbiCloning's census. |
| Staging classes | Contract: an imported callee's published post-staging parameter types are a pinned segmentation, as kernel segmentation is today. Every class is already unanimous (0 wrappers program-wide), so no wrappers result. One possible regression to count: a tail-func function parameter of an exported spec whose producers are *only* in importers becomes a dynamic slot (generic apply, still safe). |

### 4.2 TL2a: AbiCloning, the escaping-member join

**Which members need the join.** Under requester ownership, a member's values reach another unit
only through:
- an exported definition's **published LSS signature**, or
- a **settled constructor or var row**.

Call that set **E**. For members not in E, every site and every instance is in one unit. A
**per-unit index is sound**, and it can only *add* stamps and devirts compared with today: it
never pools another unit's divergent copies or blocking wrappers. Pooling per-requester copies
globally would *increase* fence declines.

**Summary S2a.** Taken from graph3, before stamping, so stamps never feed back into it. Only for
members in E:

| Record | Content |
|---|---|
| `blocked` | member keys blocked by adopted/wrapper instances, plus the unit's μ-tie set |
| `groups` | per (member, full-depth layout key): param count, capture-layout key, `charFree`, local `unanimous ∧ fpUnanimous`, representative fingerprint hash, representative symbol (stable lambda name, top-level spec key), representative types hash, count |
| `census` | per escaping standalone member's origin global g: each *live* spec the unit owns or exposes: `(gKey, specKey, typeHash, layoutHash, row = Fn(paramLayouts, retLayout, paramIsChar) \| Ctor \| NonFn)` |
| `consulted` | E-members at the unit's singleton sites |

Size scales with |E|. Expected small, but unmeasured. A full "exact pooling" mode would be a few
MB.

**Solve: one-shot joins.**
- `blocked` = OR.
- Group licence = every unit's local flags hold ∧ captures equal ∧ representative fingerprints
  equal ∧ `charFree`. Fingerprints are compared across units *even when lambda names match*:
  today's same-lambdaId shortcut assumes one global copy.
- Census = union, deduplicated by spec key.

**Slice(U):** a merged `MemberInfo` for each consulted E-member.
- **Representative = local first.** Use U's own instance if it has one in the group, else an
  exposed home representative, else decline (new `remoteRep` reason). This replaces "first in
  SpecId walk", and it is safe because licensed groups are interchangeable.
- Census entries carry a "linkable from U" bit.

**Re-run on change:** U's stamping → CallInfo → codegen-entry → codegen.

### 4.3 TL2b: sret, a single OR

- **Today** (`Generate/MLIR/Backend.elm:474-760`): candidates, then the let-site gate
  `calledInLetPosition` (`:568`), then a greatest fixpoint over result-leaf callees
  (`sretFreshGreatest`, `:673-711`, in place in SpecId order, cap 30, least-fixpoint fallback with
  cap 6).
- **Under ownership,** leaf-callee constraints point down or stay inside a unit. **The only up
  edge is the let-site gate of an exported home-owned spec.**
- **Summary S2b:** the set of imported, exposed, shape-eligible callee keys the unit let-binds a
  direct call to. Eligibility is decided from the published signature. 0-20 per unit; a few KB
  program-wide.
- **Solve:** `letPos(f)` = OR over units. One-shot.
- **Slice:** the `letPos` bit for each of the unit's exposed eligible specs.
- **Then per unit, in import order:** the greatest fixpoint with imported memberships fixed (a
  reverse-edge worklist). Each unit publishes `sretMember(f) = slotTys | absent` as an interface
  fact.
- **Change vs today:** SpecId-ordered rounds, caps and the fallback can't survive stable naming.
  Use the worklist greatest fixpoint.
  - It equals today's table wherever today converged.
  - Where today hit the cap, it is a superset of the fallback.
  - Both tables are self-consistent, so it is safe.
- **Contract alternative:** `letPos(exposed) = true`. TL2b disappears; the cost is a worker + shim
  for unused exported specs (code size only).

### 4.4 TL2c: psplit, a real global fixpoint

**Why it needs a global fixpoint.** An importer's call site can justify an exported callee's
`$psplit` (up). The importer's own parameter admission can depend on the callee's promoted
positions (down). The *seed* rule, "a parameter already split counts as constructish"
(`Backend.elm:1088-1104`), closes the loop. This is a cross-unit cycle that bottom-up solving
cannot handle.

**Summary S2c.** Extracted after the unit's sret table is fixed, using `walkPromo` in a collect
mode that records every pass-through.

| Record | Content |
|---|---|
| `clauses` | per candidate (f, i): shape kind `{T2, T3, Ctor n}`, slot types, `localOk`, pass-throughs `[(calleeKey, pos)]` |
| `justifications` | per site per position, pre-matched against the callee's static shape: `Static(f, j)` (inline or let-bound construct, sret binder or call), or `Seed(f, j, e, p)` (enclosing spec e's own parameter p) |

Components with no imported or exported atom are solved locally and not published. ~950
candidates program-wide, mostly local, so the published cone is under 100 KB.

**Solve: Jacobi rounds from ∅, exactly today's operator.**
- `cand_n(f,i) = localOk ∧ passthroughs ⊆ allow(T_n)`.
- `just_n(f) = ∃j: cand_n(f,j) ∧ (Static ∨ Seed matched in T_n)`.
- `T_{n+1} = {f ↦ cand plans | just_n(f)}`; stop at a fixpoint or n = 4.
- Monotone and order-free, so it **reproduces today exactly**, cap included. Optionally, an uncapped
  worklist gives a superset only where a > 4-deep pass-through chain was truncated.

**Slice(U):** plans for every f that U defines or directly calls.

**Re-run:** U's codegen and back end.

**Contract alternative:** `just(exposed) = true`.

### 4.5 Ordering inside TL2

- **TL2a before sret/psplit.** AbiCloning's devirt rewrites a local closure call into a direct
  global call (`AbiCloning.elm:1629-1634`), creating new let-sites, leaf callees and psplit sites.
- **sret before psplit.** psplit excludes sret members and is justified by sret binders.
- **TL1 before TL2a.** E needs the settled rows (unless §3.1's measurement removes TL1).

## 5. TL3: the back end (two-stage per-unit lowering)

### 5.1 The two stages

- **Stage 1** = parse → eco passes → EcoGCPrepare → EcoToLLVM → ListCursor → TailConversions → a
  new **EcoUnitSummary** pass. Cache key: unit input bytes + stamp. About 12 % of a unit's
  lowering.
- **Thin link.**
- **Stage 2** = a new **EcoUnitApply** pass (erase dead, stamp facts, fill `$sat`) → translate →
  marker expansions → plan-given hoisting → `expandInlineAllocs` → Export → `$cap` prepass →
  gc-free finish → RS4GC → `-O2` → emit. Cache key: (stage-1 artifact hash, slice hash, stamp).
  About 88 %.

**Why this is exact.** Today's three closed-world passes already run last
(`runtime/src/codegen/EcoPipeline.cpp:187-206`), and the spikes matched LLVM exactly there. So:
- each pass's **local scan** moves to stage 1;
- its **solve** moves to the link;
- its **stamping** moves to stage 2.

This reproduces today's whole-program facts bit for bit, except where a contract below
deliberately gives something up.

### 5.2 Summary S3 (EcoUnitSummary, after TailConversions)

| Record | Content | Self-compile size |
|---|---|---|
| Symbol table | every symbol op: stable name; `isFunc/isGlobal/isDef/interposable/exposed/rootName/trustedName`; hash of the LLVM function type | ~150k defined + ~18k foreign declarations: ≈ 2 MB + ≈ 7 MB of names |
| Per defined function, cap | `ownBytes`; `localTop` (Loop/Other) | 98k × ~8 B |
| Per defined function, gc | `poisonAlways`; `hasUnlessCovered` (any `__eco_alloc_inline`) | 98k × 2 B |
| Callee list | per direct call to a generated symbol (local or **ExtEdge**): `(target, nOutsideLoop, nInLoop)`. Per-site counts are kept because `caphoist::solve` sums per site. | ~96k pairs ≈ 0.8 MB |
| Refs | per symbol op (functions and globals): `(target, kinds ⊆ {Call, CallMismatch, Address})`, the symbol-graph CSR row | ~150-250k ≈ 1 MB |
| Closure demand | per target: `minCaptured_u`, arity, rk; the unit's `SatSigs` set; per *owned* descriptor: `(target, P, kinds, rk, shapeOk mask)` | ~16k descriptors ≈ 0.4 MB |
| Unit | `extraRoots/extraTakes` (empty today); `hasInit`; per-definition `listFwdRewritten` bit | tiny |

**Total:** ≈ 6 MB without names, ≈ 13 MB with, i.e. 25-50 KB per unit. Collection reuses today's
scanners: `symgraph::build`, Phase A, the gc-free scan.

**The one rule change: ExtEdge.** Today a direct call to a declaration is ⊤/poison, because every
generated callee is defined in the whole module. Per unit, a direct call to a non-trusted
declaration is recorded as ExtEdge(name), with its locally computed verdict.
- The link resolves the name: an ordinary callee edge if it is defined somewhere, else the local
  verdict (e.g. BytesFusion runtime names).
- Call vs CallMismatch is still decided locally against the declaration's type. That is sound only
  if the declaration type equals the definition type, so **the link checks type hashes** (this
  replaces S6/V4).

**Prerequisites** (shared with the hand-off plan, Phase 2):
- **veq pinned in the stamp** (today it reads whether `Utils_equal` survived *this* module's
  declaration strip, which differs per unit);
- **kernel declaration attributes a pure function of the symbol;**
- **de-static the `$sat` state.**

### 5.3 Solve (in order; ≈ 30-40 ms + ≈ 50-100 ms I/O and hashing)

1. **Resolve:** intern ~170k names; resolve each ExtEdge.
   - Fatal: a declaration type hash ≠ its definer's; an unresolved non-trusted call; a cross-unit
     reference to a non-exposed symbol.
2. **Reach:** BFS from `main`, the link unit's `__eco_init_globals` and `extraRoots`, over all ref
   kinds (`EcoReachability.cpp:92-102`, 9 ms).
3. **addrTaken and eligibility:**
   - addrTaken = ⋃ `CallMismatch|Address` edges from *reached* referrers;
   - eligible = ¬interposable ∧ ¬addrTaken ∧ ¬root (`EcoCapHoistPlan.cpp:185-235`).
4. **Cap solve:** `caphoist::solve` unchanged, over live definitions (14-17 ms).
5. **gc-free fixpoint.** Seeds:
   - `poisonAlways`;
   - `hasUnlessCovered ∧ ¬covered`;
   - `covered(g) ∧ ¬covered(f)` per edge.

   Worklist from `EcoGcFreePropagation.cpp:309-326` (11 ms).
6. **`$sat` masks:**
   - global `SatSigs` = ⋃;
   - `minC(fn)` = min over creators;
   - `mask(D) = shapeOk ∧ {N ≤ P − minC} ∧ {(N, kinds-slice, rk) ∈ SatSigs}`.

   Safe in both directions, so a per-unit fallback is still sound.
7. **Emit slices and hashes.**

### 5.4 Slice(U), projected

- **Own definitions:** live/dead; `Top | Budget n` plus the covered bit; the gc-leaf bit.
- **Foreign callees directly called by U's live definitions** (~68 per unit):
  - the cap fact projected to `Covered n | Zero | Other`;
  - the gc-leaf bit.

  Written onto U's declarations in Apply.
- **Owned descriptors:** `mask(D)`.
- **Excluded:** reasons, raw `SatSigs`, facts about symbols U only takes the address of.

Size ≈ 0.35 MB in total.

### 5.5 Per-fact treatment

| Fact | Treatment |
|---|---|
| Reachability | **Exact, via the link.** The alternative (keep all exposed definitions, `--gc-sections`) costs addrTaken precision and keeps dead stackmaps. |
| Linkage | **Contract:** Export (hidden) ⇔ exposed, applied after hoisting (everything is Internal during hoisting). The link only *checks* that cross-unit references target exposed symbols. |
| Cap budget / coverage, gc-free | **Exact, via the link.** Recovers the 42-58 % of coverage that X3's R4 contract loses. Order: cap, then gc-free (5,073 of 8,558 stamps exist only through coverage). |
| Wrappers, eval descriptors | **Contract:** the owner mints them for local demand *and* every exposed closure-able definition. Link reachability erases the dead ones. Creators of foreign targets emit declarations only. One identity per fn keeps HEAP_033 interning and the `==` pointer fast path intact. Kernel artifacts go to a fixed, link-synthesized kernel-artifact unit. |
| `$sat` entries | **Link** (masks), filled in stage 2. EcoToLLVM never re-runs because of the link. |
| List-template phase 2 | **Contract only.** It runs at eco level and rewrites the callee *and every caller*, so a thin link would need a third stage. License only non-exposed definitions, which keeps all uses intra-unit. The link checks that no foreign reference targets a `listFwdRewritten` symbol. |
| veq, list chunks | Pinned in the stamp; chunks travel as a first-definition attribute (all three readers, hand-off P1) |
| `__eco_init_globals` | Each unit emits `__eco_init_globals$u` (exported). The link unit's `__eco_init_globals` registers the type graph and calls each non-empty one. |

### 5.6 What re-runs

| Change | Re-runs |
|---|---|
| A unit's input bytes | Its stage 1. Then the link. Then any stage 2 whose artifact hash or slice changed. |
| An own fact, liveness or mask | The owner's stage 2 |
| A foreign callee's *projected* fact | Callers' stage 2. Budget ripples stop at the first non-eligible caller. |
| The stamp | Everything |

**Critical path of an edit:** stage 1 of the dirty units + ~0.1-0.15 s of link + the slowest dirty
stage 2.

## 6. All summaries at a glance

| Link | Per-unit summary | Size (self-compile, est.) | Solve | Slice | Exact? |
|---|---|---|---|---|---|
| TL1 settles | `ctorRows`, `flexMarks`, `homes` | ~1-1.5 MB | union + two linear sweeps | own healed rows, homes read set | Yes, with name→global keying and an order-free heal (both deliberate changes) |
| TL1 taint | `taintHarvest`, `residualVars` | small | union | T ∩ own residuals | Yes for Prune's close; translation reads are replaced by import-closure harvests |
| TL2a AbiCloning | `blocked`, `groups`, `census`, `consulted` for E-members | ∝ \|E\| (small?) | one-shot joins | merged MemberInfo, local-first representative | Sound; may stamp more than today |
| TL2b sret | let-sites on imported exposed callees | KB | OR | `letPos` bits for own exposed specs | Equal where today converged; superset where it hit the cap |
| TL2c psplit | clauses + justifications (cross-unit cone) | < 100 KB | Jacobi lfp, cap 4 | plans for own and called specs | Exact |
| TL3 back end | symbol table, cap/gc locals, callee lists, refs, closure demand | ~6-13 MB | resolve → BFS → eligibility → `caphoist::solve` → gc fixpoint → masks | own facts, projected callee facts, masks | Exact (validate twin) |

## 7. Relation to the partitioned hand-off plan (EmitPlan)

**Obsoleted, for the incremental profile.** EmitPlan's *front-end* computation of reach, cap and
gc-free is replaced:
- the conservative Mono-level summaries;
- the E1 tally;
- the `Lower.OpEffects` mirror;
- the V8/V9 precision twins.

The back-end summaries are exact and reuse the same C++ core, so nothing can drift.

**Shared prerequisites:**
- the hand-off Phase 2 items: cmp3 declared by the front end, veq from the stamp, the `pos_view`
  row fix, order-independent `_tail_` names, kernel attributes from the symbol, de-static `$sat`;
- the partition-mode machinery: internalize then Export after hoisting, flag synthesis,
  `removeDeadConstantUsers`, the join checks, local completion.

**Conflicts:**

| Conflict | Hand-off plan | Thin link | Resolution |
|---|---|---|---|
| Clean-build streaming | Front-end facts exist so partitions can lower fully *while* codegen streams | A barrier: stage 2 (~88 % of the work) cannot start until the last unit's stage 1 | Streamed clean builds favour EmitPlan; incremental builds favour the exact link |
| Authority | V5 forbids per-partition planning and binds front-end facts | Facts come from the back end | A per-build **mode in the stamp**, never mixed per fact |
| Usage-dependent ownership | Closure owner, kernel owner and Export decided by usage | Needs usage-independent rules | §5.5's rules; 06 §6 already asks the hand-off plan to keep this open |

## 8. Measurements that decide the remaining choices

1. **Settles' effect on E9.5.** Run AbiCloning with pre-settle vs settled rows. If the difference
   is negligible, TL1-settles is unnecessary.
2. **The `settleCtorRows` order hazard.** Check the clean compiler for ⊤ / `LPartial` / `LSet`
   orderings that drop partial inhabitants.
3. **|E|:** members escaping through signatures or rows. That sizes TL2a.
4. **How often today's caps fire:** the sret 30-round cap and the psplit 4-round cap.
5. **Extra dynamic slots** under the staging contract.
6. **Over-minted wrappers** under the exposed-wrapper contract. **Licence loss** under the
   list-template contract.
7. **Slice-hash churn under the X1 edit replays,** per link. This measures how often a link change
   actually dirties anything.
8. **Validate twin:** zero diffs between thin-link facts and today's whole-program facts on the
   self-compile and the E2E suite.
