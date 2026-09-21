# LSS compile-time optimization survey — 26 steps, specified and in implementation order

Date: 2026-09-18 (the day after all 31 LSS flags were fixed at their defaults, LSS_041); §9
(the implementation specifications) and §10 (the corrections they forced on §2) were added
2026-09-19, against the tree saved as `snapshots/lss-loop/base`.

Contents: §1 where the time goes · §2 the 26 steps in implementation order, with the dependency
table · §3 cross-cutting notes · §4 the 22 numbered items considered and set aside · §5 agent
records · §6 how to gate a step · §9 one implementation specification per step · §10 what the
specifications corrected in §2. The measurement loop that consumes this plan is
`benchmarks/lss-compile-opt-loop.md`.

Scope: the compile-time cost of the LSS analysis inside `Compiler/MonoSolver/*` (Engine, Store,
Translate, LssInfer, Monomorphize, Zonk), its key machinery (`AST/Monomorphized`, `AST/Intern`,
`Monomorphize/Registry`), and the runtime services it drives. Post-mono consumers (AbiCloning) and
runtime-level items are included where the profile put them on the critical path.

Method: (1) seven parallel code-reading agents, one per angle (Step monad / settle chain / Store /
LssInfer / Translate / key machinery / cross-cutting sweep), full-file reads with `file:line`
citations — their records are summarised in §5; (1b) a second wave of twelve agents that lowered
every step to the implementation specifications in §9; (2) two `perf record` profiles of the native
compiler (`bin/eco-lss-post`, post-flag-removal, RelWithDebInfo) compiling its own front-end under
`ECO_MONO_ENGINE=solver ECO_MONO_LSS=1` per `benchmarks/lss-opt.md`: a 199 Hz frame-pointer run
(80,834 samples) and a 49 Hz DWARF-unwound run (19,907 samples) whose call chains were attributed
to the nearest Elm caller (script: session scratchpad `prof2/attrib.py`). Both runs: 6:47 wall,
12.7 GB RSS, GC 144 s (35.5 % of wall: minor 119.8 s, major 24.2 s), true mutator 261.7 s.

## 1. Where the time goes

Timeline (perf samples bucketed by 10 s, classified by symbol): the per-module front end
(parse/typecheck/typed-opt/artifact encode) runs 0–205 s; the monomorphization phase (first to last
`Compiler_MonoSolver_*` frame) runs ~227–377 s in the DWARF run; GlobalOpt + MLIR emission take the
remaining ~28 s. **The mono phase is ~48 % of wall.** Within it, only ~18 % of samples land in
compiled Elm code (Store 4 %, UnionFind 2.9 %, Unify 1.3 %, Monomorphized 1 %, Translate 0.45 %,
LssInfer 0.27 %, Engine 0.25 %, Monomorphize 0.07 %); the rest is runtime services the LSS code
drives. Attributed to the nearest Elm caller (DWARF), the mono window decomposes as:

| cluster | % of mono window | evidence |
|---|---|---|
| `Intern.probe` (K6 hash-cons hit check) | **19.6 % inclusive** | equality 8.8 %, resolve 2.8 %, Dict 2.4 %, memmove/memcmp 2.1 %, strings 1.4 % all nearest-caller `Intern_probe`; `Data_HashMap_scanBucket` 17 % inclusive |
| GC | **~21 %** | `NurserySpace::evacuate` 6 %, memcpy under `minorGC` 11 %, `eco_gc_push_stack_range` 2.6 %, scan/mark ~2 % |
| closure dispatch | **13.9 %** | 6.3 % nearest `System_TypeCheck_IO_andThen` + 2.3 % `IO_map` (Unify's CPS monad), `revMemoSetIfAbsent` 1.1 %, `mRecord` hash fold 0.8 %, `typeHasResidualNumber` 0.7 %, `harvestSuperTableExcept` 0.5 % |
| union-find store | **~12 % inclusive** | `unionS` 7.9 %, `freshS` 4.1 %, `writePointCellS` 6.9 %, `newPointCellS` 3.9 %: Array path-copy memmove 4.0 %, `Array_*`/`eco_clone_array` 4.75 %, GC 1.7 % |
| member-key strings | **6–8 %** | `internMemberKey` 3.6 % inclusive (string compare 3.2 %, Dict 3.2 %, resolve 1.8 %), `lambdaMemberLayoutQualified` 2.75 %, `insertMemberKey` ~1 % |
| enqueue key work | **9.2 % inclusive** (`enqueueSpecStamped`) | `stampSelfSpine` 4.0 %, `Intern.widenSets` 5.1 %, `enqueueSpecKeyed` 6.3 % |
| record types in load/zonk/classify | **10–12 % inclusive** | `loadRecordFieldsC` 11.6 %, `zonkRecordFieldsC` 9.8 %, `classifyRecordFields` 10.3 %, `Unify.unifyRecord` 3.9 % — the compiler's own `S`/`Env`/`ItemAux` records |
| string-pattern `case` arms | **2.2 %** | `normalizePrimHome` 1.6 % + `classifyApp` incl.: per-evaluation `eco_alloc_string_literal_utf8` (interning-table probe) + `Utils.equal` per pattern (`EcoToLLVMControlFlow.cpp:470-490`) |
| `Allocator::resolve` out-of-line | **7.7 % self** | `hpointerToPtr` → `resolve()` (`RuntimeExports.cpp:56-64`) from every kernel export; `resolveFast` exists (`Allocator.hpp:67`) but is not used there |
| GC-stats `clock_gettime` | 1.6 % (mono) / 8 % (front end) | `build` preset has GC stats on; timers around `allocateSlow`, survival/promotion records |

Other inclusive shares worth knowing (mono window): `Translate.classify` 19.3 % (→ `classifyGo` 12.2 %),
`Store.loadType` 15.6 %, `zonkToMono` 11.8 %, `translateGlobalCallSlow` 16.0 %,
**`translateGlobalCallFast` 0.00 %** (no DWARF sample had it on the stack; the frame-pointer run shows 0.01 % for its
closure wrapper, so it IS taken but is at the sampling floor — call COUNTS are unmeasured; `lssFastOk` needs a
trivial signature and no arrow-typed argument, and LSS_013 spine injection makes signatures non-trivial), `translateGlobalCallGroundMemo`
1.3 %, `LssInfer.signatureFor` 8.4 % (the lazily-run inference walk: `walkExpr` 8.0 %, `applyCalleeAt`
4.8 %, `instantiateWithSignature` 3.5 %), `connectTypes` 7.0 %, `translateVarRef` 7.7 % (`classifyRef`
4.4 %), `classifyLambdaHead` 6.5 %, `Unify.unify` 6.1 %, `settle*` 2.0 %, `pruneGraph` 2.1 %,
`revMemoSetIfAbsent` 2.2 %, `Prune`'s `typeHasResidualNumber` 1.4 %.

Two structural facts settled by agent A (Backend.elm 418-524, Expr.elm 7733-7790,
EcoToLLVMClosures.cpp 2359-2393, CGEN_067): a direct `( a, State )` return DOES get a heap-free
`$sret` worker (zero-capture callee, MTuple 2/3 result, tuple-literal leaves or direct calls to
promoted callees, direct saturated call at a `let ( a, s ) = …` site; `MonoIf` on the result spine
is not admitted for closures — a 6-line `sretTailOk` change); `Result Failure ( a, S )` NEVER does
(Backend.elm:431 matches MTuple only; REP_AGG_001) — every `Ok ( a, s )` is a heap Custom + Tuple2.
That is why the July trailing-`S` conversion (plans/monosolver-performance-optimization.md, A1)
measured neutral: it kept the `Result`.

## 2. The candidates in implementation order

The list is ordered by expected win, EXCEPT that a step whose prerequisite sits lower is placed after
that prerequisite, and the prerequisite is pulled up to just ahead of it. Old item 23 was split into
23a (the residue cleanup, which two big rewrites assume — now step 6) and 23b (regrouping `S`, which
only pays after the rewrites — now step 26); old item 25 (measurement hygiene) is step 1 because every
A/B below is otherwise measured with its overhead inside. "Was" is the number in the impact-ranked
version of this list, kept so earlier discussion stays traceable. Impact = expected reduction of the
MONO-PHASE wall (the phase is ~48 % of the run). Effort S/M/L. "BI" = expected byte-identical
emission (the substrate gate of benchmarks/lss-opt.md).

| step | was | what | impact | effort | depends on / placement |
|---|---|---|---|---|---|
| 1 | 25 | GC-stats timer overhead (measurement hygiene) | hygiene | S | no dependencies; pulled to the front because every A/B below is otherwise measured with this overhead inside |
| 2 | 1 | hash-cons equality O(arity) | H | M | no dependencies |
| 3 | 2 | transient union-find store | H | L | no dependencies; PREREQUISITE of step 19 (its `Eco.CellStore` module). The riskiest change — a new kernel module with GC rooting; it may be slid after step 10 without disturbing the rest (the spec composes with step 10 either way). Two entries: `3a` package + pure twin + pins (not measured), `3b` the measured BI change — `3b` is NOT split further, it is not correct in halves — §10 (p) |
| 4 | 7 | ground alias-subtree memo (load/classify) | M-H | M | no dependencies; also cuts the probe count that step 2 makes cheaper |
| 5 | 4 | direct-state `Unify.unifyS` | M-H | M | no dependencies; PREREQUISITE of step 10. Two entries: `5a` = the `unifyS`/`unifyStep` entry + Store/Translate/LssInfer callers (the step-10 prerequisite), `5b` = the combinator layer + `UResult` (revertable on its own) — §10 (c) |
| 6 | 23a | flag-residue/dead-arm cleanup | L (enabling) | S | no dependencies; PREREQUISITE of steps 8 and 10 (pulled ahead from old item 23) |
| 7 | 10 | census bookkeeping off the default path | M | S | no dependencies; PREREQUISITE of step 15 and simplifies steps 8 and 10. Only `7a` (gate the counters) is built; `7b` (`ItemAux.counters`) cannot move a timed stat and is SKIPPED — §10 (d) |
| 8 | 11 | no `S` copy on pure reads (`UF.peekS`, one write-back) | M | S-M | after steps 6 and 7 |
| 9 | 8 | skip ground arrow-free `enrichFromEnv`/`connectTypes` | M | S | no dependencies; done before step 10 so the rewrite has fewer sites to convert |
| 10 | 3 | retire `Step` (direct state + `$sret`) | H | L | after steps 5, 6, 7 (and 8, 9 by choice); seven entries `10a`–`10g`, `10a` (the `sretTailOk` `MonoIf` admission) is a codegen change and NOT BI (extra bootstrap turn); `10b`–`10g` are BI — §10 (e) |
| 11 | 6 | one widen per enqueue + memoised `widenSets` | M-H | S-M | no hard dependencies; done before step 13 because step 13 keys on the single canonical widened type this step produces. Entries `11a` (one widen, lazy render) and `11b` (memo); the plan's "test the annotation before minting" is analysis-order (not BI) and is a separate optional `11c` — §10 (f) |
| 12 | 9 | dense `GlobalId` + Int-keyed per-global memos | M (enabling) | M | soft dependency on step 11 (the edit list assumes its `enqueueSpecStamped` shape); PREREQUISITE of step 13 only — steps 16, 23 and 25 turned out NOT to need it (§10 (a)). Entries `12a` (facts/ids/signature memos, the win) and `12b` (tallies, registry re-key) |
| 13 | 5 | member identity as Int keys | M-H | L | after steps 11 and 12; the class table is keyed by `eqKeySpec` (the registry's own equality), not by `==`; split `13a` (non-lambda kinds) / `13b` (lambda mints + `specWidenedKeys` retirement) — §10 (g) |
| 14 | 12 | runtime: inline `resolveFast` in `hpointerToPtr` | M | S | no dependencies (runtime C++); can proceed in parallel with everything above |
| 15 | 16 | `enqueueSpecKeyed` hit path | L-M | S | after steps 7 and 11; WHICH edit applies depends on where step 11 left the widen (`15a` BI if step 11 passes the widened key in; `15b` moves the widen and needs the rail + a bootstrap turn) — §10 (h) |
| 16 | 13 | inference walk: skip set-inert work | M | S-M | loop order after step 15; NO hard dependency on step 12 (the per-global facts only make `16a`'s probes cheaper). `16a` (D1/D2/D4/D8/D10/D12) is BI; `16b` (drop callee mints) is not and is optional/dropped after step 13 — §10 (a), (i) |
| 17 | 17 | `Data.HashMap` buckets → array | L-M | S-M | no dependencies; kept adjacent to the Intern work |
| 18 | 14 | string-pattern `case` arms | L-M | S | no dependencies; `18b` (backend: cached literal intern, BI) is built FIRST, `18a` (Elm: length-first dispatch, fixed-point gate) second — §10 (j) |
| 19 | 18 | `revMemoSetIfAbsent` | L | S | after step 3 (needs `3a`'s `Eco.CellStore`). The store does NOT subsume `revMemo`: it becomes a SECOND cell store with a paired lifecycle. Fallback `19′` (geometric `Array` growth, about half the win) only if step 3 is slid to the end — §10 (p) |
| 20 | 15 | `Point` equality via `pointKey` | L-M | S | no dependencies |
| 21 | 19 | member-table Int dicts → `Array`/`BitSet` | L | S-M | step 13 NOT required: `specWidenedKeys` becomes `Array (Maybe String)` here and step 13 narrows the payload to `Int` later; `muTied` and every `ItemAux` field stay `Dict` (cold or non-dense) — §10 (k) |
| 22 | 20 | `specializeLambda`/overlay rebuild waste | L-M | S | no dependencies: part (b) is specified WITHOUT step 13 (return the id from the first mint); three entries `22a` (a+b), `22c`, `22d` — §10 (l) |
| 23 | 22 | kernel-boundary translation | L | S | step 12 NOT needed (kernels are `VarKernel` occurrences, never `TOpt.Global`s, so a `GlobalId` never covers them); stands alone after step 7 — §10 (a) |
| 24 | 21 | settle chain + Prune walks | L | S | no dependencies |
| 25 | 24 | AbiCloning fingerprints and spec scans | L-M | M | step 12 NOT needed (post-mono `Mono.Global` carries no id; the spec keys on `Mono.globalHash`); post-mono, outside the profiled window; entries `25a` (fingerprint + flattened groups), `25b` (registry rows + `hostGlobal` gate) — §10 (a) |
| 26 | 23b | regroup `S` by co-update | L-M | M | LAST — after steps 7, 8 and 10; `lambdaCounter` STAYS a top-level field; entries `26a` sched / `26b` runMemo / `26c` letCtx / `26d` drv; skipped if the §2 census shows < ~10 M surviving `S` copies — §10 (m) |

**Step 1 (was 25). Measurement hygiene: GC-stats timers in the `build` preset (runtime)** — impact: 3–5 % of
wall in every benchmark taken with this preset (vdso `clock_gettime` is 8 % of the front-end window,
1.6 % of the mono window), effort S. `GC_STATS_TIMER_START` brackets `allocateSlow`, and
`recordSurvival`/`recordPromotion`/`recordOldGenAllocation` are per-object; either sample them or
switch to a cheaper clock, and state in benchmarks/lss-opt.md that the protocol's walls include this
overhead.

*Depends on / placement:* no dependencies; pulled to the front because every A/B below is otherwise measured with this overhead inside.

**Step 2 (was 1). Make hash-cons equality O(arity) instead of a deep structural walk** — impact H (~10–15 %),
effort M, BI yes. `Intern.probe` (Intern.elm:194-201) confirms a bucket hit with `eqExact` = Elm
`==` (Intern.elm:234). On the 99 % hit path the FRESH node is never pointer-identical to the
canonical one, so the kernel `eqHelp` walks it: for `MRecord Int (Dict Name MonoType)` that is
`dictEq` (Utils.cpp) — two `std::vector` allocations, an in-order walk of both red-black trees, a
string `memcmp` per field name (`StringOps::equal` 2.25 % of the window) and a resolve per slot;
for `MCustom` it compares `ModuleName.Canonical` strings; for `MFunction`/`MCustom` it walks fresh
arg-list spines. Children ARE canonical, so their comparison is O(1) pointer equality — the waste
is entirely in the container shells. Proposals, in order of leverage: (a) give every interned node
a unique `internId : Int` (assigned by `hashCons` on insert; hash-consed children carry it), and
make `eqExact` compare `(tag, packed hash, child ids, names)` with no descent — the leading packed
hash Int is already a field on every composite (K4), so the mechanical change is the same shape;
(b) short of (a), replace `eqExact` with an Elm comparison that never enters `dictEq`: `Dict.size`
then a parallel `Dict.foldl` comparing values with `==` (O(1) on canonical children) and keys with
`==` — removes the vector allocations and resolves; (c) reduce probe COUNT with step 4. Evidence
gap: none — `Intern_probe` is 19.6 % inclusive with 15.2 % of samples containing `eqHelp`.

*Depends on / placement:* no dependencies.

**Step 3 (was 2). A transient (in-place) union-find store for the per-item scratch store** — impact H (~8–10 %),
effort L, BI yes. `IO.State.ioRefsPoint : Array PointCell` is a persistent 32-way trie; every
`UF.set`/`union`/`fresh` clones a path (`Array_setHelp` → `eco_clone_array` → memmove) and every
`freshS` pushes (`Array_unsafeReplaceTail`, `elm_array_push_box`). The mono engine threads the
store LINEARLY (`resetItem` installs a fresh store per item, Engine.elm:2433; the only
snapshot/restore sites are `withScratchStore` 2033-2100, `retranslateAt` Translate 5972-6016 and the
report-gated `rezonkSettled`/`qShadowCensus`). A kernel-backed mutable cell array with
copy-on-snapshot (version-stamped chunks, or an explicit `snapshot`/`restore` API used at those
sites) turns each write into a store instead of a path copy. The typechecker shares
`UnionFind`/`IO.State`, so it benefits too (its `Solve` also threads linearly). Risk: this is a
representation change under HEAP/REP invariants — an aliasing bug would be a silent miscompile;
gate on the 633-workload rail + bootstrap. Evidence: UnionFind + IORef ≈ 12 % inclusive. The specification (§9)
settles the design as an off-heap cell vector in a new `Eco.CellStore` kernel module, rooted through the runtime's
external-root scanner (the HEAP_040/MVar precedent), with an explicit undo-log `pushMark`/`rollback`/`commit` used at
the three rollback sites and the two report-gated census sites — not the version-stamped chunks guessed at here. It
also notes an upside this survey did not count: the typechecker shares `IO.State`, so the front-end window gets the
same per-write saving, and the loop times the whole self-compile.

*Depends on / placement:* no dependencies, and PREREQUISITE of step 19. Still the riskiest change; it may be slid to
after step 10 to de-risk (the specification composes with the `Step` retirement either way), in which case step 19
runs its `19′` fallback. Entries `3a` (kernel package, pure twin, pins — not measured) and `3b` (the measured,
byte-identical compiler change).

**Step 4 (was 7). Memoise ground, arrow-free alias-typed subtrees per item (load) and per run (classify)** — impact M-H (~5–8 %), effort M, BI yes for the arrow-free subset. `loadTypeC` memoises only `TVar`s
and arrow slots; ground structure (`App1 Int []`, records of scalars, the 31-field `S` alias body)
mints fresh Points on every load, and `classifyGo`/`zonkFlatC` re-hash-cons every node of the same
type at every occurrence (`loadRecordFieldsC` 11.6 %, `zonkRecordFieldsC` 9.8 %,
`classifyRecordFields` 10.3 %, `classifyGo` 12.2 % inclusive; `mRecord`'s hash fold 1.5 %; most of
step 2's probes). Sharing the Points of an ARROW-FREE ground subtree across loads within an item is
sound (immutable structure — unifying identical ground structures is a no-op; LSS_006 concerns
arrows only) and a ground arrow-free `Can.Type` classifies identically in every item. Proposal: a
per-item `HashMap` keyed by alias `(home, name)` (+ ground args) → loaded root Point in `LoadCtx`,
and a per-run memo `(home, name, ground args)` → canonical `MonoType` consulted by `classifyGo`/
`Zonk.canTypeToMonoWithI`; extend to `TRecord` occurrences with a stamped node id if the alias
cases are not enough. This attacks probe count (step 2), record work, and `Unify.unifyRecord`
(3.9 %) at once. Evidence gap: count loads/classifies whose canType is a ground alias.

*Depends on / placement:* no dependencies; also cuts the probe count that step 2 makes cheaper.

**Step 5 (was 4). Direct-state entry for `Unify.unify` (`unifyS`)** — impact M-H (~5–8 %), effort M, BI yes.
`Store.unifyStep` → `Unify.unify` → `guardedUnify` → `Unify k` → `k []` → `IO.andThen` →
`IO.pure (AnswerOk …)`: ~10 allocations and 1–2 `S` copies per unification before any structural
work (Unify.elm 51-79, 89-130; Store.elm 1031-1068). The DWARF profile puts 8.5 % of the window's
dispatch under `System_TypeCheck_IO_andThen/map` and `Unify.unify` at 6.1 % inclusive. The P1
precedent (UnionFind's "DIRECT STATE-PASSING CORE") applies: export
`unifyS : Variable -> Variable -> State -> ( Answer, State )` running `guardedUnify`'s body directly
(error arm keeps `toErrorType` off the hot path); `unifyStep` becomes `S -> ( Bool, S )`. Shared
with the real typechecker, which also gains.

*Depends on / placement:* no dependencies; PREREQUISITE of step 10 (the Step retirement needs `unifyStep : S -> ( Bool, S )`).

**Step 6 (was 23a). Flag-residue and dead-arm cleanup that unblocks the direct-state rewrites** — impact L on its own, effort S, BI yes. The inner `if lss.enabled` in `enqueueSpec` is unreachable; `LoadCtx.arrowIdOn`/`arrowMintOn` and `LssZonkAcc.groundStandalones`/`honestSources` are constant in production (only tests seed the other value — give them their own entry point); `unifySlotWithSetSlow` + `SetWriteCtx.needSlow` are measured-dead (`setWriteSlow = 0` across the self-compile) and deleting them removes the `Result` from `foldSetWrites` — the one thing keeping the spine/successor injectors (`injectSpineMemberId`, `injectPapSuccessors`) from being `S -> S`; `bumpArgFlowCensus` keys are concatenated before the gate at ~24 sites (hoist the `report` test); dead `unifyParamsWithArgs` and `unifyParamsBestEffort` in Translate (confirm tree-wide). Pulled forward because the Step retirement (step 10) and the pure-read fix (step 8) both assume it.

*Depends on / placement:* no dependencies; PREREQUISITE of steps 8 and 10 (pulled ahead from old item 23).

**Step 7 (was 10). Census bookkeeping off the default path** — impact M (~2–4 % + GC), effort S, BI yes.
`Store.foldZonkStats` runs per `zonkToMono` call: copies `S` + 32-field `LssStats` (+ `SigFlowStats`)
and folds two `Dict Int Int` histograms that `bumpZonkAcc` inserts into UNGATED per set readback
(654K/run) — `sizeHist`/`widenedSizeHist` are read only by `renderLssReport`; `zonkToMono` allocates
a 22-field `LssZonkAcc` (16 census-only fields) + 10-field `ZonkCtx` per call. Unconditional
`{ s | lssStats = { st | … } }` bumps (64 refs each): `bumpKeyedHit` 98K, `mintLayoutQualified`
83K (triple copy), `bumpCompletionJoin(Noop)` 43K, `bumpDevirt*`, `bumpWidenedBy*`,
`recordKernelMiss` (builds `home ++ "." ++ name` and a `Dict String` histogram), `slotsMinted` per
slot-minting load, `foldSetWrites` per traversal (205K). Gate the histograms on `censusOn`; keep
the few live counters (`flexCtorSpecs`, `joinRounds`, `retranslations`, `setsZonked`) as Ints in a
small `ItemAux.counters` folded ONCE at `finishNode` (the `SetWriteCtx` pattern at item level).

*Depends on / placement:* no dependencies; PREREQUISITE of step 15 and simplifies steps 8 and 10 (fewer `lssStats` writes to convert).

**Step 8 (was 11). Stop copying `S` for reads that change nothing** — impact M (~2–3 %), effort S-M, BI yes.
`writeBackShared` (Store 150-176) makes two `S` copies + an `ItemAux` copy per `loadType`
because `arrowIdOn` is hard-wired True; ~30 sites do `{ s | store = store1 }` or
`liftIO (UF.get …)` after a PURE read (`UF.getS` returns the same state for root/one-link chains,
"the overwhelmingly common case"; `addSlotSource` = three `liftIO`s per edge; `ordinalOfGo`/
`repOrdinal` per probe); `zonkToMonoC` copies the 10-field `ZonkCtx` per zonked NODE; `classifyGo`'s
TVar miss copies `S` + `ItemAux` per erased-var occurrence (MONO_029 key log); `Engine.scoped`
copies per branch/lambda/let, `insertVar` per binder. Add `UF.peekS` (non-compressing read), a
single guarded write-back with a `memoInserts` flag, drop `store` from `ZonkCtx`, thread the
MONO_029 read list as an accumulator written once per `classifyDirect`.

*Depends on / placement:* after steps 6 and 7. **8a MEASURED AND REVERTED 2026-09-19** (loop entry `8a`): wall flat, minor GC +11, promoted +50 MiB, RSS +73 MB. Step 3 removed the cost this step targets — a compression write is now one C call, not a trie path copy — while the cost of NOT compressing is unchanged, because compression is work that pays forward. Re-read 8b against the current tree before building it; and see the loop entry for a better target the run surfaced: `writePointCellS` allocates an `IO.State` record and a `Store` wrapper per WRITE, both holding what they already held.

**Step 9 (was 8). Skip `enrichFromEnv` re-encoding and `connectTypes` unification for ground, arrow-free types** — impact M (~3–5 %), effort S, BI yes. `enrichFromEnv` (Translate 4770-4870) re-encodes the ENTIRE
varEnv-bound MonoType into fresh store structure (`monoTypeToVar`, a Point per node — hundreds for
`s : S`) on every local-variable argument/callee and unifies it, right after `loadType` minted the
same structure; `connectTypes` (165-181) loads both canTypes (each `writeBackShared` = 2 `S` copies +
`ItemAux` copy) and unifies for every let, case branch, if, list ELEMENT, tuple slot and record
field, even when both sides are ground and arrow-free (`connectTypes` 7.0 % inclusive,
`argUnifyVar` 1.7 %, `unifyParamsCollect` 2.4 %). Early-exit both on a fused `groundNoArrow` walk
(LSS_006: no arrows ⇒ no slots; ground ⇒ no memo/MONO_029 reads).

*Depends on / placement:* no dependencies; done before step 10 so the rewrite has fewer sites to convert.

**Step 10 (was 3). Retire the `Step` encoding: `Step a` → `S -> ( a, S )`, `Step ()` → `S -> S`** — impact H
(allocation: Closure + Tuple2 + Custom are 65 % of LSS's +15.1e9 objects; GC is 21 % of the
window), effort L, BI yes. 81 unit-returning steps (`connectTypes`, `insertVar(s)`, `unifySlotWithSet`,
`addSlotSource`, `injectSpineMemberId`, `injectPapSuccessors`, `injectArgLambdaMember(Go)`,
`enrichFromEnv`, `flowArgDemands`, `demandUnify`, `unifyResultWithExpected`, …) become
allocation-free; tuple-returning steps get `$sret` workers (conditions in §1). Failure channel:
`UnifyMismatch` is the ONLY recovered failure (manufactured in `Store.unifyStep` 1031-1068;
recovered by `unifyBestEffort`, `unifyStepBestEffort`, `classifyRef`) → make `unifyStep` return
`( Bool, S )`; `EngineBug`/`Unsupported` (25 sites) → `Utils.Crash.crash (renderFailure f)` with the
same text (a policy decision: today they surface as `Err String`); `LimitExceeded` → keep
`Result` at the 11 `enqueueSpec*` callers or a `pendingFailure` checked once per item in `drain`.
Prerequisite: land the `MonoIf` admission in `Backend.sretTailOk` (614) so branchy result spines
still promote. Probe first: convert `connectTypes` (+16 callers) and `classifyAs`/`classifyGo`,
rebuild, `grep -c '\$sret' out.mlir`, read the ECO_INLINE_ALLOC=0 Custom/Tuple2 deltas. Then
desugar the remaining `andThen` nests (Translate 165 sites: `translateGlobalCallFast` 6 closures,
GroundMemo miss 12, `appShapeConnect` 8 + `buildAppVar` 2/arg, `unifyParamsWithArgs` 3/arg,
`resultVarAfter` 2/depth, `memberIdForDepth` per depth, `injectArgLambdaMember` 1 closure per ARG
just to sequence a report-gated census, container arms' `traverse |> map`/`foldlS`).

*Depends on / placement:* after steps 5, 6, 7 (and 8, 9 by choice); start with the `sretTailOk` `MonoIf` admission and the two-function probe.

**Step 11 (was 6). Stop rendering and re-widening the whole demand type on every enqueue** — impact M-H
(~5–7 %), effort S-M, BI yes. `stampSelfSpine` (Translate 4691-4706) STRICTLY computes
`toComparableMonoType (widenSets monoType)` on every `enqueueSpecStamped` (~141K/run: every global
reference and call), consumed only at depth 0 in the Define arm of `memberIdForDepth` (4670-4683)
and wasted for arity-0 globals, kernel/ctor heads and already-`LSet` heads (tested AFTER the mint);
`enqueueSpecKeyed` then runs a SECOND, interned `Intern.widenSets` (Engine 2331) whose result is
consumed only when the spec is CREATED (43K) or over budget (`maxSpecsPerGlobal = 0` = never), and
renders the string a THIRD time for `specWidenedKeys` (2381); the completion join repeats the
render per finished spec (Monomorphize 4276-4285). For `Step`-typed demands the type embeds the
31-field `S` record. Proposal: lazy `groundKey` thunk rendered only in the `Just _` arm; test `anno`
before minting; one interned widen shared between `stampSelfSpine`, `enqueueSpecKeyed` and
`recordSpecWidenedKey`; memoise `Intern.widenSets` per canonical INPUT node (a second table inside
`Intern`, pointer hit on canonical input) so repeat widening is O(1); move the widen under `if
created` (verify on the bootstrap rail — intern insertion order shifts). Also `stampSpineGo`
rebuilds every spine node even when unchanged (4733-4748), so demands are never pointer-identical to
the stored type and `Registry.elm:147`'s `storedType == storeType` must descend — return the input
by pointer when nothing changed.

*Depends on / placement:* no hard dependencies; done before step 13 because step 13 keys on the single canonical widened type this step produces.

**Step 12 (was 9). Global identity as a dense Int (`GlobalId`) and Int-keyed per-global memos** — impact M
(~2 % direct, prerequisite for 5 and 13), effort M, BI yes. `TOpt.toComparableGlobal` (a 5-concat
string) is rebuilt per probe for `lssSignatures` (twice per translated call via `lssFastOk` +
`instantiateLss`), `specCountByGlobal` (per enqueue), `Registry.countByGlobal` (twice per created
spec), `nodeResolution` (per item), `schemeMono`, `lssInProgress`, `env.annotations` (`DMap` —
the exact pattern 4c fixed for `toptNodes`), plus `HashMap.get globalHash (==)` doing four string
equalities per hit on a freshly allocated `Mono.Global`. Mint ids once in `initState` from
`env.toptNodes`; convert the seven maps to `Dict Int`/`Array`/`BitSet`; memoise `declaredArityOf`/
`kernelAliasOf`/`canTypeMentionsArrow`-of-annotation per id (a per-global facts record).
Measured directly at only ~1–2 % of the window, so ranked for its enabling role.

*Depends on / placement:* soft dependency on step 11; PREREQUISITE of step 13 only — the specs for 16, 23 and 25 found they do not need it (§10 (a)). Still placed here for its own direct win and for step 13.

**Step 13 (was 5). Member identity: structural Int keys instead of strings** — impact M-H (~6–8 %), effort L,
BI yes (ids mint in the same order iff key-equality classes are identical, pinned by
`ComparableKeyEncodingTest`). `LssMemberTable.byKey : Dict String Int` holds 62,647 keys of the
shapes `l|<raw>|<FULL widened type string>|#<tag>`, `g|<author>\0<project>\0<module>\0<name>|<full
widened arrow string>`, `p|<global>|<n>`; a probe is ~16 long-common-prefix string compares. Per
lambda mint (83,233/run) `layoutQualKey` (Engine 729-780) concatenates the multi-KB widened spec
string, the root-lambda fold `String.dropLeft`s a copy and prepends `"g|"++global`, and
`lambdaInstanceMemberMaybe` REPEATS the build+probe to read the id back (Translate 1734). Per PAP
successor (`papMemberKey`, 5 Translate sites per spec + `varsucc` twice) a ~50-char string per depth.
Proposal: `widenedClass : SpecMap Int` (dense class id of the canonical widened type via
`specHashOf`/`eqKeySpec`, pointer hit on hash-consed input), `specWidenedKeys : Array Int`, per-kind
Int-tuple maps (`(raw, class, tag)`, `(globalId, class)`, `(globalId, n)`), a `classRepr : Array
MonoType` so the report still renders the same text; cache PAP successor id arrays per global.
Needs step 12's global ids. Rewords LSS_017/018/019/024 (they name the string shapes) and the
`LayoutQualTest`/`LssGroundingTest` string pins.

*Depends on / placement:* after steps 11 and 12.

**Step 14 (was 12). Inline the HPointer resolve in the kernel export path (runtime)** — impact M (~4–6 % of the
mono window, more of the front end), effort S, BI yes. `hpointerToPtr` (RuntimeExports.cpp:56-64)
calls the out-of-line `Allocator::resolve` loop from every kernel export (`eco_get_header_tag`,
`eqHelp`'s `resolveAndCompare`, `dictEq`, string ops); `Allocator::resolveFast` (Allocator.hpp:67-72)
already implements the inline "header tag is not `Tag_Forward`" fast path but is used only by
generated code. 7.7 % of window self time is `resolve`. Not LSS code, but it is on every LSS hot
path above.

*Depends on / placement:* no dependencies (runtime C++); can proceed in parallel with everything above.

**Step 15 (was 16). `enqueueSpecKeyed` hit path** — impact L-M, effort S, BI yes. On 98K hits/run: `bumpKeyedHit`
copies `S` + `LssStats`, `s1` is rebuilt storing the identical registry/tally/stats, `toComparableGlobal`
+ a `Dict String` probe run every call though the count matters only when `maxSpecsPerGlobal > 0`
(default 0), `checkSpecWatchdogs` walks the whole type and rebuilds the global string twice per
created spec while `Registry.countByGlobal` duplicates `specCountByGlobal`. Return `sProbe`
unchanged on hits; probe the tally only under `created`.

*Depends on / placement:* after steps 7 and 11.

**Step 16 (was 13). Inference walk: skip work that cannot write a set** — impact M (~3 %), effort S-M, BI
expected (D2 may shift member-id interning order — rail-gated). `LssInfer.applyCalleeAt` (1733-1795)
instantiates the callee's WHOLE annotation into the scratch store and runs a full `Unify.unify` per
argument and result for EVERY global call even when the signature is trivial and args/result are
arrow-free (the `Inert`-kernel precedent at 2130-2145 already skips exactly this); the `Call` arm
re-walks the callee `func` child so every `VarGlobal` callee gets the standalone-value treatment
(load, `g|` intern, head write, two `toptNodes` probes, `p|` successor mints) whose head slot is
unreachable from any signature slot; `storeMentionsArrow` DFSes the store per container flow only
to feed a report-gated counter; `Let`/literal types are loaded when arrow-free; trivial-signature
callees still build the ordinal `Array` on the per-spec `instantiateLss` path. `signatureFor` is
8.4 % inclusive.

*Depends on / placement:* loop order after step 15; no hard dependency on step 12 (corrected by the spec — §10 (a)). `16a` is BI, `16b` is not.

**Step 17 (was 17). `Data.HashMap` buckets: `Dict Int` → array-backed table** — impact L-M (~2 %), effort S-M,
BI yes (iteration already sorts on sequence numbers). Every hash-cons probe and `SpecKeyMap` probe
does a red-black `Dict Int` descent over ~116K buckets (`Dict_get` 1.6 % self) before the bucket
scan. An `Array` of buckets indexed by `hash mod capacity` with doubling gives O(log32) probes with
no comparisons.

*Depends on / placement:* no dependencies; kept adjacent to the Intern work.

**Step 18 (was 14). String-pattern `case` arms in `normalizePrimHome`, `classifyApp`, `Zonk`** — impact L-M
(~2 %), effort S, BI yes. The backend lowers each string pattern as a per-evaluation
`eco_alloc_string_literal_utf8` (an interning-table probe) followed by `Utils.equal`
(EcoToLLVMControlFlow.cpp 454-490); a non-primitive elm/core type name evaluates six of them per
`App1` load/zonk. Elm-side: dispatch on `String.length`/first char, or test the module
(`Basics`/`Char`/`String`/`List`) before the name; backend-side (benefits everything): pre-materialise
the literal HPointer once per pattern instead of calling the intern function per evaluation.

*Depends on / placement:* no dependencies.

**Step 19 (was 18). `revMemoSetIfAbsent` per var mint** — impact L (~1.5–2 %), effort S, BI yes. Every minted
var Point does `Array.repeat gap Nothing` + `push` + `append` (Store 524-540; 2.2 % inclusive with
1.1 % generic dispatch into the array kernel); the two "already present" arms are dead on the mint
path. Grow by doubling or append in one step; or record `revMemo` lazily. The specification takes the first route on
top of step 3 (a second `CellStore`, `gap` in-place pushes per mint, 2.2 % → ~0.3 %), and keeps the doubling version
as the `19′` fallback for a series where step 3 came last.

*Depends on / placement:* after step 3 (`3a` suffices). The re-check the plan asked for is done: the store does NOT
subsume `revMemo` — see §10 (p) — so this is a second cell store sharing the store's lifecycle, not a lane of the
first one.

**Step 20 (was 15). Point equality through the generic `==`** — impact L-M (~1–2 %), effort S, BI yes.
`Vars.Point = Pt Int` is a boxed Custom, so `point2 /= point1` (UnionFind.elm:171) and
`point1 == point2` (250) on every `reprS`/`unionS`, plus `Dict.member`/`List.any` on Points, go
through `Elm_Kernel_Utils_equal` → `eqHelp` → two resolves + `eqUnboxableSlot` (1.85 % self);
`Intrinsics.elm:549` specialises `==` only for `MInt`/`MFloat`. Compare `pointKey` Ints.

*Depends on / placement:* no dependencies.

**Step 21 (was 19). `LssMemberTable`/`ItemAux` Int dicts → `Array`/`BitSet`** — impact L (~1 %), effort S-M,
BI yes. Member ids are dense (lambdas `0..nextLam-1`, interned ids contiguous above); the hottest
read is `provisionalStandalone` membership per member per set zonk (654K zonks), then
`lambdaQualified` per mint, `sources` per devirt, `flexCtorSpecs`, `muTied`, `specWidenedKeys`
(→ `Array`), `rootLamOf` (→ `Array (Maybe Global)`); `dirtySpecs.removeGrowing` per item grows a
never-populated set. Negative finding kept for the record: `arrowMemo` is per item (~19 entries)
— a run-wide Array would LOSE; sorted `List Int` sets beat a BitSet 700× on the 69 % singletons.

*Depends on / placement:* step 13 not required (`specWidenedKeys` becomes `Array (Maybe String)` here, `Array Int` if step 13 is already in — §10 (k)).

**Step 22 (was 20). `specializeLambda`/`classifyLambdaHead` waste** — impact L-M, effort S, BI yes for (b)-(d).
(a) every param is classified then discarded (only names survive when arity matches); (b) the
`l|raw|<widened key>` string is built and probed TWICE per lambda (step 13 removes it);
(c) the lss-on head does `zonkToMono` + `classifyAs` + `overlayAnnotations` (three trees);
(d) `overlayAnnotations`/`enrichAnnotationsWith` (13 sites) rebuild whole trees NON-canonically,
undoing K6 retention and defeating every later pointer short-circuit — add `*Changed` variants
with an entry `structural == annoSource` fast path and `consS` the rebuilt spine;
`joinAnnotationsChanged` needs the same `a == b` entry test and must stop allocating `Dict.keys`
lists per record node. `classifyLambdaHead` is 6.5 % inclusive.

*Depends on / placement:* no dependencies — part (b) is specified without step 13 (§10 (l)).

**Step 23 (was 22). Kernel-boundary translation** — impact L, effort S, BI yes. `deriveKernelAbiTypeWith` builds
a `currentMVarEnv` per call that the callee ignores, walks `hasAnyFreeVar` with `Dict.toList`, tests
`suffixSelectingKernels` twice, and `remapEcoVarsFresh` rebuilds the whole ABI type with zero
`CEcoValue` vars; `KernelSetFacts.factFor` is a `Dict (Name, Name)` (tuple of strings) probe per
kernel call/ref; `bumpWidenedByKernel` copies `S` + `LssStats` ungated. Resolve facts once per
kernel id, guard the remap with `monoTypeMentionsEco`.

*Depends on / placement:* stands alone after step 7 — step 12 does NOT apply to kernels (corrected by the spec — §10 (a)).

**Step 24 (was 21). Settle chain and post-drain walks** — impact L (~1.5 % total; the chain is 2.0 % inclusive,
`pruneGraph` 2.1 %), effort S, BI yes. Four full-registry type REBUILDS that write nothing
(`succType` ×3, `rewrite` ×1 — pre-scan `Mono.hasVarAnno`, return the input when unchanged); the
`varSuccRounds` verification round is provably a no-op (rounds = 3 = 2+1); `varArgIds` is dead
(never read by `varCellWalk`); `midKeys`/`compGlobals` (62K-entry inversion + a string per global)
are rebuilt per round instead of read from `lssMemberTable.sources`; ctor-row sweeps probe every
row four times; `lambdaHomesOf` and `assembleRawGraph`'s edge/effect fold can share one walk;
Prune's `collectAllCustomTypes` does a `layoutMapInsert` per `MCustom` occurrence in every live
node and `typeHasResidualNumber` allocates a PAP per list element (direct recursion instead).
Order constraints are on READS as well as writes (agent B) — fuse per row, not across passes.

*Depends on / placement:* no dependencies.

**Step 25 (was 24). AbiCloning (post-mono, outside the mono window: GlobalOpt + emission ≈ 28 s of the run)** — impact L-M, effort M, BI yes. Per singleton site a `siteFingerprint` STRING (`String.join` of
`shallowLayoutKey`s) and a `Dict String` probe, built twice for over-applying sites — use the packed
layout hashes (K4) as an Int key; `resolvePapSuffix` flattens all buckets per miss; `papResolve`/
`matchSpec` scan ALL specs of the global per `p|`/`g1` site (e.g. 1,939 `List.foldl` specs ×
2,418 sites); `hostGlobalAt` builds 43K strings outside the census gate; `MonoInlineSimplify.elm:864`
`widenSets` rebuilds every node type with no identity shortcut.

*Depends on / placement:* no dependency on step 12 (keys on `Mono.globalHash`; corrected by the spec — §10 (a)); post-mono, outside the profiled window.

**Step 26 (was 23b). Regroup `S` by co-update (M7 rule)** — impact L-M (scales with the copies that survive steps 7, 8 and 10), effort M, BI yes. `S` has 31 fields (the "32-slot cap" comments overstate by one — verify with the MLIR verifier); seven rarely-written fields (`env`, `ports`, `superTable`, `lambdaCounter`, `lssSignatures`, `lssInProgress`, `nodeResolution`, `monoMemo`) ride every hot copy; nest ONLY co-updated groups: `sched` {registry, scheduled, worklist, dirtySpecs, dirtyList, specCountByGlobal}, `runMemo` {lssSignatures, lssInProgress, nodeResolution, monoMemo, superTable, lambdaCounter, ports}, `letCtx` {numberMulti, localMulti, derivedDestructors, localCanTypes}; keep the per-node writers (`store`, `memo`, `revMemo`, `varEnv`, `itemAux`, `intern`, `nextMVarId`, `lssMemberTable`, `nextMemberId`, `lssStats`) top-level. Deliberately LAST: the win is proportional to the number of `S` copies still standing after the direct-state work, and the update sites move with every earlier step.

*Depends on / placement:* LAST — after steps 7, 8 and 10.

## 2b. What the measurement loop actually found (2026-09-19/20)

`benchmarks/lss-compile-opt-loop.md` ran **43 entries** against this plan and is COMPLETE.
**398.71 s -> 265.28 s, -33.5 %**; minor GC 1825 -> 1241 (-32 %); promoted 20,846 -> 19,982 MiB;
peak RSS 12.71 -> 11.48 GB (-9.7 %); GC time 142.10 -> 124.11 s. Twenty entries kept, twenty-two
reverted after their own measurement, one deferred. **Every step of the twenty-six except step 10
has at least one measurement of its own**; step 10's entry says why it is a programme rather than
a loop iteration. The per-step numbers, arguments and gate results are in that file; what belongs
HERE is where this plan turned out to be wrong.

### The central correction: time is SURVIVOR COPYING, not allocation volume

The first thirty entries supported "this compiler's compile time is dominated by allocation
volume". Two later entries priced that claim and corrected it:

- **5b** removed ~10^6-scale short-lived closures and `Ok`/`UnifyOk` boxes from `Unify`'s
  combinator layer. The minor GC cycle count fell by **26** — the largest counter move in the
  series — and the compiler was **2.1 % SLOWER**: GC TIME rose 5.31 s, which was the whole
  regression. Fewer collections each spanned more elapsed work, so more of the live set was still
  alive when they ran.
- **26a** took 40 B off each of 11.9 M `S` record copies — **476 MB less allocation, measured by
  uprobe** — and bought **0.62 s** of GC time. About 1.3 microseconds per megabyte.

An object that dies before the next minor collection is very nearly free: never traced, never
copied, space reclaimed by moving a pointer. **The wins in this series did not work because they
allocated less; they worked because what they stopped allocating was being COPIED** — retained
trees (22d, 24(i')), retained store structure (3, 4a, 11b), whole extra passes over the registry
(24(ii)), per-node PAPs on a walk whose results outlive it (24(vii)a). Score a candidate on GC
TIME and PROMOTED BYTES; the minor-cycle count is a proxy that can point the wrong way.

### The five biggest wins, and the four repeating failure shapes

Biggest: **step 3** (off-heap union-find store), **22d** (pointer-preserving `overlayAnnotations`,
-9.08 s from one file), **24(vii)a** (de-PAP one `List.any`, -6.87 s from NINE LINES), **4a**
(ground-alias load memo), **18b** (per-literal string-intern cache in the codegen, -2.16 s and
-8.7 MB RSS).

The failures repeat in four shapes, each paid for with a measured run:

- **A guard on a hot path is hot-path work** — 16a, 15, 22c, 24(i). Four steps added a test to
  skip work and got slower: the test ran on every item, the skip paid off on few. This plan sized
  the work avoided and not the test, in every one of those specifications.
- **A cheaper container is only cheaper if the operation it replaced was the expensive one** —
  27, 21a, 24(iii). Hashing a string in Elm is a closure call per character and loses to the C++
  ordered compare it replaces; `BitSet.member` does not beat a red-black descent on Int keys.
- **The same transformation wins in one place and loses in another** — 22d vs 22c, 24(vii)a vs
  24(vii)b. What decides it is whether the population it optimises is the common one. This is why
  no step could be disposed of by a sibling's evidence.
- **A specification is invalidated by its own prerequisites landing** — 8a (premise deleted by
  step 3), 18a (premise deleted by 18b), 16-D10 (premise deleted by 4a). Re-read a spec against
  the tree as it IS.

A fifth, about scale: **24(v)** removed 129,000 redundant string hashes from a pass that runs once
over the registry and no counter noticed. Once-per-graph waste is a rounding error beside
per-item work.

### Where the time is now (perf, 83K samples, mid-series binary)

GC ~30 % (`evacuate` 10.8 alone) plus ~11 % libc memcpy driven by it = **over 40 %**;
`Allocator::resolve` 6.1 %; string comparison 7.6 %; `Dict` operations 6.9 %; generic dispatch
4.3 %; `Utils::eqHelp` 0.5 %.

**The two clusters this plan was written to attack are gone.** Hash-cons equality fell from ~20 %
inclusive to 0.5 % (step 2). The union-find store cluster (~12 %) is out of the top thirty
entirely (step 3). What is left is dominated by a cost no step here targets.

**Next, in order:** (1) attack SURVIVOR COPYING — not "allocate less", which 5b and 26a priced at
nearly nothing, but promote less and copy less; (2) attack emission-side string interning (about
two thirds of the string cost is the `.ecot` table and MLIR attribute tables, outside this plan) —
and per entry 27 the fix is a kernel-side hash primitive or interning at construction, never an
Elm-level hash; (3) then step 13 rebuilt as integer identity end to end, with step 12 first.
Plan §4 N22 ruled GC tuning out of scope when GC was a smaller share of a slower compile; that
decision is stale and should be revisited before anything else here.

## 3. Cross-cutting notes and findings that are not optimizations

- **GC is 21 % of the mono window and is dominated by SURVIVOR copying** (memcpy under `minorGC`
  11 %), not by collecting the monad garbage. Steps 10, 11, 4, 7, 8 cut allocation volume; step 3
  cuts the biggest churner of live array nodes. The 12.7 GB RSS is retained structure (intern
  table 116K types, registry, member table, nodes).
- **The translation-time fast path (`translateGlobalCallFast`, M2a) is negligible by samples under LSS**
  (0 DWARF samples; 0.01 % in the frame-pointer run): call-translation time is Slow (16 % inclusive) or
  GroundMemo (1.3 %). This is the monomorphizer's call-site shortcut, NOT the runtime LSS fast-dispatch tier,
  which the compiled compiler does use; the profile's "dispatch" cluster is the generic tier only. Whether
  Fast is CALLED rarely or merely cheap needs a per-path counter (agent E's evidence gap). Item 16/D8 and E's per-global facts memo
  target the Slow path directly; alternatively let `lssFastOk` accept spine-only-injected
  signatures.
- **NO MUTABLE HEAP OBJECT IS AVAILABLE, and this bounds every "just mutate it" idea in this plan.**
  The generational GC has no write barrier, remembered set or card table — HEAP_005 states the
  invariant that makes that safe ("there are no old to young pointers in the heap"), and a search of
  the allocator finds only the fold-proof slot barriers of REP_LLVM_002. So a long-lived heap object
  mutated to point at a nursery object is invisible to a minor GC: a dangling cell, not a slow path.
  The sanctioned way to hold mutable state that references Elm values is OFF the heap, in a kernel
  module whose storage is registered as an external root scanner — the list scratch stack (HEAP_040)
  and `Eco.MVar` are the two precedents, and step 3 follows them. A consequence worth knowing before
  designing anything similar: such a module cannot live in `compiler/src`. It needs a kernel package
  with a C++ and a JavaScript implementation, plus a pure Elm twin under `compiler/src-xhr`, because
  stage 1 and the unit suite are built by stock Elm — which also means the unit suite can never catch
  an aliasing bug in it. See §9 step 3 §4.2 for the full comparison of the three representations.
- **A zero-argument definition is a memoised constant, and that is the sharpest trap around an
  in-place store.** `Engine.freshStore` (Engine.elm:2409) is one today, harmlessly, because it returns
  a persistent array. The moment the store is mutable, every "fresh" store minted from it is the SAME
  object, and the stash in `withScratchStore` aliases the scratch. Step 3 makes it take a unit
  argument. Any future kernel-backed state must do the same.
- **Possible precision bug** (agent B): `settleVarCtorRows.gkeyOf` (Monomorphize.elm 382-388) keys
  cells by ctor NAME only, unlike its docstring and `settleCtorRows` (full global) — same-named
  ctors across modules share a cell (sound over-approximation; may inflate sets). Not an
  optimization; output-changing if fixed.
- **`Result`-to-crash policy** (step 10) and **nesting of `withScratchStore`** (D9: the module doc
  forbids it, the code looks re-entrant) are decisions the owner has to make before those items.
- The FRONT-END window (0–205 s, 51 % of wall) is outside this survey but shows the same
  signature: GC 30 %+, `Dict String` compares 6 %, `clock_gettime` 8 %.

## 4. Considered and set aside — numbered so they are not re-investigated by accident

Each entry gives the measurement or argument that ranked it out, and the trigger that would put it
back on the list. "Window" = the mono-phase window of the DWARF profile.

**N1. Settle-chain pass fusion (Q1).** The five sweeps (`settleVarCtorRows`, `settleCtorRows`,
`settleVarSuccessors` ×2, `settleVarLambda`) are 2.0 % of the window inclusive (and were measured at
~0.5 % of wall on Sep 3). The ordering is load-bearing on READS as well as writes: B's structural
union consumes A's path-keyed writes, and D must decide a child position before E writes a `p|`
head there (Monomorphize.elm 748-754). A per-row fused walk is possible but is M effort with a
precision-changing failure mode for ~2 s. Revisit only if the chain grows new passes. The cheap
parts survive as step 24.

**N2. The LSS_010 dirty-flush loop.** `joinRounds = 0`, `retranslations = 0`, `changed = 0` on the
self-compile: the loop never runs; its residue is one `BitSet.member` per item and the
`removeGrowing` in step 21. Do not touch the loop itself; it is the safety net for shared-key
joins and re-arms if `maxSpecsPerGlobal` is ever set.

**N3. `ItemAux.arrowMemo : Dict Int Variable` → run-wide `Array`.** ArrowIds are dense per run
(262,375), but the memo is PER ITEM (cleared by `resetItem` for 42,955 items and by `clearedAux`
at every scratch-store swap): ~19 entries on average, so a probe is 4-6 Int compares and an insert
~30 words, while a 262K-slot Array would pay a 3-level path copy (~100 words) per insert and need
generation stamping to clear. A loss. Trigger: a per-item `arrowMemo` size census showing a tail of
steps with > 500 arrows.

**N4. Lambda-set representation: sorted `List Int` vs `BitSet` / packed array (Q2).** 99,243 of
143,944 positions are singletons = one cons cell; `classifySorted` on two singletons is ≤ 3
comparisons with zero allocation; `unionSortedAsc` allocates only the merged prefix; every write
ADOPTS the caller's list by pointer and `Mono.LSet members` IS the store list. A BitSet over
74,837 member ids is 2,339 words per set (~700× a singleton); a packed array wins only at k ≥ 3.
Total set payload ≈ 0.6 M words ≈ 0.0001 % of LSS allocation. Trigger: `sizeHist` showing
multi-member sets becoming the majority.

**N5. Visited sets as `Dict Int ()` in the DFS walks (`poisonGoC`, `spineGoC`, `papSuccGoC`,
`sigEdgesGo`; `List Int` + `List.member` in `resolveSources`).** Per-traversal size is one type's
nodes (3-30); `Dict Int` costs ~6 words × log2 n per insert, a BitSet must span the item store's
point range and breaks even only at ~30+ nodes; the store is acyclic so dropping the sets is sound
but risks k× re-walks of shared bindings. `resolveSources`' edge lists are < 10 (install-time
dedupe is itself `List.any`). Trigger: a `maxSourcesPerSlot` / max-nodes-per-traversal census row
above ~30.

**N6. `demandQualifiedFor` per item.** One walk of the stored demand + an Int-dict op per member,
≈ 1-4 M Int-dict ops per run; a per-spec cache keyed on the stored type would be sound but would
never hit while `retranslations = 0`. Micro only: `List.foldl (::)` instead of `ms ++ acc`
(Monomorphized.elm 1428-1470); adapt to step 21's `Array`.

**N7. Report/census gating in general.** `rezonkSettled`, `qShadowCensus`/`qInferenceCensus`,
`noteMultiSet`, `noteArrowClass`, `bumpCauseC`, `noteArrow`, `zonkLog`, `bumpEdgeInstalled`,
`bumpArgFlowCensus`, `censusProducer`/`censusArgs`/`m2ShapeCensus`/`argDeepCensus`/`caseAnnoCensus`/
`destrAnnoCensus`/`enrichCensus`/`censusSignature`/`censusSigFacts`, `noteApplied` (its own
`arrowCensus` flag, one Bool per application) all test the flag BEFORE any work. The only default-path
leaks are the ones listed in steps 7 and 6 (`foldZonkStats` histograms, the ungated `bump*`
copies, `recordKernelMiss`'s string histogram, `slotsMinted`, ~24 `++`-before-gate census keys,
`bumpMixedFlexDemand`'s `membersClass`).

**N8. `overlayLocalMultiUses` / the E4a overlay and `retypeLet`.** One direct deferred walk per
outermost let-function, skipped entirely when `pendingEnrich` is empty (Translate 6913-6914);
`retypeLet` is O(1). Fixed Sep 4; nothing left.

**N9. Tail recursion (Q7).** All 74 `List.length` sites take arity/field/member-sized lists; the
Store/Translate/AbiCloning list helpers (`loadListC`, `zonkListC`, `classifyList`,
`monoListToVarC`, `goList`, the `olm*` family) recurse over arity-bounded lists; the only unbounded
non-tail helper is `Engine.traverseGo` over `TOpt.List` LITERALS (accumulate-and-reverse if a long
literal ever shows up); elm/core's `foldrHelper` is stack-safe (4-way unrolled to depth 500, then
`foldl` over a reverse). `poisonGoC`/`resolveSources`/`classifySortedGo` are worklist loops.

**N10. `Closure.computeClosureCaptures`' three body walks per lambda.** 0.18 % inclusive of the
window despite re-walking nested bodies per enclosing lambda; not worth touching before step 22's
cheaper parts.

**N11. End-of-run and per-item driver work.** `assembleRawGraph` (one D14-fused fold),
`buildMemberOrigins` (one 62K fold, ~10 ms), `finishNode`/`arraySetGrowing` (amortized O(1);
> 128-slot pads ≤ ~340 per run), `resetItem`/`processItem` (~10 `S` copies × 43K items — two orders
below the per-node writers), `harvestSuperTableExcept` (O(item revMemo), necessary),
`Engine.scoped`'s copy (it IS the restore; only its `Ok` boxing is waste — step 10).

**N12. `Registry.getOrCreateSpecIdKeyed`'s probe.** The key type is canonical, so `eqKeySpec` hits
the `identicalOr` pointer path; `Array.get` O(log32); `storedType == storeType` descends only the
non-canonical spine that step 11 stops rebuilding. The cost is around the probe (steps 11 and 15),
not in it.

**N13. `annoCovers` / `unionAnno` / `sortedSubsetOf` / `unionSortedInts`.** Allocation-free on
the covers path; `unionSortedInts` allocates only on a real change and `changed = 0`.

**N14. `withIntern` size guard, `memberIdFor` hit path, `enqueueSpecCommit`'s D2 return.** All
already avoid the copy on the no-change path; the unconditional copies are in
`mintLayoutQualified`, `bumpKeyedHit` and the `s1` rebuild (steps 7 and 15).

**N15. `sigEdgesGo` / `ordinalOf` / `repOrdinal` complexity.** Per signature O(E × n + E²) with
E = reached edge nodes and n = arrows in THIS signature (arity-sized); `repOrdinal`'s O(n²)
`UF.equivalent` over ~10,123 signatures is ~10^5 probes. Nothing scans the 262K program-wide
arrows. The only wart is the per-probe `S` copy (step 8).

**N16. `walkExpr`'s structural arms and `directChildren`.** Every child-bearing constructor has an
explicit arm; `directChildren` is reached only for leaves and `Access`, so the inference walk does
not allocate a child list per node. It does in `collectReferencedGlobals` (the pre-resolve walk),
which is inside step 16.

**N17. `Descriptor.rank`/`mark`/`copy` are constant on every MonoSolver path** (~3 dead words per
minted Point, ~100 MB/run) — the type is shared with the typechecker's `Unify`; a fork is not
worth it. Revisit together with step 3 if the store representation changes anyway.

**N18. Record-field `Dict.toList` + insert-per-field in `loadRecordFieldsC`/`zonkRecordFieldsC`/
`recordFieldPointsC`.** Inherent to elm/core `Dict` (no `mapAccum`); the leverage is not a better
fold but not doing the work again per occurrence — step 4. A record-shape representation
(field-name array + values array) would remove the per-field string compares in `unifyRecord` too,
but it is a typechecker-shared representation change; only revisit if step 4 leaves `unifyRecord`
above ~3 %.

**N19. `KernelSetFacts.factFor` tuple-keyed probe in the INFERENCE walk.** Once per kernel call per
body, and the `Inert` arm skips instantiation for ~5/6 licensed kernels — fine. The per-spec
translation-side probe is step 23.

**N20. `canTypeMentionsArrow` / `canTypeHasArrow` alias-body walks.** Agent G predicted 10^7-10^8
node visits (every `s : S` reference walks ~150 nodes to answer False); the DWARF profile measures
them at 0.25 % + 0.19 % inclusive. Folded into step 12's per-global facts memo rather than a
standalone item. Trigger: a node-visit counter disagreeing with the profile.

**N21. `mintVarSlots`' second walk of every demand type in `monoTypeToVar` (C10).** ~10^7 node
visits, low tens of ms, small allocation; a single-walk rewrite changes Point mint order (UF root
choice can differ) so it is NOT byte-identical for free. Not worth the rail run on its own; do it
only inside step 9 if `monoTypeToVar` survives there.

**N22. GC as its own item.** GC is 21 % of the window but it is SURVIVOR copying (memcpy under
`minorGC` 11 %), not the cost of discarding the monad garbage; reducing short-lived allocation
helps by shrinking nursery pressure, reducing live churn (steps 3, 4) helps more per object. No
GC-tuning step is on the list; step 1 covers the stats overhead only.

## 5. Agent records

Condensed records of the seven agent reports (A Step monad, B settle/driver, C Store, D LssInfer,
E Translate, F key machinery, G sweep) are in the session scratchpad
(`findings-{A..G}-*.md`); every finding above cites their `file:line` evidence. Profile artefacts:
`prof/` (frame-pointer run: `flat.txt`, `flat-mono.txt`, `flat-fe.txt`, `timeline.txt`,
`callers-mono.txt`) and `prof2/` (DWARF run: `attrib.txt`, `attrib.py`, `attrib2.py`).

The §9 specifications were written by a second wave of agents, one file per group of steps
(scratchpad `spec-{A..L}.md`, brief in `spec-brief.md`), and assembled into §9 in step order by
`assemble.py` — re-runnable, it replaces §9 and leaves §10 alone.

## 6. How to gate any of these

Substrate steps (BI yes): two binaries, one frozen corpus, `cmp` the `-out.mlir` per
benchmarks/lss-opt.md, plus the 633-workload rail (`benchmarks/mlir-workload-rail.sh`) whose census
artefact catches precision drift the bytes miss. Analysis-order steps need the bootstrap 8c fixed
point as well, because member-id interning order can move spec ids: the specifications settle the
list as `10a` (a codegen change), `11c`, `15b`, `16b` and `18a` — see §10 (e), (f), (h), (i), (j).
Every other entry is expected byte-identical, and a substrate entry that is NOT is a bug in the
step, not a licence to skip the `cmp`. (This paragraph named steps 5, 6 and 13 until 2026-09-19;
those were the numbers of the impact-ranked draft — in today's order they are 13, 11 and 16.) Measure
with `ECO_MONO_LSS_REPORT=0` for wall (report-on adds real work: `zonkLog`, `arrowOfSlot`, `qLog`)
and `ECO_INLINE_ALLOC=0` lowering for any allocation attribution.

## 9. Implementation specifications

One specification per step, in implementation order (§2). Each was written against the tree of
2026-09-19 (`snapshots/lss-loop/base`) by an agent that read the code in full; line numbers are
as of that tree and move as earlier steps land — re-run the `grep`s each spec gives before editing.
Every spec follows the same eight headings: goal and expected effect, preconditions, inventory of
touched code, design, edit sequence, verification, risks, effort. Where a spec disagrees with the
shorter §2 text, the spec is the more recent and more careful reading; §2's dependency notes were
corrected from them (see §10). Conventions blocks (file abbreviations, line-number caveats) are
repeated under each step that came from the same spec file. Section numbers 7 and 8 of this plan
are deliberately unused: inside a spec, `§1`–`§8` always mean that spec's own eight headings, and
`§10` is the only plan-level cross-reference the specs make.

### Step 1 (was 25). GC-stats timer overhead in the `build` preset (measurement hygiene)

1. **Goal and expected effect**

The `build` preset (CMakePresets.json:22-37, `RelWithDebInfo`, `-O2 -g -UNDEBUG`) compiles the
runtime with `ENABLE_GC_STATS=1` (top-level CMakeLists.txt:107-116: `ECO_GC_STATS` defaults ON for
every non-Release build). The profile attributes vdso `clock_gettime` to 8 % of the front-end
window and 1.6 % of the mono window (plan §1, last table row).

**Attribution (which macro fires that often):** the only timer bracket that runs per OBJECT is the
one around the body of `OldGenSpace::allocate` (runtime/src/allocator/OldGenSpace.cpp:613-700):
`GC_STATS_TIMER_START()` at :633 and `GC_STATS_TIMER_ELAPSED_NS(helper_t0)` at :692, routed by
`g_in_minor_gc` (:693) into `total_oldgen_alloc_in_minor_ns` or `total_oldgen_alloc_in_mutator_ns`.
`OldGenSpace::allocate` is called once per PROMOTED object by the three nursery evacuation
copiers — NurserySpace.cpp:1043 (`evacuate`), :1213 (the JIT-root copier), :1732 (list-spine
copier) — "Direct allocation to old gen (simplified - no TLAB buffering)". A recorded self-compile
banner (`build/compiler/build-kernel/afwd-bench-off.stdout`) shows `Objects promoted: 762,846,271`
and `In minor pauses (nested in Minor GC): 40.97 s`; the loop baseline promotes 20,846 MiB
(≈ 7×10⁸ objects at ~30 B). Two `high_resolution_clock::now()` reads per promotion ⇒ ~1.5×10⁹ vdso
calls per run ≈ 20-40 s of a 399 s wall. The comment at OldGenSpace.cpp:622-631 ("Two clock reads on
the slow path is ~40 ns, negligible vs the dispatch") was written for the mutator-context path
(large-pinned / region allocations: banner `Old-gen alloc in mutator: 278.06 ms` total) and is
false for the promotion path, where the "dispatch" is a size-class free-list pop.

Everything else is per-CYCLE and negligible: nursery `allocateSlow` bracket (NurserySpace.cpp:196/216)
fires once per nursery fill (= once per minor GC; the fast path at :171-183 is explicitly untimed);
minor-GC bracket (:402/:859) twice per cycle; major-GC brackets (ThreadLocalHeap.cpp:561/663 plus the
four `high_resolution_clock::now()` phase stamps at :572/:600/:642/:660, and OldGenSpace.cpp
:2046/2061/2094 and :2137/2145/2161) ~10 reads per major (10 majors per run); shrink brackets
(OldGenSpace.cpp:2553/2558, :2705/2710, :2872/2874) per sweep/shrink event;
`GCStats::nowSinceProcessStartNs` (GCStats.cpp:679) once per major (`beginMajorGCEvent`);
Allocator.cpp:255-257 once at init and :949-951 once at exit. The per-object records
`recordSurvival` (GCStats.cpp:448), `recordPromotion` (:435) and `recordOldGenAllocation` (:385)
contain NO clock call — they are a few array increments and must stay (they produce the judged
`promoted MiB`).

Expected effect: wall −3…−7 % on every run of the loop (the plan's 3-5 %; the promotion count says
the upper end is possible), GC counters IDENTICAL, RSS unchanged. This is hygiene: it makes every
later A/B smaller in absolute seconds and removes a per-object cost that scales with promotion
volume (steps that change promotion volume would otherwise be mis-credited).

Byte identity: runtime-only C++; `out.mlir` cannot change. The candidate binary is the SAME
`bin/eco-compiler.mlir` re-lowered by the rebuilt `$BOOT` (the runtime is statically linked at
Stage 6), so the Phase 2 fixed-point `cmp` is against the existing `.mlir`.

2. **Preconditions**

- No plan-step dependency. Verify the timer inventory has not moved:
  `grep -rn "GC_STATS_TIMER_START\|high_resolution_clock::now\|steady_clock::now" runtime/src/allocator/` — expect the 14 macro sites and the chrono sites listed above; any NEW site must be classified per-object vs per-cycle before touching anything.
- Verify what the loop reads (benchmarks/lss-loop-extract.sh:16-21): `Minor GC cycles:`, `Major GC cycles:`, `totals: promoted <n> (<MiB>)`, `Total GC/Alloc time:` — the first three come from `minor_gc_count` (GCStats.cpp:520), `recordMajorGCEnd` (:808) and `promoted_bytes_by_tag` (:439-440); none of them is derived from a timer.
- Confirm the preset really has stats on: `grep -c "ENABLE_GC_STATS=1" build/compile_commands.json` (non-zero).

3. **Inventory of touched code**

| file | function (lines) | what changes |
|---|---|---|
| runtime/src/allocator/OldGenSpace.cpp | `OldGenSpace::allocate` 613-700 (bracket :621-634, :691-697) | bracket becomes mutator-context-only: no clock read when `g_in_minor_gc` |
| runtime/src/allocator/NurserySpace.cpp | `minorGC` 374-882 (:403-409 snapshot, :859-870 subtraction) | delete `helper_ns_at_start` and the `pure_elapsed_ns` subtraction; record `elapsed_ns` directly |
| runtime/src/allocator/GCStats.hpp | field docs 425-458; field `total_oldgen_alloc_in_minor_ns` :458; comment :36-41 | delete the field and its doc paragraph; update the `g_in_minor_gc` comment |
| runtime/src/allocator/GCStats.cpp | `combine` :894; banner :1372-1384; `reset` :1820 | delete the field's three references; banner block prints only the three remaining nested counters; rename `Minor GC (pure nursery-copy)` (:1343) to `Minor GC (incl. promotion alloc)` |
| benchmarks/lss-opt.md :118 and benchmarks/lss-compile-opt-loop.md §3 | protocol note | one sentence: walls recorded before step 1 include ~1.5×10⁹ per-promotion `clock_gettime` calls; not comparable across the step |

Callers of the changed functions: `OldGenSpace::allocate` — NurserySpace.cpp:1043/1213/1732,
ThreadLocalHeap.cpp:338/349/355/376/383, and internal sweep/promotion helpers (grep
`old_gen_.allocate\|oldgen.allocate`); no signature changes anywhere.

4. **Design**

Keep counts exact, remove the per-promotion clock:

```cpp
// OldGenSpace.cpp:613 — replace the unconditional bracket
void *OldGenSpace::allocate(size_t size) {
    size = (size + 7) & ~7;
    GC_STATS_OLDGEN_RECORD_ALLOC(alloc_stats_, size);        // histogram: exact, no clock, KEEP
#if ENABLE_GC_STATS
    // Promotion calls (g_in_minor_gc) are already inside the minor-GC bracket
    // (NurserySpace::minorGC :402/:859); timing them again cost two vdso reads
    // per promoted object (~7e8/run). Only mutator-context calls are timed.
    const bool timed = !g_in_minor_gc;
    std::chrono::high_resolution_clock::time_point helper_t0;
    if (timed) helper_t0 = GC_STATS_TIMER_START();
#endif
    ... body unchanged (:637-689) ...
#if ENABLE_GC_STATS
    if (timed)
        alloc_stats_.total_oldgen_alloc_in_mutator_ns += GC_STATS_TIMER_ELAPSED_NS(helper_t0);
#endif
    return result;
}
```

`g_in_minor_gc` is `thread_local bool` (GCStats.cpp:24) — one fs-relative load, and it is already
read at :693 today. `minorGC` then records `elapsed_ns` unmodified:

```cpp
// NurserySpace.cpp:859-870 becomes
uint64_t elapsed_ns = GC_STATS_TIMER_ELAPSED_NS(gc_start);
GC_STATS_MINOR_RECORD_GC_END(stats, elapsed_ns, bytes_freed);
```

and :403-409 loses `helper_ns_at_start`. The banner identity (GCStats.cpp:1333-1339,
`wall = minor + major + oldgen_alloc_in_mutator + nursery_alloc_in_mutator + true_mutator`) is
unchanged: the in-minor counter was NESTED inside `minor` and never part of the sum. The minor-GC
histogram/min/max now include promotion allocation time (it always was wall time of the pause; the
old "pure copy" figure was the pause minus a figure that was mostly timer overhead).

Rejected alternatives (state them in the entry so they are not re-proposed): (a) `rdtsc` — still
two instructions + serialisation per promotion, and TSC-vs-vdso disagreement on this VM is
unmeasured; (b) sampling every 2ⁿ-th promotion and scaling — produces a non-deterministic
sub-counter for a figure nobody judges; (c) keeping the field and writing 0 — a zero that reads
like data. Delete the field.

5. **Edit sequence** (each compiles; `cmake --build build --target eco-runtime` or the `test` target)

1. OldGenSpace.cpp:621-634 and :691-697 as in §4 (the file still builds with the field present).
2. NurserySpace.cpp:403-409 and :859-870: drop snapshot + subtraction.
3. GCStats.hpp:458 delete field, :425-435 delete its doc paragraph, :36-41 rewrite the comment to
   "Read by OldGenSpace::allocate to SKIP timing when the allocation is a promotion";
   GCStats.cpp:894, :1376-1384, :1820 delete the references; :1343 rename the label.
   (Anything else referencing the field fails to compile here — that is the check.)
4. benchmarks note (lss-opt.md:118 sentence, loop doc §3 one line).

6. **Verification**

- Build the `build` preset; `cmake --build build --target test 2>&1 | tee /tmp/test_output.txt`
  (test/CMakeLists.txt:82 — includes test/allocator/GCPressureTest.cpp and AllocatorTest.cpp; grep
  showed no test reads the deleted field or the "In minor pauses" line).
- `cmake --build build --target check 2>&1 | tee /tmp/test_output.txt` (C++-only change, so
  `check` is allowed per CLAUDE.md).
- Attribution before/after (the brief's `perf on vdso`):
  `perf record -F 199 -g -o <scratch>/perf.data -- env ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 bin/eco-optN make <front-end Main> --output=/dev/null` then
  `perf report -i … --no-children --sort dso,symbol | grep -i "vdso\|clock_gettime"`.
  Expect: `[vdso] __vdso_clock_gettime` from ~8 % (front-end window) / 1.6 % (mono) to < 0.05 %
  (remaining reads: 2 per minor × 1825, ~10 per major × 10, one per mutator-context old-gen alloc).
- Loop triple (benchmarks/lss-compile-opt-loop.md §2, `ARM=eco-opt1`, R=1..3): candidate =
  `$BOOT bin/eco-compiler.mlir -o bin/eco-opt1` with the rebuilt runtime; fixed point
  `cmp bin/eco-opt1-r1-out.mlir bin/eco-compiler.mlir`. Judged stats must read
  minor **1825**, major **10**, promoted **20846** MiB exactly (benchmarks/lss-compile-opt-loop.md:301-306);
  wall is the only thing allowed to move. `gc_s` (`Total GC/Alloc time`) will DROP by roughly the
  removed overhead's share that landed inside minor pauses — record it, it is not judged.
- Step 1's triple becomes the new REFERENCE for step 2 onward (loop §1: "the reference for step N is
  the recorded triple of the last win").

7. **Risks, gotchas, what NOT to do**

- Do not touch `HeapConfig`/`ECO_HEAP_CONFIG` (majors are a judged stat).
- Do not remove `GC_STATS_OLDGEN_RECORD_ALLOC` (:618) or `GC_STATS_MINOR_INC_PROMOTED/SURVIVORS`
  (GCStats.hpp:854-858, `recordPromotion` :435) — they are exact per-object counters with no clock and
  they feed the judged `promoted MiB` (`totals: promoted` at GCStats.cpp:1578).
- Do not switch `ECO_GC_STATS` OFF for the loop instead: the judged counters come from the
  stats build; a stats-off binary prints no banner and `lss-loop-extract.sh` returns NA.
- `recordTLHAllocOnCurrentThread` (GCStats.cpp:462-465) does an `Allocator::instance().getCurrentThreadHeap()` lookup per SLOW-path mutator allocation — counters only, not a clock; out of scope (plan §4 N22: no GC-tuning step).
- The "Minor GC (pure nursery-copy)" label change alters banner text; `lss-loop-extract.sh` does not
  grep it. Grep `benchmarks/*.sh` for "pure nursery-copy" before renaming (none today).

8. **Effort:** S — two files of mechanics plus a field deletion; one loop entry (`1`).

---

<details><summary>Conventions used in this spec (from spec-I)</summary>

All line numbers verified against the tree on 2026-09-19 (HEAD, clean). None of the four steps
changes the LSS analysis; three of them (1, 14, 18b) are runtime/backend-only and are byte-identical
at the MLIR level by construction, two (18a, 20) change compiler SOURCE and therefore change the
workload (`out.mlir`) without changing the analysis — the loop's fixed-point rule (Phase 1.5:
A≠B is propagation, the gate is B==C) applies to those.

---

</details>

### Step 2 (was 1). Make hash-cons equality O(arity) instead of a deep structural walk

#### 1. Goal and expected effect

**What it attacks.** `Intern.probe` (`/work/compiler/src/Compiler/AST/Intern.elm:194-201`) and
`probeRO` (211-218) confirm a bucket hit with `eqExact a b = a == b` (234-236). On the ~99 % hit
path the FRESH node handed to `hashCons` is never the object stored in the table, so the kernel
walks it: `Elm_Kernel_Utils_equal` (`/work/elm-kernel-cpp/src/core/UtilsExports.cpp:95-117`) →
`Utils::equal` → `eqHelp` (`/work/elm-kernel-cpp/src/core/Utils.cpp:507-731`). Reading `eqHelp`
corrects the plan's picture in one respect and confirms it in another:

- `eqHelp` is ALREADY O(arity) with a pointer short-circuit per child (`if (a == b) return true`
  at 509; list children via the `Tag_Cons` loop 605-634; custom fields via `eqUnboxableSlot`
  100-117 → `resolveAndCompare` 75-92, which resolves BOTH slots out of line and then recurses
  into `eqHelp`, whose first line is the pointer test). So for `MList`/`MTuple`/`MCustom`/
  `MFunction` the shell compare is not a deep walk when children are canonical; its cost is the
  export call, two out-of-line `Allocator::resolve` per slot (plan step 14), and the
  `ModuleName.Canonical`/`Name` string compares (`StringOps::equal`, `StringOps.hpp:1486`, with
  a length check then `memcmp`; pointer-identical strings return at `eqHelp:509` first).
- For `MRecord Int (Dict Name MonoType)` the `Tag_Custom` arm routes to `dictEq` (646-648 →
  733-780): two `std::vector<Custom*>` that start empty and REALLOCATE on `push_back`
  (`pushLeftSpine` 749-754; the profile's `memmove` 2.1 % and `Dict` 2.4 % under
  `Intern_probe` are this), a `resolveCustom` per tree node, and per field two
  `eqUnboxableSlot`s (four out-of-line resolves). For the compiler's own `S` record (31 fields)
  that is ~8 heap allocations and ~130 resolves per probe — the single most expensive shape, and
  the shape every `s : S` occurrence classifies (plan §1: record types in load/zonk/classify
  10-12 % inclusive).

**The lever.** The compiled compiler lowers `==` on a boxed value to the `eco.value.eq`
intrinsic (`/work/compiler/src/Compiler/Generate/MLIR/Intrinsics.elm:706-710`, gated by
`boxedComparable` 818-842 which admits `MString`/`MUnit`/`MList`/`MTuple`/`MRecord`/`MCustom`,
and by `Expr.gateIntrinsic` `/work/compiler/src/Compiler/Generate/MLIR/Expr.elm:1417-1429`
requiring both SSA operands to be `!eco.value`). Its LLVM-level expansion
`expandValueEqFastPath` (`/work/runtime/src/codegen/EcoBackend.cpp:1817-1875`) is a three-arm
diamond: `icmp eq %a, %b` → true; embedded-constant test → false; else the kernel call.
`valueEq = True` is the shipped default (`/work/compiler/src/Compiler/Eco/Config.elm:48, 722`,
kill switch `ECO_VALUE_EQ=0`) and the inline diamond is on unless `ECO_VALUE_EQ_INLINE=0` at
LOWERING time (`EcoBackend.cpp:1781-1787`). Therefore an Elm-side shallow compare that tests
the packed hash `Int` and then `==`s each child is, on the hit path with canonical children,
one inline `icmp` per child and ZERO kernel calls — strictly cheaper than `eqHelp`'s in-C++
walk for every shape, and for records it replaces `dictEq`'s vectors + ~130 resolves with
`f` inline compares of names and `f` inline compares of values.

**Expected effect.** Of the five loop stats only WALL should move: the hit path becomes
allocation-free on both the GC heap and `malloc` (the `std::vector`s were never GC objects, so
minor/major GC counts and promoted MiB are expected IDENTICAL to the reference — treat any GC
delta > 1 minor cycle as a bug in the edit). The probe cluster is 19.6 % of the window
(equality 8.8 + resolve 2.8 + Dict 2.4 + memmove 2.1 + strings 1.4 = 17.5 % is the compare
itself); halving it is 8-9 % of the window ≈ 4 % of wall (~16 s of 399 s). The plan's
"~10-15 %" is the ceiling if records dominate the probe mix (they do by cost; the count mix is
unmeasured — §6 adds the attribution leg). RSS: +≈10 MB retained (one sorted field list per
canonical record, ~20 K records × ~10 fields) — invisible against the 2.15 GB bimodality.

**Byte-identical: YES, required.** `eqExact` remains EXACTLY `==` (proof in §4), the hash
functions and `hashBase` are untouched, and the intern table is never iterated (only
`get`/`insert`/`size` — `Intern.elm` 127-130, 196-201, 213), so neither what is canonicalised
nor any emission-visible order can change. Gate: Phase-2 `cmp` per
`/work/benchmarks/lss-compile-opt-loop.md`.

#### 2. Preconditions

- No plan step is a prerequisite. Step 17 is independent (it must carry `HashMap.getBy`, added
  here, if it lands later).
- Verify the diamond is live in the loop's toolchain, otherwise the win is capped (still
  correct):
  ```bash
  grep -n "valueEq = True" /work/compiler/src/Compiler/Eco/Config.elm      # expect line 722
  env | grep -E "ECO_VALUE_EQ"                                              # expect NOTHING set
  ```
  and, after Phase 1.3 of the loop, that the new function is emitted with the intrinsic:
  ```bash
  awk '/func.func @Compiler_AST_Intern_eqExactAgainst/,/^  }/' build/compiler/build-kernel/bin/ecoN.mlir | grep -c "eco.value.eq"        # expect >= 4
  awk '/func.func @Compiler_AST_Intern_eqExactAgainst/,/^  }/' build/compiler/build-kernel/bin/ecoN.mlir | grep -c "Elm_Kernel_Utils_equal"  # expect 0
  ```
- Confirm the table is threaded linearly (it is today; the design does not depend on it, but
  the §7 note on design (a) does):
  `grep -n "intern = " /work/compiler/src/Compiler/MonoSolver/*.elm` must show only forward
  writes (Engine 2785, Store 2259/2396/2403, Translate 3185/8136, Monomorphize 3870) and no
  restore of an older `intern` (`withScratchStore` Engine 2033-2100 and `retranslateWithTag`
  Translate 5995-6016 restore `store`/`memo`/`revMemo`/`itemAux` only; `scoped` Engine
  2631-2638 restores `varEnv` only).

#### 3. Inventory of touched code

| file | function (lines now) | what changes |
|---|---|---|
| `/work/compiler/src/Data/HashMap.elm` | `get` 62-69, `scanBucket` 72-83 | ADD `getBy : (q -> Int) -> (q -> k -> Bool) -> q -> HashMap k v -> Maybe v` (probe type ≠ key type); `get` becomes `getBy hash eq`. Nothing else in the file changes. |
| `/work/compiler/src/Compiler/AST/Intern.elm` | `type Intern` 71-74 | key type becomes `Canon` (new record: the canonical node + its pre-sorted field list); value stays `MonoType`. |
| same | `empty` 79-81, `readOnly` 108-118, `size` 123-133, `hashCons` 141-187, `widenSets` 270-321, `widenList` 324-338 | UNCHANGED (types line up through the alias). |
| same | `probe` 194-201, `probeRO` 211-218 | use `HashMap.getBy Mono.specHashOf eqExactAgainst mt m`; on a miss `probe` inserts `canonOf mt`. |
| same | `eqExact` 234-236 | REPLACED by `eqExactAgainst : MonoType -> Canon -> Bool`, `eqChildren`, `eqFieldsAgainst`, `failedFields`, `canonOf`, `canonHash`, `canonEq`; `eqExact : MonoType -> MonoType -> Bool` is KEPT as the exported oracle-comparable form (`eqExact a b = eqExactAgainst a (canonOf b)`) and exposed for the unit pin. |
| same | module header 1-4 | expose `eqExact`. |
| `/work/compiler/tests/TestLogic/Monomorphize/ComparableKeyEncodingTest.elm` | `suite` 36-262 | ADD two tests (§6); existing K6/K7 tests (149-262) need NO edit — the `Intern` API they use is unchanged. |
| `/work/compiler/tests/Compiler/Data/HashMapTest.elm` (NEW; sibling of `BitSetTest.elm`, `NameKernelTest.elm`) | — | pins `getBy` (and is extended by step 17). |
| `/work/compiler/src/Compiler/AST/Monomorphized.elm` | `mRecord` 473-485 | OPTIONAL entry 2b only: fuse the two `Dict.foldl` hash folds into one (hash VALUES unchanged). |

Call sites of the `Intern` API — all UNCHANGED, listed so the engineer can confirm the type
still lines up (`Intern` is opaque; only its constructor payload changes):

- `Intern.hashCons`: `/work/compiler/src/Compiler/Monomorphize/TypeSubst.elm:873, 876, 879, 882, 913, 920, 1110`;
  `/work/compiler/src/Compiler/MonoSolver/Zonk.elm:113, 116, 119, 122, 151, 158, 225`;
  `/work/compiler/src/Compiler/MonoSolver/Engine.elm:2757` (`consS` 2753-2759);
  `/work/compiler/src/Compiler/MonoSolver/Store.elm:2253` (`consC` 2249-2259);
  `Intern.elm:281, 288, 295, 311, 318` (`widenSets`).
- `Intern.widenSets`: `Engine.elm:2129` (`enqueueSpec` 2110) and `:2331` (`enqueueSpecKeyed` 2305).
- `Intern.size`: `Engine.elm:2781` (`withIntern` 2779-2785), `Store.elm:2255`.
- `Intern.empty`: `/work/compiler/src/Compiler/Monomorphize/State.elm:363`, `/work/compiler/src/Compiler/MonoSolver/Monomorphize.elm:3870`,
  tests `LssDirectedFlowTest.elm:188`, `LssHonestSourcesTest.elm:318`, `ComparableKeyEncodingTest.elm` (several).
- `Intern.readOnly`: `TypeSubst.elm:785` (`applySubstPureRO` 783); `Intern.disabled`: `TypeSubst.elm:760`, `Zonk.elm:46, 58`.
- Bare `Intern` writes through `S`/`MonoState`: `Translate.elm:3183-3185` (`computeSchemeMono`), `:8134-8136`; `Store.elm:2387, 2396, 2403, 2485` (`zonkToMono` ctx); `Specialize.elm:201-204`.

#### 4. Design

**4.1 The compared pair.** A probe compares a FRESH node `mt` (built one line earlier by a
smart constructor, `Mono.m*`, so its packed hash is correct) against the STORED canonical.
The two are never the same object. Children of `mt` are canonical whenever the producer
hash-conses bottom-up — that is every recursive producer: `Store.classifyGo` (3527-3630:
`consS` at 3577/3598/3619 and `Engine.consS (classifyApp …)` at 3585), `Store.zonkFlatC`
(2769-2845: `consC` at 2791/2808/2816/2845, `classifyAppC` 3444-3446), `zonkRecordFieldsC`
(3407-3418, `consC` 3411), `Zonk.canTypeToMonoWithI` (60-160, `lambdaChain` 207-226),
`TypeSubst.applySubstPureI` (809-925, `applySubstLambdaChainI` 1097-1112), `Intern.widenSets`
(270-321). Children are NOT canonical when the caller passes a subtree built by one of the
pure rebuilders and later re-conses only the top: `Mono.widenSets` (Monomorphized.elm
2056-2073, `Dict.map`), `overlayAnnotations` (2526-2560), `enrichAnnotationsWith`
(1543-1580), `joinAnnotations`/`joinAnnotationsChanged` (2208 / 2277), `Translate.joinBranchTypes`
(7737-7761), `remapEcoVarsFresh` (1316-1371), `stampSpineGo` (4748), `recordTypeFromFields`
(5408), `unionRecordTypes` (5598), `replace{Custom,Unbox,Record}Slot` (6413/6454/6624),
`Monomorphize.settleVarCtorRows`/`settleVarLambda`/`varSuccRounds` (527-582/777-838/1277-1367),
`TypeSubst` 126-138/276-319/692-736/1688-1720, and the `Translate.elm:702` site which conses
`overlayAnnotations monoType0 (mList …)` — a non-canonical spine under a canonical top.
**Consequence for the design:** correctness must not assume canonical children; only speed
does. Every child comparison below is `==`, whose slow arm is the kernel's full structural
equality, so a structurally-equal-but-distinct child still compares equal — `eqExact ≡ (==)`
holds for every input. `Disabled` tables never reach the compare (`hashCons` 144-145);
`ReadOnly` tables reach it through `probeRO` with the same function.

**4.2 Types (Intern.elm).**

```elm
{-| One table entry: the canonical node plus, for a record, its fields in ascending
name order (`Dict.toList`), so a probe can walk a fresh record's `Dict.foldl`
(ascending) in LOCKSTEP without allocating and without `Dict.get`. `fields` is `[]`
for every other kind. Built once per canonical node, on the miss path only.
-}
type alias Canon =
    { node : MonoType
    , fields : List ( Name, MonoType )
    }

type Intern
    = Intern (HashMap.HashMap Canon MonoType)
    | ReadOnly (HashMap.HashMap Canon MonoType)
    | Disabled

canonOf : MonoType -> Canon
canonOf mt =
    case mt of
        Mono.MRecord _ fields ->
            { node = mt, fields = Dict.toList fields }

        _ ->
            { node = mt, fields = [] }

canonHash : Canon -> Int
canonHash c =
    Mono.specHashOf c.node

canonEq : Canon -> Canon -> Bool
canonEq a b =
    eqExactAgainst a.node b
```

`Name` is `String` (import `Compiler.Data.Name` as `Monomorphized` does, or spell `String`).

**4.3 The probes.**

```elm
probe : MonoType -> HashMap.HashMap Canon MonoType -> Intern -> ( MonoType, Intern )
probe mt m intern =
    case HashMap.getBy Mono.specHashOf eqExactAgainst mt m of
        Just canonical ->
            ( canonical, intern )

        Nothing ->
            ( mt, Intern (HashMap.insert canonHash canonEq (canonOf mt) mt m) )

probeRO : MonoType -> HashMap.HashMap Canon MonoType -> Intern -> ( MonoType, Intern )
probeRO mt m intern =
    case HashMap.getBy Mono.specHashOf eqExactAgainst mt m of
        Just canonical ->
            ( canonical, intern )

        Nothing ->
            ( mt, intern )
```

The LOAD-BEARING property of both (docs at 190-193 and 204-210) is preserved: on a hit the
very `intern` value passed in is returned, so `Engine.withIntern` (2779-2785) and `Store.consC`
(2249-2259) size guards keep firing only on a real insert.

**4.4 The compare.** Nested `case`s, never a `case ( a, b ) of` tuple scrutinee (agent G's
open question G13 — whether the backend materialises the tuple is unsettled; nested cases are
allocation-free for certain). Order of tests inside each arm: packed `Int` first (an unboxed
field, `eco.int.eq`), then the cheapest boxed slots, then the children.

```elm
{-| EXACT structural equality of a fresh node against a stored entry — decides
precisely what `==` decides (the module docs above say why it must be `==` and not
`eqKeySpec`), but shaped so that on the hit path with canonical children it is
one inline word compare per slot (`eco.value.eq`'s fast arm) and no kernel call.
The packed hash `Int` (K4: equal structures ⇒ equal packed hashes, both halves) is
tested first so a bucket collision is rejected in O(1).
-}
eqExactAgainst : MonoType -> Canon -> Bool
eqExactAgainst a c =
    case a of
        Mono.MRecord ha fa ->
            case c.node of
                Mono.MRecord hb _ ->
                    ha == hb && eqFieldsAgainst fa c.fields

                _ ->
                    False

        Mono.MCustom ha homeA nameA argsA ->
            case c.node of
                Mono.MCustom hb homeB nameB argsB ->
                    ha == hb && nameA == nameB && homeA == homeB && eqChildren argsA argsB

                _ ->
                    False

        Mono.MFunction ha annoA argsA retA ->
            case c.node of
                Mono.MFunction hb annoB argsB retB ->
                    ha == hb && annoA == annoB && retA == retB && eqChildren argsA argsB

                _ ->
                    False

        Mono.MTuple ha xs ->
            case c.node of
                Mono.MTuple hb ys ->
                    ha == hb && eqChildren xs ys

                _ ->
                    False

        Mono.MList ha x ->
            case c.node of
                Mono.MList hb y ->
                    ha == hb && x == y

                _ ->
                    False

        _ ->
            -- Leaves never reach a probe (`hashCons` 148-167 filters them), but
            -- the function must stay total and `==`-exact.
            a == c.node


eqChildren : List MonoType -> List MonoType -> Bool
eqChildren xs ys =
    case xs of
        [] ->
            List.isEmpty ys

        x :: restX ->
            case ys of
                y :: restY ->
                    x == y && eqChildren restX restY

                [] ->
                    False
```

The record arm walks the fresh `Dict` in ascending order (`Dict.foldl` is in-order) against
the stored ascending list. The accumulator is the remaining stored list; a mismatch parks the
accumulator on a sentinel that can never match a real field (Elm record field names are
lower-case identifiers, never `""`), so the fold stays allocation-free and total:

```elm
{-| Sentinel: a list that no real field can match, parked in the accumulator after
the first mismatch. Names are never `""`, so every later step keeps returning it.
-}
failedFields : List ( Name, MonoType )
failedFields =
    [ ( "", Mono.MUnit ) ]


{-| `fresh` equals the stored record iff walking it in ascending name order consumes
the stored list EXACTLY: every (name, value) pair equal, nothing left over on either
side. Size equality is implied — fewer fresh fields leave a non-empty remainder,
more fresh fields hit `[]` and fail.
-}
eqFieldsAgainst : Dict Name MonoType -> List ( Name, MonoType ) -> Bool
eqFieldsAgainst fresh stored =
    List.isEmpty (Dict.foldl eqFieldStep stored fresh)


eqFieldStep : Name -> MonoType -> List ( Name, MonoType ) -> List ( Name, MonoType )
eqFieldStep name t remaining =
    case remaining of
        ( n, ct ) :: more ->
            if n == name && ct == t then
                more

            else
                failedFields

        [] ->
            failedFields


eqExact : MonoType -> MonoType -> Bool
eqExact a b =
    eqExactAgainst a (canonOf b)
```

**Exactness argument (why BI holds).** Elm `==` on `MonoType` is the kernel's structural
equality: same constructor, then every field equal — `Int`s by value, boxed slots by `eqHelp`,
and a `Dict` by `dictEq` CONTENT equality (in-order key/value sequences pairwise equal, colour
and tree shape ignored, 733-780). Arm by arm: `ha == hb` is implied by structural equality
(K4 contract, `hashBase` docs 277-304: hashes are computed from the children's stored hashes,
so equal structures produce equal packed `Int`s — both halves — and `ComparableKeyEncodingTest`
pins "equal keys imply equal hashes", which is weaker than but consistent with this) and so
never rejects an equal pair; the remaining tests are the field-wise `==`s in a different order
(`&&` is commutative for pure, total predicates). The record arm is content equality: the
ascending in-order sequence of `fresh` (`Dict.foldl`) against the ascending in-order sequence
of the stored record (`Dict.toList` at insert), pairwise `n == name` (string content, exactly
what `dictEq`'s key `eqUnboxableSlot` decides) and `ct == t`, consumed exactly. Hence
`eqExactAgainst a (canonOf b) == (a == b)` for all `a`, `b` — the §6 pin checks this over the
encoder corpus.

**4.5 `HashMap.getBy` (Data/HashMap.elm).** Same body as `get`, with the probe type freed:

```elm
{-| `get` with a PROBE of a different type than the stored keys. `hash` is applied
to the probe; `eq probe storedKey` decides. The two must agree with the `hash`/`eq`
pair the map was built with, exactly as `get`'s must.
-}
getBy : (q -> Int) -> (q -> k -> Bool) -> q -> HashMap k v -> Maybe v
getBy hash eq probe (HashMap _ _ buckets) =
    case Dict.get (hash probe) buckets of
        Nothing ->
            Nothing

        Just bucket ->
            scanBucketBy eq probe bucket


scanBucketBy : (q -> k -> Bool) -> q -> List ( Int, k, v ) -> Maybe v
scanBucketBy eq probe bucket =
    case bucket of
        [] ->
            Nothing

        ( _, k, v ) :: rest ->
            if eq probe k then
                Just v

            else
                scanBucketBy eq probe rest


get : (k -> Int) -> (k -> k -> Bool) -> k -> HashMap k v -> Maybe v
get hash eq key m =
    getBy hash eq key m
```

`insert canonHash canonEq (canonOf mt) mt m` (129) still runs `bucketMember canonEq` on the
(already known to miss) bucket — one redundant scan per MISS (1 % of probes); not worth an
`insertNew` variant.

**4.6 Mint-order / emission constraints.** The set of probes, their order, and which of them
miss are unchanged (same producers, same inputs, same decision function), so the table's
insertion sequence is identical; and nothing iterates the table, so even that is not
emission-visible. No member id, Point index, or SpecId is minted on this path. No `S` field
is added (the 32-slot cap, Engine.elm:1323 comment, is untouched).

**4.7 Optional entry 2b — one hash fold in `mRecord`** (Monomorphized.elm 473-485). Today two
`Dict.foldl`s each call `String.length name` and a `hashOf` per field. Fuse them with a packed
accumulator; the produced `Int` is bit-identical, so the K4 pins and every bucket stay put:

```elm
mRecord : Dict Name MonoType -> MonoType
mRecord fields =
    let
        seed =
            mixHash 13 (Dict.size fields)

        packed =
            Dict.foldl
                (\name t h ->
                    let
                        len =
                            String.length name

                        l =
                            mixHash (mixHash (h // hashBase) len) (layoutHashOf t)

                        s =
                            mixHash (mixHash (modBy hashBase h) len) (specHashOf t)
                    in
                    packHashes l s
                )
                (packHashes seed seed)
                fields
    in
    MRecord packed fields
```

(`h // hashBase` and `modBy hashBase h` recover the two running hashes; both stay in
`[0, hashBase)` so the pack never exceeds 2^52.) Measured share is only 0.8-1.5 % of the
window (plan §1), so this is its own loop entry, never mixed into 2a.

#### 5. Edit sequence

Each step leaves `elm make` green (`compiler/src/Terminal/Main.elm`, ~1 s) and the unit suite
runnable.

1. **HashMap.getBy.** Add `getBy`/`scanBucketBy` to `/work/compiler/src/Data/HashMap.elm`
   (after `scanBucket` 72-83), re-express `get` through it, export `getBy` (module header
   1-6, docs 35-39). Add `/work/compiler/tests/Compiler/Data/HashMapTest.elm` with the `getBy`
   pin (§6). Build + run `elm-tests`.
2. **Canon + compare, old key type still in place.** In `Intern.elm` add `Canon`, `canonOf`,
   `canonHash`, `canonEq`, `eqExactAgainst`, `eqChildren`, `failedFields`, `eqFieldsAgainst`,
   `eqFieldStep`; redefine `eqExact a b = eqExactAgainst a (canonOf b)`. Nothing uses the new
   functions yet except `eqExact`, which `probe`/`probeRO` still pass to `HashMap.get`. This
   already changes the hot path's compare (the `canonOf b` allocation per probe is the reason
   step 3 follows immediately — do NOT measure this state). Expose `eqExact`; add the two
   `ComparableKeyEncodingTest` pins (§6); run `elm-tests`.
3. **Switch the table.** Change the two `HashMap.HashMap MonoType MonoType` payloads (72-73)
   to `HashMap.HashMap Canon MonoType`; rewrite `probe`/`probeRO` per §4.3 (`getBy` with
   `Mono.specHashOf`/`eqExactAgainst`; insert with `canonHash`/`canonEq`/`canonOf`). `size`
   (123-133) and `readOnly` (108-118) compile unchanged. Update the module docs (16-19,
   221-233) to say the compare is the shallow `eqExactAgainst`, still `==`-exact. Run
   `elm-tests`; this is the `try-2` snapshot for the loop.
4. **(Entry 2b, separate loop iteration.)** Replace `mRecord`'s two folds with §4.7. The
   `ComparableKeyEncodingTest` golden/differential/range tests are the pin (no edit needed:
   the hash values do not change — add a one-line assertion that `Mono.specHashOf`/`layoutHashOf`
   over the corpus equal a recorded list only if you want a stronger pin; the differential test
   already fails if the packing slips).

#### 6. Verification

**Unit (Phase 4 gate, `cmake --build build --target elm-tests`; filter with
`build/toolchain/bin/elm-test-rs --project build/compiler/build-xhr --fuzz 1 --filter Intern`).**

- In `ComparableKeyEncodingTest` add:
  - "K6: Intern.eqExact decides exactly `==`" — over `pairs` (the existing 90×90 + handwritten
    product, lines 265-274): `List.filter (\( a, b ) -> Intern.eqExact a b /= (a == b)) pairs`
    is `[]`.
  - "K6: record probes are content-exact and shape-blind" — a handwritten list of pairs
    `( a, b, expected )`: same fields inserted in two orders (`Dict.fromList` vs a reversed
    `Dict.fromList`) → True; strict subset → False; strict superset → False; one field
    renamed at equal length (`{ ab : Int }` vs `{ ba : Int }`, which also collides on the
    packed hash) → False; same names, one child differs (`MInt` vs `MFloat`) → False; a nested
    record whose inner value is an equal-but-distinct object (two separate `mRecord` builds)
    → True; an empty record vs empty record → True. Assert
    `Intern.eqExact a b == expected && (a == b) == expected` for each.
- The existing K6/K7 tests (149-262) keep running unchanged and pin: hash-consing returns an
  `==`-equal value; replaying a canonical corpus adds nothing (`size` unchanged — this is the
  test that catches a compare that is too STRICT); read-only tables never grow.
- `HashMapTest`: `getBy` with a probe type different from the key type finds exactly the entries
  `get` finds, on a map with forced collisions (`hash = modBy 3`).

**Loop (`/work/benchmarks/lss-compile-opt-loop.md` §1-§4).** `try-2`; Phase 1.3/1.4; Phase 2
triple; the two mechanical checks (`cmp` r1/r2/r3 and `cmp r1-out.mlir bin/eco2.mlir` — this
step is BI so no extra bootstrap turn). Verdict on medians; expect minor GC, major GC and
promoted MiB IDENTICAL to the reference row — if they are not, the edit allocates on the hit
path (a `case (a, b)` tuple, a `Dict.get`, a `Dict.toList`) and must be fixed before the wall
number is read.

**Attribution leg (untimed, separate).** Two checks on the candidate binary:
1. MLIR shape (§2 commands): `eqExactAgainst`/`eqFieldStep`/`eqChildren` contain
   `eco.value.eq` and no `Elm_Kernel_Utils_equal`.
2. `perf record -F 199 -g` of one candidate self-compile (plan §1 method, `prof2/attrib.py` in
   this scratchpad): `dictEq` must drop to ≈0 samples; `Intern_probe` inclusive should fall from
   19.6 % toward ~10 %; `Data_HashMap_scanBucketBy` replaces `scanBucket`. If `Intern_probe`
   does not move, read the probe KIND mix before concluding — add (report-gated, never in a
   timed run) a per-kind counter to `Intern.probe` threaded through a `Dict`-free tally in
   `S.lssStats` only if the perf attribution is ambiguous.

#### 7. Risks, gotchas, and what NOT to do

- **Do not use `case ( a, b ) of`** in the hot compare (G13: tuple materialisation unsettled).
- **Do not compare records with `Dict.get` per field** (`Mono.eqFieldsBy`, 677-692, is the
  shape the plan's (b) sketched): `Dict String` descent compiles to a kernel string `compare`
  per level (`Intrinsics.elm` `CompareToOrder StringKind`, no pointer fast path) — ~155 kernel
  calls for `S`, worse than `dictEq`. **Do not** use `Dict.keys a == Dict.keys b` / `Dict.values`
  either: 2f cons cells per probe. **Do not** call `Dict.size` in the compare (it is O(n),
  elm/core `Dict.elm:124-133`); the lockstep makes it unnecessary.
- **Keep `eqExact ≡ (==)`.** Never substitute `eqKeySpec`/`eqModuloTopLabel`/kind-blind anno
  equality — the module docs (25-31, 221-233) and `LTop`-vs-`LVar` twins depend on exactness;
  a looser compare changes which object is handed back and therefore emission.
- **Do not touch `hashBase`, `mixHash`, `packHashes` or any hash function** (306-320, 448-543):
  `ComparableKeyEncodingTest` pins the range (< 67108864) and the differential; the JS-hosted
  build (Stage 5) needs the pack < 2^53; `TOpt.globalMixHash` (TypedOptimized.elm 341-345)
  mirrors the modulus. Entry 2b changes only the fold's shape, not its value.
- **LOAD-BEARING comments to keep true:** `probe` returns the given `intern` on a hit (190-193);
  `withIntern`'s size guard is an exact "did it grow" test (2762-2778); `Store.consC`'s guard
  (2240-2248). None of them changes; do not "simplify" the hit path into `Intern (…)`.
- The `""` sentinel relies on field names never being empty; `Specialize.elm:886, 3843, 3857`
  and `Translate.elm:5408, 6624` build records from source field names only. If a future
  producer could mint an empty name, switch the sentinel to a dedicated `Maybe`-free marker
  (a private `MonoType` value is not available; use a two-element list `[ ( "", MUnit ), ( "", MUnit ) ]`
  compared by pointer via `==`) — note it in the docs, do not "fix" it by allocating a
  `Maybe` per field.
- **`ECO_VALUE_EQ=0` or `ECO_VALUE_EQ_INLINE=0`** in the environment of Phase 1.3 (the
  compiler) or 1.4 (the lowering) removes the inline arm; the result is still correct but the
  step reads as flat. The loop's `ENV` sets neither — keep it that way.
- Not canonical ≠ wrong: a non-canonical child costs a kernel `eqHelp` in the slow arm, which
  is what happens today for the whole node. The `Translate.elm:702` overlay-then-cons site and
  the rebuilders in §4.1 are step 22's business (plan), not this step's.
- Retention: `Canon.fields` keeps one `( Name, MonoType )` list per canonical record (the
  names and children are already retained by the node; the list is ~6 words per field). If RSS
  needs to be argued, count records in the table with a one-off `HashMap.foldl` under
  `ECO_MONO_LSS_REPORT=1`.
- Plan §4 items that stay out: N12 (the registry probe is already on the pointer path;
  `identicalOr` 585-587 is NOT changed — its `a == b` is the same diamond), N22 (no GC
  tuning), and step 4's memo (probe COUNT) is a separate step.
- `Intern.size`/`HashMap.size` must stay O(1) (the guards above call it per composite).
- **Invariants touched:** none amended. MONO_003/D4 key merges are unaffected because the
  compare is exact (Intern docs 25-31); LSS_041 (flags fixed) unaffected; MONO_030 unaffected.

**Design (a) — intern id on every node — and why not.** It is disqualified by SEMANTICS
before effort: `==` on `MonoType` is a decision, not a fast path, at `eqLayout`'s fallback arm
(Monomorphized.elm:2106 — AbiCloning's layout grouping), `eqModuloTopLabel` (1951),
`Registry.getOrCreateSpecIdKeyed`'s `storedType == storeType` (Registry.elm:147), the
`Dict.keys ==` guards of `overlayAnnotations`/`enrichAnnotationsWith`/`joinAnnotations*`,
`identicalOr` (587), and the K6 pin "hash-consing returns a type EQUAL to the one handed in"
(ComparableKeyEncodingTest 149-152). An id field makes every FRESH node (id 0) `/=` its
canonical twin, so structurally equal types become layout-unequal wherever one side is fresh —
an emission change at best and a miscompile at worst; every `==` on `MonoType` in the compiler
would have to be found and replaced (the M4 audit's whole population). Mechanically it is also
worse than the plan rates it: adding a constructor field touches 917 constructor mentions in 40
files; packing the id into the leading `Int` forces the two hashes down to 16 bits each to stay
under the JS 2^53 exact range (`hashBase` docs 306-310) and needs an id-overflow policy. And it
buys nothing over (b): with the `eco.value.eq` diamond, comparing a canonical child by `==`
IS one inline word compare — the same cost as an `Int` id compare — while names and
`ModuleName.Canonical` still have to be compared under either design. The only thing (a) would
add is a stable Int identity for step 13's member keys; that step's own design (a side
`widenedClass : SpecMap Int`) does not need it.

#### 8. Effort

**M.** 2a = `getBy` (10 lines) + ~90 lines in `Intern.elm` + two pins: one loop entry (`2`).
2b = the `mRecord` fold fusion: its own entry (`2b`), S, only after 2a is kept.

---

<details><summary>Conventions used in this spec (from spec-A)</summary>

Line numbers are as of 2026-09-19 (`/work`, clean tree). Every cited line was read, not
remembered. "Window" = the mono-phase window of the DWARF profile in plan §1.

---

</details>

### Step 3 (was 2). A transient (in-place) union-find store for the per-item scratch store

1. **Goal and expected effect**

`IO.State.ioRefsPoint : Array PointCell` (IO.elm:102) is a persistent 32-way trie. Every
`IORef.writePointCellS` (IORef.elm:107-109) is an `Array.set` = a path copy of 2-3 32-slot nodes
(`Array_setHelp` → `eco_clone_array` → memmove), every `newPointCellS` (112-116) an `Array.push`
(`Array_unsafeReplaceTail`, `elm_array_push_box`). `UF.unionS` (UnionFind.elm:239-274) does two such
writes per union plus `reprS`'s compression writes (172). Plan §1 attributes **~12 % of the mono window
inclusive** to this cluster (`unionS` 7.9 %, `freshS` 4.1 %, `writePointCellS` 6.9 %, `newPointCellS`
3.9 %; Array path-copy memmove 4.0 %, `Array_*`/`eco_clone_array` 4.75 %, GC 1.7 %) and notes (§3) that
GC is dominated by survivor copying, of which the churned trie nodes are the biggest single source.

The change: the cell array becomes an **off-heap mutable cell vector owned by a kernel module**
(`Eco.CellStore`, new in the `eco/kernel` package), rooted through the runtime's external-root-scanner
mechanism (the HEAP_040 / MVar precedent), with a **trail (undo log) behind an explicit
`pushMark`/`rollback`/`commit`** API used at the 3 rollback sites and the 2 report-gated census sites, and
a fresh store object per scratch scope. A write becomes one C call + one store; a fresh Point one C call +
one vector push. No trie nodes are allocated at all. The Elm-visible interface of `UnionFind`/`IORef`
is unchanged (same 15 exports, same types), so no caller outside the 22 sites in §3 changes.

Expected: the whole 12 % cluster collapses to the C-call overhead (≈ 1-2 %) ⇒ mono window −8…−10 %,
and the GC's survivor-copy share falls (fewer live trie nodes per minor GC). The typechecker shares
`IO.State`, so the front-end window (51 % of wall, `Solve`/`Unify` also thread the store linearly) gets the
same per-write saving — an extra win the plan does not count. Loop stats (benchmarks/lss-compile-opt-loop.md
§4): **wall down** (expected −4…−6 % of the whole run), **minor-GC time down**, **objects down** by roughly
(writes + pushes) × (2-3 trie nodes) ≈ 10^7-10^8 objects, RSS flat-to-down.

**Emission must stay byte-identical (BI = yes)** and it does by construction: the same cells are read and
written in the same order; `push` returns the same monotone index that `Array.length` returned before
(`newPointCellS` 114); union-by-weight (`unionS` 259-271) sees the same weights; rollback restores the
exact pre-mark cells AND the pre-mark cell count, which is exactly what discarding the persistent array
did. Path compression is preserved as-is (same writes, `reprS` 166-175).

2. **Preconditions**

- Plan dependencies: none. Placement: the plan allows sliding it after step 10; this spec composes with
  spec-E either way (§4.6 gives both shapes). Doing it BEFORE step 8 (spec-F) is fine — spec-F's
  `peekS` sites then simply become `CellStore.get` reads with no copy.
- Verify the store's only construction sites (must be exactly these, else the audit in §4.1 is stale):
  `grep -rn "ioRefsPoint" compiler/src compiler/tests --include=*.elm` → IO.elm:63,95,102; Solve.elm:132;
  Vars.elm:44,72 (comments); Engine.elm:2412. And
  `grep -rn "freshStore" compiler/src compiler/tests --include=*.elm` → Engine.elm:2409-2427 (def), 2042,
  2435; Translate.elm:6006; Monomorphize.elm:3901; tests/TestLogic/Monomorphize/ArrowIdentityTest.elm:141,
  212, 222.
- Verify the swallowed-error sites are still exactly the ones audited in §4.1:
  `grep -n "Err _ ->" -A 2 compiler/src/Compiler/MonoSolver/{Store,Translate,LssInfer,Engine,Monomorphize}.elm`
  → Store 1082, 2066, 2479; Translate 1952, 1959, 1964, 5290; Monomorphize 150, 1252, 3968, 4283.
  Any NEW `Err _ ->` arm that continues with an older `S` must be classified per §4.1 before building.
- Verify the native toolchain: `bin/eco-opt-prev` exists (loop §2), `build/runtime/src/codegen/eco-boot-native`
  builds, and `cmake --build build --target test` links `EcoKernel_MVar` whole-archive
  (test/CMakeLists.txt:144-157) — the new library is added at the same places.
- Read `design_docs/invariants.csv` rows HEAP_005, HEAP_011, HEAP_020, HEAP_040, FORBID_HEAP_003,
  REP_ABI_001, KERN_006, LSS_004 before writing any C++.

3. **Inventory of touched code**

| file | function (lines as of 2026-09-19) | what changes |
|---|---|---|
| **NEW** `eco-kernel-cpp/src/Eco/CellStore.elm` | whole module | Elm wrapper over `Eco.Kernel.CellStore.*` (§4.3); add `"Eco.CellStore"` to `eco-kernel-cpp/elm.json` `exposed-modules` (7-19) |
| **NEW** `eco-kernel-cpp/src/Eco/Kernel/CellStore.js` | whole file | JS implementation for the JS bootstrap stages (eco-boot.js is built from this package: compiler/CMakeLists.txt 256-257, 299) |
| **NEW** `eco-kernel-cpp/src/eco/CellStore.hpp`, `CellStore.cpp`, `CellStoreExports.cpp` | whole files | C++ store table + trail + root scanner + `extern "C"` exports (§4.4) |
| `eco-kernel-cpp/src/eco/KernelExports.h` | after the MVar block (200-213) and the hook list (235-237) | declare the 9 `Eco_Kernel_CellStore_*` exports and `Eco_Kernel_CellStore_register_gc_roots` |
| `eco-kernel-cpp/src/eco/RuntimeExports.cpp` | `Eco_Kernel_register_all_gc_roots` 46-51 | call `Eco_Kernel_CellStore_register_gc_roots()` |
| `eco-kernel-cpp/CMakeLists.txt` | MVar library block 158-167; `EcoKernel` INTERFACE list 250-260; asserts foreach 264-268 | add `EcoKernel_CellStore` (same three places as `EcoKernel_MVar`) |
| `compiler/CMakeLists.txt` | link lists 752-754, 812-814, 847-849 | add `EcoKernel_CellStore` next to `EcoKernel_MVar` |
| `test/CMakeLists.txt` | whole-archive lists 153-157, 168, 174-182, 209-219 | add `EcoKernel_CellStore` next to `EcoKernel_MVar` (the JIT must dlsym the symbols) |
| **NEW** `compiler/src-xhr/Eco/CellStore.elm` | whole module | the PURE twin (persistent `Array` + snapshot stack) for stock-Elm builds: Stage 1 and the elm-test-rs unit suite (compiler/CMakeLists.txt 108-123, 1053: "Stage 1 uses stock Elm"; build-xhr/elm.json `source-directories: ["src","src-xhr"]`) |
| `System/TypeCheck/IO.elm` | `State` 101-106; `unsafePerformIO` 61-68; new `freshState : () -> State` | field type `ioRefsPoint : CellStore.Store PointCell`; run + dispose |
| `Data/IORef.elm` | `readPointCellS` 97-104, `writePointCellS` 107-109, `newPointCellS` 112-116; module doc 8-19 | the three primitives become `CellStore.get`/`set`/`push` + `size` |
| `Compiler/Type/UnionFind.elm` | module doc 6-22, 125-143 (no code change) | document the linearity rule (§4.8) |
| `Compiler/Type/Solve.elm` | `runWithIds` snapshot 128-134 | `cells = CellStore.freeze s.ioRefsPoint` (type of `solverState.cells` stays `Array Vars.PointCell`, so SolverRoots.elm:383 and SolverSnapshot.elm:51 are untouched) |
| `Compiler/MonoSolver/Engine.elm` | `freshStore` 2409-2427 → `freshStore : () -> IO.State`; `resetItem` 2433-2435; `withScratchStore` 2033-2100 (2042, 2100); `liftIO` 1732-1739 (unchanged) | fresh store per call; `renew` at reset; `release` at scratch exit |
| `Compiler/MonoSolver/Translate.elm` | `retranslateWithTag` 5997-6016 (6006, 6016); `unifyStepBestEffort` 5284-5291; `classifyRef` 1945-1968 | fresh scratch + release; mark/rollback/commit |
| `Compiler/MonoSolver/Store.elm` | `unifyBestEffort` 1076-1083; `rezonkSettled` 2448-2500 (2475-2485); `qShadowCensus`/`qCensusInto` 1410-1470 | mark/rollback/commit; census sites bracketed by mark+rollback |
| `Compiler/MonoSolver/Monomorphize.elm` | initial `S` literal 3901 (`store = Engine.freshStore`) | `Engine.freshStore ()` |
| `compiler/tests/TestLogic/Monomorphize/ArrowIdentityTest.elm` | 141, 212, 222 | `Engine.freshStore ()` |
| `Compiler/Generate/MLIR/KernelAbi.elm` | `kernelInstanceSymbol` arms, before the `_ -> rootSymbol` fall-through (406) | fail-stop arms for a primitive cell type (§4.7) |
| `Compiler/GlobalOpt/CafHoist.elm` | `MonoVarKernel` arm 399-410 (`home == "Debug"` test) | `home == "Debug" || home == "CellStore"` ⇒ ineligible (defensive; pass is default-off) |
| `design_docs/invariants.csv` | new rows | HEAP_047 (off-heap mutable store rooted by scanner), KERN_00x (CellStore linearity), see §4.7 |
| **NEW** `test/eco-kernel/src/CellStore{Roundtrip,Rollback,GcSurvival,FreshHandles}Test.elm` | | native E2E pins (§6) |
| **NEW** `compiler/tests/TestLogic/CellStoreTest.elm` | | pins the API contract on the pure twin (§6) |

Call sites that do NOT change but were audited (every `.store` read, from
`grep -n "\.store\b" compiler/src/Compiler/MonoSolver/*.elm`, 55 lines, and every `Engine.liftIO (UF.…)`
site): Monomorphize 4739, 4749, 4762; LssInfer 837, 1068, 1122, 1169, 1647, 1906, 1936, 2021, 2594, 2644,
2674, 2713, 2748, 2818, 2837, 2911, 3021, 3135, 3328; Store 101, 128, 155, 162, 183, 190, 471, 699, 1068,
1141, 1247, 1251, 1292, 1385, 1452, 1466, 1685, 1867, 2037-2073, 2141, 2164, 2387, 2396, 2403, 2688, 2867,
2910, 2964, 3043, 3293; Engine 1737, 2693; Translate 3819, 3867, 4828, 5166, 5261, 5362. All are linear
(read-then-continue with the returned state) or are reads whose returned state is dropped (compression
only — §4.1 class C). The `IO`-shaped wrappers (UnionFind 51-121, IORef 59-85) stay as they are.

4. **Design**

**4.1 Where the store is non-linear — the audit.** An in-place store is sound wherever a store value is
never read after a later write to a state derived from it, EXCEPT where the code relies on the old value
being the OLD contents. Every place a `store`/`IO.State` is snapshotted, aliased, or kept beyond a linear
thread, from the grep list in §3 read in context:

| class | site | what the code relies on today | required treatment |
|---|---|---|---|
| **A rollback** | `Store.unifyBestEffort` 1076-1083 (`Err _ -> Ok ( (), s )`; doc: "restoring the pre-unify state (free via Elm's persistent arrays)") — callers LssInfer 1847, 1948, 2923 | the FAILED unify's partial merges, `Chain` links, descriptor overwrites, fresh points (`Unify.register`, Unify.elm 294) AND compression writes are all discarded | `pushMark` before, `rollback` on `Err`, `commit` on `Ok` |
| A | `Translate.unifyStepBestEffort` 5284-5291 (`Err _ -> Ok ( (), s )`) — callers Translate 178, 1255, 2195, 2206, 3812, 3895, 3913, 4819, 4890, 5335, 5775 | same | same |
| A | `Translate.classifyRef` 1945-1968: three `Err _ ->` arms fall back to `classifyAs … s0`/`s1`/`s2` — i.e. keep the store AS OF THE LAST SUCCESSFUL STEP (s1 keeps `loadType`'s mints; s2 keeps `injectArgLambdaMember`'s writes) and drop only the failed step's writes | per-step discard | one mark per fallible step: mark→`loadType`→(Err: rollback, fallback s0 / Ok: commit)→mark→inject→…→mark→zonk→… (§4.6). With spec-E in, only `UnifyMismatch` survives as recoverable and the same bracketing applies |
| **B stash/restore** | `Engine.withScratchStore` 2033-2100: `sFresh = { s0 \| store = freshStore … }` (2042) then `{ s3 \| store = s0.store … }` (2100) | the stashed item store is untouched while the scratch runs; the scratch store dies | `freshStore ()` must return a NEW store object (today `freshStore` is a CAF — a shared mutable object would alias the stash: THE trap); on exit `release` the scratch object |
| B | `Translate.retranslateWithTag` 5997-6016 (6006, 6016) | same | same |
| B | `Engine.resetItem` 2433-2435 (`store = freshStore`) | a new empty store per item; the finished item's store is dead (finishNode's `rezonkSettled`/`qShadowCensus`/`harvestSuperTable` ran before — Monomorphize 4696/4704) | `renew` (dispose old, allocate new) |
| B | initial `S` (Monomorphize 3901) | one store before the first `resetItem` | `freshStore ()` |
| **C dropped compressing reads** (benign) | `Store.rezonkSettled` 2448-2500 (`{ store = s.store … }` 2485; threaded store DROPPED, only counters cross — doc 1394-1397 says READ-ONLY, "if that ever changes … every byte-identity rail is silently invalid") | `UF.get`/`repr` inside `zonkToMonoC` path-compress; the compression is discarded | compression is observationally invisible (same roots, same weights, same descriptors) so correctness holds without work; for exactness (cell SHAPES identical under report) bracket with `pushMark`/`rollback` — report-gated, cost irrelevant |
| C | `Store.qShadowCensus`/`qCensusInto` 1410-1470 (`qAcc0 s.store` 1452, `acc.store` 1466, `UF.repr` at 1685, `a.store` 1867; result store dropped at 1466-1470) | same | same bracket |
| C | `Engine.harvestSuperTableExcept` 2659-2690 (`UF.get (Vars.Pt pointIdx) store`, result store dropped 2693) | compression discarded; runs at finishNode BEFORE `resetItem` disposes the store | nothing (spec-F makes it `peekS`) |
| C | Monomorphize `staleResidualRead`/`staleVarRead`/`varResolvedNow` 4739, 4749, 4762 (`UF.equivalent … s.store`, state dropped) | compression discarded | nothing (spec-F: `equivalentQ`/`peekS`) |
| **D escaping snapshot** | `Solve.runWithIds` 128-134: `solverState = { cells = s.ioRefsPoint }` returned out of the IO run, read later by `SolverSnapshot.resolveVariableHelp` (51) and `SolverRoots.lookupContent` (383) via `Array.get`, and kept live until Compile.elm:411-429 (`stampArrowRoots`) | the array outlives the run; nobody writes after (`unsafePerformIO` discards the state, IO.elm:61-68) | `freeze` = copy the live cells into an `Array PointCell` and dispose the store; consumers unchanged |
| **E state-dropping `Err` arms that touch no store** | Monomorphize 147-151 and 3963-3969 (`Translate.stampSelfSpine … Err _ ->` re-seeds with the pre-state) and 4278-4284 (`Ok ( stamped, _ ) -> stamped` — state dropped on SUCCESS); Monomorphize 1252 (`papMemberIdFor` Err); Store 2066 (`UF.get src` Err — unreachable, `get` never errs) | `stampSelfSpine` 4691-4705 → `stampSpineGo` 4708-4732 → `memberIdForDepth`: member-table mints only, NO store access; `papMemberIdFor`: member ids only | nothing; listed so nobody "fixes" them. If a store write is ever added under `stampSpineGo`, site 4278 (state dropped on success) becomes a class-A site |
| typechecker | `Unify.unify` 51-70 threads state through `Err` too (`UF.union v1 v2 errorDescriptor`, 68) — no rollback anywhere; `Solve.solve`/`solveGo` 187-…, `occurs` 499, `Type.toAnnotation`/`toCanTypeBatch` all thread linearly (every `IO.State ->` signature in Solve/Unify/Constrain/Typed/* is a linear `( State, a )` thread); `Compile.elm:286` (`Type.run`, no snapshot) and `:343` (`runWithIds`, class D) | linear | `unsafePerformIO` disposes the run's store at the end (§4.5); `runWithIds` freezes first (idempotent double dispose) |

Everything else threads the store linearly through `S`, `LoadCtx` (Store 58-70; seeded at 101/128 and
written back once at 155/162/183/190), `SetWriteCtx` (1153-1166; seeded by `setWriteCtx … s0.store`,
folded back by `foldSetWrites` 1224-1262) and `ZonkCtx` (2216-2237; seeded 2387/2485, written back
2396/2403). In all three the ctx's `store` is the SAME object as `s.store` for the duration; the
write-back `{ s | store = c.store }` re-installs the same handle. Nothing between seed and write-back
reads `s.store` (verified by reading each seed→write-back span: `loadType*` 205-260, `zonkToMono`
2376-2421, `foldSetWrites`, `poisonArrowSets` 2136-2141, `unifySlotWithSet` 1137-1141, LssInfer 2594/2644/
2674/2818). `Engine.scoped` 2631-2638 restores only `varEnv`. `Data.Vector`/`MVector` use `ioRefsMVector`,
untouched.

**4.2 Representation: the decision.** Three candidates were evaluated against the runtime as it is:

(i-heap) *A kernel-allocated ON-HEAP object with N boxed slots, mutated in place.* Rejected. HEAP_005
("there are no old to young pointers in the heap … so the GC does not require a write barrier") is
load-bearing: the generational GC (NurserySpace/OldGenSpace) has no remembered set, card table or write
barrier (`grep -rln "remember\|card_\|cardTable\|barrier" runtime/src/allocator` hits only the RS4GC
fold-proof slot barriers of REP_LLVM_002, nothing generational). A long-lived store object promoted to
old-gen and then written with nursery pointers would be invisible to minor GC → dangling cells. Making it
sound means adding a remembered set to the GC — a runtime change orders of magnitude riskier than this
step, and it would also break HEAP_031 (`array.set` stores only into fresh objects).

(ii) *A version-stamped chunked array in Elm that mutates only when the writer holds the latest version.*
Rejected: Elm has no mutation, so "mutate when latest" needs a kernel primitive anyway; a version stamp
needs a mutable counter (a kernel cell); and a chunked persistent array only shrinks the copied node
(32 → chunk) — it does not remove the copy, the `Array_setHelp` recursion, or the trie-node garbage that
is the actual cost. Any Elm-only variant keeps allocation-per-write and cannot reach the target.

(i) **RECOMMENDED: an OFF-HEAP cell vector in the kernel, handle-addressed, rooted by an external root
scanner, with a trail for rollback.** This is exactly the runtime's existing pattern for mutable kernel
state that holds Elm values: the list scratch stack (HEAP_040, RuntimeExports.cpp 4384-4409: a
`std::vector<uint64_t>` of boxed words registered via `RootSet::addExternalRootScanner`, evacuated in
place at minor-GC phase 1d) and the MVar store (MVar.cpp 343-365, `registerGcRootScanner`). No heap object
is mutated, so HEAP_005/HEAP_031 are untouched; roots go through `RootSet` external scanners, the blessed
container (HEAP_020, FORBID_HEAP_003). Objects referenced only from the store are kept alive and their
slots updated by `evacuate(uint64_t&)` (RootSet.hpp 92-94). The price: every minor GC scans every live
cell of every live store (O(cells) per GC — an item store is ~10^2-10^4 cells, the typechecker's per-module
store ~10^3-10^4, at most two stores live at once: item + one scratch, or item + stash), and stores must be
disposed explicitly (a tracing GC has no finalizers) — §4.5 places the disposals at exactly the points
where today the array becomes garbage.

**4.3 The `Eco.CellStore` interface — one module, two implementations.** The kernel version lives in
the `eco/kernel` package (`eco-kernel-cpp/src/Eco/CellStore.elm`, wrapping `Eco.Kernel.CellStore.*`, the
`Eco.MVar` pattern: MVar.elm 30-79); the pure twin lives in `compiler/src-xhr/Eco/CellStore.elm` and is
what stock Elm (Stage 1, elm-test-rs) compiles (the `src-xhr/Eco/MVar.elm` precedent). Same module name,
same exports, same contract; opaque `Store a`. All operations take the store LAST and every write RETURNS
the handle, so a chain of writes is a data-dependency chain (§4.8 explains why that is load-bearing).

```elm
module Eco.CellStore exposing
    ( Store, new, size, get, set, push
    , pushMark, rollback, commit
    , disposeThen, freeze, renew, release
    )

{-| A mutable, index-addressed store of boxed cells with an undo trail.

LINEARITY CONTRACT (the only rule): after `set`/`push`/`rollback`/`commit`/`renew`/`release` on a
handle, use ONLY the handle they return; a read through an older handle observes the NEW contents
(the store is in place). Never let two live handles denote the same store. `Store a` must never be
instantiated at `Int`, `Float` or `Char` (the cell crosses the kernel ABI boxed — REP_ABI_001;
KernelAbi crashes on a primitive instantiation).
-}

type Store a = Store Int            -- kernel: the handle id (never reused; a disposed id crashes on use)

new : Int -> Store a                -- capacity hint; ALWAYS call with an argument, never bind as a value
new cap = Store (Eco.Kernel.CellStore.new cap)

size : Store a -> Int
size (Store h) = Eco.Kernel.CellStore.size h

get : Int -> Store a -> a           -- crashes on an out-of-range index (today: IORef.elm:104)
get ix (Store h) = Eco.Kernel.CellStore.get ix h

set : Int -> a -> Store a -> Store a
set ix cell (Store h) = Store (Eco.Kernel.CellStore.set ix cell h)

push : a -> Store a -> Store a      -- appends at index `size st`; read the index back with `size` BEFORE, or `size st1 - 1` after
push cell (Store h) = Store (Eco.Kernel.CellStore.push cell h)

pushMark : Store a -> Store a       -- opens an undo scope (nestable)
rollback : Store a -> Store a       -- closes the innermost scope restoring every cell and the cell COUNT to the mark
commit : Store a -> Store a         -- closes the innermost scope keeping the writes

disposeThen : Store a -> b -> b     -- frees the store (idempotent), returns its second argument (data dependency)
freeze : Store a -> Array a         -- copies the live cells out, then disposes
freeze st = disposeThen st (Array.initialize (size st) (\i -> get i st))
renew : Store a -> Store a          -- disposes `st`, returns a fresh empty store (capacity = old size)
renew st = disposeThen st (new (size st))
release : Store a -> Store b -> Store b   -- disposes the first, returns the second
release dead keep = disposeThen dead keep
```

Pure twin (`compiler/src-xhr/Eco/CellStore.elm`): `type Store a = Store (Array a) (List (Array a))`;
`new _ = Store Array.empty []`; `size (Store arr _) = Array.length arr`; `get ix (Store arr _) = case
Array.get ix arr of Just c -> c; Nothing -> Utils.Crash.crash "Eco.CellStore.get: index out of range"`;
`set ix c (Store arr ms) = Store (Array.set ix c arr) ms`; `push c (Store arr ms) = Store (Array.push c
arr) ms`; `pushMark (Store arr ms) = Store arr (arr :: ms)`; `rollback (Store _ (m :: ms)) = Store m ms`
(crash on `[]`); `commit (Store arr (_ :: ms)) = Store arr ms` (crash on `[]`); `disposeThen _ x = x`;
`freeze (Store arr _) = arr`; `renew _ = new 0`; `release _ keep = keep`. Under the pure twin the
contract is trivially satisfied (values), so the unit suite cannot catch an aliasing bug — §6 puts the
native pins in `test/eco-kernel`.

**4.4 Kernel implementation sketches.**

C++ (`eco-kernel-cpp/src/eco/CellStore.cpp`, namespace `Eco::Kernel::CellStore`):

```cpp
struct Store {
    std::vector<uint64_t> cells;                       // encoded HPointer words (Export::encode)
    std::vector<std::pair<int64_t, uint64_t>> trail;   // (index, previous word) — only while marks are open
    std::vector<std::pair<size_t, size_t>> marks;      // (trail length, cell count) at each pushMark
};
static std::vector<std::unique_ptr<Store>> s_stores;  // handle = index; nullptr = disposed; ids never reused
static Store& live(int64_t h) { /* bounds + nullptr check → std::abort with "CellStore: use after dispose" */ }

int64_t newStore(int64_t cap) { auto s = std::make_unique<Store>(); s->cells.reserve(cap > 0 ? cap : 64);
                                s_stores.push_back(std::move(s)); return (int64_t)s_stores.size() - 1; }
uint64_t get(int64_t ix, int64_t h) { Store& s = live(h); /* 0 <= ix < cells.size() else abort */ return s.cells[ix]; }
int64_t  set(int64_t ix, uint64_t w, int64_t h) { Store& s = live(h); /* bounds */ 
           if (!s.marks.empty()) s.trail.emplace_back(ix, s.cells[ix]); s.cells[ix] = w; return h; }
int64_t  push(uint64_t w, int64_t h) { live(h).cells.push_back(w); return h; }
int64_t  size(int64_t h) { return (int64_t)live(h).cells.size(); }
int64_t  pushMark(int64_t h) { Store& s = live(h); s.marks.emplace_back(s.trail.size(), s.cells.size()); return h; }
int64_t  rollback(int64_t h) { Store& s = live(h); auto [tl, n] = s.marks.back(); s.marks.pop_back();
           while (s.trail.size() > tl) { auto [ix, w] = s.trail.back(); s.trail.pop_back(); if ((size_t)ix < n) s.cells[ix] = w; }
           s.cells.resize(n); if (s.marks.empty()) s.trail.clear(); return h; }
int64_t  commit(int64_t h) { Store& s = live(h); s.marks.pop_back(); if (s.marks.empty()) s.trail.clear(); return h; }
void     dispose(int64_t h) { if (0 <= h && (size_t)h < s_stores.size()) s_stores[h].reset(); }   // idempotent
void registerGcRootScanner() {
    Elm::Allocator::instance().getRootSet().addExternalRootScanner([](Elm::RootSet::EvacuateFn evacuate) {
        for (auto& sp : s_stores) { if (!sp) continue;
            for (uint64_t& w : sp->cells) if (w != 0) evacuate(w);
            for (auto& [ix, w] : sp->trail) if (w != 0) evacuate(w); } });
}
```

Exports (`CellStoreExports.cpp`, `extern "C"`, ElmDerived ABI — Int ⇒ `int64_t`, the cell ⇒ `HPtr`;
KernelAbi.elm 141-166, 182-407 root symbol, no suffix): `int64_t Eco_Kernel_CellStore_new(int64_t cap)`,
`int64_t Eco_Kernel_CellStore_size(int64_t h)`, `HPtr Eco_Kernel_CellStore_get(int64_t ix, int64_t h)`,
`int64_t Eco_Kernel_CellStore_set(int64_t ix, HPtr cell, int64_t h)`, `int64_t Eco_Kernel_CellStore_push(HPtr
cell, int64_t h)`, `int64_t Eco_Kernel_CellStore_pushMark(int64_t h)`, `…_rollback`, `…_commit`, `HPtr
Eco_Kernel_CellStore_disposeThen(int64_t h, HPtr x)` (disposes, returns `x` unchanged), and `void
Eco_Kernel_CellStore_register_gc_roots()`. The cell word is stored and returned VERBATIM (`HPtr::toBits`/
`fromBits`, no `resolve()` — the step-14 `hpointerToPtr` cost never arises here). None of these allocate on
the Elm heap, so no `StackRootGuard` is needed and no GC can run inside them (HEAP_011); `push` may grow
the C++ vector (C++ heap, gc-leaf-compatible like `cppAlloc = True` rows). Register the scanner from
`Eco_Kernel_register_all_gc_roots` (RuntimeExports.cpp 46-51) — that hook is already called once per Elm
thread by all four launch paths (ecoc.cpp 350, EcoRunner.cpp 235, eco_entry.cpp 107, eco_embed).

JS (`eco-kernel-cpp/src/Eco/Kernel/CellStore.js`, the MVar.js shape — plain `var _CellStore_x = F2(…)`
functions, no scheduler): `_CellStore_stores = []`; `_CellStore_new = function(cap){ var h =
_CellStore_stores.length; _CellStore_stores.push({cells: [], trail: [], marks: []}); return h; }`;
`get`/`set`/`push`/`size`/`pushMark`/`rollback`/`commit`/`disposeThen` mirror the C++ one-for-one (a
disposed handle is `null`; use → `throw new Error('CellStore: use after dispose')`). The JS store needs
no root handling. This file is exercised by every JS bootstrap stage after Stage 1 (eco-boot.js compiles
the compiler: compiler/CMakeLists.txt 290-300), i.e. by `cmake --build build --target full`.

**4.5 `IO.State`, `IORef`, `UnionFind`, and the lifecycle sites.**

```elm
-- System/TypeCheck/IO.elm
import Eco.CellStore as CellStore
type alias State =
    { ioRefsPoint : CellStore.Store PointCell        -- was Array PointCell
    , ioRefsMVector : Array (Array (Maybe (List Variable)))
    , names : NameState
    , nodeIds : NodeIdState
    }
freshState : () -> State                              -- NEW; NEVER a zero-arg definition (would be a CAF sharing one store)
freshState () = { ioRefsPoint = CellStore.new 256, ioRefsMVector = Array.empty, names = emptyNameState, nodeIds = emptyNodeIds }
unsafePerformIO : IO a -> a
unsafePerformIO ioA =
    case ioA (freshState ()) of
        ( s1, a ) -> CellStore.disposeThen s1.ioRefsPoint a   -- one store per typecheck run; idempotent after `freeze`

-- Data/IORef.elm (doc 8-19 rewritten to say "handle into a CellStore")
readPointCellS s ref = CellStore.get ref s.ioRefsPoint                       -- was Array.get + crash
writePointCellS ref cell s = { s | ioRefsPoint = CellStore.set ref cell s.ioRefsPoint }
newPointCellS weight desc s =
    let st = s.ioRefsPoint in
    ( CellStore.size st, { s | ioRefsPoint = CellStore.push (Vars.Root weight desc) st } )
    -- `size` is evaluated when the tuple is built, `push` too; both are arguments of the same
    -- constructor so Elm's strict left-to-right evaluation of the tuple literal runs `size` FIRST.
    -- Do NOT let-bind them separately (§4.8).
```

`UnionFind.elm` needs no code change (it only calls the three IORef primitives); its header (6-22) gets the
linearity contract and the "compression is unobservable" note. `Compiler/Type/Solve.elm:132`:
`solverState = { cells = CellStore.freeze s.ioRefsPoint }`. `Engine.freshStore` (2409-2427) becomes
`freshStore : () -> IO.State` with `ioRefsPoint = CellStore.new 256` (keep the engine-local `names`/`nodeIds`
literals as they are — the comment at 2405-2407 says why it is not `IO.freshState`); its five callers pass
`()`. `resetItem` 2435: `store = CellStore … renew`: write `{ s | store = renewStore s.store, … }` where
`renewStore st = { st | ioRefsPoint = CellStore.renew st.ioRefsPoint }` (an `IO.State` copy — 5 words —
per item, 43K items: nothing). Scratch scopes: `withScratchStore` 2042 `store = freshStore ()`; 2100
`store = releaseScratch s3.store s0.store` with `releaseScratch dead keep = { keep | ioRefsPoint =
CellStore.release dead.ioRefsPoint keep.ioRefsPoint }`; identically `retranslateWithTag` 6006/6016. On the
`Err e` exits (2045, 6011) the scratch store is not released — that path ends the build (spec-E turns it
into a crash), so the leak is one store; note it in the comment, do not add a release there.

**4.6 The rollback sites.** Current `Result` shape (spec-E not in):

```elm
-- Store.elm 1076-1083
unifyBestEffort v1 v2 s =
    case unifyStep v1 v2 (markStore s) of
        Ok ( _, s1 ) -> Ok ( (), commitStore s1 )
        Err _ -> Ok ( (), rollbackStore s )          -- `s`'s handle IS the live store; rollback restores it
-- Engine.elm, next to liftIO: three S-level helpers (each one IO.State copy + one kernel call)
markStore s = { s | store = ioMark s.store }      -- ioMark st = { st | ioRefsPoint = CellStore.pushMark st.ioRefsPoint }
commitStore s = { s | store = ioCommit s.store }
rollbackStore s = { s | store = ioRollback s.store }
```
`Translate.unifyStepBestEffort` 5284-5291: the same three lines. With spec-E in (its §4 "unifyBestEffortS"
sketch `if ok then s1 else s`): `let ( ok, s1 ) = Store.unifyStep v1 v2 (Engine.markStore s) in if ok then
Engine.commitStore s1 else Engine.rollbackStore s1` — note `rollbackStore s1`, not `s`: the handle is the
same object and s1 carries the other fields the successful part of the step may have changed (member ids,
stats) exactly as today's `Err _ -> Ok ( (), s )`… CHECK: today's arm returns `s`, i.e. it also discards
non-store fields written before the mismatch. `unifyStep` (1034-1068) writes nothing but the store on its
way to `UnifyMismatch` (it is `liftIO (Unify.unify …)` then a diagnostic), so `s` and `s1` differ only in
the store, and `rollbackStore s` ≡ `rollbackStore s1`. Keep `rollbackStore s` in the `Result` shape (mirrors
the old text) and `rollbackStore s1` in spec-E's shape (the Bool form has no `s`-only path). Byte-identical
either way.

`classifyRef` 1945-1968 — bracket each fallible step so each `Err` arm's state matches today's:

```elm
classifyRef refExpr canType s0 =
    if not (…) then classifyAs Mono.tkClassMisc canType s0 else
    case Store.loadType canType (Engine.markStore s0) of
        Err _ -> classifyAs Mono.tkClassMisc canType (Engine.rollbackStore s0)
        Ok ( canVar, s1a ) ->
            let s1 = Engine.commitStore s1a in
            case injectArgLambdaMember refExpr canVar (Engine.markStore s1) of
                Err _ -> classifyAs Mono.tkClassMisc canType (Engine.rollbackStore s1)
                Ok ( _, s2a ) ->
                    let s2 = Engine.commitStore s2a in
                    case Store.zonkToMono canVar (Engine.markStore s2) of
                        Err _ -> classifyAs Mono.tkClassMisc canType (Engine.rollbackStore s2)
                        Ok ( monoType, s3 ) -> Ok ( monoType, Engine.commitStore s3 )
```
(The three brackets are what makes the fallback states equal today's `s0`/`s1`/`s2` stores. `zonkToMono`
only compresses, so its bracket may be dropped once spec-F is in; keep it until then.)

Census sites (class C, exactness under `lss.report`): `rezonkSettled` 2448-2500 — seed the ctx from
`ioMark s.store` (2485) and return `s` unchanged as today (the dropped ctx store is the same object; the
mark is popped by a `rollback` on the returned `s.store`): concretely `let stM = ioMark s.store in … ctxN =
List.foldl … { store = stM, … } log in … { s | store = ioRollback stM, lssStats = … }` — the function's
result must carry the rolled-back handle (2496-2500 today rebuilds `s` with new stats; add `store =
ioRollback stM` to that record update). Same in `qCensusInto` 1440-1470 (`qAcc0 (ioMark s.store)` at 1452
and `store = ioRollback …` in the result). Both are behind `s.env.lss.report`/`qCensus` (N5 in
findings-C) — zero cost at defaults.

**4.7 Invariants touched and to add.**
- HEAP_005, HEAP_031: untouched — no heap object is mutated (the decisive reason for off-heap).
- HEAP_020 / FORBID_HEAP_003 / HEAP_040: roots via `RootSet::addExternalRootScanner`, evacuated in place
  at phase 1d and marked at major GC — the sanctioned path; cite HEAP_040 as the precedent.
- HEAP_011: the exports never allocate on the Elm heap, so no GC can occur inside them and no
  StackRootGuard is needed; `disposeThen` returns its argument word untouched.
- REP_ABI_001 / KERN_006 / CGEN_038: Int parameters are `i64`, the cell is `!eco.value`; the declared
  `func.func … is_kernel=true` types are derived by `monoTypeToAbi` from the wrapper's monomorphized type.
  A `Store Int` (or Float/Char) instantiation would derive an `i64` cell against the `HPtr` C signature —
  add fail-stop arms in `kernelInstanceSymbol` right before `_ -> rootSymbol` (KernelAbi.elm:406):
  `( "CellStore", "get", [ _, _ ] )`-style arms cannot see the RESULT type, so match on
  `( "CellStore", "set", [ Mono.MInt, Mono.MInt, _ ] ) -> crash "…"` / `[ _, Mono.MFloat, _ ]` /
  `[ _, Mono.MChar, _ ]` and `( "CellStore", "push", [ Mono.MInt, _ ] )` etc.; `get`'s result is checked by
  `ensurePrimitiveAbi` only against the declaration — a lone primitive instantiation would be SILENT, hence
  the `set`/`push` arms (every store that is read is also written).
- LSS_004 (unlicensed kernel ⇒ full treatment): the kernel's Elm types contain no arrow at any position
  (`Int`, `Store a`, `PointCell`), so the license question is vacuous; do NOT add `KernelSetFacts` rows.
- KernelFacts whitelist (§6.F, KernelFacts.elm 21-24): do NOT add rows — unlisted ⇒ `CsePurity.kernelCseSafe`
  = False (CsePurity.elm 92-93), not droppable, not hoistable, and at MLIR an un-stamped kernel call reports
  Read+Write effects (EcoOps.cpp 970-988) so LLVM never reorders or merges two calls. `CafHoist` is
  default-off and "unlisted-tolerant" (399-410): add `|| home == "CellStore"` to its Debug test so turning
  the pass on can never hoist a `new`.
- MONO_029 / LSS_006 / LSS_010: untouched (no representation of types or sets changes; Point indices are
  identical).
- New rows to add to `design_docs/invariants.csv`: **HEAP_047** "Eco.CellStore is an OFF-HEAP mutable
  cell vector (eco-kernel-cpp/src/eco/CellStore.cpp) whose boxed words and trail are GC roots via an
  external root scanner (HEAP_040 pattern); it is never a heap object (HEAP_005 has no write barrier);
  stores are disposed explicitly (idempotent) and a disposed handle aborts on use"; **KERN_007** "CellStore
  handles are LINEAR: every writer returns the handle and readers must use the newest handle; the kernel is
  unlisted in KernelFacts on purpose (no CSE/hoist/drop); `new` must never be bound as a zero-argument
  value (CAF)"; and a TYPE_002 amendment: "the solver store is a CellStore; `Solve.runWithIds` freezes it
  into `Array PointCell` for `SolverSnapshot`/`SolverRoots`".

**4.8 Order-of-evaluation constraints (the rules an engineer must not break).**
- *Mint order is unchanged*: `push` appends at `size` exactly where `Array.push`/`Array.length` did
  (IORef 114-115), so every Point index, every `revMemo` slot, every `pointKey`-keyed census map is the
  same. No member id, intern order or emission changes.
- *Let-binding reordering*: the canonicalizer sorts a `let`'s bindings into SCC order
  (`Graph.stronglyConnComp`, Canonicalize/Expression.elm 822, 1205-1244); independent bindings are NOT
  guaranteed to keep source order. Today that is harmless (persistent values); with an in-place store a
  read bound next to an independent write is a RACE. Rule: a read and a write of the same store in one
  `let` must be linked by the handle (`let s1 = write … s; x = read … s1.store`), or sequenced with nested
  `let`/`case`. The existing code already threads through the newest handle everywhere (it had to, to see
  its own writes); the one new place is `newPointCellS` (§4.5: tuple literal, not two bindings).
- *Kernel purity*: the Elm-level inliner LET-BINDS arguments rather than substituting them
  (InlineSimplify.elm:37 "Why arguments are LET-BOUND rather than substituted"), so a kernel write passed
  as an argument is evaluated once; unlisted kernels are never CSE'd, hoisted or dropped (§4.7).
- *No zero-arg kernel values*: `CellStore.new` and `IO.freshState`/`Engine.freshStore` are functions of
  `()`/`Int`; a zero-arg definition is a memoized CAF (HEAP_035, plans/task-purity-and-caf-guard-removal.md
  F1 is the MVar precedent) and would make every "fresh" store the same object — the stash in
  `withScratchStore` would alias the scratch.
- *Dispose discipline*: a store is disposed at exactly the points where the old array became garbage
  (§4.5). Adding a new scratch scope means adding a `release`; forgetting one is a leak, not a crash;
  disposing twice is a no-op; using after dispose aborts with a message (the C++ `live()` check, the JS
  `null` check) — that turns any missed alias into a loud failure instead of a silent miscompile.

5. **Edit sequence** (each edit leaves `elm make` of `compiler/src/Terminal/Main.elm` green under BOTH
roots — `build/compiler/build-xhr` (stock Elm, pure twin) and `build/compiler/build-kernel` (eco, kernel);
the loop's Phase 1 step 2 type-check is the build-kernel one)

1. **3a-1 kernel package.** Add `eco-kernel-cpp/src/Eco/CellStore.elm` (§4.3), `src/Eco/Kernel/CellStore.js`
   (§4.4), `src/eco/CellStore.{hpp,cpp}` + `CellStoreExports.cpp` (§4.4), the declarations in
   `src/eco/KernelExports.h`, the registration call in `src/eco/RuntimeExports.cpp:46-51`, the CMake
   library + INTERFACE + asserts entries (eco-kernel-cpp/CMakeLists.txt 158-167 / 250-260 / 264-268),
   `"Eco.CellStore"` in `eco-kernel-cpp/elm.json` exposed-modules, the link-list entries in
   `compiler/CMakeLists.txt` 752-754 / 812-814 / 847-849 and `test/CMakeLists.txt` 153-157 / 168 / 174-182 /
   209-219. Then `cmake --build build --target clean` (the package's `artifacts.dat`/`typed-artifacts.dat`
   cache masks new kernel files — compiler/CMakeLists.txt 262-271) and `cmake --preset build` (new source
   files; CMake globs at configure time). Nothing in the compiler uses it yet; native + JS build green.
2. **3a-2 pure twin + pins.** Add `compiler/src-xhr/Eco/CellStore.elm` (§4.3 pure), the unit pin
   `compiler/tests/TestLogic/CellStoreTest.elm` (API contract on the twin), and the four native E2E programs
   in `test/eco-kernel/src/` (§6). Run `cmake --build build --target elm-tests` and the eco-kernel suite
   (`build/test/test --gtest_filter='EcoKernel*'` — see test/eco-kernel/EcoKernelTest.hpp for the CHECK-line
   runner). Both green. **Snapshot `try-3a` here**; 3a is unmeasured (no compiler change).
3. **3b-1 the state.** `System/TypeCheck/IO.elm`: field type, `freshState`, `unsafePerformIO`;
   `Data/IORef.elm`: the three primitives + doc; `Compiler/Type/Solve.elm:132`: `freeze`;
   `Compiler/MonoSolver/Engine.elm`: `freshStore : () -> IO.State` (2409-2427), `renewStore`/`ioMark`/
   `ioCommit`/`ioRollback`/`markStore`/`commitStore`/`rollbackStore`/`releaseScratch` helpers next to
   `liftIO` (1732); callers 2042 (+ 2100 `releaseScratch`), 2435 (`renewStore`); `Translate.elm` 6006/6016;
   `Monomorphize.elm:3901`; `ArrowIdentityTest.elm` 141/212/222 (`Engine.freshStore ()`) — **same edit**
   (the test file names the CAF). `UnionFind.elm` header text. Green under both roots; `elm-tests` green
   (the twin). At this point the native compiler is CORRECT only where use is linear — the rollback sites
   still silently keep failed merges — so do not measure yet.
4. **3b-2 rollback sites.** `Store.unifyBestEffort` 1076-1083, `Translate.unifyStepBestEffort` 5284-5291,
   `Translate.classifyRef` 1945-1968 (§4.6). Green.
5. **3b-3 census brackets.** `Store.rezonkSettled` 2475-2500, `Store.qCensusInto` 1440-1470 (§4.6). Green.
6. **3b-4 guards + docs.** `KernelAbi.kernelInstanceSymbol` fail-stop arms (§4.7), `CafHoist.elm:399`
   ineligibility, `design_docs/invariants.csv` rows HEAP_047 / KERN_007 / TYPE_002 amendment, `IORef.elm`
   and `UnionFind.elm` module docs. Green. **Snapshot `try-3` (= 3b)**; this is the measured entry.

6. **Verification**

- Unit: `cmake --build build --target elm-tests` — all of it (the twin); specifically
  `TestLogic/CellStoreTest.elm` (new: push/size/get/set, nested pushMark/rollback restores cells AND count,
  commit keeps, rollback after commit of an inner scope undoes the inner writes, `freeze` contents),
  `Monomorphize/ArrowIdentityTest`, `LssDirectedFlowTest`, `LssHonestSourcesTest`, `Type/*` (they drive
  `IO.unsafePerformIO` / `UF.*` directly — unchanged behaviour expected).
- Native pins (`test/eco-kernel/src/`, CHECK-line programs run by the `test` binary's EcoKernel suite,
  the MVar tests are the template):
  `CellStoreRoundtripTest` — new/push 1000 boxed records/get back/set/get, expected values printed;
  `CellStoreRollbackTest` — mark, set + push 50, rollback ⇒ `size` back and old cells back; nested
  mark/commit/rollback; `CellStoreGcSurvivalTest` — push 100 000 freshly allocated records (each a distinct
  nursery object), then allocate ~64 MB of garbage in a loop (forces several minor GCs and a promotion),
  then verify every cell's payload — this is the root-scanner + evacuation pin, and it must also be run
  under `dev` (asserts on) once; `CellStoreFreshHandlesTest` — `new 8` twice in one function gives
  handles whose writes do not alias (pin against a future CAF/CSE regression), and `disposeThen` twice is a
  no-op while `get` after dispose aborts (expected-crash form, if the harness has one; else print-and-skip).
- E2E: `cmake --build build --target full` (exercises the JS kernel through the eco-boot stages and the
  native compiler through the AOT E2E). Expected 887/889-class result as before.
- Byte identity (substrate step): the loop triple with `cmp` of the three `-out.mlir` and the fixed-point
  `cmp` against `ecoN.mlir` (benchmarks/lss-compile-opt-loop.md §2). Additionally ONE untimed report-on
  run (`ECO_MONO_LSS_REPORT=1`) with `eco-opt-prev` and `eco-opt3`, `cmp` the two `-out.mlir` AND `diff` the
  two reports (stderr) — this checks the census brackets (§4.6 class C) reproduce the same counters.
- The 633-workload rail (`benchmarks/mlir-workload-rail.sh`) — mandatory here because the typechecker
  (front end) moved too.
- Attribution leg (if the wall delta needs explaining): `perf record` the mono window and confirm
  `Array_setHelp`, `eco_clone_array`, `Array_unsafeReplaceTail`, `elm_array_push_box` have left the
  `UnionFind`/`IORef` call chains; `ECO_INLINE_ALLOC=0` lowering + the object census: size-32 Array nodes
  should fall by ~(writes + pushes); `Eco_Kernel_CellStore_*` self time should be ≤ 2 % of the window.
  GC stats: minor-GC time and survivor bytes both down; if minor-GC time is UP, the root scanner is
  scanning stores that should have been disposed — count live stores at GC (a debug counter in the
  scanner) — expected ≤ 2.

7. **Risks, gotchas, and what NOT to do**

- **The CAF trap** (§4.8): `Engine.freshStore` is a zero-arg definition today (2409-2427) and so is any
  `store = Array.empty` literal; after this step every "fresh store" must be a CALL. Grep for
  `CellStore.new` and `freshStore`/`freshState` uses at top level before every build.
- **Let reordering** (§4.8): never bind an old-handle read next to an independent write.
- **Two builds, two implementations**: the elm-test-rs suite and Stage 1 compile the PURE twin
  (`src-xhr`), so a passing unit suite proves nothing about aliasing; the native pins in `test/eco-kernel`
  and the loop's fixed-point `cmp` are the real gates. Keep the two `Eco/CellStore.elm` modules' exports
  identical or the build-xhr root stops compiling.
- **Stale package cache** (compiler/CMakeLists.txt 262-271): after touching `eco-kernel-cpp/src/**`, run
  `cmake --build build --target clean` or the JS stages silently use the old kernel; and
  `build-kernel/src` is a SYMLINK to `compiler/src` (CMakeLists.txt 200) — the path argument to `make` does
  not pick the tree.
- **Dispose discipline**: `withScratchStore` nests re-entrantly today (plan §3, D9) — fine, each level
  allocates and releases its own object; but a new stash/restore site written without `release` leaks one
  store per call, and a leaked store keeps its cells' objects alive forever AND is scanned at every GC.
  Watch minor-GC time in the loop stats.
- **`freeze` cost**: one `Array.initialize` of `size` kernel reads per typechecked module (typed path
  only). Thousands of cells per module — negligible next to the solve, but do not move it into a hot path.
- **Err-path leaks** (§4.5) are deliberate; do not "fix" them with unit-returning dispose calls — a
  `let _ = dispose st` is a dead binding the optimizer may drop; every disposal must be data-dependent
  (`disposeThen`/`renew`/`release`).
- **Do not** put the store ON the heap (HEAP_005), do not touch `Descriptor` (`rank`/`mark`/`copy` are
  dead on the mono path but the type is the typechecker's — plan §4 N17), do not fork `IO.State` for the
  mono engine (Engine.elm 2405-2407 "touches zero lines of the type checker" is a preference, not a
  boundary; a fork would duplicate `UnionFind`), do not add `KernelFacts`/`KernelSetFacts`/
  `KernelIntrinsics` rows (whitelist-conservative is what we want; an annotation row is fail-stop for
  package code and buys nothing since the wrapper functions are annotated).
- **32-slot cap**: `S` stays at 31 fields (no new field — marks live inside the store), `IO.State` at 4,
  `LssStats` at 32 — untouched.
- **Plan §4 items not to re-open**: N17 (Descriptor fork), N22 (GC tuning) — this step is the "reduce live
  churn" lever §3 asks for, nothing else.
- **A subtle one for spec-E**: after spec-E the `Result` is gone and `classifyRef`'s three arms recover
  only `UnifyMismatch`; the brackets in §4.6 stay exactly as written (mark per fallible step).

8. **Effort**

**L** — a new kernel module in three languages (C++/JS/pure Elm) with GC rooting, wired through four CMake
files and two package manifests, plus 22 compiler sites and four native pins; the compiler-side edits
themselves are small. Split into loop entries: **3a** (edits 1-2: package + twin + pins; no compiler change,
not measured, gated by the eco-kernel suite and `elm-tests`) and **3b** (edits 3-6: the measured entry,
BI, gated by the loop triple + `full` + the rail). Do not split 3b further — 3b-1 alone is not correct on
the rollback sites.

---

<details><summary>Conventions used in this spec (from spec-B)</summary>

Written 2026-09-19 from full reads of `Compiler/Type/UnionFind.elm` (299 ln), `Data/IORef.elm` (151 ln),
`System/TypeCheck/IO.elm` 55-110, `Compiler/Type/Vars.elm` 38-105, `Compiler/Type/Solve.elm` 60-185,
`Compiler/Type/Unify.elm` 25-180 and 285-330, `Compiler/MonoSolver/Engine.elm` 1296-1350, 1725-1760,
2025-2100, 2405-2436, 2631-2690, `Compiler/MonoSolver/Store.elm` 40-200, 465-560, 1036-1100, 1135-1262,
1385-1470, 1678-1692, 1860-1872, 2030-2080, 2136-2170, 2200-2240, 2375-2500, 2682-2692, 2860-2872,
3038-3048, 3288-3298, `Compiler/MonoSolver/Translate.elm` 1940-1972, 3815-3824, 3864-3871, 4330-4360,
4691-4732, 4826-4832, 5164-5170, 5259-5295, 5360-5366, 5960-6016, `Compiler/MonoSolver/LssInfer.elm`
828-845, 1060-1075, 1114-1130, 1162-1176, 1645-1652, 1840-1856, 1898-1915, 1930-1958, 2015-2030,
2586-2600, 2905-2932, 3015-3030, 3128-3142, 3322-3336, `Compiler/MonoSolver/Monomorphize.elm` 140-156,
1238-1258, 3893-3908, 3952-3972, 4268-4290, 4685-4712, 4728-4770, plus every `grep` cited inline.
Kernel side: `eco-kernel-cpp/src/Eco/MVar.elm`, `src/Eco/Kernel/MVar.js`, `src/eco/MVar.{hpp,cpp}`,
`src/eco/MVarExports.cpp`, `src/eco/RuntimeExports.cpp` 20-55, `src/eco/KernelExports.h` 200-250,
`eco-kernel-cpp/CMakeLists.txt` 158-270, `compiler/src-xhr/Eco/MVar.elm`, `compiler/CMakeLists.txt`
100-130, 195-215, 240-300, 748-850, 1040-1060, `runtime/src/allocator/RootSet.hpp` 80-110,
`runtime/src/allocator/RuntimeExports.cpp` 4380-4415 (the HEAP_040 scratch-stack scanner),
`runtime/src/codegen/ecoc.cpp` 340-356, `runtime/src/codegen/EcoOps.cpp` 970-990,
`Compiler/Generate/MLIR/KernelAbi.elm` 1-420, `Compiler/GlobalOpt/KernelFacts.elm` 1-215,
`Compiler/GlobalOpt/CsePurity.elm` 88-96 and 276-284, `Compiler/GlobalOpt/CafHoist.elm` 395-410,
`Compiler/GlobalOpt/InlineSimplify.elm` 37, `Compiler/Type/KernelIntrinsics.elm` 1-140,
`test/eco-kernel/*`, `test/CMakeLists.txt` 130-225, `design_docs/invariants.csv` (HEAP_*, REP_*,
FORBID_*, KERN_006, LSS_004 rows).

Composition with the sibling specs (read): spec-F (step 8) adds `UF.peekS`/`rootQ`/`equivalentQ` and drops
`store` from `ZonkCtx` — every one of its sites is a READ and is unaffected by this step (a pure read on an
in-place store is the same call with no copy). spec-I (step 20) compares `Pt` indices — unaffected. spec-E
(step 10) makes every Step `S -> ( a, S )` and names exactly three `UnifyMismatch` recovery sites
(`unifyBestEffort`, `unifyStepBestEffort`, `classifyRef`) — those are precisely this step's rollback sites,
and the API below (`pushMark`/`rollback`/`commit`, handle-threaded) is what spec-E's `unifyBestEffortS`
must call (§4.6 gives the body in both the current `Result` shape and spec-E's shape).

---

</details>

### Step 4 (was 7). Memoise ground, arrow-free alias-typed subtrees per item (load) and per run (classify)

#### 1. Goal and expected effect

Today an alias-typed occurrence such as `s : S` (the compiler's own 31-field state record) is
re-loaded into the item store node by node on EVERY `Store.loadType` (Store 262-463: `loadTypeC`
memoises only `TVar` Points via `memo` and arrow SET SLOTS via `arrowMemo`; every `TType`/`TRecord`/
`TTuple`/`TUnit` node mints a fresh Point through `structC` 476-481) and re-classified node by node
on every `classify` (`classifyGo` 3527-3634 re-`consS`es every composite of the same structure at
every occurrence — a `HashMap` probe with a structural `==` confirm per node, Intern.elm 194-201/234).

The plan's §1 attributes to this exact population: `loadRecordFieldsC` 11.6 %, `zonkRecordFieldsC`
9.8 %, `classifyRecordFields` 10.3 %, `classifyGo` 12.2 % inclusive, `Unify.unifyRecord` 3.9 %, plus
the bulk of `Intern.probe`'s 19.6 % (every re-classify probes every node) and a large share of the
union-find store cluster (~12 %: `freshS` 4.1 %, `newPointCellS` 3.9 %, `Array` path copies). The
uprobe count leg of the Sep-18 profile (`scratchpad/uprobe/counts.txt`) measured **5,739,553
`UnionFind.freshS` calls** and 918,925 `unionS` per self-compile — the load side is where most of
those mints come from.

Two memos, both keyed by the alias INSTANTIATION `(home, name, ground args)`:

- **4a (per item, load side)** — `ItemAux.groundLoads : HashMap AliasKey Vars.FlatType`: after the
  first load of an eligible alias occurrence in an item, every later load of the same instantiation
  mints ONE root Point (`structC flat`) whose children are the first load's Points. For `S` that is
  1 mint instead of ~150-300 (31 fields, each a `Dict`/`Array`/`Maybe`/alias subtree).
- **4b (per run, classify side)** — `MonoMemo.aliasMemo : HashMap AliasKey AliasVerdict`: after the
  first `classifyGo` of an eligible instantiation, every later classify returns the canonical
  interned `MonoType` with ZERO probes and no `S` change; the same map also caches the "this alias
  body carries an arrow" verdict so ineligible aliases cost one probe per occurrence, never a walk.

Loop stats expected to move: **minor GC count down** (the mints and their persistent-`Array` path
copies are nursery allocation: ~5.7 M `freshS` × (cell + descriptor + `Array.push` tail copy) and
~10^7 `consS` probes with their bucket scans), **wall down** (plan estimate 5-8 % of the mono window
≈ 2.5-4 % of the run), promoted MiB / major GC flat-to-down (smaller live per-item stores).
Emission **must stay byte-identical** (substrate step): the memos change WHICH Points are minted and
which probes run, never any `MonoType`, member id, spec key or intern insertion order — §4.3 and
§4.10 carry the argument; Phase 2's `cmp` is the gate.

#### 2. Preconditions

No plan step is required first. Steps 2 (hash-cons equality) and 3 (transient store) are
independent; this step reduces the probe/mint COUNT they make cheaper. Verify before starting:

```bash
# (a) the tree is the reference snapshot
benchmarks/lss-loop-snap.sh verify <ref>
# (b) S.intern is seeded empty and only ever grows — the classify memo's exactness rests on it
grep -n "Intern.empty\|Intern.readOnly\|Intern.disabled\|intern = " compiler/src/Compiler/MonoSolver/*.elm
#   expected: Monomorphize.elm:3870 `intern = Intern.empty` (initState); Engine.elm:2785 (withIntern);
#   Store.elm:2259/2396/2403 (ZonkCtx write-back); Translate.elm:3185/8136 (canTypeToMonoI write-back).
#   NO readOnly/disabled inside S.
# (c) the alias arms and helpers are where this spec says
grep -n "Can.TAlias" compiler/src/Compiler/MonoSolver/Store.elm            # 429 432 3621 3624
grep -n "^type alias LoadCtx\|^testLoadCtx\|^writeBackShared\|^writeBackIsolated\|^structC\|^classifyGo" compiler/src/Compiler/MonoSolver/Store.elm
grep -n "^type alias MonoMemo\|^emptyMonoMemo\|^type alias ItemAux\|^emptyItemAux\|^clearedAux\|^restoredAux" compiler/src/Compiler/MonoSolver/Engine.elm
grep -rn "testLoadCtx\|loadTypeC" compiler/tests/TestLogic | grep -v "^.*://"   # ONE test: ArrowIdentityTest.elm:124
# (d) baseline mint count for the census leg (§6): scratchpad/uprobe/counts.txt already holds
#     freshS=5,739,553 / unionS=918,925 for bin/eco-lss-post (== bin/eco-opt-prev on 2026-09-19).
```

#### 3. Inventory of touched code

| file | function (lines now) | what changes |
|---|---|---|
| Engine.elm | `type alias MonoMemo` 483-486, `emptyMonoMemo` 489-491 | add `aliasMemo : HashMap AliasKey AliasVerdict` (+ empty) |
| Engine.elm | new, next to `MonoMemo` | `type alias AliasKey`, `aliasKeyHash`, `aliasKeyEq`, `type AliasVerdict`, `putAliasVerdict : AliasKey -> AliasVerdict -> S -> S`; add them to the module's export list (line 8) |
| Engine.elm | `type alias ItemAux` 1414-1513, `emptyItemAux` 1516-1518, `clearedAux` 1529-1531, `restoredAux` 1537-1539 | add `groundLoads : HashMap AliasKey Vars.FlatType` (store-scoped: cleared on entry, restored from `outer` on exit, exactly like `arrowMemo`); `clearResidualReads` 1545-1551 must NOT clear it (same rule as `arrowMemo`, comment at 1455-1458) |
| Store.elm | imports 27-41 | `import Data.HashMap as HashMap` |
| Store.elm | `type alias LoadCtx` 58-70 | add `groundLoads : HashMap AliasKey Vars.FlatType` |
| Store.elm | `testLoadCtx` 80-92 | seed `groundLoads = HashMap.empty` |
| Store.elm | `sharedLoadCtx` 99-110, `isolatedLoadCtx` 126-142 | seed `groundLoads = s.itemAux.groundLoads` in BOTH (§4.3: ground structure carries no slot, so H1 does not apply) |
| Store.elm | `writeBackShared` 150-176 | add `groundLoads = c.groundLoads` to the `itemAux` update at 166-173 |
| Store.elm | `writeBackIsolated` 178-203 | write `groundLoads` back when it grew (`HashMap.size` compare — O(1)); keep NEITHER memo rule for `memo`/`arrowMemo` |
| Store.elm | `loadType` 205-212, `loadTypeWithArrows` 221-228, `loadTypeIsolatedWithArrows` 235-242, `loadTypeIsolated` 252-259 | pass `s.monoMemo.aliasMemo` as the new second argument of `loadTypeC` |
| Store.elm | `loadTypeC` 262-463 (signature 262) and its recursive callers `loadListC` 542-556, `loadRecordExtC` 559-566, `loadRecordFieldsC` 569-581 | new read-only parameter `aliasMemo`; the `TAlias` arms 429-463 become the memo arm of §4.7 (today's bodies move to `loadAliasPlainC`) |
| Store.elm | new helpers after `normalizePrimHome` 590-622 | `mix`, `groundHash`, `groundHashList`, `noArrowBody`, `aliasKeyOf`, `aliasBodyEligible`, `groundNoArrow`, `groundNoArrowWith`, `loadAliasPlainC`, `classifyAliasPlain` |
| Store.elm | `classifyGo` 3527-3634, `TAlias` arms 3621-3634 | become the memo arm of §4.8 (today's bodies move to `classifyAliasPlain`) |
| Store.elm | export list 1-5 | add `groundNoArrow`, `groundNoArrowWith`, `aliasKeyOf` (Step 9 and tests) |
| compiler/tests/TestLogic/Monomorphize/ArrowIdentityTest.elm | `loadInto` 120-133, call at 124 | `Store.loadTypeC Dict.empty HashMap.empty canType (...)` (+ `import Data.HashMap as HashMap`) |
| compiler/tests/TestLogic/Monomorphize/GroundAliasMemoTest.elm | NEW | the pins of §6 |

Call sites of the changed signature `loadTypeC` (from `grep -n "loadTypeC" Store.elm` + tests):
Store 208, 224, 238, 255 (the four entry points), 270, 273 (TLambda arm), 400 (TType via
`loadListC`), 409/412 (TRecord), 421-427 (TTuple), 430 (Filled), 435/447 (Holey), 549 (`loadListC`),
563 (`loadRecordExtC` → `loadVarC`, untouched), 574 (`loadRecordFieldsC`), ArrowIdentityTest 124.
NOTHING in Translate/LssInfer calls `loadTypeC` directly (they use the four `Step` entry points,
24 + 18 sites listed in the grep of §3 of Step 9 — unchanged).

`classifyGo`'s signature does NOT change (it already threads `S`, which carries `monoMemo`).

#### 4. Design

##### 4.1 What a `Can.Type MVarId` occurrence IS (answers the object-identity question)

`AssignMVarIds.rewriteCanType` (1239-1350) REBUILDS every node of every type per occurrence — the
`TAlias` arm (1328-1350) rebuilds the args with `ensureBinder` for each param name and
`rewriteAliasType` (1382-1397) rebuilds the `Holey`/`Filled` body. Its input, `Can.Type Name`, is
itself decoded per module from artifact bytes (`Can.typeDecoderS`, Canonical.elm ~760-830), so two
occurrences of `S` are two distinct object trees already before the rewrite. There is NO per-node id
on `Can.Type` (only `TLambda`'s `ArrowSlot` — arrows, excluded here — and the `MVarId`s of vars);
a memo therefore cannot be keyed on object identity or on a stamped id. It must be keyed
structurally, and the cheapest exact structural key of an alias occurrence is its NAME plus its
ARGUMENTS: an alias `(home, name)` is defined once per module and a module exists once per program,
so `(home, name, args)` determines the expanded body (`Filled inner` is `body[params := args]`,
produced by the canonicaliser deterministically; `Holey inner` is the body itself and the args bind
its params). The param `MVarId`s in `args : List ( id, Type id )` are per-def binder ids
(`ensureBinder argName`), NOT identity — they are dropped from the key.

##### 4.2 Which Points may be shared across loads within an item

Shared: every Point of an eligible alias body BELOW its root — `App1`, `Record1`, `Tuple1`, `Unit1`,
`EmptyRecord1` structure Points, including the roots of NESTED alias occurrences inside the body.
Never shared: (i) var Points (an eligible type has no `TVar`, so `loadVarC` 484-507 / `recordVarC`
510-521 / `revMemo` are never touched — `memo` and `revMemo` do not interact with this memo at all:
a memo hit inserts nothing into `memo`, and a miss behaves exactly as today, including the Holey
arm's bind/restore of param ids at 435-463, whose net effect on `memo` is nil); (ii) arrow `FunL`
nodes and their SET SLOTS (no `TLambda` ⇒ `arrowSlots`/`arrowMemo`/`slotsMinted` untouched — the
LSS_006 ordinal contract, all four rows of the table at Store 298-311, is not reached); (iii) the
ROOT of the alias occurrence, which is minted fresh on every hit (§4.3 says why).

##### 4.3 Soundness of sharing — the reader census and the one hazard

Sharing ground structure is semantically invisible to unification: `Unify.unifyStructure` (Unify
701-870) on two `App1`/`Record1` with pairwise-IDENTICAL children hits `guardedUnify`'s
`UF.equivalent left right` short-circuit (295-330) per child and only `merge`s the two roots (262-274,
`UF.unionS` union-by-weight 239-270). The merged content is structurally the same type. The only
content that could differ, `Vars.Error`, is written by `Unify.unify`'s failure arm (Unify 51-79,
`UF.union v1 v2 errorDescriptor` at 69) — and every failure is either DISCARDED with the whole
post-attempt state (`Store.unifyBestEffort` 1076-1084 returns the pre-unify `s`;
`Translate.unifyStepBestEffort` 5284-5292 likewise; `classifyRef` 1945-1960 falls back to the
pre-load state) or ABORTS the compile (`Store.unifyStep` 1034-1074 → `Engine.fail`, propagated by
`unifyStepCtx` 5264-5275). So a shared Point never carries `Error` into a later load.

What sharing DOES change is the union-find class graph: every var ever unified with a shared child
`P` joins `P`'s class, so two vars that today end in two classes (each bound to its own copy of
`Int`) end in ONE. The census of every consumer of Point identity/equivalence over structure Points
(`grep -n "pointKey\|UF.equivalent\|UF.repr" Store.elm LssInfer.elm Translate.elm Engine.elm
Monomorphize.elm`):

| reader | keyed on | effect of sharing |
|---|---|---|
| `revMemo` (Store 517, 2749, 2761; Engine `harvestSuperTableExcept` 2659-2700; Monomorphize 4750) | var Points only | none (no var Points shared) |
| `arrowOfSlot` (Store 353, 2913-2972; LssInfer 1911) — report-gated | set slots | none |
| `varOf` in `varNumberFor` 2863-2878 | repr of set slots; numbering by walk order | none |
| visited sets / worklists: `poisonGoC` 2144-2213, `qSigGo` 1562-1600 (qCensus), `qEagerGo` 1973, `resolveSources` 3273-3326, LssInfer `sigEdgesGo` 1030, `joinCallArgs` 2010, `papSuccGoC`/`papSuccWrite` 2700-2745, `spineGoC` 2820, `storeMentionsArrowGo` 3120, 3320 | raw `pointKey`, membership only | a shared child is visited once instead of k times — same writes (joins are idempotent, ⊤ absorbs), fewer visits |
| `ordinalOf`/`repOrdinal` LssInfer 1122/1169, `addSlotSource` Store 2037 | `UF.equivalent` on SET SLOTS | none (a slot is never unified with ground structure — `FunL`×`FunL` sub-unifies slot with slot only, Unify 743-747) |
| **`staleVarRead` Monomorphize 4747-4766** | `UF.equivalent memoPoint var` on TWO VAR POINTS with the same `MVarId` | **the hazard** — below |

`staleVarRead` is the MONO_029 R2 barrier's test (b): a recorded free-read var `var` counts as stale
only if it is now bound AND UF-equivalent to the item memo's Point for its own `MVarId`. Its
docstring (4723-4731) says why (b) exists: "isolated per-call instantiations … are read-free-then-
bound on EVERY pass by construction; treating them as stale livelocks the saturation loop". An
isolated twin `b` (minted by `loadTypeIsolated` for a call of global `g`, revMemo-backed) and the
family var `a = memo[mvarId(b)]` (the same scheme var loaded through the SHARED memo — the item's
own annotation via `demandUnifyVar` Translate 88-104, or a kernel's scheme via
`deriveKernelAbiTypeRef` 4910-4913) must stay in different classes unless a var-to-var unification
joins them. If both were unified with the SAME shared ground Point they would become equivalent
through it, (b) would flip to True, and `specializeNodeSaturating` (4422-4449) would re-translate;
a re-translation reproduces the read-free-then-bound pattern, so after `maxSaturationPasses = 5`
(4451-4453) the compile fails LOUDLY with `EngineBug "MONO_029 stale-read saturation exceeded"`.
Loud, not silent — but a failed bootstrap all the same.

Where can `a` and `b` meet a ground Point? `b` meets the arg/result structure of its call
(`argUnifyVar` 4221-4239 loads the ARG's canType through the shared memo — a memo hit under 4a);
`a` meets the DEMAND (`Store.monoTypeToVar` 694-704 — minted by `monoTypeToVarC`, NEVER memoised,
so never shared) and the node types of the item's own body. For the item's OWN scheme vars the
typechecker guarantees no node type places a ground type where the scheme var sits (a generalised
var is rigid inside its def), so `a` reaches a LOADED ground Point only through a var-var chain —
which is a legitimate family join today too. For a KERNEL scheme var loaded at a bare reference
(`Utils.equal` at node type `S -> S -> Bool`), `a` is unified with the node type's `S` — i.e. with
the ROOT of an alias occurrence — and the twin `a'` of a call `Utils.equal x y` is unified with the
ROOT of the argument's `S` load. This is the case that decides the design:

**Rule: a memo HIT mints a FRESH ROOT Point (`structC flat`) over the shared children; only the
children are shared.** With per-load roots, `a ~ root_1` and `a' ~ root_2` stay in two classes
(the roots are never unified with each other — nothing connects a bare reference's use var with a
call's argument var except a var-var chain), exactly as today. A var reaches a shared CHILD only
when a structure with a var in a CHILD position is unified against the alias body — a row-
polymorphic scheme (`{ r | store : x } -> x`, the accessor shape) facing `S`, or a type-argument var
facing an alias-body field. Row-polymorphic globals are never both bare-referenced (shared family)
and call-instantiated (isolated twin) in one item with the twin read free before being bound: an
accessor applied to a value is a `TOpt.Access` node, not a call, and user-defined row-polymorphic
functions instantiate ISOLATED at every call (`instantiate` 5216-5217) while their bare references
load the REFERENCE NODE's already-instantiated type (`classifyRef` 1951: `Store.loadType canType`
where `canType` is the node type, not the scheme) — so no family var of such a scheme ever exists.
The residual is stated, not hand-waved: §6 adds the pin (`saturationRetries` must be IDENTICAL
between arms) and the failure mode is a loud `EngineBug`, never a silent miscompile.

Cost of the rule: one `UF.fresh` per hit (1 cell push, no path copy beyond the tail) instead of
zero — negligible against the 150-300 mints it replaces.

##### 4.4 The key and its hash — no strings built, no string hashing per probe beyond the alias name

```elm
-- Engine.elm (next to MonoMemo, 483)
{-| Step 4: identity of one alias INSTANTIATION with ground, arrow-free arguments.
`hash` is computed ONCE by `Store.aliasKeyOf` from the canonical's part LENGTHS, the
alias NAME's characters (short, decides bucket quality — the `TOpt.globalHash`
precedent, TypedOptimized.elm 329-341) and the args' structural `groundHash`es;
`args` are the argument TYPES only — the param ids in `Can.TAlias`'s list are
per-def binder ids (`AssignMVarIds.ensureBinder`), not identity. -}
type alias AliasKey =
    { hash : Int
    , home : ModuleName.Canonical
    , name : String
    , args : List (Can.Type TypeIds.MVarId)
    }

aliasKeyHash : AliasKey -> Int
aliasKeyHash k = k.hash

aliasKeyEq : AliasKey -> AliasKey -> Bool
aliasKeyEq a b =
    -- name first (cheapest discriminator), then the three canonical strings, then
    -- the args: `==` on `List (Can.Type MVarId)` is O(1) for `[]` (the S/Env/ItemAux
    -- case) and a small structural walk otherwise; args are arrow-free and var-free,
    -- so no ArrowId/MVarId ever enters the comparison.
    a.name == b.name && a.home == b.home && a.args == b.args

type AliasVerdict
    = AliasIneligible                 -- body has an arrow (Holey) / inner not eligible (Filled): never memoise this instantiation
    | AliasGround Mono.MonoType       -- eligible; the canonical interned classification
```

`HashMap.get aliasKeyHash aliasKeyEq key m` (HashMap.elm 62) resolves collisions by `aliasKeyEq`, so
the hash needs only "equal keys ⇒ equal hash", which holds because every ingredient is a pure
function of `(home, name, args)`.

`Mono.mixHash` is NOT exported from `Monomorphized.elm` (checked: export list 1-12 has no `mixHash`),
so Store gets a local twin:

```elm
-- Store.elm
mix : Int -> Int -> Int
mix h x =
    modBy 67108864 (h * 33 + modBy 67108864 x + 7)   -- == Mono.mixHash / TOpt.globalMixHash
```

##### 4.5 Where the memos live (32-slot cap)

`S` has 31 top-level fields (Engine 1302-1412) and its own comment at 1385-1391 forbids a 32nd. Both
new maps nest in fields that already exist and are already copied on their write paths:

- per run: `S.monoMemo : MonoMemo` (Engine 483-486, "the three classification memos (ONE field: … S is
  at the runtime's 32-slot record scan cap)") gains `aliasMemo`. `MonoMemo` goes 2 → 3 fields.
- per item: `S.itemAux : ItemAux` (Engine 1414-1513) gains `groundLoads`. `ItemAux` goes 13 → 14.
- per load: `LoadCtx` (Store 58-70) gains `groundLoads` (11 → 12 fields; the per-node copy grows by one
  word — C6's four dead fields are Step 6's business, not this step's).
- `Env` is not touched (immutable).

##### 4.6 Invalidation rules

| event | `ItemAux.groundLoads` (holds `FlatType`s = Points of THIS store) | `MonoMemo.aliasMemo` (per run) |
|---|---|---|
| `resetItem` (Engine 2433-2435) — fresh store per item | cleared via `emptyItemAux` | kept |
| `withScratchStore` (2033-2100) — LssInfer's inference scratch store | cleared by `clearedAux` on entry, restored from `outer` by `restoredAux` on exit — the `arrowMemo` rule at 1447-1458 verbatim | kept |
| `Translate.retranslateWithTag` (5999-6016) — local-multi/number-multi instance re-translation in a fresh store | same: it calls `Engine.clearedAux` / `Engine.restoredAux` | kept |
| `clearResidualReads` (1545-1551) — MONO_029 saturation re-pass against the SAME store | KEPT (Points still valid; clearing would re-mint and lose sharing mid-item — the `arrowMemo` comment at 1455-1458) | kept |
| a best-effort unify failure | nothing to do — the failed state is discarded wholesale (§4.3) | — |
| `withIntern` never shrinks `S.intern` (2779-2786; seeded `Intern.empty` at Monomorphize 3870) | — | never invalidated: a stored `AliasGround mono` is the canonical object for the rest of the run |

Never put `groundLoads` in `restoredAux`'s "keep-from-inner" set: a scratch store's `FlatType`s
name scratch Points and would alias low outer indices — the exact silent-miscompile hazard the
`arrowMemo` comment records (Engine 1444-1452).

##### 4.7 Load side — `loadTypeC`'s alias arm

```elm
loadTypeC :
    Dict.Dict Int Vars.SuperType
    -> HashMap.HashMap Engine.AliasKey Engine.AliasVerdict   -- NEW, read-only: the run's verdicts
    -> Can.Type TypeIds.MVarId
    -> LoadCtx
    -> ( Vars.Variable, LoadCtx )
loadTypeC superStatic aliasMemo canType c0 =
    case canType of
        ...  -- every other arm unchanged except for threading `aliasMemo` into the recursive calls

        Can.TAlias home name args aliasType ->
            case aliasKeyOf home name args of
                Nothing ->
                    -- an ARG is not ground/arrow-free: today's path, verbatim
                    loadAliasPlainC superStatic aliasMemo args aliasType c0

                Just key ->
                    case HashMap.get Engine.aliasKeyHash Engine.aliasKeyEq key c0.groundLoads of
                        Just flat ->
                            -- HIT: ONE fresh root over the shared children (§4.3).
                            structC flat c0

                        Nothing ->
                            let
                                eligible =
                                    case HashMap.get Engine.aliasKeyHash Engine.aliasKeyEq key aliasMemo of
                                        Just (Engine.AliasGround _) -> True
                                        Just Engine.AliasIneligible -> False
                                        Nothing -> aliasBodyEligible aliasType   -- one walk; the classify side caches the verdict per run

                                ( p, c1 ) =
                                    loadAliasPlainC superStatic aliasMemo args aliasType c0
                            in
                            if not eligible then
                                ( p, c1 )

                            else
                                -- MISS on an eligible instantiation: remember the ROOT's flat content.
                                -- `p` was minted by this very load and nothing has unified it, so
                                -- `UF.get` is a root read (no path write; `store1 == c1.store`).
                                let
                                    ( store1, desc ) =
                                        UF.get p c1.store
                                in
                                case desc.content of
                                    Vars.Structure flat ->
                                        ( p, { c1 | store = store1, groundLoads = HashMap.insert Engine.aliasKeyHash Engine.aliasKeyEq key flat c1.groundLoads } )

                                    _ ->
                                        -- unreachable for an eligible body (its root is always Structure);
                                        -- degrade to "not memoised", never crash
                                        ( p, { c1 | store = store1 } )


{-| Today's two `TAlias` arms (Store 429-463), moved verbatim. -}
loadAliasPlainC : Dict.Dict Int Vars.SuperType -> HashMap.HashMap Engine.AliasKey Engine.AliasVerdict -> List ( TypeIds.MVarId, Can.Type TypeIds.MVarId ) -> Can.AliasType TypeIds.MVarId -> LoadCtx -> ( Vars.Variable, LoadCtx )
loadAliasPlainC superStatic aliasMemo args aliasType c0 =
    case aliasType of
        Can.Filled inner ->
            loadTypeC superStatic aliasMemo inner c0

        Can.Holey inner ->
            -- the bind / load / restore block of 435-463, unchanged
            ...
```

Alias-of-alias (`type alias A = B`): `A`'s miss loads its body, whose root is `B`'s hit root, and
stores `B`'s `flat` under `A`'s key — consistent (every `A` hit is a fresh root over `B`'s children).
Alias of a leaf (`type alias Name = String`): the memo stores `App1 string "String" []` and a hit
mints one `App1`, exactly today's cost plus a probe; not worth a special case.

`writeBackShared` (150-176): the `itemAux` update at 166-173 becomes
`{ aux | arrowMemo = c.arrowMemo, arrowOfSlot = c.arrowOfSlot, groundLoads = c.groundLoads }`.
`writeBackIsolated` (178-203): today it rebuilds `itemAux` only under `censusOn`; add
`|| HashMap.size c.groundLoads /= HashMap.size s.itemAux.groundLoads` to the condition and write
`groundLoads` there (the `memo`/`arrowMemo` H1 asymmetry at 116-124 is about SLOTS and stays).

##### 4.8 Classify side — `classifyGo`'s alias arm

```elm
        Can.TAlias home name args aliasType ->
            case aliasKeyOf home name args of
                Nothing ->
                    classifyAliasPlain topKind s aliasSubst args aliasType

                Just key ->
                    case HashMap.get Engine.aliasKeyHash Engine.aliasKeyEq key s.monoMemo.aliasMemo of
                        Just (Engine.AliasGround mono) ->
                            -- HIT: the canonical object, no probe, no S change (no intern growth,
                            -- no MONO_029 key read — ground types never reach the TVar arm).
                            Ok ( mono, s )

                        Just Engine.AliasIneligible ->
                            classifyAliasPlain topKind s aliasSubst args aliasType

                        Nothing ->
                            if aliasBodyEligible aliasType then
                                case classifyAliasPlain topKind s aliasSubst args aliasType of
                                    Err e ->
                                        Err e

                                    Ok ( mono, s1 ) ->
                                        -- `mono` came out of `consS`, so it IS the canonical object.
                                        Ok ( mono, Engine.putAliasVerdict key (Engine.AliasGround mono) s1 )

                            else
                                classifyAliasPlain topKind (Engine.putAliasVerdict key Engine.AliasIneligible s) aliasSubst args aliasType


classifyAliasPlain : Int -> Engine.S -> Dict.Dict Int Mono.MonoType -> List ( TypeIds.MVarId, Can.Type TypeIds.MVarId ) -> Can.AliasType TypeIds.MVarId -> Result Failure ( Mono.MonoType, Engine.S )
classifyAliasPlain topKind s aliasSubst args aliasType =
    -- today's 3621-3634, verbatim
    case aliasType of
        Can.Filled inner -> classifyGo topKind s aliasSubst inner
        Can.Holey inner ->
            case classifyAliasArgs topKind s aliasSubst args aliasSubst of
                Err e -> Err e
                Ok ( newSubst, s1 ) -> classifyGo topKind s1 newSubst inner
```

```elm
-- Engine.elm
putAliasVerdict : AliasKey -> AliasVerdict -> S -> S
putAliasVerdict key v s =
    let m = s.monoMemo in
    { s | monoMemo = { m | aliasMemo = HashMap.insert aliasKeyHash aliasKeyEq key v m.aliasMemo } }
```

`topKind` and `aliasSubst` are irrelevant on a hit: `topKind` is consumed only by the `TLambda` arm
(3576-3584) and `aliasSubst` only by the `TVar` arm (3530-3535); an eligible instantiation reaches
neither. `superTable`/`superStatic` likewise (var arms only). The stored value is exact under
`Intern` because `S.intern` is live for the whole run (§2 (b)) and `consS` (Engine 2753-2759) always
returns the table's canonical object; a later probe of the same structure would hand back the SAME
object, so returning it without probing is indistinguishable — and `==`-based downstream consumers
(`identicalOr` Mono 585-587) see pointer-equal inputs either way.

`Zonk.canTypeToMonoWithI` (Zonk 61-183) is NOT given the memo: its two `S`-threaded callers
(`computeSchemeMono` Translate 3179-3190, once per global and cached in `schemeMono`; the kernel-
boundary conversion at 8134) are cold, and its bare-`Intern.disabled` callers (`translateGlobal-
CallGroundMemo` 3297-3298, Monomorphize 134/3961) have no `S` to read a memo from.

##### 4.9 The fused predicate / hash walks (one walk, early exit) — shared with Step 9

```elm
-- Store.elm — exported: groundNoArrow, groundNoArrowWith, aliasKeyOf

{-| -1 when the type has a free var, an arrow or an open record ANYWHERE; otherwise a
structural hash in [0, 2^26). ONE walk, exits at the first disqualifier. Through a
Filled alias only `inner` is looked at (what load/classify consume); through a Holey
alias the args and the body's arrow-freeness (its vars are the params). -}
groundHash : Can.Type TypeIds.MVarId -> Int
groundHash t =
    case t of
        Can.TVar _ ->
            -1

        Can.TLambda _ _ _ ->
            -1

        Can.TUnit ->
            1

        Can.TType (ModuleName.Canonical _ modName) name args ->
            groundHashList (mix (mix (mix 2 (String.length modName)) (String.length name)) (List.length args)) args

        Can.TTuple a b rest ->
            groundHashList (mix 3 (List.length rest)) (a :: b :: rest)

        Can.TRecord _ (Just _) ->
            -1

        Can.TRecord fields Nothing ->
            -- Dict.foldl cannot break; once negative it stays negative (one compare per field)
            Dict.foldl
                (\k (Can.FieldType _ ft) h ->
                    if h < 0 then
                        h
                    else
                        let hf = groundHash ft in
                        if hf < 0 then -1 else mix (mix h (String.length k)) hf
                )
                (mix 4 (Dict.size fields))
                fields

        Can.TAlias _ _ _ (Can.Filled inner) ->
            groundHash inner

        Can.TAlias (ModuleName.Canonical _ modName) name args (Can.Holey inner) ->
            let
                h = groundHashList (mix (mix 5 (String.length modName)) (String.length name)) (List.map Tuple.second args)
            in
            if h < 0 || not (noArrowBody inner) then -1 else h


groundHashList : Int -> List (Can.Type TypeIds.MVarId) -> Int
groundHashList h ts =
    case ts of
        [] -> h
        t :: rest ->
            let ht = groundHash t in
            if ht < 0 then -1 else groundHashList (mix h ht) rest


{-| Arrow-freeness of an alias BODY: vars (params) and open extensions (a param) are fine. -}
noArrowBody : Can.Type TypeIds.MVarId -> Bool
noArrowBody t =
    case t of
        Can.TVar _ -> True
        Can.TLambda _ _ _ -> False
        Can.TUnit -> True
        Can.TType _ _ args -> List.all noArrowBody args
        Can.TTuple a b rest -> noArrowBody a && noArrowBody b && List.all noArrowBody rest
        Can.TRecord fields _ -> Dict.foldl (\_ (Can.FieldType _ ft) ok -> ok && noArrowBody ft) True fields
        Can.TAlias _ _ _ (Can.Filled inner) -> noArrowBody inner
        Can.TAlias _ _ args (Can.Holey inner) -> List.all (\( _, at ) -> noArrowBody at) args && noArrowBody inner


groundNoArrow : Can.Type TypeIds.MVarId -> Bool
groundNoArrow t =
    groundHash t >= 0


{-| The memo key of an alias occurrence: Nothing when an ARGUMENT disqualifies it.
Looks at the args only — never the body — so a probe never pays a body walk. -}
aliasKeyOf : ModuleName.Canonical -> String -> List ( TypeIds.MVarId, Can.Type TypeIds.MVarId ) -> Maybe Engine.AliasKey
aliasKeyOf ((ModuleName.Canonical ( author, project ) modName) as home) name args =
    let
        argTypes =
            List.map Tuple.second args     -- [] for the zero-arg case: no allocation

        h0 =
            mix (mix (mix (mix 6 (String.length author)) (String.length project)) (String.length modName))
                (String.foldl (\c h -> mix h (Char.toCode c)) 23 name)

        h =
            groundHashList h0 argTypes
    in
    if h < 0 then
        Nothing
    else
        Just { hash = h, home = home, name = name, args = argTypes }


{-| Is the alias BODY eligible (the part `aliasKeyOf` did not look at)? -}
aliasBodyEligible : Can.AliasType TypeIds.MVarId -> Bool
aliasBodyEligible aliasType =
    case aliasType of
        Can.Filled inner -> groundHash inner >= 0
        Can.Holey inner -> noArrowBody inner


{-| `groundNoArrow` that answers an alias occurrence from the run's verdict map when it
can (O(1) for `S`, `Env`, `ItemAux` after their first classify) and walks otherwise.
Step 9's predicate. -}
groundNoArrowWith : HashMap.HashMap Engine.AliasKey Engine.AliasVerdict -> Can.Type TypeIds.MVarId -> Bool
groundNoArrowWith aliasMemo t =
    case t of
        Can.TAlias home name args aliasType ->
            case aliasKeyOf home name args of
                Nothing -> False
                Just key ->
                    case HashMap.get Engine.aliasKeyHash Engine.aliasKeyEq key aliasMemo of
                        Just (Engine.AliasGround _) -> True
                        Just Engine.AliasIneligible -> False
                        Nothing -> aliasBodyEligible aliasType
        Can.TType _ _ args -> List.all (groundNoArrowWith aliasMemo) args
        Can.TTuple a b rest -> groundNoArrowWith aliasMemo a && groundNoArrowWith aliasMemo b && List.all (groundNoArrowWith aliasMemo) rest
        Can.TRecord fields Nothing -> Dict.foldl (\_ (Can.FieldType _ ft) ok -> ok && groundNoArrowWith aliasMemo ft) True fields
        Can.TRecord _ (Just _) -> False
        Can.TUnit -> True
        Can.TVar _ -> False
        Can.TLambda _ _ _ -> False
```

`groundNoArrow t == (Translate.groundCanType t && not (Translate.canTypeHasArrow t))` for every
`t` EXCEPT a Filled alias whose PHANTOM arg carries an arrow (`canTypeHasArrow` 3031 looks at Filled
args; `groundNoArrow` does not, matching what is loaded). Pin that equivalence in the unit test on the
non-phantom corpus (§6) — Step 9 relies on it.

##### 4.10 Order-of-evaluation and mint-order constraints (what makes emission byte-identical)

- **Member ids**: loads and classifies mint none. Unchanged.
- **Intern insertion order**: a classify HIT inserts nothing — but so does today's re-classify of a
  structure already in the table (every `probe` hits). The FIRST classify of an instantiation runs
  `classifyAliasPlain` and inserts bottom-up in today's order. Hence the sequence of `HashMap.insert`s
  into `S.intern` is identical, and `HashMap`'s insertion-ordered iteration (HashMap.elm 30-36) sees
  the same sequence numbers.
- **Point indices** shift (fewer mints ⇒ smaller later indices; a hit's root is minted where today
  the body's first child was). No consumer orders on `pointKey` (table in §4.3): `revMemo` is index-
  ADDRESSED, its harvest folds into a `Dict` (order-free), `ecoReads`/`ecoResidualKeyReads` are
  consumed by `List.any` (Monomorphize 4732-4745), visited sets are membership-only.
- **Union-by-weight root choice** (UnionFind 239-270) can differ because shared children accumulate
  weight; `UF.repr` results are consumed only for set slots (`varOf`, `qKey`, `arrowOf`) and for
  equivalence tests, never for ordering — and slot classes are untouched (§4.2).
- **Path compression** writes (`reprS`/`getS`) are unobservable.
- **`slotsMinted`** (LoadCtx 65 → `lssStats.slotsMinted`, 154-164): zero for eligible subtrees, so
  the counter is unchanged even under report.
- **Census under `ECO_MONO_LSS_REPORT=1`**: `arrowOfSlot` is slot-keyed and unaffected; `zonkLog`
  logs the Points handed to `zonkToMono`, whose count is unchanged (loads are not zonks). The rail's
  `.census` diff is expected to be ZERO lines.

##### 4.11 Optional 4c — zonk side (separate loop entry, only if 4a+4b leave `zonkRecordFieldsC` hot)

After 4a, every zonk of an `S`-typed Point still walks the 31 shared field Points
(`zonkFlatC` 2769-2860 → `zonkRecordFieldsC` 3407-3421, `consC` per node). A per-item
`ItemAux.groundZonks : Dict Int Mono.MonoType` keyed by the `pointKey` of each shared CHILD (inserted
at the 4a miss by one extra walk of the freshly loaded body, reading each child's content) is exact
for the same reason 4b is: a shared child's class content is always the same ground structure, it
carries no residual var (`residualIdC` never mints), no set slot (`varOf` untouched) and no
`ecoReads`. Consult it in `zonkToMonoC` (2684-2727) BEFORE `UF.get`, only for the Points a 4a miss
registered (probe cost: one `Dict Int` lookup per zonked Point — gate on `not (Dict.isEmpty …)`).
Clear/restore with `groundLoads`. Not part of the first measured run: it adds a probe to EVERY zonked
node and must be judged on its own row.

#### 5. Edit sequence (each edit leaves `elm make` green)

1. **Engine.elm** — add `AliasKey`, `aliasKeyHash`, `aliasKeyEq`, `AliasVerdict(..)`, the `aliasMemo`
   field on `MonoMemo` (483-486) + `emptyMonoMemo` (489-491), `putAliasVerdict`; export them (line 8).
   `import Compiler.AST.Canonical as Can` is already present (S uses `Can.Type` at 1400-1401).
   Build: green (nothing reads the new field yet).
2. **Engine.elm** — add `groundLoads : HashMap.HashMap AliasKey Vars.FlatType` to `ItemAux` (1414),
   `emptyItemAux` (1516-1518: `groundLoads = HashMap.empty`), `clearedAux` (1529-1531: clear),
   `restoredAux` (1537-1539: `groundLoads = outer.groundLoads`). Write the store-scoped comment
   (copy the `arrowMemo` one at 1444-1458). Build: green.
3. **Store.elm** — `import Data.HashMap as HashMap`; add `mix`, `groundHash`, `groundHashList`,
   `noArrowBody`, `groundNoArrow`, `aliasKeyOf`, `aliasBodyEligible`, `groundNoArrowWith` after
   `normalizePrimHome` (622); export `groundNoArrow`, `groundNoArrowWith`, `aliasKeyOf`. Build: green.
   **Test pin in the same edit**: `GroundAliasMemoTest` cases T1-T3 (§6) compile against these alone.
4. **Store.elm, classify side (4b)** — extract `classifyAliasPlain` from 3621-3634; replace the two
   `TAlias` arms of `classifyGo` by the single memo arm of §4.8. Build: green. Run the unit suite:
   `MonomorphizeTest`, `ComparableKeyEncodingTest`, the `Lss*Test` files must be unchanged; add T4-T5.
   **This is a natural stopping point for a loop entry `4b`** (classify only; `loadTypeC` untouched).
5. **Store.elm, load side (4a)** — add `groundLoads` to `LoadCtx` (58-70), `testLoadCtx` (80-92),
   `sharedLoadCtx` (99-110), `isolatedLoadCtx` (126-142); thread `groundLoads` through both
   write-backs (150-203); add the `aliasMemo` parameter to `loadTypeC`/`loadListC`/`loadRecordExtC`/
   `loadRecordFieldsC` and pass `s.monoMemo.aliasMemo` from the four entry points (205-259); extract
   `loadAliasPlainC` from 429-463 and install the memo arm of §4.7. **Same edit**: ArrowIdentityTest.elm
   124 → `Store.loadTypeC Dict.empty HashMap.empty canType (…)` + its import. Build: green.
   Add T6-T9.
6. Run `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt` ONCE; grep it.

Loop entries: `4b` after edit 4 (cheap, classify-only), `4a` after edit 5. If only one row is
affordable, do both edits and measure once as `4`.

#### 6. Verification

**Unit (new `compiler/tests/TestLogic/Monomorphize/GroundAliasMemoTest.elm`, fixtures built the
ArrowIdentityTest way — `Can.TAlias` literals with `Can.Filled`/`Can.Holey`, `Can.tLambda` for arrows,
`Store.testLoadCtx True True Dict.empty Engine.freshStore`):**

- T1 `groundHash` table: `TVar` → -1; `tLambda Int Int` → -1; `TRecord … (Just v)` → -1; a record with
  an arrow in a nested field → -1; Holey alias with a `TVar` arg → -1; Holey alias with an arrow in the
  body → -1; Filled alias over a ground record → ≥ 0; two structurally equal occurrences (fresh
  objects) → equal hashes; `Int` vs `String` → different.
- T2 `groundNoArrow t == (groundCanType t && not (canTypeHasArrow t))` over the T1 corpus (Translate's
  two predicates are exposed? they are top-level in Translate but not exported — expose them or copy
  the two 20-line definitions into the test; the copy is fine, they are pinned by name in the test).
- T3 `aliasKeyOf` drops param ids: two occurrences of `Pair Int` whose param `MVarId`s differ produce
  keys with `aliasKeyEq == True` and equal hashes.
- T4 classify memo: `classifyDirect` twice on fresh `S`-like alias objects through one `S` — the second
  result `==` the first, `Intern.size s2.intern == Intern.size s1.intern`, and `s2.monoMemo.aliasMemo`
  has ONE entry; an arrow-bearing alias leaves an `AliasIneligible` entry and the two results are
  still `==`.
- T5 classify memo is `topKind`-blind on eligible types: `classifyDirect Mono.tkDeclStoreS` then
  `classifyDirect Mono.tkClassMisc` return the same object.
- T6 load memo: load a 5-field record alias twice through one `LoadCtx`; `Array.length
  c.store.ioRefsPoint` grows by exactly 1 on the second load (IO.elm 101-106: `ioRefsPoint : Array
  PointCell`); the two roots differ by `Engine.pointKey`; the two `Record1` field dicts are
  `==` (same child Points); `c.memo`, `c.revMemo`, `c.arrowSlots`, `c.slotsMinted` unchanged.
- T7 ordinal contract untouched: an alias `{ f : Int -> Int }` loaded twice → NO memo entry,
  `arrowSlots` length 2, `slotsMinted` 2 (the LSS_006 table, ArrowIdentityTest's `shape` helper).
- T8 Holey with ground args keyed per instantiation: `Box Int` then `Box String` → 2 entries; a third
  `Box Int` → +1 Point.
- T9 isolated + shared write-back: `loadTypeIsolated` then `loadType` of the same alias through one
  `S` → the second is a hit (+1 Point); `s.memo` unchanged by the isolated one.

**Byte identity + effect (the loop, `benchmarks/lss-compile-opt-loop.md` §2):** Phase 1.3/1.4 build
`bin/eco-opt4`, Phase 2 three cold runs, then `cmp` r1/r2/r3 and `cmp bin/eco-opt4-r1-out.mlir
bin/eco4.mlir` (fixed point). Judge the five stats against the reference row.

**Gates on a win (Phase 4):** `cmake --build build --target elm-tests`, `cmake --build build --target
full`, and `benchmarks/mlir-workload-rail.sh` — expect `CENSUS: 0 diff lines` (§4.10).

**Attribution leg (untimed, separate):** re-run `scratchpad/uprobe/run.sh` with `BIN=$BK/bin/eco-opt4`
(the two probes that are known to attach are `Compiler_Type_UnionFind_freshS_*` and `…_unionS_*`;
baseline 5,739,553 / 918,925). Expected: `freshS` down by the number of memo-hit body nodes (order
10^6), `unionS` down (fewer structure merges). If `freshS` does not move, the memo is not hitting —
check `aliasKeyOf` returns `Just` for `S` (a `TVar` somewhere in the compiler's `S`? there is none)
before anything else. To count hits/misses directly, add a TEMPORARY `Debug.log`-free counter pair to
`LoadCtx` for the leg and remove it before the timed run (never ship a counter in `LssStats`: it is at
the 32-field cap, Engine 144-300).

**The §4.3 residual pin:** count saturation re-passes per run in both arms
(`specializeNodeSaturating` attempt > 0 — one temporary `bumpArgFlowCensus "mono029|repass"` at
Monomorphize 4444 in a report-on, untimed leg) — the two counts must be IDENTICAL. Any increase
means a var reached a shared child through a path §4.3 ruled out; do not ship until it is understood.

#### 7. Risks, gotchas, and what NOT to do

- **The fresh-root rule is load-bearing** (§4.3). Returning the memoised root Point itself would make
  kernel-scheme family vars and their isolated twins UF-equivalent through the root and trip
  `staleVarRead` → `EngineBug` after 5 passes. Do not "optimise away" the one `structC`.
- **Never memoise through `monoTypeToVarC`** (721-946). The demand side is what keeps family vars
  and twins apart (§4.3); it is also N21/C10's territory (mint-order change ⇒ not BI for free).
- **`groundLoads` is STORE-SCOPED.** It holds `FlatType`s = Points. Any new store swap (there are
  three: `withScratchStore`, `retranslateWithTag`, `resetItem`) must clear it; `clearResidualReads`
  must NOT. Same rule and same comment as `arrowMemo` (Engine 1444-1458).
- **Do not key on strings** (`toComparableGlobal`-style) — that is the cost class Step 13 removes; the
  key hashes name characters once per probe and compares the canonical only on a bucket hit.
  Step 12's dense `GlobalId` can later replace `home`/`name` in `AliasKey` by one Int.
- **Do not extend the memo to non-alias `TRecord`/`TType` occurrences** in this step. The plan
  mentions it as a fallback "with a stamped node id" — there is no node id (§4.1), and a structural
  key for a bare record would need a full-tree hash per occurrence, which is the walk the memo
  exists to avoid. Measure the alias-only version first.
- **Filled aliases with phantom arrow args** are not memoised (`aliasKeyOf` → `Nothing`); that is a
  missed hit, not a bug. Holey bodies whose vars are NOT all params would be a canonicaliser bug and
  are treated as ground exactly as `groundCanType` 3133-3136 already does.
- **`HashMap` iteration** is never used on either map (probe/insert only), so the insertion-order
  caveat of HashMap.elm 30-36 does not apply.
- **32-slot cap**: `S` stays at 31 fields; `MonoMemo` 3, `ItemAux` 14, `LoadCtx` 12 — all far below.
- **`LssStats` is at 32 fields** (Engine 144-300): no counters go there.
- **Test suite**: only `ArrowIdentityTest.elm:124` calls `loadTypeC`; no test builds an `ItemAux`,
  `MonoMemo` or `LoadCtx` literal (grep in §2 (c)), so `emptyItemAux`/`emptyMonoMemo`/`testLoadCtx`
  are the only constructors to update.
- **Report mode**: nothing here is report-gated; the memos are live under report too, and the
  `.census` must not change (§4.10). Measure with report OFF (loop hygiene §5).
- Plan §4 items NOT to do here: N3 (run-wide `arrowMemo` Array — a loss), N18 (record-shape
  representation change — typechecker-shared), N21 (`mintVarSlots` single walk — not BI).

#### 8. Effort

**M.** Two small type additions in Engine, ~150 lines of new Store helpers, two arm rewrites, one
parameter threaded through five Store functions, one test-file edit and one new test file. Split as
`4b` (classify memo, ~1 hour, no signature change) and `4a` (load memo + `loadTypeC` parameter). `4c`
(zonk memo) is a third, optional entry.

---

<details><summary>Conventions used in this spec (from spec-C)</summary>

All line numbers are from the tree as of 2026-09-19 (`compiler/src/Compiler/...`); every one was
re-verified with `grep -n` before being written down. `Store` = `MonoSolver/Store.elm` (3722 ln),
`Translate` = `MonoSolver/Translate.elm` (8263 ln), `Engine` = `MonoSolver/Engine.elm` (2823 ln),
`Zonk` = `MonoSolver/Zonk.elm` (228 ln), `Mono` = `AST/Monomorphized.elm`, `Can` = `AST/Canonical.elm`.

Shared vocabulary for both steps:

- **eligible type** = a `Can.Type MVarId` with no `TVar`, no `TLambda` anywhere, and no open record
  (`TRecord _ (Just _)`); through a `TAlias _ _ _ (Filled inner)` only `inner` is inspected (that is
  all `loadTypeC`/`classifyGo`/`Zonk` ever consume of a Filled alias — Store 429, Store 3621, Zonk
  163); through `TAlias _ _ args (Holey inner)` every arg must be eligible and `inner` must be
  arrow-free (its vars are the alias params, bound by the args — the same assumption
  `Translate.groundCanType` 3104-3136 already makes at 3133-3136).
- `groundHash t` = the ONE-walk, early-exit fused predicate + structural hash: `-1` when `t` is not
  eligible, else an `Int` in `[0, 2^26)`. Defined in §4.9 of Step 4 and reused by Step 9.

---

</details>

### Step 5 (was 4). Direct-state entry for `Unify.unify` (`unifyS`)

#### 1. Goal and expected effect

**Where the CPS goes.** The WHOLE unifier is written in the `Unify` combinators — not only the
entry. `type Unify a = Unify (List Variable -> IO (Result UnifyErr (UnifyOk a)))` (Unify.elm 91),
and every arm of `actuallyUnify` (340-376), `unifyFlex`/`unifyRigid`/`unifyFlexSuper`/`unifyAlias`/
`unifyStructure`/`unifyRecord` (384-955) returns a `Unify ()` built from `merge`, `mismatch`,
`subUnify |> andThen`, `zipAllWithM_`, `try`, `traverseAll`, `register`. Because `IO a` is itself
`State -> ( State, a )`, a `Unify a` value IS already a direct-state function
`List Variable -> State -> ( State, Result UnifyErr (UnifyOk a) )` — `guardedUnify` (296-325) and
`merge` (263-276) already exploit that by writing `Unify (\vars s0 -> …)` and calling `k vars s3`
saturated. So:

- `unifyS` needs a direct-state twin of the ENTRY only (`unify` 51-73 + `guardedUnify`'s lambda
  lifted to a top-level function). Nothing in the combinator layer has to change for `unifyS` to
  exist and be byte-identical. This is **5a**.
- The combinator layer's own per-node cost (one `Unify <| \vars -> …` closure + one `IO.andThen`
  continuation closure + `Ok`+`UnifyOk`+tuple per `andThen` node; `IO.map` closures in `map`,
  `register`, `try`, `comparableOccursCheck`) is a SEPARATE, optional rewrite — **5b** — that keeps
  the `Unify` type but re-spells the six combinators without `IO.andThen`/`IO.map`/`IO.pure` and
  flattens `Result UnifyErr (UnifyOk a)` into one constructor. 5b is where most of the
  "6.3 % nearest-caller `IO_andThen` + 2.3 % `IO_map`" (plan §1 closure-dispatch row) actually
  lives: the entry contributes exactly ONE `IO.andThen` per unification (Unify.elm 56), the
  combinators contribute one per structural node.

**What 5a removes per `Store.unifyStep` call on the success path** (Store.elm 1034-1068 →
Unify.elm 51-79 → Engine.elm 1630-1638, 1732-1739, 1620-1622): the `Engine.liftIO` thunk, the
`Engine.andThen` closure and its `\answer ->` continuation, `Engine.succeed ()`'s closure, two
`Ok`+tuple pairs, the `guardedUnify` closure, `k []`'s PAP-free call but the `IO.andThen`
continuation closure at Unify.elm 57, `onSuccess`'s `IO.pure` closure + tuple, and one of the two
`S` copies (liftIO's `{ s | store = store1 }` survives as the single write-back). ~9-10 objects /
~60 words per unification before any structural work, plus one `S` copy (31 refs). The same
shape (minus the Engine layer) is removed for the typechecker's four `Unify.unify` sites in
Solve.elm 208/235/262/289, which keep calling `unify` (now a 3-line wrapper over `unifyS`).

**Loop stats that should move:** minor GC count down (the honest allocation proxy — every removed
object is nursery allocation on a ≥10^6-per-run path); wall down by a fraction of the plan's
5-8 % (5a alone: expect 1-3 %; 5a+5b: the plan's figure). Major GC / promoted MiB flat (all of
this garbage dies young). `out.mlir` bytes and the fixed point: **BI yes** — every change is
allocation shape only; the store operations happen in the same order with the same arguments, the
same Points are minted in the same order, and the failure text is rebuilt from the same
`Error.Type` values rendered at the same moment (before the error union).

**Why BI matters here beyond the gate:** `unifyS` is shared with the real typechecker; a change in
Point mint order there would move `Vars.Pt` indices, which `IO.pointKey` (IO.elm 491) exposes to
`Unify.dedupeSources` (1007-1027) and to the LSS `seen` sets — so order-preservation is a
correctness requirement, not just the loop gate.

#### 2. Preconditions

- No plan step is required first. Step 6 comes AFTER this one (plan order), so `unifySlotWithSetSlow`
  (Store.elm 2106-2128) still exists when you build 5a — it is one of the callers you convert (see §3).
- Verify the inliner has NOT already flattened the entry (findings-C C8's warning): the lowered
  MLIR of the current compiler must still show the combinator shape. From `/work`:
  ```bash
  BK=build/compiler/build-kernel
  grep -c "System_TypeCheck_IO_andThen" $BK/bin/eco-compiler.mlir            # baseline count of andThen specs referenced
  grep -n "Compiler_MonoSolver_Store_unifyStep" $BK/bin/eco-compiler.mlir | head -3
  ```
  Record the first number; after 5a it must drop (the `Unify.unify` line-56 continuation and the
  `Engine.andThen` wrapper disappear). If the `Store_unifyStep` function body in the MLIR already
  contains no `eco.closure`/`papCreate` for the andThen chain, the inliner beat you to it and 5a's
  win is only the Engine-side `Result` removal — still do it (step 10 needs the `( Bool, S )` shape).
- Verify the caller inventory is still exactly the list in §3:
  ```bash
  grep -rn "Unify\.unify\b" compiler/src --include=*.elm          # expect Solve ×4, Store ×1
  grep -rn "unifyStep\b\|unifyBestEffort\b\|unifyStepBestEffort\b\|unifyStepCtx\b" compiler/src --include=*.elm | grep -v "^\S*:\s*--"
  grep -rln "unifyStep\|Unify\.unify\|AnswerErr\|AnswerOk" compiler/tests    # expect NO test pins (only a comment in UnificationErrorsTest.elm:132)
  ```

#### 3. Inventory of touched code

| file | function (lines now) | what changes |
|---|---|---|
| `compiler/src/Compiler/Type/Unify.elm` | module header 1 (`exposing (unify, Answer(..))`) | add `unifyS`, `unifyBoolS` to the export list |
| same | `unify` 51-73 | becomes a wrapper: `unify v1 v2 s0 = let ( a, s1 ) = unifyS v1 v2 s0 in ( s1, a )` |
| same | `onSuccess` 77-78 | delete (only caller was `unify`) |
| same | `guardedUnify` 296-325 | body lifted to a new top-level `guardedUnifyS : Variable -> Variable -> List Variable -> IO.State -> ( IO.State, Result UnifyErr (UnifyOk ()) )`; `guardedUnify left right = Unify (\vars s0 -> guardedUnifyS left right vars s0)` |
| same | NEW `unifyS`, `unifyBoolS`, `answerOkEmpty` (place after `unify`) | see §4 |
| `compiler/src/Compiler/MonoSolver/Store.elm` | export list 2-4 | `unifyStep` stays exported (new type); add `unifyStrict` |
| same | `unifyStep` 1034-1068 | becomes `Variable -> Variable -> S -> ( Bool, S )` (Bool entry, no text) |
| same | NEW `unifyStrict : Variable -> Variable -> Step ()` (right after it) | the old `unifyStep` semantics: `Err (UnifyMismatch "unify-fail …")` built ONLY on failure, byte-identical text |
| same | `unifyBestEffort` 1076-1084 | body becomes `let ( _, s1 ) = unifyStep v1 v2 s in Ok ( (), s1 )` (type unchanged `Step ()`) |
| same | `unifySlotWithSetSlow` 2106-2128, line 2128 `unifyStep slot setVar s2` | → `unifyStrict slot setVar s2` (deleted entirely in step 6) |
| same | doc comments 1127 ("full `unifyStep`") and 1335 ("`needSlow` → `unifyStep`") | reword to `unifyStrict` (step 6 deletes both paragraphs anyway) |
| `compiler/src/Compiler/MonoSolver/Translate.elm` | 1598 (`ctorNode`), 1615 (`enumNode`): `(Store.unifyStep annVar demandVar)` inside `Engine.andThen` | → `(Store.unifyStrict annVar demandVar)` (these propagate `Err`; type must stay `Step ()`) |
| same | `unifyStepCtx` 5264-5278 | `case Store.unifyStep v1 v2 s of` → `case Store.unifyStrict v1 v2 s of` (rest unchanged) |
| same | `unifyStepBestEffort` 5284-5291 | body → `Store.unifyBestEffort v1 v2 s` (or delete the function and rename its 11 callers — 178, 1255, 2195, 2206, 3812, 3895, 3913, 4819, 4890, 5335, 5775 — to `Store.unifyBestEffort`; keeping the local alias is the smaller edit) |
| `compiler/src/Compiler/MonoSolver/LssInfer.elm` | `applyFactsGo` 268-…, line 277 `Store.unifyStep repSlot slot s0` | → `Store.unifyStrict repSlot slot s0` (the surrounding `case afterRep of Err e -> Err e` stays) |
| same | 1847, 1948, 2923 `Store.unifyBestEffort …` | unchanged (type unchanged) |
| `compiler/src/Compiler/Type/Solve.elm` | 208, 235, 262, 289 `Unify.unify actual expected \|> IO.andThen …` | unchanged (wrapper keeps the `IO Answer` type) |

Every `unifyStep` caller, from grep (13 sites): Store 1078 (`unifyBestEffort`), Store 2128
(`unifySlotWithSetSlow`), Translate 1598, 1615, 5269 (`unifyStepCtx`), 5286 (`unifyStepBestEffort`),
LssInfer 277. Strict (Err-propagating): Translate 1598, 1615, 5269; LssInfer 277; Store 2128.
Recovering (state discarded on failure): Store 1078; Translate 5286. There are no others.

`Failure` consumers (from grep `UnifyMismatch`): manufactured at Store 1046 only; matched at
Translate 5273 (`unifyStepCtx` re-prefixes the text) and Monomorphize 5086 (`renderFailure`,
`"MonoSolver.unify-mismatch: " ++ msg`); recovered (any `Err _`) at Store 1082, Translate 5290 and
the three `Err _ ->` fallbacks of `classifyRef` (Translate 1952, 1959, 1964 — those catch
`loadType`/`injectArgLambdaMember`/`zonkToMono` failures, none of which is a `unifyStep`; they are
unaffected). This matches findings-A §0.5: `UnifyMismatch` is the ONLY recovered failure.

#### 4. Design

**Unify.elm — the entry twins.** `( IO.State, Result … )` (state first) is kept INSIDE Unify.elm
because that is the shape `Unify k` already produces; `unifyS`/`unifyBoolS` return `( a, IO.State )`
(value first) to match the `UnionFind`/`Store` direct-state convention that step 10 builds on.

```elm
module Compiler.Type.Unify exposing (Answer(..), unify, unifyBoolS, unifyS)

{-| The IO-typed entry the typechecker uses (Solve.elm ×4). A wrapper since 5a. -}
unify : Vars.Variable -> Vars.Variable -> IO Answer
unify v1 v2 s0 =
    let
        ( answer, s1 ) =
            unifyS v1 v2 s0
    in
    ( s1, answer )


{-| Direct-state entry: `guardedUnify`'s body run on an empty fresh-var
accumulator, then the success/error tail of the old `unify` — the two
`toErrorType` renders happen BEFORE the error union, exactly as before, so the
`AnswerErr` types show the partial merges the failed attempt made (the text the
MonoSolver's `UnifyMismatch` and the typechecker's `BadExpr` both render).
-}
unifyS : Vars.Variable -> Vars.Variable -> IO.State -> ( Answer, IO.State )
unifyS v1 v2 s0 =
    case guardedUnifyS v1 v2 [] s0 of
        ( s1, Ok (UnifyOk vars ()) ) ->
            ( answerOk vars, s1 )

        ( s1, Err (UnifyErr vars ()) ) ->
            let
                ( s2, t1 ) =
                    Type.toErrorType v1 s1

                ( s3, t2 ) =
                    Type.toErrorType v2 s2
            in
            ( AnswerErr vars t1 t2, UF.unionS v1 v2 errorDescriptor s3 )


{-| The recovering entry: `True` on success with the unified store; `False`
with the PRE-unify store `s0` (the failed attempt's partial merges are dropped,
which is what every best-effort caller did by hand). Renders no error types
and performs no error union — both are unobservable when the store is
discarded, and both were the whole cost of a best-effort failure.
-}
unifyBoolS : Vars.Variable -> Vars.Variable -> IO.State -> ( Bool, IO.State )
unifyBoolS v1 v2 s0 =
    case guardedUnifyS v1 v2 [] s0 of
        ( s1, Ok _ ) ->
            ( True, s1 )

        ( _, Err _ ) ->
            ( False, s0 )


{-| `AnswerOk []` is by far the common answer (fresh vars are registered only
by `unifyRecord` and the comparable arms); share it instead of allocating it.
-}
answerOk : List Vars.Variable -> Answer
answerOk vars =
    case vars of
        [] ->
            answerOkEmpty

        _ ->
            AnswerOk vars


answerOkEmpty : Answer
answerOkEmpty =
    AnswerOk []


{-| `guardedUnify`'s body as a saturated top-level function (the entry twins
call it directly; the combinator form below wraps it in the one closure the
CPS layer needs). Semantics and store-operation order unchanged.
-}
guardedUnifyS : Vars.Variable -> Vars.Variable -> List Vars.Variable -> IO.State -> ( IO.State, Result UnifyErr (UnifyOk ()) )
guardedUnifyS left right vars s0 =
    let
        ( equivalent, s1 ) =
            UF.equivalentS s0 left right
    in
    if equivalent then
        ( s1, Ok (UnifyOk vars ()) )

    else
        let
            ( leftDesc, s2 ) =
                UF.getS s1 left

            ( rightDesc, s3 ) =
                UF.getS s2 right
        in
        case actuallyUnify (makeContext left leftDesc right rightDesc) of
            Unify k ->
                k vars s3


guardedUnify : Vars.Variable -> Vars.Variable -> Unify ()
guardedUnify left right =
    Unify (\vars s0 -> guardedUnifyS left right vars s0)
```

Notes on the sketch:
- `Type.toErrorType : Variable -> IO ET.Type` (Type.elm 613) and `UF.unionS` (UnionFind 239) are
  called saturated; `IO.State` is the name UnionFind.elm already uses for the state alias.
- `errorDescriptor` (82-83) stays. `onSuccess` (77-78) is deleted.
- `guardedUnify` keeps the `\vars s0 ->` closure form on purpose: writing
  `Unify (guardedUnifyS left right)` would make `k vars s3` a PAP-extension call (a 4-ary function
  applied to 2, then 2 more) — the very dispatch this module's P3 comment (298-305) removed.
- `unifyBoolS`'s `( _, Err _ ) -> ( False, s0 )` is a `case` on the result spine with tuple-literal
  leaves in every arm, which `Backend.sretTailOk` (Generate/MLIR/Backend.elm: `MonoTupleCreate`,
  `MonoLet`, `MonoDestruct`, `MonoCase` admitted; `MonoIf` and everything else `-> False`) accepts
  for a zero-capture ≥1-param function — so it can get a heap-free `$sret` worker. Do NOT write it
  as `if ok then … else …`.

**Store.elm — the three entries.**

```elm
{-| Unify two store Points. `True` ⇒ the store is the unified one; `False` ⇒
`S` is returned UNCHANGED (pre-unify store: the failed attempt's partial
merges are not kept — Elm's persistent arrays make that free). Renders
nothing. This is the entry step 10 builds on.
-}
unifyStep : Vars.Variable -> Vars.Variable -> Engine.S -> ( Bool, Engine.S )
unifyStep v1 v2 s0 =
    let
        ( ok, store1 ) =
            Unify.unifyBoolS v1 v2 s0.store
    in
    ( ok, { s0 | store = store1 } )


{-| Strict unify: a mismatch is a compile-aborting `UnifyMismatch` carrying the
rendered types plus the spec/flush context. The two `Error.Type` renders and
the diagnostic string are built ONLY on the failure arm.
-}
unifyStrict : Vars.Variable -> Vars.Variable -> Step ()
unifyStrict v1 v2 s0 =
    case Unify.unifyS v1 v2 s0.store of
        ( Unify.AnswerOk _, store1 ) ->
            Ok ( (), { s0 | store = store1 } )

        ( Unify.AnswerErr _ t1 t2, _ ) ->
            Err
                (UnifyMismatch
                    ("unify-fail "
                        ++ errDeep t1
                        ++ " /vs/ "
                        ++ errDeep t2
                        ++ " [in "
                        ++ (case s0.currentGlobal of
                                Just g ->
                                    Mono.toComparableGlobal g

                                Nothing ->
                                    "?"
                           )
                        ++ " joinRounds="
                        ++ String.fromInt s0.lssStats.joinRounds
                        ++ " retrans="
                        ++ String.fromInt s0.lssStats.retranslations
                        ++ "]"
                    )
                )


unifyBestEffort : Vars.Variable -> Vars.Variable -> Step ()
unifyBestEffort v1 v2 s0 =
    let
        ( _, s1 ) =
            unifyStep v1 v2 s0
    in
    Ok ( (), s1 )
```

- `unifyStep`'s failure arm: `store1 == s0.store` (same pointer), so the `S` copy is a 31-word no-op
  copy on a rare path; it is written this way so the single leaf is a tuple literal (`$sret`
  admissible) rather than an `if` on the result spine.
- `unifyStrict`'s message text is character-for-character the old `unifyStep`'s (Store 1046-1064).
  The old code read `s.currentGlobal`/`s.lssStats` from the state AFTER `liftIO`; `liftIO` only
  rewrote `store`, so reading them from `s0` is the same value.
- The failure store of `unifyS` (post error-union) is dropped in `unifyStrict`; the old code also
  never observed it (an `Err` aborts the item; the three `classifyRef` fallbacks use their own
  earlier state).

**Translate.elm.** `unifyStepCtx` (5264-5278): only the callee name changes. `unifyStepBestEffort`
(5284-5291) becomes `unifyStepBestEffort = Store.unifyBestEffort` — do NOT eta-reduce it into a
point-free alias if the pre-mono η-expand/alias-forward cannot see through it; write
`unifyStepBestEffort v1 v2 s = Store.unifyBestEffort v1 v2 s` (saturated, no PAP).

**Order-of-evaluation constraints (must hold for BI):** (i) `equivalentS` → `getS left` → `getS right`
→ `actuallyUnify` order unchanged (path compression writes happen in `reprS`, so the ORDER of the two
`getS` calls fixes the compressed shape); (ii) on failure, `toErrorType v1` before `toErrorType v2`
before `unionS` (each `toErrorType` sets/restores marks; the union is last); (iii) `register` (139-147)
still conses fresh vars in the same order, so Solve's `introduce rank pools vars` sees the same list;
(iv) no new `UF.fresh` anywhere.

**5b — the combinator layer (separate loop entry; same module).** Keep `type Unify a` but change
its payload and re-spell the combinators directly:

```elm
type Unify a
    = Unify (List Vars.Variable -> IO.State -> ( IO.State, UResult a ))


{-| One constructor per outcome instead of `Result UnifyErr (UnifyOk a)`
(two objects per step become one). -}
type UResult a
    = UOk (List Vars.Variable) a
    | UErr (List Vars.Variable)


andThen : (a -> Unify b) -> Unify a -> Unify b
andThen callback (Unify ka) =
    Unify
        (\vars s0 ->
            case ka vars s0 of
                ( s1, UOk vars1 a ) ->
                    case callback a of
                        Unify kb ->
                            kb vars1 s1

                ( s1, UErr vars1 ) ->
                    ( s1, UErr vars1 )
        )


map : (a -> b) -> Unify a -> Unify b
map func (Unify kv) =
    Unify
        (\vars s0 ->
            case kv vars s0 of
                ( s1, UOk vars1 value ) ->
                    ( s1, UOk vars1 (func value) )

                ( s1, UErr vars1 ) ->
                    ( s1, UErr vars1 )
        )


pure : a -> Unify a
pure a =
    Unify (\vars s -> ( s, UOk vars a ))


mismatch : Unify a
mismatch =
    Unify (\vars s -> ( s, UErr vars ))


register : IO Vars.Variable -> Unify Vars.Variable
register mkVar =
    Unify
        (\vars s0 ->
            let
                ( s1, var ) =
                    mkVar s0
            in
            ( s1, UOk (var :: vars) var )
        )


try : Unify () -> Unify Bool
try (Unify u) =
    Unify
        (\vars s0 ->
            case u vars s0 of
                ( s1, UOk vs () ) ->
                    ( s1, UOk vs True )

                ( s1, UErr vs ) ->
                    ( s1, UOk vs False )
        )


merge : Context -> Vars.Content -> Unify ()
merge props content =
    Unify
        (\vars s0 ->
            ( UF.unionS props.var1 props.var2 (IO.makeDescriptor content (min props.desc1.rank props.desc2.rank) Type.noMark Nothing) s0
            , UOk vars ()
            )
        )


comparableOccursCheck : Context -> Unify ()
comparableOccursCheck props =
    Unify
        (\vars s0 ->
            let
                ( s1, hasOccurred ) =
                    Occurs.occurs props.var2 s0
            in
            if hasOccurred then
                ( s1, UErr vars )

            else
                ( s1, UOk vars () )
        )
```

`unifyComparableRecursive` (648-656): `register (\s -> let ( s1, d ) = UF.getS s var … UF.freshS …)`
— spell the two-step IO action with `UF.getS`/`UF.freshS` (value-first) and return `( s2, var )`
(state-first, because `register` takes an `IO`). The `Record1` arm (844-857): call `gatherFields`
twice saturated (`let ( s1, structure1 ) = gatherFields fields1 ext1 s0 …`) then `k vars s2`.
`gatherFields` (1030-1044) itself: `UF.getS` + tail recursion, no `IO.andThen`. `traverseAll`
(966-978), `forEach_`, `zipWithM_`, `zipAllWithM_`, `unifyField`, `fresh` need no edit — they are
written against `andThen`/`map`/`pure`/`mismatch`/`try`/`register`. `guardedUnifyS`/`unifyS`/
`unifyBoolS` from 5a match on `UOk`/`UErr` instead of `Ok (UnifyOk …)`/`Err (UnifyErr …)`; `UnifyOk`
and `UnifyErr` (95-99) are deleted. **Mint-order constraint for 5b:** `zipAllWithM_` (209-230) MUST
keep running the remaining pairs after a failed pair (`try` then recurse, then report) — the
"run-all-then-report" discipline mints the same fresh vars on the error path as today; a
short-circuiting rewrite would change Point indices on every typechecker error path and is NOT BI
for programs with type errors (E2E has such tests). `forEach_`/`zipWithM_` short-circuit today and
must stay short-circuiting.

#### 5. Edit sequence

Each edit leaves `elm make` green (`cd compiler && elm make src/Terminal/Main.elm --output=/dev/null`
or the 1-second type-check the loop doc names).

1. **Unify.elm:** add `guardedUnifyS`, rewrite `guardedUnify` as its one-closure wrapper. (No
   behaviour change; compiles alone.)
2. **Unify.elm:** add `answerOk`/`answerOkEmpty`, `unifyS`, `unifyBoolS`; rewrite `unify` as the
   wrapper; delete `onSuccess`; extend the module export list. `elm make` green; the typechecker
   already takes the new path through `unify`.
3. **Store.elm:** rename the old `unifyStep` to `unifyStrict` (body: the `case Unify.unifyS …`
   sketch), add the new `( Bool, S )` `unifyStep`, rewrite `unifyBestEffort`; change line 2128 to
   `unifyStrict`; export `unifyStrict`. This edit breaks the four external strict callers — do 4 in
   the same commit/snapshot (`elm make` is red between 3 and 4 only for the 13-line caller change).
4. **Translate.elm 1598, 1615, 5269** → `Store.unifyStrict`; **5284-5291** → delegate to
   `Store.unifyBestEffort`; **LssInfer.elm 277** → `Store.unifyStrict`. `elm make` green.
5. **Unit suite** (`cmake --build build --target elm-tests`) — no pin names any of these functions,
   so the suite is a regression check only.
6. (5b, its own loop entry) Change the `Unify` payload to `UResult`, rewrite the six combinators,
   `merge`, `comparableOccursCheck`, `unifyComparableRecursive`, the `Record1` arm, `gatherFields`;
   update the three 5a entries' pattern matches; delete `UnifyOk`/`UnifyErr`. One edit — the type
   change is not incrementally compilable.

#### 6. Verification

- **Type-check + unit:** `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt`
  (once). `TestLogic/Type/UnificationErrorsTest.elm` exercises the typechecker's error path through
  the `unify` wrapper (the rendered `BadExpr` types come from `unifyS`'s error arm).
- **Loop (benchmarks/lss-compile-opt-loop.md §2), byte-identical step:** Phase 1.3/1.4 produce
  `bin/eco5.mlir`/`bin/eco-opt5`; Phase 2 three cold runs; `cmp` r1/r2/r3 and
  `cmp bin/eco-opt5-r1-out.mlir bin/eco5.mlir` — MUST be identical (5a and 5b are substrate
  changes; a diff means a mint-order slip, most likely in 5b's `zipAllWithM_`/`register`).
- **E2E gate on a win:** `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt` (once;
  expected 893/895 per memory — the two AOT-runner gaps).
- **Attribution leg (untimed, separate):** the andThen-spec count from §2 before/after
  (`grep -c "System_TypeCheck_IO_andThen" $BK/bin/eco*.mlir`), and an `ECO_INLINE_ALLOC=0` lowering
  of both compilers to compare the Closure/Tuple2/Custom object deltas (the only honest allocation
  attribution — the timed run's `Objects allocated` undercounts ~6×). If the failure-path cost matters
  (`connectTypes` is best-effort and 7 % inclusive), a one-off counter of `unifyBoolS` False results
  is a 3-line local patch on a census binary — never in a timed run.
- **Error-text identity:** no test pins the MonoSolver's `unify-fail …` text. Prove it by
  construction (§4: same `errDeep`, same `t1`/`t2` rendered before the union, same context fields)
  and by reading the diff; optionally force a mismatch by editing a kernel annotation in a scratch
  copy and diffing the two compilers' stderr.

#### 7. Risks, gotchas, and what NOT to do

- **Do not** make `unifyBoolS` perform the error union or the `toErrorType` renders "for
  consistency": they mutate marks and union the two classes into an `Error` descriptor, and every
  best-effort caller discards that store anyway. Conversely, **do not** have `unifyStrict` call
  `unifyBoolS` and re-render on failure: rendering must happen on the PARTIALLY-MERGED store of the
  failed attempt (before the union) to reproduce today's text — `unifyS` is the only entry that has
  that store.
- **Do not** eta-reduce `guardedUnify` to `Unify (guardedUnifyS left right)` (PAP-extension calls
  in the hottest loop — the P3 comment at Unify.elm 298-305 is LOAD-BEARING).
- **Do not** write result spines with `if`: `sretTailOk` (Backend.elm) rejects `MonoIf`; use `case`
  with tuple-literal leaves, or push the branch into a tuple component.
- **Do not** touch `UF.equivalentS`/`getS` order or add a fast path that skips `getS` for
  `FlexVar`s — path compression in `reprS` writes, and the write order is part of the store shape.
- Step 10 will later crash-or-`Err` the strict callers; keep `unifyStrict : Step ()` now so the four
  strict sites (`ctorNode`, `enumNode`, `demandUnifyVar` via `unifyStepCtx`, `applyFactsGo`) stay
  `Result`-shaped until that policy decision is made (plan §3, "Result-to-crash policy").
- Plan §4 items NOT to re-open here: N2 (the LSS_010 flush loop — `joinRounds`/`retranslations`
  appear in the failure text and must keep being read from `s0.lssStats`), N5 (visited sets in
  `dedupeSources` — leave `List.member`).
- Invariants touched: TYPE_002 (every unification failure still produces an `Answer`-derived
  `Error.Type` — the `unify` wrapper preserves it), TYPE_004 (the occurs check still runs in the
  comparable arms — 5b re-spells `comparableOccursCheck`, it does not remove it), LSS_006/LSS_013
  (unchanged: `FunL x FunL` arm and slot ordinals are not edited), FORBID/CGEN rows are not touched
  (no codegen change). No invariant text needs amending; the `Unify` docstring (3-14) should mention
  `unifyS`.
- 32-slot record cap: not relevant (no record grows). `build-kernel/src` is a symlink: the loop's
  Phase 1.3 compiles `/work/compiler/src/Terminal/Main.elm` through it — edit the real tree.

#### 8. Effort

**5a: S-M** — ~120 lines across Unify/Store/Translate/LssInfer, one afternoon, mechanically
checkable. **5b: M** — the whole combinator layer plus four IO-flavoured helpers, one type change,
needs the fixed-point gate to be trusted. Run as two loop entries: `5a` (entry + Store/Translate
callers; the step-10 prerequisite) and `5b` (combinator layer + `UResult`); if 5b measures flat it
is reverted without touching 5a.

---

<details><summary>Conventions used in this spec (from spec-D)</summary>

All line numbers are as of the tree on 2026-09-19 (verified by `sed -n`/`grep -n` while writing this).
`Step a = S -> Result Failure ( a, S )` (Engine.elm 1616-1617); `IO a = State -> ( State, a )`
(IO.elm 87-88 — STATE FIRST); the direct-state convention of `UnionFind`/`Store.freshVarS` is
`( a, State )` — VALUE FIRST (UnionFind.elm 137-138, 148, 182, 277). Keep both conventions where
they are; the new functions below say which one they use.

---

</details>

### Step 6 (was 23a). Flag-residue and dead-arm cleanup that unblocks the direct-state rewrites

#### 1. Goal and expected effect

Delete code that LSS_041 (flags fixed at defaults, 2026-09-18) left unreachable or constant, so that
(a) `Store.foldSetWrites` loses its `Result` — the only reason it is `Step ()` is the deferred
`needSlow` list whose consumer `unifySlotWithSetSlow` calls the failing `unifyStep`; and (b) the
spine/successor injectors (`injectSpineMemberId`, `injectPapSuccessors`, `injectFoldedSuccessors`,
`injectPapSuccessorsFrom`) have no failing callee left below them, so step 10 can make them `S -> S`;
(c) `LoadCtx` loses two Bool fields and one always-true branch (step 8's `writeBackShared` rewrite
assumes it); (d) `LssZonkAcc` loses two Bool fields and two dead `else` arms; (e) the census-key
concatenations that run before the `report` gate are moved behind it; (f) two dead Translate
functions go. **Impact L** (a few objects per set-write traversal, one Bool test per arrow load, one
`Dict String` insert avoided on a few rare paths); **BI yes** — every deleted arm is either
unreachable (proved below) or measured 0 on the self-compile (`setWriteSlow = 0`, Run C). Minor GC
may move by a hair; wall flat. The value is enabling steps 8 and 10.

Each residue item, verified in the code NOW:

| item | evidence |
|---|---|
| `enqueueSpec` inner `if s0.env.lss.enabled` | Engine.elm 2110-2135: the outer test at 2114 routes `enabled` to `enqueueSpecKeyed`; the `else` arm re-tests `s0.env.lss.enabled` at 2119 — always False there |
| `LoadCtx.arrowIdOn` | Store.elm 65 (field, doc says "Always True from the solver"); set True at 107 (`sharedLoadCtx`) and 134 (`isolatedLoadCtx`); only `testLoadCtx` 80-92 can set False (param); read at 164 (`if c.arrowIdOn \|\| c.censusOn`) and 366 (`if not c2.arrowIdOn \|\| memoKey == 0`). Test: ArrowIdentityTest.elm 121-141 threads it; 171-176 is the single "flag OFF" case |
| `LoadCtx.arrowMintOn` | Store.elm 68; set at 91, 110, 142; **never read** (tree-wide grep: those four lines only) |
| `LssZonkAcc.groundStandalones` | Store.elm 2279; seeded True at 2382 (`zonkToMono`) and 2461 (`rezonkSettled`); read at 3060 and 3129 (`if acc0.groundStandalones then groundMembersC … else ( members0, c1 )`). LssHonestSourcesTest.elm 294 seeds False but only ever calls `resolveSlotMembers` (243, 182), which does not read it — the False seed is inert |
| `LssZonkAcc.honestSources` | Store.elm 2296; seeded True at 2382, 2461; read only via `honestSourcesOn` 3235-3242 from `resolveSlotMembers` 3215. LssHonestSourcesTest.elm 297 seeds `honest` (both values) and asserts both directions (its doc, 18-24, and 230); LssHonestSourcesPipelineTest reads the REPORT line `honestSources:` (Monomorphize 3758) — unrelated to the field |
| `unifySlotWithSetSlow` + `SetWriteCtx.needSlow` + `foldSlowWrites` + `LssStats.setWriteSlow` | Store.elm 2106-2128 / 1159 (field), 1179 (init `[]`), 1261-1266 (consumer in `foldSetWrites`), 1373-1378 (the only producer: the `_` defensive arm of `unifySlotWithSetC`), 1269-1281 (`foldSlowWrites`); Engine.elm 179 (field, "sustained 0 is the licence to delete it"), 521 (init); Monomorphize 3720 (report ` slow=`). No test names any of them (grep of compiler/tests: none) |
| `bumpArgFlowCensus` keys built before the gate | 98 call sites (Translate 59, LssInfer 20, Monomorphize 10, Engine 7 + 2 defs); 24 build the key with `++` on the call line. Mapping each to its enclosing function: 19 of the 24 are inside functions that already return early on `not s.env.lss.report` (`censusProducer` 374, `censusOneArg` 3605-3629 via `censusArgs` 3505, `censusStashMiss` 3969 via 3942, `argDeepCensus` 4298/4301 via 4251, `enrichCensus` 7293/7295 via 7258, `censusSignature` 944/945 via 925, `censusSigFacts` 741 via 731) or via a gated caller (`bumpAnnoCell` 7539 ← `caseAnnoCensus` 7456 / `destrAnnoCensus` 7561 / `destrBNowCensus` 7581). **The UNGATED `++` sites are five:** LssInfer 264-265 (`censusLenGuard`, called unconditionally from `applyFacts` 249), LssInfer 1026 (`censusMixedSig`, called from 1009), LssInfer 1576-1584 (`walkLiteral`, per literal walked — the only per-node one), LssInfer 1666 (`joinLiteralElems` `_` arm), Translate 4583-4585 (`injectPapMember`, `residualDepth > 1`). Translate 4440's `"k|" ++ home ++ "." ++ name` is a MEMBER key, not a census key — not residue |
| dead `unifyParamsWithArgs` / `unifyParamsBestEffort` in Translate | Translate.elm 5238-5262 and 3797-3828: tree-wide grep finds each referenced only by its own recursive call (5252, 3811) and doc prose (5031). The live sibling is `unifyParamsWithArgExprs` 3831 (callers 3356, 3787). **`LssInfer.unifyParamsBestEffort` 1927-1958 is a DIFFERENT, LIVE function** (called by `unifyCallShape` 1837) — do not delete it |

#### 2. Preconditions

- Step 5 is in (plan order). If it is not, the `unifyStep` at Store 2128 is deleted with its
  function either way.
- Re-run the residue greps before editing (any of these returning more than listed means the tree
  moved):
  ```bash
  grep -rn "\barrowMintOn\b\|\barrowIdOn\b\|\bgroundStandalones\b\|\bhonestSources\b\|\bneedSlow\b\|\bsetWriteSlow\b\|\bfoldSlowWrites\b\|\bunifySlotWithSetSlow\b" compiler/src compiler/tests --include=*.elm | grep -v ":\s*--"
  grep -rn "unifyParamsWithArgs\b\|unifyParamsBestEffort\b" compiler/src compiler/tests --include=*.elm | grep -v ":\s*--"
  ```
- Confirm the slow arm is still 0 on the current fixed point (untimed, report-on leg):
  `ECO_MONO_LSS_REPORT=1` self-compile per benchmarks/lss-opt.md and `grep -a "set-writes:" …stderr`
  → ` slow=0`. (It has been 0 since Run C; this is the licence the Engine.elm 179 comment demands.)

#### 3. Inventory of touched code

| file | function (lines now) | what changes |
|---|---|---|
| `Engine.elm` | `enqueueSpec` 2110-2160 | delete the inner `if s0.env.lss.enabled then … Intern.widenSets … getOrCreateSpecIdKeyed …` arm (2119-2131) and its comment; the `else` arm keeps only the `getOrCreateSpecId` path with `hit = Registry.CreatedNew` |
| `Engine.elm` | `LssStats` field `setWriteSlow` 179; initialiser 521 | delete the field and its `setWriteSlow = 0` |
| `Monomorphize.elm` | report line 3720 | drop `++ " slow=" ++ String.fromInt stats.setWriteSlow` |
| `Store.elm` | `LoadCtx` 58-70 | delete `arrowIdOn` (65) and `arrowMintOn` (68) |
| `Store.elm` | `testLoadCtx` 80-92 | signature → `Bool -> Dict Int Variable -> IO.State -> LoadCtx` (drop the `arrowIdOn` param and both field inits) |
| `Store.elm` | `sharedLoadCtx` 98-110, `isolatedLoadCtx` 125-143 | drop the two field inits (107/110, 134/142) |
| `Store.elm` | `writeBackShared` 147-170, line 164 | `if c.arrowIdOn \|\| c.censusOn then` → unconditional (the branch was always taken) |
| `Store.elm` | `loadTypeC` arrow arm, line 366 | `if not c2.arrowIdOn \|\| memoKey == 0 then` → `if memoKey == 0 then`; comment "Flag off, or `NoArrow`" → "`NoArrow`" |
| `Store.elm` | `SetWriteCtx` 1153-1164 | delete `needSlow`; `setWriteCtx` 1177-1179 drops `needSlow = []` |
| `Store.elm` | `foldSetWrites` 1224-1266 | type → `SetWriteCtx -> Engine.S -> Engine.S`; delete the `case c.needSlow of` tail; return `s1` |
| `Store.elm` | `foldSlowWrites` 1269-1281, `unifySlotWithSetSlow` 2106-2128 | delete both (and the doc paragraphs 1120-1135 "funneling it through … `unifyStep`" / 1146-1151 "`needSlow` collects …" / 1284-1286 "defers to the boundary via `needSlow`") |
| `Store.elm` | `unifySlotWithSetC` defensive `_` arm 1373-1378 | → write ⊤ (sketch in §4) |
| `Store.elm` | `unifySlotWithSet` 1137-1141 | body → `Ok ( (), foldSetWrites (…) s0 )` (type stays `Step ()` until step 10) |
| `Store.elm` | `poisonArrowSets` 2135-2141 | body → `Ok ( (), foldSetWrites (…) s0 )` |
| `Store.elm` | `LssZonkAcc` 2268-2300 | delete `groundStandalones` (2279) and `honestSources` (2296) with their comment blocks |
| `Store.elm` | seeds 2382 (`zonkToMono`), 2461 (`rezonkSettled`) | drop the two `= True` fields |
| `Store.elm` | `zonkSetSlot` 3060-3064, 3129-3133 | `if acc0.groundStandalones then groundMembersC … else ( members0, c1 )` → `groundMembersC paramT resultT members0 c1` (both sites) |
| `Store.elm` | `resolveSlotMembers` 3201-3226, `honestSourcesOn` 3235-3242 | `resolveSlotMembers = resolveSlotMembersWith True`; new exported `resolveSlotMembersWith : Bool -> …`; delete `honestSourcesOn` |
| `Store.elm` | export list 2-4 | add `resolveSlotMembersWith`; `testLoadCtx` type changes |
| `LssInfer.elm` | `spineGo` 2815-2818 | `Ok ( (), Store.foldSetWrites (…) s0 )` |
| `LssInfer.elm` | `injectPapSuccessorsFrom` 2591-2595, `injectPapSuccessors` 2641-2645, `injectFoldedSuccessors` 2671-2675 | `Ok ( (), Store.foldSetWrites (…) (Engine.bumpArgFlowCensus … s1) )` |
| `LssInfer.elm` | `censusLenGuard` 261-265 | prepend `if not s.env.lss.report then s else` |
| `LssInfer.elm` | `censusMixedSig` 1023-1026 | same gate |
| `LssInfer.elm` | `walkLiteral` 1576-1584 | replace the inline `Engine.bumpArgFlowCensus ("litFacts|" ++ form ++ …)` by a gated helper `censusLitFacts form honest s` |
| `LssInfer.elm` | `joinLiteralElems` 1666 | `Ok ( (), censusLitShapeMiss form s1 )` with a gated helper |
| `Translate.elm` | `injectPapMember` 4579-4586 | `if residualDepth > 1 then …` → `if residualDepth > 1 && s2.env.lss.report then …` |
| `Translate.elm` | `unifyParamsBestEffort` 3791-3828 (incl. doc), `unifyParamsWithArgs` 5234-5262 (incl. doc) | delete |
| `Translate.elm` | prose at 5031 mentioning `unifyParamsWithArgExprs` | unchanged (refers to the live one) |
| `compiler/tests/TestLogic/Monomorphize/ArrowIdentityTest.elm` | `loadInto` 121-136, `loadFresh` 140-141, every `loadFresh`/`loadInto` call (grep the file), test 171-176 | drop the leading `Bool` argument everywhere; **delete** the "flag OFF: sharing an ArrowId changes nothing" test (171-176) — it pins the removed regime |
| `compiler/tests/TestLogic/Monomorphize/LssHonestSourcesTest.elm` | `ctx` 283-300 (fields 294, 297), `LssAccShape` 348-360 (fields 350, 353), calls 182 and 243 | drop both fields from the shape and the builder (`ctx : Engine.LssMemberTable -> IO.State -> ZonkCtxShape`); calls become `Store.resolveSlotMembersWith honest members0 srcs (ctx table st)` |
| `compiler/tests/TestLogic/Monomorphize/LssHonestSourcesPipelineTest.elm` | — | untouched (does not build the accumulator) |
| `compiler/tests/TestLogic/Monomorphize/LssDirectedFlowTest.elm` | uses `Store.resolveSources`/`addSlotSource` (lines 6, 13) | untouched unless it builds a `SetWriteCtx`/`LssZonkAcc` literal — grep it for `needSlow`/`honestSources` (currently: no hits) |

Callers of `foldSetWrites` (all six, from grep): Store 1141, 2141; LssInfer 2593, 2643, 2673, 2818 —
every one is listed above. Callers of `testLoadCtx`: Store 80 (def), ArrowIdentityTest 124 only.

#### 4. Design

**(a) `enqueueSpec` else-arm after the deletion** (Engine.elm 2116-2160):
```elm
    else
        let
            ( specId, reg1 ) =
                Registry.getOrCreateSpecId global monoType s0.registry

            s =
                bumpKeyedHit Registry.CreatedNew s0

            storedChanged =
                False

            -- MONO_030: nextId growth is the created signal on this arm.
            watchdog =
                if reg1.nextId > s0.registry.nextId then
                    checkSpecWatchdogs global monoType reg1 s

                else
                    Nothing
        in
        case watchdog of
            Just failure ->
                Err failure

            Nothing ->
                enqueueSpecCommit specId reg1 storedChanged s
```
`bumpKeyedHit Registry.CreatedNew` is what the old code computed (`hit` was always `CreatedNew` on
this arm); `storedChanged = hit == Registry.HitChangedJoin` was therefore always `False`. This arm
is the lss-OFF path — not exercised by the loop workload (`ECO_MONO_LSS=1`), exercised by the
flag-off unit suites; keeping the two expressions literally equal keeps those byte-identical.

**(b)/(c) `LoadCtx` without the two Bools.** `writeBackShared` becomes:
```elm
writeBackShared c s =
    let
        aux =
            s.itemAux

        s1 =
            if c.slotsMinted == 0 then
                { s | store = c.store, memo = c.memo, revMemo = c.revMemo }

            else
                let
                    stats =
                        s.lssStats
                in
                { s | store = c.store, memo = c.memo, revMemo = c.revMemo, lssStats = { stats | slotsMinted = stats.slotsMinted + c.slotsMinted } }
    in
    { s1 | itemAux = { aux | arrowMemo = c.arrowMemo, arrowOfSlot = c.arrowOfSlot } }
```
(Still two `S` copies — folding them into one and skipping the `itemAux` write when the arrow memo
is unchanged is step 8's job, per plan; do not do it here or the step's win is misattributed.)
`loadTypeC` line 366: `if memoKey == 0 then mintFresh c2 else case Dict.get memoKey c2.arrowMemo of …`.

**(d) `groundStandalones`:** both reads become the unconditional `groundMembersC` call — LSS_019's
grounding is unconditional since 2026-08-19 (the invariant row already says DEFAULT-ON; amend the
row's "Under lss.groundStandalones" clause to "unconditionally" when you edit, or leave it — LSS_041
already declares every flag fixed).

**(e) `honestSources` — the test's own entry point:**
```elm
resolveSlotMembers : List Int -> List Vars.Variable -> ZonkCtx -> ( Maybe (List Int), ZonkCtx )
resolveSlotMembers =
    resolveSlotMembersWith True


{-| `resolveSlotMembers` with the LSS_026(a) honesty rule as a parameter.
Production is ALWAYS `True` (the rule is unconditional since 2026-08-23);
`False` exists only so `LssHonestSourcesTest` can pin the pre-rule reading —
the shape the rule exists to reject.
-}
resolveSlotMembersWith : Bool -> List Int -> List Vars.Variable -> ZonkCtx -> ( Maybe (List Int), ZonkCtx )
resolveSlotMembersWith honest members0 srcs c0 =
    case resolveSources srcs [] False (Just members0) c0 of
        ( Nothing, _, c1 ) ->
            ( Nothing, c1 )

        ( Just ms, sawFlex, c1 ) ->
            if sawFlex && not (List.isEmpty ms) then
                ( if honest then
                    Nothing

                  else
                    Just ms
                , bumpMixedFlexDemand ms c1
                )

            else
                ( Just ms, c1 )
```
The production call at 3092 (`zonkSetSlot`) is unchanged. `honestSourcesOn`'s `Nothing -> False`
arm (3241) was unreachable: 3092 sits under `case c1.lss of Just acc0`.

**(f) The set-write layer without the slow arm.** `SetWriteCtx` keeps `store, skip, flex, topJoin,
union, qOn, qLog` (7 fields). The defensive arm of `unifySlotWithSetC` (1373-1378) follows the
precedent already in `addSlotSource` (Store 2098-2104: "fail toward ⊤, never toward skip … ours
writes ⊤"):
```elm
        _ ->
            -- DEFENSIVE only: unreachable by closure of the slot-content
            -- channels (LSS_007); measured 0 across every self-compile since
            -- Run C. Fail toward ⊤ (sound: LSS_005 — LTop lowers to today's
            -- pipeline), never toward skip (a dropped write under-approximates).
            setRootC slot desc IO.lsTopContent { c1 | topJoin = c1.topJoin + 1 }
```
`foldSetWrites : SetWriteCtx -> Engine.S -> Engine.S` = the existing `s1` computation (1224-1258)
returned directly. The six callers wrap it in `Ok ( (), … )` for now; their own signatures
(`unifySlotWithSet`, `poisonArrowSets`, `spineGo`/`injectSpineMemberId`, the three `injectPap*`)
stay `Step ()` so that the 10 `injectSpineMemberId` call sites (LssInfer 163, 201, 209, 1809, 2510;
Translate 4137, 4425, 4454, 4466, 4592) and the 5 `injectPapSuccessors` sites (LssInfer 2536;
Translate 4392, 4400, 4404, 4415), most of them inside `Engine.andThen` chains, are untouched —
converting them is step 10's work and it needs exactly this: below `foldSetWrites` nothing can fail
any more. (`mintPapSuccessorIds` 2678-2690 is `Result`-typed by convention only: `memberIdFor`
1777-1787 and `papMemberIdFor` 1811-1825 never return `Err`. `injectLambdaMemberQualified`'s
`lambdaInstanceMemberId` CAN fail (Engine 666-700) — that stays above the injectors, in the caller.)

**(g) Census gates.** Pattern for the five ungated `++` sites:
```elm
censusLenGuard global sigN slotsN s =
    if not s.env.lss.report then
        s

    else
        s
            |> Engine.bumpArgFlowCensus "poison|lenGuard|all"
            |> Engine.bumpArgFlowCensus ("poison|lenGuard|" ++ TOpt.toComparableGlobal global)
            |> Engine.bumpArgFlowCensus ("poison|lenGuardShape|" ++ String.fromInt sigN ++ "->" ++ String.fromInt slotsN)
```
`censusMixedSig` identically. For `walkLiteral` 1576-1584 add
`censusLitFacts : String -> Bool -> Engine.S -> Engine.S` (gated, builds `"litFacts|" ++ form ++
(if honest then "|honest" else "|opaque")`) and call it in the tuple's second component; for
`joinLiteralElems` 1666 add `censusLitShapeMiss : String -> Engine.S -> Engine.S`; for Translate
4583 add `&& s2.env.lss.report` to the `residualDepth > 1` test. With `report` off none of these
sites ever ran the `Dict` insert (`bumpArgFlowCensus` 1104-1120 tests the gate itself), so the only
saving is the string concatenation and the call — measurable in nothing but honest.

**(h) Dead Translate helpers:** delete `unifyParamsBestEffort` (3797-3828 + doc 3791-3796) and
`unifyParamsWithArgs` (5238-5262 + doc 5234-5237). After the deletion `unifyStepCtx` has exactly one
caller (`demandUnifyVar` 102) and `canKind` keeps its callers; `Store.arrowParts`/`UF.get` keep
theirs. No test names either function.

**Order/mint constraints:** none of (a)-(h) changes a store write order, a member-id mint, a Point
mint, or an intern insertion on any reachable path. (f)'s deferred-write reorder (`needSlow` wrote
at traversal END) is moot because the arm never fired; if it ever does, the new inline ⊤ write is
at the visit point — a semantic change only on a path proven unreachable by LSS_007.

#### 5. Edit sequence

1. **Translate.elm:** delete `unifyParamsWithArgs` and Translate's `unifyParamsBestEffort` (with
   docs). `elm make` green (no callers).
2. **Engine.elm `enqueueSpec`:** delete the inner arm. `elm make` green. (Independent of everything
   else; the flag-off unit suites pin this path.)
3. **Store.elm `LoadCtx`:** delete `arrowMintOn` (field + 3 inits + `testLoadCtx` init) — green.
   Then delete `arrowIdOn` (field, 2 inits, `testLoadCtx` param, the reads at 164 and 366); in the
   SAME edit fix `ArrowIdentityTest.elm` (drop the Bool from `loadInto`/`loadFresh` and every call;
   delete the "flag OFF" test at 171-176). Green.
4. **Store.elm `LssZonkAcc`:** delete `groundStandalones` (field, 2 seeds, 2 `else` arms); delete
   `honestSources` (field, 2 seeds), add `resolveSlotMembersWith`, delete `honestSourcesOn`; in the
   SAME edit fix `LssHonestSourcesTest.elm` (`ctx`, `LssAccShape`, the two calls). Green.
5. **Store.elm set-write layer:** delete `unifySlotWithSetSlow`, `foldSlowWrites`, `needSlow`
   (field + init + producer arm → ⊤ write), change `foldSetWrites` to `S -> S`, wrap its two Store
   callers; **Engine.elm** delete `LssStats.setWriteSlow` + init; **Monomorphize.elm** drop ` slow=`
   from 3720; **LssInfer.elm** wrap the four `foldSetWrites` callers. One edit (the type change
   spans files). Green.
6. **Census gates** (LssInfer 261-265, 1023-1026, 1576-1584, 1666; Translate 4579-4586). Green.
7. Unit suite once: `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt`.
   Expected touched suites: `ArrowIdentityTest` (one test fewer), `LssHonestSourcesTest`
   (same assertions through `resolveSlotMembersWith`), `LssHonestSourcesPipelineTest` (unchanged).

Edits 1-6 are independent of one another (except that 5 must follow step 5's `unifyStrict` rename
or delete the function outright); they can be landed as one `try-6` snapshot.

#### 6. Verification

- **Unit:** the suite in edit 7; specifically `elm-test-rs --project build/compiler/build-xhr --fuzz 1`
  filtered to `ArrowIdentity`, `LssHonestSources`, `LssDirectedFlow` if a quick check is wanted.
- **Loop, byte-identical:** `cmp bin/eco-opt6-r1-out.mlir bin/eco6.mlir` and the r1/r2/r3 triple.
  Any diff here has exactly three possible sources: (f)'s ⊤ arm fired (it must not — grep the
  report leg for `topJoin` moving), (a)'s lss-off arm (not on this workload), or a test-only shape
  slip that would have failed `elm make` first.
- **E2E gate + rail:** `cmake --build build --target full` and, because Store/LssInfer changed,
  `benchmarks/mlir-workload-rail.sh` (633 workloads, MLIR sha256 + per-workload LSS census, ~70 s) —
  the census must be identical field-for-field; in particular `set-writes:` now prints no `slow=`
  and every other counter is unchanged.
- **Attribution:** none needed; the step is judged on "not a loss" + the counters. If it reads as a
  loss, it is noise (the change removes work) — re-run the triple before reverting.

#### 7. Risks, gotchas, and what NOT to do

- **Do not** delete `LssInfer.unifyParamsBestEffort` (1927-1958) — same name as the dead Translate
  one, different function, live (`unifyCallShape` 1837). The plan's "confirm tree-wide" resolves to:
  Translate's two are dead, LssInfer's is not.
- **Do not** replace the defensive arm with `Utils.Crash.crash`: FORBID_* and the addSlotSource
  precedent both say the LSS answer to an impossible slot content is ⊤ (LSS_005 makes it sound);
  a crash there would turn a precision bug into a compiler abort in user builds.
- **Do not** remove the `LsFrom` arm of `unifySlotWithSetC` (1334-1360) while touching its
  neighbour: the comment at 1335-1340 is LOAD-BEARING ("MANDATORY, not defensive: without it the
  `_` fallback would reroute to `needSlow`" — after this step, to the ⊤ write, which would silently
  drop sources). Update that comment's wording to name the ⊤ arm.
- **Do not** convert `unifySlotWithSet`/`poisonArrowSets`/the injectors to `S -> S` in this step:
  17+ call sites sit in `Engine.andThen` chains; that is step 10's measured entry, and doing it here
  makes step 6's row unattributable ("one step per iteration", loop doc §5).
- **Do not** fold `writeBackShared`'s two `S` copies into one here — step 8.
- `LssStats` is at/near the 32-field cap (findings-A: 32; C12 says "sits at the cap"). Deleting
  `setWriteSlow` frees one slot — do NOT spend it in this step; note it in the entry.
- Test fixtures build `ZonkCtx`/`LssZonkAcc` STRUCTURALLY (`LssHonestSourcesTest` 327: "`Store.ZonkCtx`
  is not exported by name; Elm's structural record aliases make the shape enough") — any field you
  delete from `LssZonkAcc` must be deleted from `LssAccShape` in the same edit or the test module
  stops compiling. Grep `compiler/tests` for `groundStandalones`/`honestSources` after editing
  (expect: only the Pipeline test's report-line string `"honestSources:"`, which stays).
- The `flag OFF` ArrowIdentity test being deleted is the LAST pin of the "mint a fresh slot per
  arrow POSITION" regime; LSS_006's AMENDED clause ("Under lss.arrowIdentity a position may REUSE a
  slot …") already describes the surviving behaviour and LSS_041 records the flag's removal — no
  invariant amendment needed, but say so in the entry.
- Invariants to quote in the entry: LSS_005 (⊤ arm), LSS_007 (why the arm is unreachable), LSS_019
  and LSS_026 (rules stay unconditional; only their Bool switches go), LSS_041 (the licence for all
  of it), MONO_030 (the watchdog in `enqueueSpec`'s surviving arm is untouched).
- Plan §4: N2 says do not touch the LSS_010 flush loop — `enqueueSpecCommit`'s `storedChanged`
  handling is that loop's arm; you only pass the literal `False` the old code already produced.

#### 8. Effort

**S** — ~150 deleted lines, ~40 added, three test files touched; half a day including the unit
suite. Single loop entry `6`; if the census-gate part (edit 6) is wanted separately for
attribution it can be `6b`, but it will not register on any stat and is better folded in.

<details><summary>Conventions used in this spec (from spec-D)</summary>

All line numbers are as of the tree on 2026-09-19 (verified by `sed -n`/`grep -n` while writing this).
`Step a = S -> Result Failure ( a, S )` (Engine.elm 1616-1617); `IO a = State -> ( State, a )`
(IO.elm 87-88 — STATE FIRST); the direct-state convention of `UnionFind`/`Store.freshVarS` is
`( a, State )` — VALUE FIRST (UnionFind.elm 137-138, 148, 182, 277). Keep both conventions where
they are; the new functions below say which one they use.

---

</details>

### Step 7 (was 10). Census bookkeeping off the default path

1. **Goal and expected effect.** Stop the default (report-off) path from copying `S` (32 refs) +
   `LssStats` (32 refs) per census event and from allocating a 22-field `LssZonkAcc` + `Just` +
   `ZonkCtx` + `Dict Int Int` insert per set readback. Plan §1 shares attacked: part of the GC 21 %
   (nursery churn) and the `zonkToMono` 11.8 % inclusive path. Measured multiplicities per
   self-compile: 654,140 set readbacks (each ~57 words / 5 objects of pure census garbage), every
   `zonkToMono` call with ≥ 1 set (S + LssStats + 2 closures + 2 `Dict.foldl` merges), 98K keyed
   hits, 83K layout-qualified mints (S + LssStats + LayoutQualStats, 73 refs), 43K completion joins,
   824,834 slot-minting loads (an extra S + LssStats copy each), 205K set-write traversals. Expected:
   minor-GC count down (order 1-2 %), wall down 2-4 % of the mono window, promoted MiB flat.
   **Emission must be byte-identical (BI)**: counters never influence a decision on the default path
   (verified per field in §3 below); under report every bump still fires, so the census text is
   also byte-identical.

2. **Preconditions.**
   - Step 6 landed: `grep -n "groundStandalones\|honestSources\|arrowIdOn\|arrowMintOn\|needSlow" compiler/src/Compiler/MonoSolver/Store.elm`
     returns nothing. If it has NOT landed, keep `honestSources : Bool` (seeded True) and
     `groundStandalones : Bool` as plain fields on the new `ZonkCtx` (they are policy bits, not
     counters) and keep `arrowIdOn` in `writeBackShared`'s guard; everything else below is unchanged.
   - Confirm the report-only claim mechanically before editing:
     `grep -n "stats\.\(setsZonked\|widenedBy[A-Za-z]*\|devirt[A-Za-z]*\|sizeHist\|declined[A-Za-z]*\|kernel[A-Za-z]*Hist\|setWrite[A-Za-z]*\|join[A-Za-z]*Hit\|joinNoop\|joinChanged\|completionJoin[A-Za-z]*\|slotsMinted\|grounding\|layoutQual\|unqualifiedLambdaMints\)" compiler/src/Compiler/MonoSolver/*.elm | grep -v "stats | "`
     — every hit must be in Monomorphize.elm inside `renderLssReport` (1418-3790) or a `{ stats | … }`
     writer. (Today: yes — the only non-report reads are `flexCtorSpecs` at 464, `joinRounds` at 3994,
     and the two error-text reads Store 1060/1062.)
   - Reference report text for the verification diff (§6): run the LAST KEPT compiler once with
     `ECO_MONO_LSS_REPORT=1` (untimed leg) and keep its stderr.

3. **Inventory — the definitive table.** Classes: **semantic** = read by a decision; **report-only** =
   read only by `renderLssReport`; **gated** = writer already tests `env.lss.report`/`censusOn`;
   **dead** = step 6 deletes it. "Copy" = what the default path pays per event today.

| field | written where (line) | gated today | read by (line) | class → step-7 action |
|---|---|---|---|---|
| `setsZonked` | Store.foldZonkStats 2556 ← `bumpZonkAcc` 3381/3384, `bumpWidenedAcc` 3365 (per set readback) | no | report 1754, 1767, 1769, 3676, 3678, 3689 | report-only → counted in `ZonkCensus` (Just iff report) |
| `flexCtorSpecs` (Dict) | Engine.markFlexCtorSpec 1098 ← Translate 3466 (slow-path ctor call whose arg has a var anno) | no — must not be | **Monomorphize.settleVarCtorRows 464** | **SEMANTIC — untouched** |
| `joinRounds` | Monomorphize.drain 4027 (per flush round, merged into the worklist update) | n/a | **drain 3994** (cap); Store 1060 (error text) | **SEMANTIC — untouched** |
| `retranslations` | Monomorphize.processItem 4082 (per re-translated item; already merged into the `resetItem` update 4077-4090) | no | report 3717; Store 1062 (error text) | free already — untouched |
| `widenedBySize` | foldZonkStats 2557 | no | report 1558, 3670, 3715 | report-only → `ZonkCensus` |
| `widenedByKernel` | Engine.bumpWidenedByKernel 954 ← Translate 1121, 5064, 5082, 5112, 5143; LssInfer 2185, 2279 | no | 3715 | report-only → gate the bumper |
| `widenedByBudget` | Engine.enqueueSpecKeyed 2366-2371 | over-budget arm only (never at default `maxSpecsPerGlobal = 0`) | 3715 | report-only → gate (step 15 restructures the site) |
| `devirtDirect` | Translate.bumpDevirtDirect 2812 ← 2261 | no | 3722 | report-only → gate |
| `devirtKernel` | Translate.bumpDevirtKernel 2821 ← 2312 | no | 3722 | report-only → gate |
| `sizeHist` (Dict) | foldZonkStats 2558 (merge) ← bumpZonkAcc 3384 (`Dict.insert` per within-cap readback) | **no** | 1446, 1451, 1533, 1545, 3689 | report-only → `ZonkCensus.hist` |
| `unqualifiedLambdaMints` | Engine.lambdaInstanceMemberId 690 | no (expected 0) | 3722 | report-only → gate |
| `declinedKernelShape` | Translate.bumpKernelDeclineShape 2832 ← 2293 | no | 3771 | report-only → gate |
| `declinedKernelCNumber` | Translate.bumpKernelDeclineEmission 2863 ← 2301 | no | 3771 | report-only → gate (before `isCNumber` is computed) |
| `declinedKernelEmission` | same 2866 | no | 3771 | report-only → gate |
| `declinedKernelArity` | Translate.recordKernelArityMiss 2735 ← 2603, 2668 | no | 3771 | report-only → gate |
| `kernelUnsolvedHist` (Dict String) | Translate.recordRefusedLicense ~2713-2718 ← 5051 | **yes**, at the caller 5049 | 3774, 3780 | gated — untouched |
| `kernelMissHist` (Dict String) | Translate.recordKernelMiss 2692 ← 2606, 2671 (builds `home ++ "." ++ name` + `Dict.update` per non-whitelisted kernel singleton site) | **no** | 1486, 1490 | report-only → gate at function top (string built under the gate) |
| `setWriteSkip/Flex/TopJoin/Union` | Store.foldSetWrites 1249-1256 (per traversal with any non-zero delta) | no | 3720 | report-only → gate the `lssStats` half of the update |
| `setWriteSlow` | Store.unifySlotWithSetSlow 2113 | dead arm | 3720 | dead — step 6 deletes |
| `joinIdenticalHit/joinNoop/joinChanged` | Engine.bumpKeyedHit 2228/2231/2234 ← 2144 (lss-off arm: always `CreatedNew`, no write), 2349 (keyed; 98K hits) | no | 3721 | report-only → gate |
| `completionJoins/completionJoinNoop` | Engine 2246 / 2262-2263 ← Monomorphize 4350 / 4353 (per body-bearing spec) | no | 3721 | report-only → gate |
| `widenedSizeHist` (Dict) | foldZonkStats 2559 ← bumpWidenedAcc 3367 | only over cap (never at `maxSetSize = 0`) | 1478, 1483 | report-only → `ZonkCensus.widenedHist` |
| `slotsMinted` | Store.writeBackShared 162 / writeBackIsolated 190 (per load with ≥ 1 mint) | no | 3720 | report-only → `if c.censusOn && c.slotsMinted > 0` |
| `grounding.{grounded,deferred}` | foldZonkStats 2560-2567 ← groundMembersC 3343-3346 | no | 3734 | report-only → `ZonkCensus`; the member-table write stays unconditional |
| `layoutQual.{mints,shared,fallback,tieBypass,instApplied}` | Engine.mintLayoutQualified 838-879 (83K) | no | 3741-3742 | report-only → `s2 = if report then … else s1` |
| `layoutQual.{instCapped,instRootSkip}` | Engine.bumpInstanceQual 596 ← 584, 611 | no | 3742 | report-only → gate |
| `sigStats.widenedBySigSize` | Engine 969 ← LssInfer 871, 1146 | no ("policy") | 3715 | report-only → gate |
| `sigStats.widenedByCf` | Engine 985 | yes 977 | 3751 | gated |
| `sigStats.kernelFactHits` | 1004 | yes 996 | 3751 | gated |
| `sigStats.kernelLicensed` | 1063 | yes 1055 | 3751 | gated |
| `sigStats.edgesInstalled` | 1023 ← Store.addSlotSource 2077 | yes 1015 | 3751 | gated |
| `sigStats.flowDegraded` | 1042 | yes 1034 | 3751 | gated |
| `sigStats.multiSetsByArrow` | foldZonkStats 2600-2606 ← noteMultiSet 2893 | `censusOn` + `Dict.isEmpty` 2590 | 1563, 3765, 3767 | gated |
| `sigStats.appliedArrows` | 1166 | yes 1155 | 3561 | gated |
| `sigStats.topMixedFlexSig` | Engine 1083 ← LssInfer 1009 | no (measured 0) | 3758 | report-only → gate |
| `sigStats.topMixedFlexDemand` | foldZonkStats 2595 ← bumpMixedFlexDemand 3251-3270 (ungated; also runs `Engine.membersClass` — a string classification — per mixed resolution) | no (measured 0) | 3758 | report-only → `ZonkCensus` |
| `sigStats.argFlowCensus` | bumpArgFlowCensus 1117 / By 1139; foldZonkStats 2607-2666 | yes 1106/1128; 2610 + `causesTotal` | 1530, 3766 | gated |
| `sigStats.settled` | Store.rezonkSettled 2506-2532; Engine.withScratchStore 2072 | yes 2450; 2061 | 1584 | gated |
| `sigStats.qShadow/qInfer` | Store.qShadowCensus ~1527; withScratchStore 2095 | yes (`qCensus`) | 1612/1615 | gated |

   Touched code:

| file | function (lines) | change |
|---|---|---|
| Store.elm | `LssZonkAcc` 2265-2357 | replaced by `ZonkCensus` (18 fields, counters only) |
| Store.elm | `ZonkCtx` 2216-2237 | `lss : Maybe LssZonkAcc` → `lssOn : Bool`, `maxSetSize : Int`, `census : Maybe ZonkCensus` |
| Store.elm | `bumpCauseC` 2362-2373 | becomes `bumpCensus : (ZonkCensus -> ZonkCensus) -> ZonkCtx -> ZonkCtx` (the one bump helper) |
| Store.elm | `zonkToMono` 2376-2421 | build `ZonkCtx` with `census = if enabled && report then Just emptyZonkCensus else Nothing` |
| Store.elm | `rezonkSettled` 2448-2532 | ctx literal 2461/2485 → `lssOn = True, census = Just emptyZonkCensus`; reads `acc.*` → `z.*` |
| Store.elm | `foldZonkStats` 2535-2669 | `case c.census of Nothing -> s; Just z -> <today's body>` |
| Store.elm | `zonkSetSlot` 3039-3165 | `case c1.lss of Just acc0 / Nothing` → `if c1.lssOn`; `acc0.maxSetSize` → `c1.maxSetSize`; `acc0.groundStandalones` gone (step 6) |
| Store.elm | `honestSourcesOn` 3235-3242 | gone with step 6 (else reads the plain Bool field) |
| Store.elm | `bumpMixedFlexDemand` 3251-3270, `groundMembersC` 3329-3348, `bumpWidenedAcc` 3354-3369, `bumpZonkAcc` 3372-3384, `noteMultiSet` 2893-2938, `noteArrowClass` ~2950-2990 | all go through `bumpCensus` (no-op when `Nothing`) |
| Store.elm | `writeBackShared` 150-172, `writeBackIsolated` 178-202 | one record update; `lssStats` only under `c.censusOn && c.slotsMinted > 0` |
| Store.elm | `foldSetWrites` 1224-1262 | `lssStats` half under `s0.env.lss.report` |
| Engine.elm | `bumpInstanceQual` 590-596, `lambdaInstanceMemberId` 686-690, `mintLayoutQualified` 838-879, `bumpWidenedByKernel` 948-954, `bumpWidenedBySigSize` 960-969, `bumpTopMixedFlexSig` 1074-1083, `bumpKeyedHit` 2217-2234, `bumpCompletionJoin` 2240-2246, `bumpCompletionJoinNoop` 2253-2265, `enqueueSpecKeyed` 2366-2371 | wrap in `if s.env.lss.report then … else s` |
| Translate.elm | `recordKernelMiss` 2679-2693, `recordKernelArityMiss` 2728-2735, `bumpDevirtDirect` 2806-2812, `bumpDevirtKernel` 2815-2821, `bumpKernelDeclineShape` 2826-2832, `bumpKernelDeclineEmission` 2843-2866 | same wrapper |
| Engine.elm | doc comments 142, 233-235, 284-290, 957-958, 1069-1072, 2205-2215 | "unconditional/policy" → "report-gated (step 7)" |
| tests/TestLogic/Monomorphize/LssHonestSourcesTest.elm | `ctx` 283-323, `ZonkCtxShape` 330-341, `LssAccShape` 345-367, `counter` 370-376 | new ctx shape (see §5 edit 3) |
| tests/TestLogic/Monomorphize/LssDirectedFlowTest.elm | `resolveAt` 178-192 | `lss = Nothing` → `lssOn = False, maxSetSize = 0, census = Nothing` |
| tests/TestLogic/Monomorphize/ArrowIdentityTest.elm | `loadInto` 118-135 | unchanged (reads `LoadCtx.slotsMinted`, which stays) |
| (7b only) Engine.elm | `ItemAux` 1414-1513, `emptyItemAux` 1518, `resetItem` 2433-2435; Monomorphize `finishNode` 4682-4711, `drain` result ~185 | `counters : ItemCounters` + `foldItemCounters` |

4. **Design.**

   **7a — the gate (this is the whole default-path win).** Every report-only writer tests
   `s.env.lss.report` FIRST and returns `s` untouched otherwise (the `bumpWidenedByCf` 975-988
   precedent, already used by 9 bumpers). The zonk side gets the same gate structurally: the
   counters live in `census : Maybe ZonkCensus` which is `Nothing` off report, so every bump is a
   `case` on a constant `Nothing` — no allocation, no `Dict.insert`, no `LssZonkAcc`.

   ```elm
   -- Store.elm, replaces LssZonkAcc (2265-2357). Counters ONLY; policy bits moved to ZonkCtx.
   type alias ZonkCensus =
       { zonked : Int, widenedBySize : Int
       , hist : Dict.Dict Int Int, widenedHist : Dict.Dict Int Int
       , grounded : Int, groundingDeferred : Int
       , mixedFlex : Int, mixedFlexGc : Int
       , causeSet : Int, causePoison : Int, causeFlex : Int
       , causeEdgeSet : Int, causeEdgeEmpty : Int, causeEdgeTop : Int, causeUnknown : Int
       , multiSets : Dict.Dict Int (List Int), varArrows : Dict.Dict Int Int, setArrows : Dict.Dict Int Int
       }                                                  -- 18 fields

   emptyZonkCensus : ZonkCensus                          -- a CAF: one allocation per run
   emptyZonkCensus =
       { zonked = 0, widenedBySize = 0, hist = Dict.empty, widenedHist = Dict.empty, grounded = 0, groundingDeferred = 0
       , mixedFlex = 0, mixedFlexGc = 0, causeSet = 0, causePoison = 0, causeFlex = 0, causeEdgeSet = 0
       , causeEdgeEmpty = 0, causeEdgeTop = 0, causeUnknown = 0, multiSets = Dict.empty, varArrows = Dict.empty, setArrows = Dict.empty }

   type alias ZonkCtx =
       { store : IO.State            -- removed by step 8
       , next : TypeIds.MVarId
       , lssOn : Bool                -- was `lss /= Nothing`: lss.enabled
       , maxSetSize : Int            -- policy (0 = unlimited), read on the LsMembers/LsFrom arms
       , census : Maybe ZonkCensus   -- Just iff lss.enabled && lss.report
       , ecoReads : List Vars.Variable, intern : Intern, memberTable : Engine.LssMemberTable
       , nextMemberId : Int, arrowOf : Dict.Dict Int Int, varOf : Dict.Dict Int Int, nextVar : Int
       }                                                  -- 12 fields (11 after step 8)

   bumpCensus : (ZonkCensus -> ZonkCensus) -> ZonkCtx -> ZonkCtx
   bumpCensus f c =
       case c.census of
           Nothing -> c                                   -- the default path: no allocation
           Just z -> { c | census = Just (f z) }
   ```

   Rewrites in `zonkSetSlot` (3039-3165), byte-for-byte the same counter arithmetic under report:
   - 3053: `( Mono.topOfKind tpK, bumpCensus (\z -> { z | zonked = z.zonked + 1, causePoison = z.causePoison + 1 }) c1 )`
   - 3056-3081: `if c1.lssOn then let (members, c2) = groundMembersC paramT resultT members0 c1 … if c1.maxSetSize > 0 && size > c1.maxSetSize then ( Mono.topWiden, bumpWidenedAcc size c2 ) else ( Mono.LSet members, noteArrowClass True setVar (noteMultiSet setVar members (bumpCensus (\z -> { z | zonked = z.zonked + 1, causeSet = z.causeSet + 1, hist = histInsert size z.hist }) c2)) ) else ( Mono.topEdge, c1 )`
     where `histInsert size h = Dict.insert size (1 + Maybe.withDefault 0 (Dict.get size h)) h` is the
     body of today's 3384. Same shape for the LsFrom arms 3095, 3115-3119, 3138-3142 and the
     FlexVar arm 3159-3165 (`causeFlex`/`causeEdgeEmpty`/`causeEdgeTop` + `causeUnknown` as today).
   - `bumpWidenedAcc size c = bumpCensus (\z -> { z | zonked = z.zonked + 1, widenedBySize = z.widenedBySize + 1, widenedHist = histInsert size z.widenedHist }) c`.
   - `groundMembersC` 3338-3347: `( r.members, bumpCensus (\z -> { z | grounded = z.grounded + r.grounded, groundingDeferred = z.groundingDeferred + r.deferred }) { c | memberTable = r.table, nextMemberId = r.nextId } )` — the table/supply write is NOT gated (LSS_019 rewrite is unconditional).
   - `bumpMixedFlexDemand members c = bumpCensus (\z -> { z | mixedFlex = z.mixedFlex + 1, mixedFlexGc = if Engine.membersClass members c.memberTable == "gc" then z.mixedFlexGc + 1 else z.mixedFlexGc }) c` — the `membersClass` string compare now runs only under report (its only consumer is `argFlowCensus` at 2610-2613, itself report-gated).
   - `noteMultiSet`/`noteArrowClass`: `case c.lss of Just acc -> if not acc.censusOn …` → `case c.census of Nothing -> c; Just z -> …` (they already return `c` when off; unchanged cost).
   - `foldZonkStats`: `case c.census of Nothing -> s; Just z -> …` with `acc` renamed `z`; keep the
     `z.zonked == 0 && z.widenedBySize == 0 && z.mixedFlex == 0` guard and everything after it verbatim.
   - `zonkToMono` 2380-2387: `zonkToMonoC s.superTable s.revMemo var { store = s.store, next = s.nextMVarId, lssOn = s.env.lss.enabled, maxSetSize = s.env.lss.maxSetSize, census = if s.env.lss.enabled && s.env.lss.report then Just emptyZonkCensus else Nothing, ecoReads = [], intern = s.intern, memberTable = s.lssMemberTable, nextMemberId = s.nextMemberId, arrowOf = s.itemAux.arrowOfSlot, varOf = Dict.empty, nextVar = 0 }`.
     The `lss.enabled = False` regime (still a supported configuration: Translate's 25 and Store's 8
     `if s.env.lss.enabled` arms are live) keeps `lssOn = False` ⇒ `zonkSetSlot` returns `topEdge` as today.

   Loads (`writeBackShared` 150-172; `writeBackIsolated` 178-202) — after step 6 the
   `if c.arrowIdOn || c.censusOn` is `True`, so the shape is one update plus a report-only rider:
   ```elm
   writeBackShared c s =
       let aux = s.itemAux
           s1 = { s | store = c.store, memo = c.memo, revMemo = c.revMemo
                    , itemAux = { aux | arrowMemo = c.arrowMemo, arrowOfSlot = c.arrowOfSlot } }
       in
       if c.censusOn && c.slotsMinted > 0 then
           let stats = s1.lssStats in { s1 | lssStats = { stats | slotsMinted = stats.slotsMinted + c.slotsMinted } }
       else s1
   ```
   (`writeBackIsolated`: same without `memo`/`arrowMemo`; `arrowOfSlot = c.arrowOfSlot` may be written
   unconditionally — off report it is the pointer `isolatedLoadCtx` 143 seeded from `s`.) `LoadCtx.slotsMinted`
   itself stays: `ArrowIdentityTest.loadInto` 132 reads it and the increment rides a ctx copy already made.

   Set writes (`foldSetWrites` 1224-1262): `if not s0.env.lss.report || (c.skip == 0 && c.flex == 0 && c.topJoin == 0 && c.union == 0) then { s0 | store = c.store } else <today's full update>`; `withQ` unchanged.

   Engine/Translate bumpers: mechanical `if s.env.lss.report then <today's body> else s`. In
   `mintLayoutQualified` 838-879 this is `s2 = if s1.env.lss.report then { s1 | lssStats = … } else s1`
   (the `lambdaQualified` insert 884-888 stays — it is LSS_018 semantics). In `bumpKeyedHit` keep the
   `CreatedNew -> s` arm and gate the three others. In `bumpKernelDeclineEmission` put the gate ABOVE
   `isCNumber` (2848-2860) so the `unboxedScalar` walks are not run off report. In `enqueueSpecKeyed`
   2366-2371: `lssStats = if underBudget || not s.env.lss.report then stats0 else { stats0 | widenedByBudget = … }`.

   **7b — `ItemAux.counters` (specified as the brief asks; read the verdict at the end).** For the
   REPORT-ON leg the gate still pays S + LssStats per event. Batching those per item:
   ```elm
   type alias ItemCounters =                            -- nested: ItemAux 13 → 14 fields (cap 32); 27 Ints
       { setsZonked : Int, widenedBySize : Int, grounded : Int, groundingDeferred : Int, mixedFlexDemand : Int
       , slotsMinted : Int
       , setWriteSkip : Int, setWriteFlex : Int, setWriteTopJoin : Int, setWriteUnion : Int
       , joinIdenticalHit : Int, joinNoop : Int, joinChanged : Int
       , completionJoins : Int, completionJoinNoop : Int
       , widenedByKernel : Int, devirtDirect : Int, devirtKernel : Int
       , declinedKernelShape : Int, declinedKernelCNumber : Int, declinedKernelEmission : Int, declinedKernelArity : Int
       , lqMints : Int, lqShared : Int, lqFallback : Int, lqTieBypass : Int, lqInstApplied : Int }

   -- ItemAux gets `counters : ItemCounters`; emptyItemAux seeds emptyItemCounters.
   -- NOT listed in clearedAux (1529-1531) / restoredAux (1537-1539): unlisted fields flow inner → outer through
   -- every scratch swap (withScratchStore 2042/2100; Translate.retranslateAt uses the same two helpers at ~6000/6017),
   -- so bumps inside a scratch store survive.

   foldItemCounters : S -> S
   foldItemCounters s =
       let c = s.itemAux.counters in
       if c == emptyItemCounters then s                  -- 27 Int compares; the common no-event case copies nothing
       else let stats = s.lssStats; sig = stats.sigStats; lq = stats.layoutQual; aux = s.itemAux in
            { s | lssStats = { stats | setsZonked = stats.setsZonked + c.setsZonked, … (one field per counter) …
                             , sigStats = { sig | topMixedFlexDemand = sig.topMixedFlexDemand + c.mixedFlexDemand }
                             , layoutQual = { lq | mints = lq.mints + c.lqMints, … } }
                , itemAux = { aux | counters = emptyItemCounters } }
   ```
   Fold placement (proof of no loss): every writer above runs between `Engine.resetItem`
   (Monomorphize 4078 — the ONLY caller) and the `finishNode` of the same item (4114, 4137, 4367; the
   completion join at 4350/4353 precedes 4367). So: (i) merge the fold into `finishNode`'s existing
   record update 4711-4718 (`itemAux = { aux | currentSpecId = Nothing, qLog = [], counters = emptyItemCounters }`,
   `lssStats = …`); (ii) defensively fold at the top of `resetItem` (`resetItem s = let s1 = foldItemCounters s in { s1 | … itemAux = emptyItemAux }`)
   — a no-op copy-free check when already folded; (iii) fold once more on `sDrained` before the settle
   chain (Monomorphize ~185) for anything after the last `finishNode` (there is none today:
   `grep -n "LssInfer.signatureFor\|Store.loadType" Monomorphize.elm` is empty).
   Per-event cost under report becomes ItemAux (14) + ItemCounters (28) + the S copy the site makes
   anyway, instead of S (32) + LssStats (32) (+ LayoutQualStats 8).
   **Verdict:** under 7a every counter 7b would hold is bumped only when `report` is on, and the loop
   never times a report-on run (§5 hygiene: no census variables in a timed leg). 7b therefore cannot
   move any of the five judged stats. Build 7a; build 7b only if a report-on census leg's wall becomes
   a problem, and then as its own entry (`7b`) with the report-text diff as its gate. Do NOT put
   `flexCtorSpecs`/`joinRounds`/`retranslations` in it (semantic; wrong write points).

   Invariants touched: LSS_019 (grounding rewrite stays unconditional; only its counters move),
   LSS_026 (resolution policy untouched — `resolveSources` 3273-3322 is not a census site),
   LSS_041 (no flag re-introduced: `report` is one of the 8 surviving env knobs), the 32-slot record
   cap (Engine 450-452 / 1352-1356: `S` 31 fields, `LssStats` 32, `ItemAux` 13→14, `ZonkCtx` 12 — all
   under; `ItemCounters` 27). No mint-order or intern-order effect: no member id, Point or intern
   insertion depends on any counter.

5. **Edit sequence** (each leaves `elm make compiler/src/Terminal/Main.elm` green).
   1. Engine.elm: gate `bumpKeyedHit`, `bumpCompletionJoin`, `bumpCompletionJoinNoop`, `bumpWidenedByKernel`,
      `bumpWidenedBySigSize`, `bumpTopMixedFlexSig`, `bumpInstanceQual`, the 686-690 arm, `mintLayoutQualified`'s
      `s2`, `enqueueSpecKeyed` 2366-2371; fix the six doc comments.
   2. Translate.elm: gate `recordKernelMiss`, `recordKernelArityMiss`, `bumpDevirtDirect`, `bumpDevirtKernel`,
      `bumpKernelDeclineShape`, `bumpKernelDeclineEmission`. Store.elm: `foldSetWrites` gate; `writeBackShared`/
      `writeBackIsolated` single update + rider. (Compile + `elm-tests` here: nothing structural has changed yet.)
   3. Store.elm: introduce `ZonkCensus`/`emptyZonkCensus`/`bumpCensus`, reshape `ZonkCtx`, rewrite `zonkToMono`,
      `rezonkSettled`, `foldZonkStats`, `zonkSetSlot`, `groundMembersC`, `bumpWidenedAcc`, `bumpMixedFlexDemand`,
      `noteMultiSet`, `noteArrowClass`; delete `bumpZonkAcc`/`bumpCauseC`. **Same edit**: LssHonestSourcesTest
      `ctx` 283-323 becomes `{ store = st, next = …, lssOn = True, maxSetSize = 8, census = Just { emptyZonkCensus | … } , ecoReads = [], … }`
      (the test can name `Store.emptyZonkCensus` if exported, else spell the 18 fields), `ZonkCtxShape`/`LssAccShape`
      330-367 follow, `counter get c = case c.census of Just z -> get z; Nothing -> -1` (370-376); whatever
      step 6 did with `honest` stays as step 6 left it. LssDirectedFlowTest `resolveAt` 178-192:
      `lss = Nothing` → `lssOn = False, maxSetSize = 0, census = Nothing`.
   4. (7b, optional, separate entry) `ItemCounters` + `foldItemCounters` + the 27 writers re-pointed + the three fold sites.

6. **Verification.**
   - Unit: `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt` — LssHonestSourcesTest
     (tests 1c/2b/3b assert `mixedFlex`/`mixedFlexGc` under `census = Just`), LssDirectedFlowTest,
     ArrowIdentityTest, LssHonestSourcesPipelineTest, PostSettleDevirtTest, LayoutQualTest, SpecWatchdogTest.
   - BI: loop Phase 2 `cmp` triple + fixed point (`cmp bin/eco-opt7-r1-out.mlir bin/eco7.mlir`).
   - Census exactness (the reconciliation proof), untimed leg:
     `rm -rf $BK/eco-stuff; (cd $BK && ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_MONO_LSS_REPORT=1 ./bin/eco-opt7 make --optimize --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp --output=bin/eco7-report-out.mlir /work/compiler/src/Terminal/Main.elm 2> report-7.stderr)`
     then `diff <(grep -a -A600 '=== LSS census ===' report-ref.stderr) <(grep -a -A600 '=== LSS census ===' report-7.stderr)` — must be EMPTY
     (every counter, `ledger … RECONCILES=yes`, `MATCHES=yes`, both histograms identical). This is
     stronger than the plan's "keep them exact under report": it proves it.
   - Rail: `benchmarks/mlir-workload-rail.sh` (sha256 + per-workload census, ~70 s) — must be identical.
   - Attribution (optional): `ECO_INLINE_ALLOC=0` lowering, compare Record/Custom/Tuple2 object counts;
     expect roughly −3.3M objects from readbacks + −(2 × zonkToMono-with-sets calls) records.
   - Loop triple: expect minor GC count down first (deterministic), wall second.

7. **Risks, gotchas, what NOT to do.**
   - LOAD-BEARING: `rezonkSettled`'s READ-ONLY discipline (Store 2430-2436) — it drops the final ctx and
     reads only `ctx.census`; keep that. The `zonkLog` push at 2410-2419 stays report-gated.
   - `bumpMixedFlexDemand` currently runs `membersClass` off report; gating it is safe because
     `mixedFlexGc` feeds only `argFlowCensus` (2610-2613, report-gated). The POLICY (`Nothing` on mixed) is
     in `resolveSlotMembers` 3208-3221 and is untouched.
   - `foldZonkStats`'s `s.currentGlobal` string 2623-2629 and 14 `bumpCensusKey` calls stay under
     `causesTotal /= 0`, which is 0 off report — already free; do not restructure it.
   - Do NOT gate `markFlexCtorSpec` (Translate 3466; `settleVarCtorRows` 464 reads it), `joinRounds`
     (`drain` 3994 caps on it — an ungated cap becoming gated would change the flush-loop behaviour) or
     `retranslations`.
   - `LssHonestSourcesTest` seeds `censusOn = True` and asserts counters are FLAG-INDEPENDENT of the
     policy — under the new shape "flag-independent" means `census = Just` regardless of the honest bit;
     keep that pairing when rewriting the fixture.
   - `Engine.emptyLssStats` 519-521 and `SigFlowStats` stay 32/15 fields — no field is removed (the
     report renders all of them).
   - Plan §4 N7: everything else in the census is ALREADY gated (`rezonkSettled`, `qShadowCensus`,
     `noteArrow`, `zonkLog`, `bumpEdgeInstalled`, `bumpArgFlowCensus`, `noteApplied`); do not touch them.
     N14: `withIntern`, `memberIdFor`'s hit path and `enqueueSpecCommit` already avoid copies.
   - `build/compiler/build-kernel/src` is a symlink to `compiler/src` — edit only under `/work/compiler/src`;
     `rm -rf $BK/eco-stuff` before every build (mtime cache).

8. **Effort: S** (7a ≈ 25 mechanical gates + one ctx reshape + two test fixtures; one loop entry). 7b is
   a separate S entry that by construction cannot move the judged stats — recommend skipping it.

---

<details><summary>Conventions used in this spec (from spec-F)</summary>

Line numbers are from the tree as read on 2026-09-19 (Store.elm 3722 ln, Engine.elm 2823, Translate.elm
8263, Monomorphize.elm 5097, LssInfer.elm 3597, UnionFind.elm 299). Every writer/reader below was
verified by `grep -n "lssStats = " MonoSolver/*.elm` (34 hits), `grep -n "UF\.\(get\|repr\|equivalent\|set\)\b"`
(48 hits) and `grep -n "store = store[0-9]"` (31 hits), not from memory.

Shared finding that shapes all three steps: **every `LssStats`/`SigFlowStats` field except
`flexCtorSpecs`, `joinRounds` and `retranslations` is read ONLY inside `Monomorphize.renderLssReport`
(1418-…), which is rendered only when `lssConfig.report` (Monomorphize 197-201).** `setsZonked` is
"reconciled" against `sigStats.settled.zonked` at 1754 — but that reconciliation is itself a report
line, and `settled` is populated only under report (`rezonkSettled` 2450). So the census can be
report-gated wholesale at zero semantic cost, and `lss.report` is excluded from the config hash
(Engine 1172-1176: "a report-on run must produce the same artifact as a report-off one"), so gating
cannot move emission.

---

</details>

### Step 8 (was 11). Stop copying `S` for reads that change nothing

1. **Goal and expected effect.** Remove the state copy that follows every PURE union-find read:
   `UF.getS` (UnionFind 182-199) returns the SAME store for a root or one-link chain, yet every
   MonoSolver read site rebuilds its context — `{ c0 | store = store1 }` per zonked NODE
   (`zonkToMonoC` 2690, ~2-3M ctx copies of 11 refs per run), per source in `resolveSources` 3296, per
   visited node in `poisonGoC` 2167 and the LssInfer spine walkers, `{ s | store = store1 }` (a 32-ref `S`
   copy) at 15 LssInfer sites and 6 Translate `liftIO (UF.get …)` sites (closure + `Ok` + tuple + `S`),
   three `liftIO`s per installed edge in `addSlotSource` 2035-2103, plus the two structural copies:
   `writeBackShared` (2 × S + ItemAux per load, ~10^6-10^7 loads) and `classifyGo`'s TVar-miss arm
   (S + ItemAux + cons per erased-var occurrence, 3546-3557). Plan §1 shares: UnionFind 2.9 % self,
   `zonkToMono` 11.8 % incl., `Translate.classify` 19.3 % incl., GC 21 %. Expected: wall −2-3 % of the
   mono window, minor GC down. **BI**: path compression is unobservable (proof in §4); skipping a record
   update whose fields would be pointer-identical is unobservable; the MONO_029 list is reproduced
   element-for-element.

2. **Preconditions.** Steps 6 and 7 in (`ZonkCtx` already has no `lss : Maybe …`; `writeBackShared` has
   no `arrowIdOn`). Verify the read-site census is still what this spec lists:
   `grep -n "UF\.\(get\|repr\|equivalent\)\b" compiler/src/Compiler/MonoSolver/*.elm | wc -l` → 46 (code sites:
   Store 15, LssInfer 17, Translate 6, Engine 1, Monomorphize 2; plus 5 doc-comment lines — Engine 317,
   Store 1394/1399/1540/2213; re-counted 2026-09-19 against the base snapshot, the first draft said 40/Store 12
   — a miscount, the inventory below was already complete); and that nothing but UnionFind
   reads chain shapes: `grep -rn "Vars.Chain\|readPointCellS" compiler/src/Compiler --include=*.elm | grep -v "Type/UnionFind.elm\|Data/IORef.elm"` → empty.

3. **Inventory of touched code.**

| file | function (lines) | change |
|---|---|---|
| Type/UnionFind.elm | exports 1-4; new `peekS`, `rootQ`, `equivalentQ` after `redundantQ` 292-299 | three pure readers |
| MonoSolver/Engine.elm | new `peekVar : Vars.Variable -> Step Vars.Descriptor` next to `liftIO` 1732-1739 | Step-shaped pure read, no `S` copy |
| Engine.elm | `harvestSuperTableExcept` 2659-2690 | `UF.get (Vars.Pt pointIdx) store` → `UF.peekS`; drop the `store` half of the fold accumulator |
| Store.elm | `ZonkCtx` 2216 | drop `store`; `store : IO.State` becomes a positional arg of every zonk helper |
| Store.elm | `zonkToMono` 2376-2421 | pass `s.store`; single guarded write-back (sketch §4) |
| Store.elm | `rezonkSettled` 2475/2485 | pass `s.store`; ctx literal without `store` |
| Store.elm | `zonkToMonoC` 2684-2727, `residualWithTaintC` 2730, `zonkFlatC` 2769-2845, `zonkListC` 3387, `zonkRecordFieldsC` 3407, `zonkRecordExtC` 3424 | `store` param threaded; `UF.get` 2688 → `UF.peekS store var`; `c1` deleted |
| Store.elm | `varNumberFor` 2863-2879 | `UF.rootQ store setVar`; hit arm returns `( n, c )` (no copy) |
| Store.elm | `noteMultiSet` 2893-2938, `noteArrowClass` ~2950-2990 | `rootQ`; `Nothing -> c` (no copy) |
| Store.elm | `zonkSetSlot` 3039-3165 | `store` param; `UF.get` 3043 → `peekS`; `c1 := c0` |
| Store.elm | `resolveSlotMembers` 3201-3227, `resolveSources` 3273-3322 | `store` param; 3293 → `peekS`; `c1 := c0` |
| Store.elm | `poisonGoC` 2144-2202 | 2164 → `UF.peekS c0.store v`; `c1` deleted (SetWriteCtx keeps `store`: `unifySlotWithSetC` writes) |
| Store.elm | `addSlotSource` 2035-2103 | direct-state rewrite (sketch §4): one `S` copy per installed edge |
| Store.elm | `classifyDirect` 3522-3524, `classifyGo` 3527-3633, `classifyList` 3636, `classifyAliasArgs` 3656, `classifyRecordExt` 3671, `classifyRecordFields` 3693 | MONO_029 accumulator (sketch §4) |
| Store.elm | `writeBackShared` 150-172, `writeBackIsolated` 178-202 | guard the `itemAux` half (sketch §4) |
| Translate.elm | 3867, 4828, 5166 (`case Engine.liftIO (UF.get v) s0 of`) | `let desc = UF.peekS s0.store v in …`, `s1 := s0`, dead `Err` arm removed |
| Translate.elm | 3819, 5261, 5362 (`(Engine.liftIO (UF.get funcVar))` as an `andThen` argument) | `(Engine.peekVar funcVar)` |
| LssInfer.elm | 1647 (`joinLiteralElems`) | `Engine.peekVar litVar` |
| LssInfer.elm | 837-840, 1068-1071 (`sigEdgesGo`), 1936-1939 (`unifyParamsBestEffort`), 2021-2024, 3135-3138 (`storeMentionsArrowGo`), 3328-3331 | `UF.peekS sN.store v`; the `{ sN | store = store1 }` copy deleted |
| LssInfer.elm | 1122-1125 (`ordinalOfGo`), 1169-1175 (`repOrdinal`) | `UF.equivalentQ s0.store a b`; copies deleted |
| LssInfer.elm | 1906-1909 (`noteApplied`) | `UF.rootQ sA.store pSet`; copy deleted |
| LssInfer.elm | 2713-2716 (`papSuccGoC`), 2748-2751 (`papSuccWrite`), 2837-2840 (`spineGoC`) | `UF.peekS c0.store v`; `c1 := c0` |
| LssInfer.elm | 2911-2917 (`joinArrowSets`), 3021-3027 (`flowArrowSets`) | two `peekS`; `s1 := s0` |
| Monomorphize.elm | 4762 (`staleVarRead`), 4772 (`varResolvedNow`) | `equivalentQ` / `peekS` |
| tests LssHonestSourcesTest.elm `ctx`/`runResolve` 233-323; LssDirectedFlowTest.elm `resolveAt` 178-192 | drop `store` from the ctx literal; pass `st` as the new argument of `Store.resolveSlotMembers` |
| tests ArrowIdentityTest.elm | none (LoadCtx unchanged) |

   NOT converted (write paths; the write re-walks anyway): `unifySlotWithSetC` 1292-1299 + `setRootC`
   1381-1387, `Unify.elm` 317/320 (typechecker), the q-census readers 1574/1588/1685/1985 (report-gated),
   `Engine.freshVar` 1752, `Store.freshVarC` 471, `monoTypeToVar` 704 (mints).

4. **Design.**

   **`UF.peekS` and friends** — pure walks of ANY depth; never write:
   ```elm
   -- Type/UnionFind.elm (add to the export list; keep getS/reprS/setS untouched)
   {-| Read a descriptor WITHOUT path compression. Pure at every depth. Use at read-only sites;
   a site that goes on to write the same Point keeps getS/setS (the write walks anyway). -}
   peekS : IO.State -> Vars.Point -> Descriptor
   peekS s (Vars.Pt ref) =
       case IORef.readPointCellS s ref of
           Vars.Root _ desc -> desc
           Vars.Chain parent -> peekS s parent

   rootQ : IO.State -> Vars.Point -> Vars.Point
   rootQ s ((Vars.Pt ref) as point) =
       case IORef.readPointCellS s ref of
           Vars.Root _ _ -> point
           Vars.Chain parent -> rootQ s parent

   equivalentQ : IO.State -> Vars.Point -> Vars.Point -> Bool
   equivalentQ s p1 p2 =
       IO.pointKey (rootQ s p1) == IO.pointKey (rootQ s p2)     -- Int compare, not generic == on Pt
   ```
   Why this is byte-identical: `reprS` compression (166-175) rewrites `Chain` cells to point nearer the
   root; it changes no `Root`, no weight, no descriptor. Union-by-weight (`unionS` 239-274) chooses the
   root from weights and pointer identity of the two roots, both compression-independent. Every later
   `getS`/`reprS`/`setS`/`unionS` therefore returns/writes exactly what it would have, and nothing outside
   UnionFind inspects `Chain` cells (precondition grep). Chains are ≤ log2(weight) deep (≤ 17 at 10^5
   points; "root or one-link — the overwhelmingly common case", 178-180), and `Unify`'s own reads still
   compress. "When it must fall back to getS": never for correctness — only at sites that subsequently
   WRITE the Point (they keep `getS`/`setS` as today).

   **`Engine.peekVar`** (replaces the 7 `liftIO (UF.get v)` forms with zero `S` copy until step 10 removes the `Ok`/tuple):
   ```elm
   peekVar : Vars.Variable -> Step Vars.Descriptor
   peekVar v s = Ok ( UF.peekS s.store v, s )
   ```

   **`ZonkCtx` without `store`.** Signatures become
   `zonkToMonoC : Dict Int SuperType -> Array (Maybe MVarId) -> IO.State -> Variable -> ZonkCtx -> Result Failure ( MonoType, ZonkCtx )`
   and likewise `zonkFlatC`/`zonkListC`/`zonkRecordFieldsC`/`zonkRecordExtC`/`zonkSetSlot`/`resolveSlotMembers`/
   `resolveSources`/`varNumberFor`/`noteMultiSet`/`noteArrowClass` take `store` positionally (same style as
   `superTable`/`revMemo`). Proof the store is never written during a zonk: the only store touches in the
   whole zonk family are `UF.get` (2688, 3043, 3293) and `UF.repr` (2867, 2910, 2964) — all reads;
   `groundMembersC` writes the member table, not the store. After this change `rezonkSettled`'s
   "READ-ONLY BY CONSTRUCTION" (2430) is enforced by the types.

   **Single guarded write-back in `zonkToMono`** (step 7 already made `foldZonkStats` free off report):
   ```elm
   zonkToMono var s =
       case zonkToMonoC s.superTable s.revMemo s.store var (zonkCtx0 s) of      -- zonkCtx0 = step 7's literal minus `store`
           Err e -> Err e
           Ok ( mt, c ) ->
               let
                   changed = c.next /= s.nextMVarId
                             || Intern.size c.intern /= Intern.size s.intern
                             || c.nextMemberId /= s.nextMemberId               -- covers memberTable: it changes only on a fresh intern (Engine 1760-1767)
                   auxNeeded = not (List.isEmpty c.ecoReads) || s.env.lss.report
               in
               if not changed && not auxNeeded then
                   Ok ( mt, s )                                                -- the common ground/arrow-free case: ZERO copies
               else
                   let aux0 = s.itemAux
                       aux1 = if auxNeeded then
                                  { aux0 | ecoResidualReads = c.ecoReads ++ aux0.ecoResidualReads      -- same order as today (2403)
                                         , zonkLog = if s.env.lss.report then var :: aux0.zonkLog else aux0.zonkLog }
                              else aux0
                   in
                   Ok ( mt, foldZonkStats c { s | nextMVarId = c.next, intern = c.intern, lssMemberTable = c.memberTable
                                               , nextMemberId = c.nextMemberId, itemAux = aux1 } )
   ```
   (Today: `s1` = S copy always, `s2` = second S copy under report, `foldZonkStats` = third + LssStats.)

   **`writeBackShared` guard** (on top of step 7's shape). `arrowMemo` can only change on the miss path
   of the `TLambda` arm (Store 385-395), which also does `slotsMinted + 1`; `arrowOfSlot` changes only when
   `censusOn`. Hence:
   ```elm
   writeBackShared c s =
       if c.slotsMinted == 0 && not c.censusOn then
           { s | store = c.store, memo = c.memo, revMemo = c.revMemo }          -- one S copy, no ItemAux
       else <step 7's fused update>
   ```
   Same guard in `writeBackIsolated` (`c.slotsMinted == 0 && not c.censusOn` → `{ s | store, revMemo }`).
   No new `memoInserts` flag is needed: the mint counter already implies it. Phase 2a H1 (isolated loads
   never write `arrowMemo`, 115-124) unchanged.

   **`addSlotSource` direct-state** (per installed edge: one `S` copy instead of 3 `liftIO` closures + 3 `Ok`/tuple + 3 `S`):
   ```elm
   addSlotSource src dst s0 =
       let store0 = s0.store in
       if UF.equivalentQ store0 src dst then Ok ( (), s0 )
       else
           let desc = UF.peekS store0 dst
               s1 = if qOnFor s0 then
                        let aux = s0.itemAux in
                        { s0 | itemAux = { aux | qLog = Engine.QEdge dst src (qPreOf desc) (qPreOf (UF.peekS store0 src)) :: aux.qLog } }
                    else s0
               write content = Ok ( (), Engine.bumpEdgeInstalled { s1 | store = UF.setS dst { desc | content = content } s1.store } )
           in
           case desc.content of
               … the five arms of 2078-2103 verbatim, `Ok ( (), s2 )` → `Ok ( (), s1 )` …
   ```
   `UF.setS` (201-217) re-walks and writes the root — the same cell `UF.set` wrote. LSS_023's "who may
   mint `LsFrom`" claim is untouched (callers LssInfer 339, 3033 unchanged).

   **MONO_029 read-list accumulator for `classifyGo`.** Thread `reads : List Int` positionally and
   return it as the third tuple component; write `itemAux` once at `classifyDirect`:
   ```elm
   classifyDirect topKind canType s =
       case classifyGo topKind s Dict.empty [] canType of
           Err e -> Err e
           Ok ( mono, s1, [] ) -> Ok ( mono, s1 )                              -- no erased-var miss: no ItemAux copy
           Ok ( mono, s1, reads ) ->
               let aux = s1.itemAux in
               Ok ( mono, { s1 | itemAux = { aux | ecoResidualKeyReads = reads ++ aux.ecoResidualKeyReads } } )

   classifyGo : Int -> Engine.S -> Dict.Dict Int Mono.MonoType -> List Int -> Can.Type TypeIds.MVarId -> Result Failure ( Mono.MonoType, Engine.S, List Int )
   -- TVar arm 3546-3557 becomes:
   --   Mono.MVar _ Mono.CEcoValue -> Ok ( Mono.MVar mvarId Mono.CEcoValue, s, key :: reads )
   -- memo-hit arm 3541-3544: case zonkToMono pt s of Err e -> Err e; Ok ( m, s1 ) -> Ok ( m, s1, reads )
   -- every structural arm / helper threads `reads` in evaluation order exactly as it threads `s`.
   ```
   Order proof: today occurrence i does `key_i :: older` at its own time, so the item list ends as
   `k_n :: … :: k_1 :: older` (walk order). The accumulator starts `[]` and conses in the same walk
   order, ending `k_n :: … :: k_1`; `reads ++ older` is identical, element for element, multiplicity
   kept (no dedupe — although the consumer `Monomorphize` 4736-4744 is `List.any`, keep it exact). The
   memo-hit `zonkToMono` writes the OTHER field (`ecoResidualReads`, Variables) immediately, as today;
   the deferred key write reads `s1.itemAux`, which already includes those. `classifyDirect`'s signature
   (`Step MonoType`) is unchanged, so `Translate.classify` 61-66 / `classifyAs` 73-78 and their ~23
   callers do not move. Per node: a 3-tuple (+1 word over today's pair) against S + ItemAux (46 refs) saved
   per TVar-miss occurrence; step 10's `$sret` admits `MTuple 3` (CGEN_067) and removes the tuple.
   Do NOT cache `pointKey → MonoType` inside a classify (C4): a Point without a `revMemo` entry mints a
   FRESH residual id per zonk (`residualIdC` 2757-2766), so two hits legitimately differ.

   Invariants: MONO_029 (barrier list identical), LSS_006 (ordinals: `arrowSlots` untouched), LSS_023,
   LSS_026 (`resolveSources` logic untouched; only its ctx copy goes), CGEN_067 (tuple-3 leaf is sret-able
   later). No mint order changes: Points are minted in the same order (no `fresh` moves), member ids
   likewise, intern insertions likewise.

5. **Edit sequence.**
   1. UnionFind.elm: add `peekS`/`rootQ`/`equivalentQ` + exports. Engine.elm: `peekVar`. (green, no behaviour change)
   2. Translate.elm 6 sites + LssInfer 1647 → `peekVar`/`peekS`; LssInfer 15 `S`-threaded sites; Monomorphize 2 sites; Engine `harvestSuperTableExcept`. (green; run `elm-tests`)
   3. Store.elm `addSlotSource` rewrite; `poisonGoC`; LssInfer 3 SetWriteCtx sites. (green)
   4. Store.elm: drop `ZonkCtx.store`, thread `store` through the zonk family, `varNumberFor`/`noteMultiSet`/`noteArrowClass` via `rootQ`, `zonkToMono` guarded write-back, `rezonkSettled`. **Same edit**: LssHonestSourcesTest `ctx` (drop `store`; `runResolve` calls `Store.resolveSlotMembers members0 srcs st (ctx honest table)`), LssDirectedFlowTest `resolveAt` (drop `store`; pass `st`). (green; `elm-tests`)
   5. `writeBackShared`/`writeBackIsolated` guard. (green)
   6. `classifyGo` family accumulator + `classifyDirect` write-once. (green; `elm-tests`)
   Loop entries if split: `8a` = edits 1-5 (pure-read sites + zonk ctx + write-backs), `8b` = edit 6 (classify accumulator).

6. **Verification.** Unit suite (`elm-tests`); BI `cmp` triple + fixed point; `--target full`; the 633-workload
   rail (front-end change). Attribution leg (`ECO_INLINE_ALLOC=0`): Record objects of size 11 (ZonkCtx) and
   the S/ItemAux class must drop by the multiplicities in §1; `Closure` count drops by the 7 `liftIO` sites'
   share. Purpose-built check for the accumulator: a temporary `Debug`-free counter is NOT needed —
   the MONO_029 tests (`grep -rln "MONO_029\|RecordNarrow\|staleVarRead" compiler/tests`) and the E2E suite
   pin the barrier; additionally diff `ECO_MONO_LSS_REPORT=1` census text against the reference (must be empty).

7. **Risks, gotchas, what NOT to do.**
   - Do NOT convert `unifySlotWithSetC` 1292 or `setRootC` (write path) or `Unify.elm` (typechecker shares
     UnionFind; its `getS` at 317/320 keeps compressing — that is fine, compression is idempotent).
   - Deep chains are now re-walked by zonk reads until a Unify read compresses them; bounded by log2(weight).
     If a perf counter ever shows deep chains, add compression back at `zonkToMono`'s ENTRY (one `reprS`
     per call) — never inside the ctx walk.
   - `[] ++ xs` is `xs` by pointer in elm/core, but the guard `auxNeeded` avoids relying on it.
   - The `Err` arms removed at Translate 3867/4828/5166 are provably dead (`liftIO` never fails, 1732-1739);
     step 10 assumes the same.
   - 32-slot cap: `ZonkCtx` 11, `S` 31 — untouched. `Result Failure ( a, S, List Int )` is a 3-tuple —
     Elm's maximum; do not add a fourth component (use a record if step 10 needs more).
   - `harvestSuperTableExcept`: after `peekS` the fold no longer produces a store; make sure the caller
     (Monomorphize 4177) no longer expects `store` in its result if it did.
   - Symlinked `build-kernel/src`, `rm -rf $BK/eco-stuff`, and: the `LssHonestSourcesTest` docs 274-281
     explain the ctx fields — update them, or the next reader rebuilds `store` into the ctx.

8. **Effort: M** (one small UF API + ~40 mechanical sites + a signature change across ~12 zonk helpers and 6
   classify helpers). Split as `8a`/`8b` above if one measured run is too coarse; `8a` alone is S-M.

---

<details><summary>Conventions used in this spec (from spec-F)</summary>

Line numbers are from the tree as read on 2026-09-19 (Store.elm 3722 ln, Engine.elm 2823, Translate.elm
8263, Monomorphize.elm 5097, LssInfer.elm 3597, UnionFind.elm 299). Every writer/reader below was
verified by `grep -n "lssStats = " MonoSolver/*.elm` (34 hits), `grep -n "UF\.\(get\|repr\|equivalent\|set\)\b"`
(48 hits) and `grep -n "store = store[0-9]"` (31 hits), not from memory.

Shared finding that shapes all three steps: **every `LssStats`/`SigFlowStats` field except
`flexCtorSpecs`, `joinRounds` and `retranslations` is read ONLY inside `Monomorphize.renderLssReport`
(1418-…), which is rendered only when `lssConfig.report` (Monomorphize 197-201).** `setsZonked` is
"reconciled" against `sigStats.settled.zonked` at 1754 — but that reconciliation is itself a report
line, and `settled` is populated only under report (`rezonkSettled` 2450). So the census can be
report-gated wholesale at zero semantic cost, and `lss.report` is excluded from the config hash
(Engine 1172-1176: "a report-on run must produce the same artifact as a report-off one"), so gating
cannot move emission.

---

</details>

### Step 9 (was 8). Skip `enrichFromEnv` re-encoding and `connectTypes` unification for ground, arrow-free types

#### 1. Goal and expected effect

`connectTypes` (Translate 165-178) loads BOTH canonical types through the shared memo (each
`Store.loadType` = `loadTypeC` + `writeBackShared` = two `S` copies + an `ItemAux` copy, Store
150-176) and unifies them, on every `Let`/`Destruct` body (898, 956), `If` branch and final (732,
1025), `Case` inline choice and jump (7417, 7428), `List` ELEMENT (638/644), `Tuple` slot (792),
record-literal field (296), field access (6193), derived destructor (6226) and tail-call argument
(205). `enrichFromEnv` (4770-4906) re-encodes the varEnv-bound `MonoType` of a local into fresh
store structure (`Store.monoTypeToVar` 694-704: one Point per node — hundreds for `s : S`) and
unifies it with the just-loaded use var, on every local-variable call argument (`argUnifyVar` 4229),
indirect callee (`appShapeConnect` 2210) and record-field argument (the `Access` arm 4855-4900).
Plan §1: `connectTypes` 7.0 % inclusive, `argUnifyVar` 1.7 %, `unifyParamsCollect` 2.4 %.

When both sides are ground and arrow-free the work is provably a no-op on every observable (§4):
skip it on a fused predicate. Loop stats: minor GC down (two loads + an encode + a unify per site),
wall down (plan: 3-5 % of the mono window). Emission **byte-identical** (substrate step); the
report census rows of `enrichFromEnv` are preserved deliberately (§4.3) so the rail's `.census`
diff is zero too.

#### 2. Preconditions

None in the plan ("no dependencies"). Step 4's `groundNoArrowWith`/`aliasMemo` make the predicate
O(1) on alias-typed sides; without Step 4 use the plain `groundNoArrow` walk (Step 4 §4.9 defines
both — if Step 4 has NOT landed, land §4.9's helpers alone as part of this step; they have no other
dependency). Verify:

```bash
grep -n "connectTypes\|enrichFromEnv" compiler/src/Compiler/MonoSolver/Translate.elm   # the 17 + 5 sites of §3
grep -rn "connectTypes\|enrichFromEnv" compiler/tests/TestLogic                            # expected: no direct pins
grep -n "^bumpArgFlowCensus" -A 3 compiler/src/Compiler/MonoSolver/Engine.elm             # 1104: gated on env.lss.report
```

#### 3. Inventory of touched code

| file | function (lines now) | what changes |
|---|---|---|
| Translate.elm | `connectTypes` 165-178 | early exit when `groundNoArrowWith s0.monoMemo.aliasMemo childCan && … parentCan` |
| Translate.elm | `enrichFromEnv` 4770-4906, local-name arm 4773-4820 and `Access` arm 4855-4900 | skip the `Store.monoTypeToVar` + `unifyStepBestEffort` pair when `groundNoArrowWith … (TOpt.typeOf arg)`; keep the `isLocalMultiTarget` test and every `bumpArgFlowCensus` row |
| Store.elm | (Step 4 §4.9) `groundNoArrow`, `groundNoArrowWith` | reused; nothing new |

Every call site of `connectTypes` (grep, 13 direct + 4 via `Engine.traverse` closures) — none
changes, all inherit the skip:

| line | caller | child / parent | may skip? |
|---|---|---|---|
| 205 | `connectTailArgsGo` (MONO_029 R1 tail-call args) | arg node type / loop-param canType | yes — R1 exists to connect the TCO-rebuilt id FAMILY to the loop params; if both sides are ground there is no family member on either side and no slot (arrow-free), so the unify has nothing to carry |
| 296 | `connectRecordFields` | field expr / record field canType | yes |
| 638, 644 | `TOpt.List` arm | element / elem slot (or first element) | yes — "an element use of a let-generalized NUMBER picks up the shared demand" (631-633): that element's canType is a `TVar` (number), so it is never ground and never skipped |
| 732 | `TOpt.If` final | final / if type | yes |
| 792 | `TOpt.Tuple` slots | slot expr / slot canType | yes |
| 898 | `TOpt.Let` body | body / let type ("DISTINCT per-occurrence arrow slots (LSS_006)" 893-896) | yes — arrow-free ⇒ no slot to connect |
| 956 | `TOpt.Destruct` body (the E9.5 PapStampTest fix, 945-955) | body / destruct type | yes — the miscompile it closes is a SET-slot flow; no arrow ⇒ no set |
| 1025 | `translateIfBranch` | branch body / if type | yes |
| 6193 | `genericAccess` | access node / record field canType | yes |
| 6226 | `generalDestruct` | destructor type / root slot canType | yes |
| 7417 | `specializeChoice` inline | choice expr / case type | yes |
| 7428 | `specializeJumps` | jump expr / case type | yes |

`enrichFromEnv` call sites (grep): 2210 `appShapeConnect` (callee — its canType is a `TLambda`, so
the predicate returns False at the root in O(1); never skipped, nothing to change), 4229
`argUnifyVar` (the hot one), and the three recursive Tuple-arm calls 4835/4840/4845 (inherit).
Callers of `argUnifyVar` (`grep -n "argUnifyVar"`: `unifyParamsWithArgExprs`/`unifyParamsCollect`
family and the Slow call path) — unchanged.

#### 4. Design

##### 4.1 `connectTypes`

```elm
connectTypes : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step ()
connectTypes childCan parentCan s0 =
    -- Step 9: two ground, arrow-free sides load two structures that carry no memo
    -- var (no TVar), no set slot (no TLambda) and no revMemo entry, then unify two
    -- equal ground structures. Nothing reachable from S changes (see the reader
    -- census in spec-C Step 4 §4.3); skipping is exact. The predicate answers alias
    -- occurrences from the run's verdict map (O(1) for `S`/`Env`/`ItemAux`).
    if groundNoArrowWith s0.monoMemo.aliasMemo childCan && groundNoArrowWith s0.monoMemo.aliasMemo parentCan then
        Ok ( (), s0 )

    else
        case Store.loadType parentCan s0 of      -- 168-178 unchanged
            ...
```

Soundness, observable by observable: the two loads mint Points nobody else references (an eligible
type touches neither `memo`/`revMemo` nor `arrowSlots`/`arrowMemo`/`slotsMinted`/`arrowOfSlot` —
Step 4 §4.2), so the only `S` fields that change are `store` (fresh cells + the merges of a
successful unify of two equal structures) and the copies themselves. `unifyStepBestEffort` (5284-
5292) either succeeds — merging cells nothing points at — or fails and returns `s2`, whose only
difference from `s0` is the same unreferenced cells. Point-index shift and union-by-weight are
unobservable (Step 4 §4.10). With Step 4 landed, the two loads would have been memo hits (two
fresh roots over shared children) and the unify a root merge: still unreferenced roots — the same
argument, and the skip additionally saves the two `writeBackShared` `S`+`ItemAux` copies and the
`unifyStep` closures (Store 1034-1074: `liftIO` + `andThen` + `succeed` ≈ 7 objects).

##### 4.2 `enrichFromEnv`

Skip only the encode+unify pair; keep the classification/census structure so report output is
unchanged:

```elm
enrichFromEnv arg canVar s0 =
    case accessedLocalName arg of
        Just localName ->
            case Engine.isLocalMultiTarget localName s0 of          -- 4780, unchanged
                Err e -> Err e
                Ok ( isLM, s1 ) ->
                    if isLM then
                        Ok ( (), Engine.bumpArgFlowCensus "enrich|localMulti" s1 )     -- unchanged
                    else
                        case Engine.lookupVar localName s1 of                           -- 4788, unchanged (a Dict probe)
                            Err e -> Err e
                            Ok ( maybeBound, s2 ) ->
                                case maybeBound of
                                    Just boundType ->
                                        -- Step 9: a ground, arrow-free USE type has nothing to receive:
                                        -- no memo var to concretise, no slot to carry members into.
                                        -- Re-encoding `boundType` (hundreds of Points for `s : S`) and
                                        -- unifying it into an unreferenced structure is a no-op.
                                        -- The report rows stay so the census is unchanged.
                                        if groundNoArrowWith s2.monoMemo.aliasMemo (TOpt.typeOf arg) then
                                            Ok ( (), enrichCensusRow boundType s2 )      -- the s3c block of 4805-4813, applied to s2
                                        else
                                            case Store.monoTypeToVar boundType s2 of      -- 4796-4813, unchanged
                                                ...
                                    Nothing ->
                                        Ok ( (), Engine.bumpArgFlowCensus "enrich|unbound" s2 )  -- unchanged
        Nothing ->
            case arg of
                TOpt.Tuple _ a b rest _ ->
                    -- Step 9: the whole tuple ground ⇒ every element ground ⇒ every leaf would skip;
                    -- skip the `UF.get` (an S copy, 4826) and the three recursions at once.
                    if groundNoArrowWith s0.monoMemo.aliasMemo (TOpt.typeOf arg) then
                        Ok ( (), s0 )
                    else
                        ... (4826-4852 unchanged)
                TOpt.Access record _ fieldName _ ->
                    ... keep 4858-4897 as is up to `Just fieldType ->`, then:
                        Just fieldType ->
                            if groundNoArrowWith s2.monoMemo.aliasMemo (TOpt.typeOf arg) then
                                Ok ( (), Engine.bumpArgFlowCensus "enrich|access|ofLocal" s2 )
                            else
                                case Store.monoTypeToVar fieldType s2 of ... (4884-4891 unchanged)
                _ -> Ok ( (), s0 )
```

`enrichCensusRow boundType s` is today's `s3c` let-block (4805-4813) hoisted to a top-level helper
(`if not s.env.lss.report then s else if List.isEmpty (Mono.collectAnnoMembers boundType) then bump
"enrich|bare" else bump "enrich|withSets"`), so the counted rows are identical in both arms; off
report it is one Bool read.

Why the skip is exact here: `canVar` was loaded from an eligible type (no memo var, no slot, no
revMemo entry) and `boundType` is the SAME type as the typechecker sees it (`varEnv` holds the
binder's classified `MonoType`; a ground use type means the binder's type at this use is that ground
type). The `unifyStepBestEffort canVar boundVar` therefore merges an unreferenced ground structure
with a freshly encoded ground structure — or, when `boundType` still carries an `MVar` (a demand not
yet concretised — the "narrow row-polymorphic generalization" comment at 4216-4219), binds a fresh
`FlexVar`/`FlexSuper` minted by `monoTypeToVarC` (940-945) that has no `revMemo` entry and is read by
nothing. Either way nothing observable moves. On failure (a shape mismatch), `unifyStepBestEffort`
already returns the pre-attempt state. The `Tuple` arm's `Engine.liftIO (UF.get canVar)` (4826) is a
path-compressing read of an unreferenced Point — unobservable.

##### 4.3 Which callers MUST NOT skip — checked against the three named mechanisms

- **MONO_029** (R1 `connectTailCallArgs` 186-215, R2 `staleVarRead`): R1's connect is skipped only
  when both sides are ground — then no id-family member is on either side (§3 table). R2 records
  reads of FREE vars (`residualWithTaintC` 2730-2754, `classifyGo` TVar arm 3543-3557); an eligible
  type has no var, so a skipped site would have recorded nothing. `staleResidualRead`'s key reads
  (4735-4745) test `s.memo` entries — untouched by a skipped load.
- **number-multi** (`S.numberMulti`, `pushNumberMulti` Engine 2473, `numberMultiRootType`, the
  `Destruct` arm at 961): a let-bound `number` var's uses have `TVar` canTypes (the var IS the
  multi-instance handle) — never eligible, never skipped. The `List`-element connect comment
  (631-633) is exactly this case and stays live.
- **local-multi** (`S.localMulti`, `isLocalMultiTarget` 2534-2536, `retranslateWithTag`): a local-multi
  FUNCTION's uses have `TLambda` canTypes — never eligible. `enrichFromEnv` already refuses
  local-multi targets BEFORE the skip point (the `isLM` branch is kept first, so the `enrich|localMulti`
  row and the refusal order are unchanged). Inside a re-translation (`retranslating /= Nothing`)
  nothing differs: the predicate reads only `aliasMemo` (per run) and the canType.
- `appShapeConnect` (2165-2213): the callee is arrow-typed — the predicate says False at the root;
  the site is untouched in behaviour and cost (one constructor test).
- `demandUnify`/`flowArgDemands`/`unifyParamsBestEffort`/`connectEncoderType` are NOT in this step
  (`flowArgDemands` 3199-3210 already skips on `groundCanType`; the others are Step 10's).

#### 5. Edit sequence

1. (If Step 4 is not in) land Step 4 §4.9's helpers in Store.elm and export `groundNoArrow`,
   `groundNoArrowWith`; with no `aliasMemo` yet, call `groundNoArrowWith HashMap.empty` — or, simpler,
   `Store.groundNoArrow` (the plain walk) at both sites and switch to the memo-aware form when Step 4
   lands. Build: green.
2. `connectTypes` (165-178): add the early exit (§4.1). Build: green. Unit suite: `MonomorphizeTest`
   and the `Lss*Test` E2E-shaped pins (`PapStampTest` is E2E — run under `--target full` in Phase 4).
   **Loop entry `9a`** if measured separately.
3. `enrichFromEnv`: hoist `enrichCensusRow`; add the three skips (§4.2). Build: green.
   **Loop entry `9b`.**
4. Run `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt` once.

#### 6. Verification

- **Unit pins (add to `GroundAliasMemoTest.elm`, or a `ConnectSkipTest.elm`):**
  - C1 `connectTypes` on two ground alias types through one `S`: `Array.length s1.store.ioRefsPoint ==
    Array.length s0.store.ioRefsPoint` and `s1 == s0` (no field changed).
  - C2 `connectTypes (TVar n) (TType Int)`: the memo point for `n` is bound afterwards (the number-
    multi path still works — `Store.zonkToMono` of `s.memo[n]` is `MInt`).
  - C3 `enrichFromEnv` with a ground-typed `VarLocal` whose varEnv type is `MRecord …`: store size
    unchanged; with a `TVar`-typed use: store grows and the use var is bound.
  - C4 report-mode census: with `env.lss.report = True`, `argFlowCensus` rows `enrich|bare`/
    `enrich|withSets`/`enrich|access|ofLocal` are bumped identically for a ground and a non-ground use
    (pin the counts).
- **Byte identity + effect:** the loop (Phase 1.3 → Phase 2 → `cmp` ×4). Judge the five stats.
- **Gates on a win:** unit suite, `--target full` (PapStampTest, SolverLayoutFoldMTest,
  SolverLayoutFoldMCycleTest, RecordNarrow tests are the MONO_029/E9.5 pins that exercise exactly these
  connects), `benchmarks/mlir-workload-rail.sh` — expect `CENSUS: 0 diff lines` (the rows are kept).
- **Attribution leg (untimed):** `scratchpad/uprobe/run.sh` with `BIN=eco-opt9`: `unionS` (baseline
  918,925) and `freshS` must both drop; add
  `uprobe:$BIN:Compiler_MonoSolver_Translate_connectTypes_* { @calls["connectTypes"] = count(); }` —
  the symbol exists (`nm` shows `Compiler_MonoSolver_Translate_connectTypes_$_33072`) but the count
  does NOT change (the function is still called; the skip is inside it). To count SKIPPED sites, make
  the skip branch a separate top-level `connectTypesSkipped : S -> Result …` for the leg only, or use
  a temporary `bumpArgFlowCensus "connect|skip"` under report.

#### 7. Risks, gotchas, and what NOT to do

- **Keep the census rows** (§4.2). Dropping `enrich|bare`/`enrich|withSets`/`enrich|unbound` would
  put lines into the rail's `.census` diff and turn a substrate step into an "explain the drift" step
  for nothing.
- **Do not skip on `groundCanType` alone.** A ground type with an arrow (`{ f : Int -> Int }`) mints
  set slots and the connect is the LSS_006 slot flow that PapStampTest (Translate 945-955) exists for.
  The predicate must be the fused one.
- **Do not skip on `not (canTypeHasArrow …)` alone.** A var-carrying arrow-free type (`List number`)
  is the number-multi handle (§4.3).
- **`appShapeConnect`'s `enrichFromEnv func …`** is not a skip candidate (callee is an arrow); leave
  the call in place — removing it would drop the MONO_029 R1 fix documented at 2171-2181.
- **Predicate cost without Step 4:** `groundNoArrow` walks an `S`-typed side fully (~200 nodes) at
  every connect. That is still far cheaper than two loads + a unify of the same 200 nodes, but it is
  why the memo-aware form is preferred once Step 4 is in.
- **Order of the two predicate calls** in `connectTypes` does not matter (both pure); put the cheaper
  side first if one is known to be a `TVar` most of the time (child), for the early exit.
- Plan §4: N21 (`mintVarSlots` single walk) is explicitly "only inside step 9 if `monoTypeToVar`
  survives there" — it survives (the non-ground path), and it is NOT byte-identical for free; do not
  fold it in.

#### 8. Effort

**S.** ~40 changed lines in Translate, no signature changes, no new types; reuses Step 4's predicate.
`9a` (connectTypes) and `9b` (enrichFromEnv) can be two loop rows if attribution is wanted; one row
is fine otherwise.

<details><summary>Conventions used in this spec (from spec-C)</summary>

All line numbers are from the tree as of 2026-09-19 (`compiler/src/Compiler/...`); every one was
re-verified with `grep -n` before being written down. `Store` = `MonoSolver/Store.elm` (3722 ln),
`Translate` = `MonoSolver/Translate.elm` (8263 ln), `Engine` = `MonoSolver/Engine.elm` (2823 ln),
`Zonk` = `MonoSolver/Zonk.elm` (228 ln), `Mono` = `AST/Monomorphized.elm`, `Can` = `AST/Canonical.elm`.

Shared vocabulary for both steps:

- **eligible type** = a `Can.Type MVarId` with no `TVar`, no `TLambda` anywhere, and no open record
  (`TRecord _ (Just _)`); through a `TAlias _ _ _ (Filled inner)` only `inner` is inspected (that is
  all `loadTypeC`/`classifyGo`/`Zonk` ever consume of a Filled alias — Store 429, Store 3621, Zonk
  163); through `TAlias _ _ args (Holey inner)` every arg must be eligible and `inner` must be
  arrow-free (its vars are the alias params, bound by the args — the same assumption
  `Translate.groundCanType` 3104-3136 already makes at 3133-3136).
- `groundHash t` = the ONE-walk, early-exit fused predicate + structural hash: `-1` when `t` is not
  eligible, else an `Int` in `[0, 2^26)`. Defined in §4.9 of Step 4 and reused by Step 9.

---

</details>

### Step 10 (was 3). Retire the `Step` encoding: `Step a` → `S -> ( a, S )`, `Step ()` → `S -> S`

> **MEASURED OUT, 2026-09-21 — implemented in full, partially kept.** Stages `10a`, `10b`, `10c`
> and `10e-i` are in the shipped compiler and are worth about 10 s together; `10e-i` alone was
> −8.34 s. Stages `10e-ii`, `10f` and `10g` were implemented to completion — the whole `Step`
> monad retired, all 55 combinator-shaped `Translate` functions rewritten, the combinator layer
> deleted, `$sret` coverage 42 → 148 MonoSolver workers — and measured **+5.63 s (+2.4 %) over
> six paired runs**. Reverted. Two findings close the step:
>
> 1. **`$sret` is a LEAF optimization.** It pays where per-call overhead dominates per-call work
>    and costs where it does not, because the promotion emits a worker PLUS a shim and
>    `Expr.trySretLetBinding` migrates only let-bound direct call sites. Blanket application is
>    negative.
> 2. **The `Step` monad was 0.03 % of allocation.** Deleting every `Result` box and all 320
>    combinator closures moved objects allocated from 273,356,771 to 273,270,023. The inliner
>    and `MonoInlineSimplify` were already folding them away. §2b's "the state monad is the
>    cost" is retracted as a wall-clock claim.
>
> The full data and the per-stage diagnosis are in `benchmarks/lss-compile-opt-loop.md`, entries
> `10a`–`10g`. `Backend.sretFreshGreatest` (greatest-fixpoint promotion selection) was written
> and is correct but measured inert; it lives in `snapshots/lss-loop/step-10g.patch`. Do not
> reopen this step — the remaining time is in the GC.

This step is a STAGED PROGRAMME. Each stage below is one loop entry (`10a` … `10g`), built on the
previous stage's `keep-*` snapshot, measured on its own, and kept or reverted on its own. The
brief's lettering maps as: brief-10a = stages 10a + 10b here (backend prerequisite, then the
probe), brief-10b = stage 10c (failure channel), brief-10c… = stages 10d–10g (conversion by
hotness, then deletion).

| stage | short name | BI? | effort |
|---|---|---|---|
| 10a | admit `MonoIf` on the closure result spine (`Backend.sretTailOk`, `Expr.generateIf`) | NO — codegen change, extra bootstrap turn | S |
| 10b | probe: `connectTypes` (+16 callers) and `classifyAs`/`classifyGo` family to direct state | yes | S-M |
| 10c | failure channel: crash for `EngineBug`/`Unsupported`/non-best-effort `UnifyMismatch`; `pendingFailure` for `LimitExceeded`; `enqueueSpec*` → `( SpecId, S )` | yes | M |
| 10d | the 81 `Step ()` signatures → `S -> S` | yes | L |
| 10e | the per-node `Step a` signatures → `S -> ( a, S )` (Store, Engine, LssInfer, Translate, Monomorphize driver) | yes | L |
| 10f | the `andThen` nests on the call paths, `scoped`/`withLoopFrame` inlining, direct traversal loops, pure-read twins | yes | M-L |
| 10g | delete the combinators, the `Step` alias, and the transitional adapters | yes | S |

All line numbers are as of the 2026-09-19 tree (`snapshots/lss-loop/base`); they move as steps
1–9 land — re-run the greps given per stage, never trust the numbers blindly.

---

#### 1. Goal and expected effect

**What changes.** Every function in `Compiler/MonoSolver/{Engine,Store,LssInfer,Translate}.elm`
typed `Step a = S -> Result Failure ( a, S )` (Engine.elm:1614-1615) becomes `S -> ( a, S )`, and
every `Step ()` becomes `S -> S`. The `Result` disappears from the per-node path; `Failure`
survives only in the Monomorphize driver (`drain`/`processItem`/`specializeNodeSaturating`,
Monomorphize.elm:3978/4048/4422) for the one recoverable class (`LimitExceeded`) and the three
driver-level `EngineBug`s.

**Why it pays (plan §1).** Today every unit step allocates `Ok ( (), s )` = one `Custom` + one
`Tuple2` per call; every tuple step allocates `Ok ( a, s )` the same way; every `Engine.andThen`
allocates its continuation closure plus the `\s -> …` closure. Backend.elm:431 admits only
`MTuple` results to the `$sret` promotion, so a `Result Failure ( a, S )` return can NEVER be
promoted (REP_AGG_001, CGEN_064, CGEN_067) — that is why the July trailing-`S` conversion was
neutral: it kept the `Result`. Closure + Tuple2 + Custom are 65 % of LSS's +15.1e9 objects; GC is
21 % of the mono window (~48 % of wall), dominated by nursery survivor copying, and the monad
garbage is exactly nursery-dead short-lived structure.

**Which stats move.** Minor GC count is the judged stat: the whole programme should remove on the
order of 10^9 nursery objects on the self-compile (the `S -> S` unit steps alone are 81 functions
called per node/per binder/per unification; `connectTypes` is 7.0 % inclusive of the window). Wall
is expected to fall 2–5 % over the programme (allocation rate + the `andThen` dispatch, not GC
copying), RSS flat, promoted MiB flat. Stage 10a alone may be flat or slightly negative on wall
(the `sretTailFuncs` precedent measured ~+4 % for tail-func loops, Compiler/Eco/Config.elm:708-712);
it is kept if it is flat-with-a-counter-improved, and re-attempted after 10e if it loses
(§7, R1).

**Byte identity.** Stages 10b–10g are pure re-encodings of sequential state-passing code: the
sequence of store/registry/member-table operations is unchanged, so the compiler's OUTPUT for its
own source must be byte-identical — the loop's fixed-point `cmp` is the proof and the gate. Stage
10a changes the backend's selection rule, so the candidate emits different MLIR (more `$sret`
workers) for any program; it is an "analysis/codegen" entry with the one extra bootstrap turn
(B==C gate) and an expected sha256 drift on the 633-workload rail (LSS census identical).

**Baseline numbers for the probe** (measured on `build/compiler/build-kernel/bin/eco-compiler.mlir`,
MLIR BYTECODE — count symbol names in its string table, never lines):
`strings -n 6 bin/eco-compiler.mlir | grep -c '[$]sret$'` = **464** unique workers;
`… | grep -c 'MonoSolver.*[$]sret$'` = **19**, all already-direct-state helpers
(`Store_freshVarC`, `Store_loadListC`, `Store_structS`, `Store_freshVarS`, `Store_monoListToVarC`,
`Engine_internMemberKey`, `Monomorphize_resolveGlobalNode`, …) — the mechanism already fires for
exactly the shape this step produces. Symbols mangle as
`Compiler_MonoSolver_Store_classifyGo_$_34857` (`_$_<specId>` suffix, then `$sret`).

#### 2. Preconditions

- **Step 5 (`Unify.unifyS`) is IN** — this spec assumes `Store.unifyStep : Vars.Variable ->
  Vars.Variable -> S -> ( Bool, S )` and an `Answer`-returning core it can reuse. Verify:
  `grep -n '^unifyStep\|^unifyS\b' compiler/src/Compiler/MonoSolver/Store.elm compiler/src/Compiler/Type/Unify.elm`.
  If step 5 landed with a different shape, §4-10c gives the adapter.
- **Step 6 (flag-residue/dead-arm cleanup) is IN** — `foldSetWrites` (Store.elm:1224) must be
  `S -> S` (the `unifySlotWithSetSlow`/`needSlow` arm deleted), otherwise `injectSpineMemberId`,
  `injectPapSuccessors`, `injectLambdaMember*` in LssInfer keep a `Result`. Verify:
  `grep -n 'foldSetWrites\|unifySlotWithSetSlow\|needSlow' compiler/src/Compiler/MonoSolver/Store.elm`
  — `unifySlotWithSetSlow` must be gone.
- **Step 7 (census off default path)** and **step 8 (`UF.peekS`)** are in by choice — fewer
  `lssStats` writers and pure reads to convert. Not hard prerequisites.
- The tree equals the last `keep-*`: `benchmarks/lss-loop-snap.sh verify <ref>`.
- Backend selection is on: `sretResults = True`, `sretFresh = True`, `sretTailFuncs = True`
  (Compiler/Eco/Config.elm:715-718; env overrides `ECO_SRET_RESULTS`/`ECO_SRET_FRESH`/
  `ECO_SRET_TAILFUNC`, Builder/Eco/Config.elm:357/372/367). Never set them in a timed run.
- `Utils.Crash.crash : String -> a` exists (compiler/src/Utils/Crash.elm:20-22).

#### 3. Inventory of touched code

Census (as of base; re-run per stage): `Step ()` signatures **81** (Engine 6, Store 8, LssInfer 30,
Translate 37); other `Step a` signatures **182** (Engine 43, Store 7, LssInfer 36, Translate 96);
`Engine.andThen` 212 uses in Translate (+1 LssInfer +1 Store); `Engine.map` 126 Translate;
`map2` 18; `traverse` 28; `foldlS` 5; `getS` 13; `modifyS` 3; `liftIO` 6 Translate + 7 Store + 1
LssInfer; `Engine.runStep` 8 (all Monomorphize); `Err e ->` arms: Translate 145, LssInfer 112,
Store 33, Engine 16, Monomorphize 7; `Ok ( (), …)` returns: Translate 51, LssInfer 32, Store 10,
Engine 4, Monomorphize 1.

| stage | file | function (lines) | change |
|---|---|---|---|
| 10a | Generate/MLIR/Backend.elm | `sretTailOk` 722-737 | add a `MonoIf` arm (mirror of `sretTailFuncOk` 674-675) |
| 10a | Backend.elm | `sretFreshTailOk` 588-608 | same `MonoIf` arm (the fresh fixpoint walks the same spine) |
| 10a | Backend.elm | `buildSretPromoted` docstring 405-416 | delete "MonoIf is a recorded v1 scope cut" |
| 10a | Generate/MLIR/Expr.elm | `generateExpr` `MonoIf` arm 460-470 | stop clearing `sretTailLayout`; pass the node's `MonoType` |
| 10a | Expr.elm | `generateIf` 4755-4852 (recursive call 4808; terminated paths 4789/4812) | flag hygiene on the condition, aggregate result type under the flag, `emitSpineYield` + `finishSpineCase` |
| 10a | Expr.elm | `generateIfWithTerminatedBranch` 4855 (recursive call 4867), `generateIfWithTerminatedElse` 4913 | thread the new parameter only |
| 10a | Expr.elm | `generateCase` 6999-7020 | extract the result-type rule (7005-7018) into `spineResultMlirType` shared with `generateIf` |
| 10b | MonoSolver/Engine.elm | new `renderFailure` (moved from Monomorphize.elm:5080-5098), new `crashFailure`, transitional `lift`/`liftU`/`afterU` | adapter scaffolding |
| 10b | MonoSolver/Monomorphize.elm | `renderFailure` 5080-5098, caller 158 | delete; call `Engine.renderFailure` |
| 10b | MonoSolver/Store.elm | `classifyDirect` 3522-3524, `classifyGo` 3527-3634, `classifyList` 3637-3652, `classifyAliasArgs` 3655-3667, `classifyRecordExt` 3670-3688, `classifyRecordFields` 3691-3702 | drop `Result`; re-tuple the `zonkToMono` hit arm |
| 10b | Store.elm | new `loadTypeS` beside `loadType` 205-212 | direct twin (`loadType canType s = Ok (loadTypeS canType s)`) |
| 10b | MonoSolver/Translate.elm | `classify` 61-66, `classifyAs` 76-78 | `S -> ( MonoType, S )` |
| 10b | Translate.elm | 47 `classifyAs` sites + 1 `classify` site (grep in §5-10b) | `case …Ok/Err` → `let ( t, s1 ) = …`; Step-valued uses → `Engine.lift (classifyAs k t)` |
| 10b | Translate.elm | `connectTypes` 165-177 | `S -> S` |
| 10b | Translate.elm | `connectTailArgsGo` 196-212 (205), `connectRecordFields` 288-300 (296), List arm 625-665 (638, 644), If arm 726-735 (732), 898, 956, `translateIfBranch` 1019-1027 (1025), record-access arm 6186-6197 (6193), destructor arm 6220-6232 (6226), `specializeChoice` 7409-7419 (7417), `specializeJumps` 7421-7429 (7428) | the 16 `connectTypes` callers |
| 10b | Translate.elm | new `unifyBestEffortS` beside `unifyStepBestEffort` 5284-5291 | direct twin used by `connectTypes` |
| 10c | Engine.elm | `ItemAux` 1414-1445, `emptyItemAux` 1516-1518, `clearedAux` 1529-1531, `restoredAux` 1537-1539 | field `pendingFailure : Maybe Failure` |
| 10c | Engine.elm | `checkSpecWatchdogs` 1235-1265 (unchanged), `enqueueSpec` 2110-2165, `enqueueSpecCommit` 2185-2200, `enqueueSpecKeyed` 2305-2400 | `( SpecId, S )`; watchdog → `notePendingFailure` |
| 10c | Translate.elm | `enqueueSpecStamped` 4758-4765; callers 993, 1193 (`Engine.enqueueSpec`), 1914, 3249, 3346, 3377, 3448 | `( SpecId, S )` |
| 10c | Monomorphize.elm | `drain` 3978-4045 | check `pendingFailure` after each `processItem` |
| 10c | Store.elm | `unifyStep` 1034-1068, `unifyBestEffort` 1076-1082; new `unifyStepOrCrash`, `mismatchMessage` | Bool + crash |
| 10c | Translate.elm | `unifyStepCtx` 5264-5277 (callers 102, 5253), `unifyStepBestEffort` 5284-5291, `classifyRef` 1945-1968 | delete / straight-line |
| 10c | Translate.elm | 19 `EngineBug`/`Unsupported` sites: 1008, 1062, 1231, 1275, 7801, 7946, 7980, 7983, 8020, 8030, 8033, 8046, 8062, 8065, 8070, 8088, 8091, 8094, 8099 | `Engine.crashFailure` |
| 10c | Store.elm 2727, 2813; LssInfer.elm 95, 827 | 4 more sites | `Engine.crashFailure` |
| 10c | Monomorphize.elm 3996 (`drain`), 4124 (`processItem`), 4434 (`specializeNodeSaturating`) | driver-level `EngineBug`s | STAY `Err` (Result-typed driver) |
| 10c | dead `Err _ ->` arms: Store 1082, 2066, 2479; Monomorphize 150, 1252, 3968, 4283; Translate 1952, 1959, 1964, 5290 | 11 arms | deleted with their enclosing rewrite |
| 10d | the 81 `Step ()` signatures (`grep -n 'Step ()' compiler/src/Compiler/MonoSolver/*.elm`) | see §4-10d | `S -> S` |
| 10e | the 182 other `Step` signatures (`grep -n -E ': .*Step [A-Za-z(]' … \| grep -v 'Step ()'`) | see §4-10e | `S -> ( a, S )` |
| 10e | Monomorphize.elm | `specializeNode` 4459-4524 (runStep at 4472, 4475, 4479, 4510, 4515, 4524), `defineFrom` 4586-4605 (4588, 4593), main/flags seeds 150/1252 | direct calls |
| 10f | Translate.elm | `translateGlobalCallFast` 3213-3270, `translateGlobalCallGroundMemo` 3272-3392, `appShapeConnect` 2165-2212, `buildAppVar` 2215-2228, `translateIndirectCallBody` 2231, `unifyParamsWithArgs` 5238-5261, `unifyResultWithExpected` 5329-5340, `resultVarAfter` 5343-5362, `memberIdForDepth` 4621-4668, `injectArgLambdaMember` 4330-4332, `specializeLambda` 1660, TailDef let arm 1547/1563, `deriveKernelAbiTypeWith` 4915, `translateDispatch` container arms 502-1010, `translateIfBranch` 1019-1027, `specializeChoice`/`specializeJumps` 7409-7429; `Engine.scoped` sites 1547, 1563, 1716, 5699, 5759, 5790, 5926, 6247, 6312, 6782, 7390, 7392, 7402, 7404, 7428; `withLoopFrame` 233 | desugar; inline scope push/pop; direct loops |
| 10f | Engine.elm | `scoped` 2631-2638, `lookupVar` 2447, `localVarInfo` 2543-2552, `isLocalMultiTarget` 2534, `lookupSchemeMono` 2702, `lookupCallMemo` 2719, `putSchemeMono` 2707, `putCallMemo` 2724; Translate `lookupAnnotation` 8225, `currentMVarEnv` ~5389 | pure-read twins (A2), `S -> S` writers |
| 10g | Engine.elm | 1614-1738 (`Step`, `succeed`, `fail`, `andThen`, `map`, `map2`, `traverse`, `traverseGo`, `foldlS`, `runStep`, `getS`, `modifyS`), exposing list lines 1-4; imports Store.elm:34, LssInfer.elm:59, Translate.elm:32 (`exposing (Failure(..), Step)`) | delete |

Tests: no unit test calls a `Step`-typed function directly (the eight `TestLogic/Monomorphize/*`
files that import MonoSolver go through the pipeline; `LssGroundingTest.elm:269-274` and
`LssDirectedFlowTest.elm:13` deliberately mirror `Step` functions with pure code). Pins that matter:
`TestLogic/Monomorphize/SpecWatchdogTest.elm:106,116` ("clean `LimitExceeded`" through
`monomorphize…` returning `Err String`) and `TestLogic/TestPipeline.elm:514`.

#### 4. Design

##### 10a — admit `MonoIf` on the closure result spine

**Selection (Backend.elm).** `sretTailOk` 722-737 gains, between the `MonoDestruct` and `MonoCase`
arms, exactly the arm `sretTailFuncOk` has at 674-675:

```elm
        Mono.MonoIf brs fin _ ->
            List.all (sretTailOk slotTys) (fin :: List.map Tuple.second brs)
```

`sretFreshTailOk` 588-608 gets the same arm (`List.all (sretFreshTailOk table slotTys) (fin :: …)`),
otherwise the fresh fixpoint (`sretFreshFixpoint` 537-585, MonoDefine only) rejects an if-spine
whose leaves are calls to promoted callees. `sretDeciderTailOk`/`sretFreshDeciderOk` are
unchanged (an `if` inside an `Inline` leaf reaches `sretTailOk` through `Leaf (Inline e)`).
`collectSretSites` 646-653 is unchanged: the call-site shape is still
`MonoLet (MonoDef _ (MonoCall _ (MonoVarGlobal _ specId _) …))`.

**Emission (Expr.elm).** The backend's docstring at Backend.elm:656-660 records why `MonoIf` was
cut: TailRec's `compileIfStep` (TailRec.elm:1560-1640) threads the spine through
`compileStep` and yields decomposed columns with `Ops.ecoYieldMany`/`Ops.ecoCaseMany`, while
`Expr.generateIf` yields one aggregate. The change makes `generateIf` do for `if` what
`generateCase` already does for `case` (Expr.elm:6455-6470, 6590-6605):

1. `generateExpr`'s `MonoIf` arm (460-470) becomes
   `generateIf ctx branches final monoType` (no clear; the returned-ctx restore at 468-470 stays —
   `generateIf`'s own result ctx must carry `ctx.sretTailLayout`, as the tuple arm does at 566-568).
   The hygiene `case` at 384-406 already lists `MonoIf` as a spine arm, so the flag reaches here.
2. New signature `generateIf : Ctx.Context -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> Mono.MonoExpr
   -> Mono.MonoType -> ExprResult`; the three recursive/forwarding calls at 4808, 4867 and the
   `generateIfWithTerminatedBranch` parameter list (4855) pass the same `MonoType` through.
   `generateIf` callers outside Expr.elm: none (`grep -n 'generateIf' compiler/src/Compiler/Generate/MLIR/*.elm`
   → Backend.elm:660 is a comment).
3. Condition hygiene is MANDATORY: `condRes = generateExpr { ctx | sretTailLayout = Nothing } condExpr`
   — a condition can itself be a `MonoCase` (a spine arm), and a leaked flag there would
   make-promote a `Bool`-typed case (the `eco.papExtend` aggregate-operand incident the docstring
   at 372-380 records). Then `condCtxSpine = { condCtx | sretTailLayout = ctx.sretTailLayout }`
   (the flag was cleared on the ctx that flowed through the condition) and
   `thenRes = generateExpr condCtxSpine thenExpr`; the else ctx is
   `{ Ctx.ctxForSiblingRegion condCtx thenFinalCtx | sretTailLayout = ctx.sretTailLayout }`.
4. Result type under the flag: extract lines 7005-7018 of `generateCase` into
   `spineResultMlirType : Ctx.Context -> Mono.MonoType -> MlirType` (aggregate
   `Ops.aggTupleType (Types.tupleSlotTypes tailLayout)` iff the node's `MTuple` slot types equal
   the layout's, SLOT-TYPE-EXACT; else `Types.monoTypeToAbi`) and use it in both. With the flag
   `Nothing` it is `Types.monoTypeToAbi resultMonoType`, which must equal today's
   `thenRes.resultType` for the non-promoted path — keep today's `resultMlirType = thenRes.resultType`
   when `ctx.sretTailLayout == Nothing` so the non-promoted path is byte-identical by construction,
   and use `spineResultMlirType` only under `Just`.
5. Yields and the case: in the both-branches-yield path (4816-4852) replace the two `Ops.ecoYield`
   with `emitSpineYield` (7494-7540: projections + `ecoYieldMany` when the flag is set and the
   result type is an aggregate; exactly `Ops.ecoYield` otherwise) and build the `eco.case` with
   `finishSpineCase` (7551-7620) using the two builders `generateCase` passes at 6599-6603:
   ```elm
   spineCase =
       finishSpineCase ctxAfterYields resultMlirType
           (\cS vS tS -> Ops.ecoCase cS vS condVar I1 "bool" [ 1, 0 ] [ thenRegionEco, elseRegion ] tS)
           (\cM pairsM -> Ops.ecoCaseMany cM condVar I1 "bool" [ 1, 0 ] [ thenRegionEco, elseRegion ] pairsM)
   ```
   and return `{ ops = condOpsAll ++ spineCase.ops, resultVar = spineCase.resultVar,
   resultType = spineCase.resultType, ctx = Ctx.ctxAfterBranchOp condCtx spineCase.ctx spineCase.newVars,
   isTerminated = False }`. Order of fresh-name allocation must stay: else-yield ctx (`ctx2`),
   then-yield (ctx discarded, as at 4831), then `finishSpineCase`'s `Ctx.freshVar` for the case
   result, then `ecoCase` — which is what `singlePath` in `finishSpineCase` does with the ctx it is
   given, so the flag-off emission is unchanged token for token.
6. The two terminated-branch paths (4789/4812) are unreachable on a promoted spine (selection
   rejects `MonoTailCall` leaves for closures; case jumps are inlined in yield mode), so they keep
   treating the flag as `Nothing` — only the parameter is threaded.

Invariants: CGEN_064 (Phase 3.4 #1 clause: `eco.case` join shapes are result producers, decomposed
yields), CGEN_067 (stores immediately before return — unchanged, the worker/shim emitter is not
touched), REP_AGG_001 (make-form aggregates dissolve under SROA; no aggregate crosses a block
boundary — `finishSpineCase` rebuilds block-locally after the merge). No csv row changes; the
Backend docstring at 405-416 and 656-660 is updated.

##### 10b — the probe

Purpose: prove on the loop's own numbers that a direct-state MonoSolver function gets a `$sret`
worker and stops allocating, before the large rewrite. Two hot targets, both on every node:
`connectTypes` (7.0 % inclusive) and `classifyAs`/`classifyGo` (`Translate.classify` 19.3 %,
`classifyGo` 12.2 %).

**Scaffolding in Engine.elm (all deleted in 10g).**

```elm
renderFailure : Failure -> String          -- moved VERBATIM from Monomorphize.elm:5080-5098
crashFailure : Failure -> a
crashFailure f =
    Crash.crash (renderFailure f)          -- import Utils.Crash as Crash

-- transitional adapters: let converted callees serve unconverted Step-typed callers
lift : (S -> ( a, S )) -> Step a
lift f =
    \s -> Ok (f s)

liftU : (S -> S) -> Step ()
liftU f =
    \s -> Ok ( (), f s )

afterU : (S -> S) -> Step b -> Step b      -- `andThen (\_ -> step) (liftU u)` without the boxing
afterU u step =
    \s -> step (u s)
```

`Monomorphize.renderFailure` is deleted; line 158 calls `Engine.renderFailure`.

**Store: the classify family** (3522-3702). Signatures drop `Result Failure`:
`classifyDirect : Int -> Can.Type … -> S -> ( Mono.MonoType, S )`, `classifyGo : Int -> S -> Dict Int MonoType -> Can.Type … -> ( MonoType, S )`,
`classifyList … -> ( List MonoType, S )`, `classifyAliasArgs … -> ( Dict Int MonoType, S )`,
`classifyRecordExt … -> ( Dict String MonoType, S )`, `classifyRecordFields … -> ( Dict String MonoType, S )`.
Every `Ok ( x, s )` becomes `( x, s )`; every
`case classifyGo … of Err e -> Err e; Ok ( m, s1 ) -> body` becomes `let ( m, s1 ) = classifyGo … in body`.
The one failing callee, `zonkToMono` (2376; `EngineBug` at 2727/2813), is still `Step`-typed in
this stage, so the `TVar` memo-hit arm (3545-3548) is written with an EXPLICIT re-tuple:

```elm
                        Just pt ->
                            case zonkToMono pt s of
                                Ok ( mono, s1 ) ->
                                    ( mono, s1 )               -- a tuple LITERAL leaf, never `r`
                                Err f ->
                                    Engine.crashFailure f
```

`Ok (Engine.consS (Mono.mRecord allFields) s2)` (3598) becomes `Engine.consS (Mono.mRecord allFields) s2`
— a direct call leaf to `consS` (2753-2758, itself a tuple-literal-leaf function), admitted by the
fresh fixpoint once `consS` is in the table.

**Store: `loadTypeS`.** `loadType` (205-212) never fails; add the direct twin and re-express the
Step version through it so the probe can use it without touching the ~40 `loadType` callers:

```elm
loadTypeS : Can.Type TypeIds.MVarId -> Engine.S -> ( Vars.Variable, Engine.S )
loadTypeS canType s =
    let
        ( v, c ) =
            loadTypeC s.env.superStatic canType (sharedLoadCtx s)
    in
    ( v, writeBackShared c s )

loadType : Can.Type TypeIds.MVarId -> Step Vars.Variable
loadType canType s =
    Ok (loadTypeS canType s)
```

**Translate.**

```elm
classify : Can.Type TypeIds.MVarId -> Engine.S -> ( Mono.MonoType, Engine.S )
classify canType s =
    Store.classifyDirect Mono.tkDeclStoreS canType s

classifyAs : Int -> Can.Type TypeIds.MVarId -> Engine.S -> ( Mono.MonoType, Engine.S )
classifyAs topKind canType s =
    Store.classifyDirect topKind canType s

unifyBestEffortS : Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
unifyBestEffortS v1 v2 s =
    let
        ( ok, s1 ) =
            Store.unifyStep v1 v2 s        -- step 5's shape
    in
    if ok then s1 else s                  -- restore-on-mismatch, as 5284-5291 today

connectTypes : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Engine.S -> Engine.S
connectTypes childCan parentCan s0 =
    let
        ( parentVar, s1 ) =
            Store.loadTypeS parentCan s0

        ( childVar, s2 ) =
            Store.loadTypeS childCan s1
    in
    unifyBestEffortS childVar parentVar s2
```

(If step 5 is not in, `unifyBestEffortS` is `case Store.unifyStep v1 v2 s of Ok ( _, s1 ) -> s1; Err _ -> s`.)

Caller recipe for the 16 `connectTypes` sites: `case connectTypes a b s of Err e -> Err e; Ok ( _, s1 ) -> body`
→ `let s1 = connectTypes a b s in body` (205, 732, 898, 956); `Engine.traverse (\e -> connectTypes …) xs |> Engine.map (\_ -> ())`
→ `List.foldl (\e s -> connectTypes (TOpt.typeOf e) elemCan s) s0 xs` (638, 644, 792, and 296 where
the `Nothing -> Engine.succeed ()` arm becomes `Nothing -> s`); `Engine.andThen (\_ -> step) (connectTypes …)`
→ `Engine.afterU (connectTypes …) step` (1025, 6193, 6226, 7417, 7428 — inside the `Engine.scoped`
at 7428 the argument becomes `Engine.afterU (connectTypes …) (translate expr)`). Note `connectElems`
at 630-650 is a local `Step ()` value: it becomes a local `S -> S` and the
`case connectElems s0 of` at 651 becomes `let s1 = connectElems s0`. `List.foldl` visits
left-to-right exactly as `traverseGo` (1683-1699) does, so the unification order — and therefore
every Point index — is unchanged.

Caller recipe for the 48 `classifyAs`/`classify` sites (`grep -n 'classifyAs\|classify ' Translate.elm`):
the `case classifyAs k t s of Err e -> Err e; Ok ( mt, s1 ) -> body` form (516, 533, 556, 571, 591,
655, 722, 769, 907, 968, 984, 1506, 1877, 1885, 1948, 1955, 1960, 1965, 5558, 5643, 5813, 5808's
inner) → `let ( mt, s1 ) = classifyAs k t s in body`; the Step-valued form inside `Engine.map`/
`Engine.traverse`/`Engine.andThen` (1195, 1235, 1531, 1541, 1565, 1567, 1722, 2257, 2546, 3756,
5755, 5794, 5864, 5916, 6024, 6145, 6189, 6268, 6315, 6785, 6813, 7883) → wrap:
`Engine.lift (classifyAs k t)` (one extra closure at these cold sites for the duration of the
probe; they are desugared in 10e/10f).

Why this proves the mechanism: after the build, `classifyGo`, `classifyList`, `classifyAliasArgs`,
`classifyRecordExt`, `classifyRecordFields`, `classifyDirect`, `classifyAs`, `classify`,
`loadTypeS` and `consS` are zero-capture, ≥1 param, `MTuple 2` results with slot types
`[value, value]`, every leaf a tuple literal or a direct call to one of the others, and each has
a `let ( x, s1 ) = …` site — the full CGEN_064/REP_AGG_001 admission set (Backend.elm:418-450 +
537-585). `connectTypes` returns `S` (a record → `!eco.value`), so it allocates nothing at all.

##### 10c — the failure channel

**Policy (the owner decision plan §3 names).** `EngineBug` and `Unsupported` are, by their own
docstring (Engine.elm:1592-1600), "never a fallback" — every site aborts the build. They become a
process abort via `Engine.crashFailure`, printing the SAME rendered text (`"MonoSolver.bug: …"`,
`"MonoSolver.unsupported: …"`) that `Builder/Generate.elm:1058-1068` surfaces today as an
`Err String`. `UnifyMismatch` (manufactured only in `Store.unifyStep` 1045-1067) is recovered at
exactly three places — `unifyBestEffort` 1076-1082, `unifyStepBestEffort` 5284-5291, and
`classifyRef` 1945-1968 — and aborts at the two `unifyStepCtx` callers (102 `demandUnifyVar`,
5253 `unifyParamsWithArgs`); the recovery sites read a `Bool`, the abort sites crash with the same
text. `LimitExceeded` (MONO_030, raised only by `checkSpecWatchdogs` 1235-1265 from the two
`enqueueSpec*` create paths, 2160/2395) is the ONE failure that must stay a clean `Err`
(`SpecWatchdogTest.elm:106,116`; MONO_030 says "diagnosable, not a bug") — it becomes a
`pendingFailure` checked once per item by `drain`.

**`pendingFailure`.** In `ItemAux` (Engine.elm:1414, 13 → 14 fields; NOT in `S`, which is at 31 of
the 32-slot cap and reserved for step 26):

```elm
    , pendingFailure : Maybe Failure   -- MONO_030 watchdog trip recorded at enqueue time, consumed by Monomorphize.drain once per item; first trip wins
```

`emptyItemAux` (1516-1518): `pendingFailure = Nothing`. `clearedAux` (1529-1531): untouched (it
must flow through a scratch store). `restoredAux` (1537-1539) is `{ inner | … }`, so a trip inside
`withScratchStore` propagates out — correct. `finishNode`'s update at Monomorphize.elm:4716
(`{ aux | currentSpecId = Nothing, qLog = [] }`) and 4162 keep it. `resetItem` (2433-2435) clears
it at the start of the next item, which is after `drain` has read it.

```elm
notePendingFailure : Failure -> S -> S
notePendingFailure f s =
    let aux = s.itemAux in
    case aux.pendingFailure of
        Just _ -> s                          -- first trip wins (today: first trip aborts)
        Nothing -> { s | itemAux = { aux | pendingFailure = Just f } }
```

`enqueueSpec` (2110-2165) and `enqueueSpecKeyed` (2305-2400) become `… -> S -> ( Mono.SpecId, S )`;
`enqueueSpecCommit` (2185-2200) becomes `… -> S -> ( Mono.SpecId, S )` (drop the `Ok`; the D2
unchanged-hit arm still returns the SAME `s` pointer — load-bearing, see the docstring 2170-2183).
The watchdog arms:

```elm
        case watchdog of
            Just failure ->
                enqueueSpecCommit specId reg1 storedChanged (notePendingFailure failure s)
            Nothing ->
                enqueueSpecCommit specId reg1 storedChanged s
```

(the tripped spec IS committed — a valid state is required to continue the item; it is never
processed because `drain` stops first). `Translate.enqueueSpecStamped` (4758-4765) becomes
`( SpecId, S )`; its callers 1914, 3249, 3346, 3377, 3448 and the two direct `Engine.enqueueSpec`
callers 993, 1193 follow the caller recipe (`let`/`Engine.lift`).

`drain` (3978-4045), `SpecializeGlobal` arm:

```elm
        (SpecializeGlobal specId) :: rest ->
            case processItem specId { s | worklist = rest } of
                Err e ->
                    Err e
                Ok s1 ->
                    case s1.itemAux.pendingFailure of
                        Just f ->
                            Err f                    -- renders via Engine.renderFailure at Monomorphize.elm:158: text unchanged
                        Nothing ->
                            drain s1
```

Termination is unaffected: a trip no longer aborts mid-item, but one item's translation is finite
(bounded by its body; `specializeNodeSaturating` and LssInfer are capped), and the next `drain`
step stops. The rendered message is built at trip time with `context ()` = the current global
(1246-1254), so it is byte-for-byte today's message.

**`unifyStep` and the crash form (Store.elm).** With step 5 in, `unifyStep : Var -> Var -> S -> ( Bool, S )`
(the AnswerOk/AnswerErr projection). Keep the `Answer`-returning core private and add:

```elm
unifyAnswer : Vars.Variable -> Vars.Variable -> Engine.S -> ( Unify.Answer, Engine.S )   -- step 5's core

unifyStepOrCrash : (() -> String) -> Vars.Variable -> Vars.Variable -> Engine.S -> Engine.S
unifyStepOrCrash ctx v1 v2 s =
    case unifyAnswer v1 v2 s of
        ( Unify.AnswerOk _, s1 ) ->
            s1
        ( Unify.AnswerErr _ t1 t2, s1 ) ->
            Engine.crashFailure (UnifyMismatch (ctx () ++ " | " ++ mismatchMessage t1 t2 s1))

mismatchMessage : TErr.Type -> TErr.Type -> Engine.S -> String   -- the string at 1046-1064, verbatim
```

`unifyBestEffort` (1076-1082) → `S -> S` via the Bool. `Translate.unifyStepCtx` (5264-5277) is
deleted; 102 and 5253 call `Store.unifyStepOrCrash` (the `ctx` thunk stays a thunk — D3, built
only on the crash path). `unifyStepBestEffort` (5284-5291) → `S -> S` (= `unifyBestEffortS` from
10b; keep one name). `classifyRef` (1945-1968): `loadType` never fails (1952 dead),
`injectArgLambdaMember`'s chain never fails after step 6 (1959 dead), `zonkToMono` fails only on
the two `EngineBug` invariants (1964: a recovery of a bug signal, crash policy applies) — it becomes
straight-line `let` code.

**The 23 crash sites.** Replace `Engine.fail (EngineBug …)` / `Err (EngineBug …)` /
`Err (Unsupported …)` by `Engine.crashFailure (EngineBug …)` at Translate 1008, 1062, 1231, 1275,
7801, 7946, 7980, 7983, 8020, 8030, 8033, 8046, 8062, 8065, 8070, 8088, 8091, 8094, 8099; Store
2727, 2813; LssInfer 95, 827. `crashFailure : Failure -> a` type-checks in a `Step`-typed position
as well as in a direct one, so this is done in 10c regardless of the enclosing function's state.
The three driver-level sites (Monomorphize 3996, 4124, 4434) stay `Err (EngineBug …)` — their
functions keep `Result Failure` for `LimitExceeded` anyway.

**Dead arms deleted in 10c:** Store 1082 (rewritten), 2066 and Store 2037-2075 (`liftIO (UF.get …)`
never fails — `addSlotSource` becomes straight-line), 2479 (`rezonkSettled` census replay: its
`Err _ -> c` "must not fail a build" arm recovered only the two `EngineBug` invariants — under the
policy they crash, which they would on the main path first); Monomorphize 150, 1252, 4283
(`stampSelfSpine` never fails: its only callees are Engine mints, and Engine.elm contains no
`fail`/`Err (` except the enqueue watchdog), 3968 (`papMemberIdFor` never fails); Translate 1952,
1959, 1964, 5290.

##### 10d — the 81 unit steps → `S -> S`

Enumerate: `grep -n 'Step ()' compiler/src/Compiler/MonoSolver/*.elm` (Engine 1725 `modifyS`, 2440
`insertVar`, 2455, 2519, 2707, 2724; Store 1034, 1076, 1137, 1224, 1269, 2035, 2106, 2136; LssInfer
156, 172, 243, 268, 327, 495, 517, 663, 1630, 1645, 1669, 2236, 2282, 2574, 2622, 2662, 2810, 2815,
2907, 2994, 3017, 3092, 3169, 3177, 3184, 3192, 3207, 3222, 3411, 3466; Translate 85, 112, 165, 186,
288, 1108, 1244, 1469, 2165, 2806, 2815, 2826, 2843, 3199, 3503, 3512, 3797, 3831, 4085, 4125,
4163, 4249, 4312, 4330, 4351, 4451, 4463, 4477, 4542, 4770, 5192, 5238, 5264, 5284, 5329, 5385,
5869). Hotness order inside the stage (plan §1): `connectTypes` (done), `enrichFromEnv` 4770,
`insertVar`/`insertVars` 2440/5869, `unifySlotWithSet` 1137, `addSlotSource` 2035, `foldSetWrites`
1224, `injectSpineMemberId` 2810 / `spineGo` 2815, `injectPapSuccessors*` 2574/2622/2662,
`injectArgLambdaMember(Go)` 4330/4351, `injectLambdaMember(Qualified)` 156/172, `flowArgDemands`
3199, `demandUnify` 85, `unifyResultWithExpected` 5329, `unifyParamsWithArgs` 5238, `appShapeConnect`
2165, `applyFacts(Go)` 243/268, `installSources` 327, `joinArrowSets*`/`flowArrowSets*` 2907-3222,
`walkChildren` 3466, then the census-only ones (2806-2843, 3503-3512, 4163, 4249: with step 7 in,
most are `if report then … else s`).

Mechanical recipe (identical evaluation order by data dependency on `s`):

| today | after |
|---|---|
| `f x = Engine.map (\_ -> ()) (g x)` | `f x s = let ( _, s1 ) = g x s in s1` (or `Tuple.second (g x s)`) |
| `f x s = Ok ( (), h s )` | `f x s = h s` |
| `Engine.succeed ()` as a leaf | `s` |
| `Engine.andThen (\_ -> k) (u …)` | `k (u … s)` |
| `Engine.andThen (\a -> k a) (m …)` | `let ( a, s1 ) = m … s in k a s1` |
| `Engine.traverse (\x -> u x) xs \|> Engine.map (\_ -> ())` | `List.foldl (\x s -> u x s) s0 xs` |
| `Engine.foldlS (\x _ -> u x) () xs` (5869 `insertVars`) | `List.foldl (\( n, t ) s -> Engine.insertVar n t s) s0 pairs` |
| `Engine.modifyS f` | `f s` |
| `Engine.liftIO io` then unit | `let ( store1, _ ) = io s.store in { s \| store = store1 }` — or step 8's no-copy read |
| a unit step used as a Step VALUE by a still-Step-typed caller | `Engine.liftU (u …)` / `Engine.afterU (u …) step` until that caller converts |

`joinArrowSets : (S -> S) -> …` and friends already take `S -> S` bumpers — unchanged shape.
Ends with `grep -c 'Step ()' *.elm` = 0 and a count of `liftU`/`afterU` uses (allowed > 0 until 10g).

##### 10e — the per-node tuple steps → `S -> ( a, S )`

Enumerate: `grep -n -E ': .*Step [A-Za-z(]' compiler/src/Compiler/MonoSolver/*.elm | grep -v 'Step ()'`.
Hotness order: **Store** `loadType` family 205-260 (15.6 %; bodies already `\s -> Ok ( v, writeBack… )`
→ `( v, writeBack… )`, `loadTypeS` from 10b becomes `loadType`), `zonkToMono` 2376 (11.8 %; two
`EngineBug` sites now crash — its `Result` disappears together with the `Ok (…)` wrapping of the
`zonkToMonoC` result), `monoTypeToVar` 694; **Engine** `freshVar` 1750 (`liftIO` shape),
the member mints 574-940 and 1777-2015 (`localInstanceTagFor`, `instanceQualTagFor`,
`lambdaInstanceMemberId(Go)`, `lambdaMemberLayoutQualified`, `mintLayoutQualified(Fold)`,
`lambdaInstanceMemberMaybe`, `memberIdFor`, `papMemberIdFor`, `standaloneMemberIdFor`,
`standaloneMemberGlobal`, `kernelMemberIdFor`, `standaloneMemberKernel`), `withScratchStore` 2033
(HOF: `(S -> ( a, S )) -> S -> ( a, S )`; cold, per inference unit), `lookupVar` 2447 and the
multi-stack helpers 2455-2570 (`popNumberMulti`, `isNumberMultiTarget`, `numberMultiRootType`,
`recordNumberInstance(Ord)`, `popLocalMulti`, `isLocalMultiTarget`, `localVarInfo`,
`recordLocalInstance`, `recordMultiInstance`), the M2 caches 2702-2730; **LssInfer** the whole
walk (`signatureFor` 80 at 8.4 %, `instantiateWithSignature` 127, `inferUnit` 364, `resolveUnit`
418, `inferUnitInScratch` 563, `loadMemberSlots` 626, `zonkSignatures` 706, `zonkOneSignature` 773,
`zonkSigGo` 778, `sigEdgesGo` 1029, `ordinalOf(Go)` 1101/1106, `repOrdinal` 1156, `walkExpr` 1239
(8.0 %), `walkFunction` 1470, `walkLiteral` 1516, `walkMaybe` 1600, `walkKeyed` 1615, `walkCall`
1696, `applyCalleeAt` 1733 (4.8 %), `injectPapMemberInfer` 1797, `unifyCallShape` 1835,
`unifyParamsBestEffort` 1927, `localCalleeJoin` 1967, `joinCallArgs` 2009, `kernelCallBoundary`
2095, `kernelArgsGo` 2203, `poisonCallBoundary` 2261, `standaloneMember` 2318,
`standaloneMemberWith` 2497 (takes `S -> ( Int, S )`), `withPapSuccessors` 2527 (HOF),
`mintPapSuccessorIds` 2678, `joinLetUse` 2860, `joinCfHub` 3362, `walkIfPairs` 3427, `walkCollect`
3447 — LssInfer is already written in the `case … of Ok ( a, s1 ) -> …` style (230 `Ok (` sites,
only 2 `andThen`), so this is the mechanical `let` rewrite); **Translate** `translate` 337 /
`translateDispatch` 502 (`( Mono.MonoExpr, S )`), `specializeLambda` 1660, `translateVarRef` 1905,
`classifyRef` 1945, `translateCall` and the three call paths 3213/3272/3392, `memberIdForDepth`
4621 (already direct: only the `Engine.map Just` wrappers go), `stampSelfSpine`, `enqueueSpecStamped`
4758, `deriveKernelAbiTypeWith` 4915 (HOF over `S -> ( Var, S )`), `resultVarAfter` 5343,
`currentMVarEnv` ~5389, `flushLocalMultiEnrich` 6880, `specializeChoice`/`specializeJumps`/
`specializeDecider`/`specializeDtPath` 7380-7429, `lookupAnnotation` 8225, and the rest of the 96;
**Monomorphize** `specializeNode` 4459-4524 → `S -> ( Mono.MonoNode, S )` (the six `Engine.runStep`
sites become direct calls), `defineFrom` 4586-4605 → `( MonoNode, S )`, seeds 150/1252 →
`let ( stamped, s0b ) = Translate.stampSelfSpine …`; `specializeNodeSaturating` (4422-4445),
`processItem` (4048) and `drain` keep `Result Failure` (`let ( monoNode, s1 ) = specializeNode … in
if …`).

Rules that make `$sret` actually fire (Backend.elm:418-450, 537-585, 646-653; Expr.elm:7733-7790):

1. **Tuple-literal leaves.** Every leaf of the result spine (let/destruct bodies, case branches,
   and — with 10a kept — if branches) is a literal `( a, s )`, or a DIRECT saturated call to
   another function that satisfies these rules (the fresh fixpoint, ≤ 6 rounds). After a
   destructure, RE-TUPLE: `case f x s of ( a, s1 ) -> ( a, s1 )`, never `-> r` on a tuple-typed
   variable, never `Tuple.mapFirst …`.
2. **No `if` on the result spine unless 10a is kept.** If 10a was reverted, an `if`-shaped leaf
   keeps the function boxed; such functions are written so the `if` decides a scalar that is then
   tupled once (`let s1 = if c then u s0 else s0 in ( a, s1 )`), or the branch bodies are `S -> S`.
3. **Zero captures, ≥ 1 parameter, top-level.** A local `let go … s = …` that captures is never
   promoted; lift it to top level and pass what it captured. Curried definitions
   (`f x = \s -> …`) are written with the explicit trailing `s` (`f x s = …`, the A1 style
   already used at Store.elm:205-212) so every call is saturated.
4. **Direct saturated call at a `let ( a, s1 ) = f … s0` or `case f … s0 of ( a, s1 ) -> …` site.**
   Both lower to `TOpt.Let (TOpt.Def tmp call) (Destruct …)` (LocalOpt/Typed/Expression.elm:652-680)
   and to `MonoLet (MonoDef _ (MonoCall …))` which `collectSretSites` (646-653) matches; the tuple
   case is admitted by `walkPromo`'s T1.3.1b arm (Expr.elm:7407-7430 + the `MonoCase` arm). A
   function that is ONLY ever called as a leaf of other functions is never promoted (the base
   table requires one let-position site), and then its leaf callers lose freshness too — every
   hot tuple function needs at least one `let ( a, s1 ) = …` site (it will have).
5. **Result arity 2 or 3.** `( a, b, s )` is fine; wider results go through a record (boxed) —
   avoid on hot paths.
6. **Indirect calls box.** A function passed as a VALUE (`traverseS translate xs`) is called through
   its shim, which heap-allocates the tuple. Hot traversals get a dedicated direct loop
   (`translateList`, §4-10f) — the generic `traverseS` is for cold, arity-sized lists.

Order-of-evaluation: every `let ( a, s1 ) = … s0` chain is ordered by the `s` data dependency, so
mint order (Point indices, member ids, spec ids, intern insertion) is exactly today's. A pure read
(`let a = f s0`) may float; that is harmless because it reads only. Never drop an intermediate
whose result is unused but whose `S` is threaded (`let ( _, s1 ) = censusStep s0`).

##### 10f — the `andThen` nests, scopes, traversals, pure reads

Enumerate: `grep -n 'Engine\.\(andThen\|map\|map2\|traverse\|foldlS\|getS\|modifyS\|liftIO\|succeed\|scoped\|lift\|liftU\|afterU\)\b' compiler/src/Compiler/MonoSolver/*.elm`.

Hot nests, in plan §2 / findings A8 order, each desugared with the 10d/10e recipe:

- `translateGlobalCallFast` 3213-3270 — 6 `andThen` + `getS` (via `cachedSchemeMono`) → a `let`
  chain: `let ( funcMonoType, s1 ) = cachedSchemeMono … s0 in if List.length paramMonos < argCount
  then translateGlobalCallSlow … s1 else let s2 = flowArgDemands … s1; s3 = if groundCanType callCanType
  then s2 else demandUnify callCanType resultMonoType s2; ( monoArgs, s4 ) = translateList args s3;
  ( specId, s5 ) = enqueueSpecStamped global funcMonoType s4 in ( Mono.MonoCall …, s5 )`.
- `translateGlobalCallGroundMemo` 3272-3392 — hit 4 / miss 12 closures → the same shape.
- `appShapeConnect` 2165-2212 (8 `andThen` + `getS` + `succeed`) → `S -> S` with a `let` chain;
  `buildAppVar` 2215-2228 (2 closures per arg) → `S -> ( Var, S )` with the recursive call in
  let position and a tuple-literal leaf (`freshVar` is `liftIO`-shaped: `( v, { s | store = … } )`).
- `unifyParamsWithArgs` 5238-5261 (3 per arg) → `S -> S`; `resultVarAfter` 5343-5362 (2 per depth)
  → `S -> ( Maybe Var, S )` with the `noteAppliedStep` prefix as an `S -> S` `let`;
  `unifyResultWithExpected` 5329-5340 → `S -> S`.
- `injectArgLambdaMember` 4330-4332: `injectArgLambdaMemberGo arg canVar (argDeepCensus arg s)`
  (the census stays sequenced, it is just a `let`).
- `translateIndirectCallBody` 2231, `specializeLambda` 1660, the TailDef let arm 1547/1563,
  `deriveKernelAbiTypeWith` 4915, `translateIfBranch` 1019-1027 (`map2`-free: three `let`s),
  `specializeChoice`/`specializeJumps` 7409-7429.
- Container arms of `translateDispatch` (List 625-665 and the tuple/record arms): `traverse |> map`
  → `translateList`; `foldlS` per record field → a direct recursive fold returning `( acc, S )`.

`Engine.scoped` (2631-2638) and `withLoopFrame` (233): a HOF over a closure makes the inner call
indirect, so at the 15 hot sites (1547, 1563, 1716, 5699, 5759, 5790, 5926, 6247, 6312, 6782,
7390, 7392, 7402, 7404, 7428) inline the push/pop:

```elm
-- today: Engine.scoped (Engine.andThen (\_ -> translate body) (insertVars monoParams))
let
    ( monoBody, s2 ) =
        translate body (insertVars monoParams s1)
in
( monoBody, Engine.restoreScope s1 s2 )       -- restoreScope outer inner = { inner | varEnv = outer.varEnv }
```

`withLoopFrame` splits into `pushLoopFrame : Name -> List … -> S -> S` / `popLoopFrame : S -> S -> S`
(the frame stack restore is `{ s2 | itemAux = { aux2 | loopParams = s0.itemAux.loopParams } }` —
read 233-260 for the exact fields it saves). Keep `scoped`/`withLoopFrame` as direct-state HOFs
for cold sites if any remain.

Traversals: add to Engine

```elm
traverseS : (a -> S -> ( b, S )) -> List a -> S -> ( List b, S )      -- traverseGo minus Result; cold lists
traverseS f items s =
    case items of
        [] -> ( [], s )
        x :: rest ->
            let ( b, s1 ) = f x s
                ( bs, s2 ) = traverseS f rest s1
            in ( b :: bs, s2 )
```

and in Translate the dedicated direct loops for the per-node cases: `translateList : List (TOpt.Expr
TypeIds.MVarId) -> S -> ( List Mono.MonoExpr, S )` (same shape, `translate x s` written out — a
SATURATED direct call, so this site is an sret site and `translateList` itself has tuple-literal
leaves), `classifyParams : List ( A.Located Name, Can.Type … ) -> S -> ( List ( Name, MonoType ), S )`
for the 1541/1567/1722/5808 shape, `connectAll` (10b's folds). Same left-to-right order as
`traverseGo`.

Pure reads (findings A2): `lookupVar`, `localVarInfo`, `isLocalMultiTarget`, `isNumberMultiTarget`,
`numberMultiRootType`, `lookupSchemeMono`, `lookupCallMemo`, `currentMVarEnv`, `lookupAnnotation`
become `S -> a` (no tuple; `localVarInfo : String -> S -> ( Bool, Bool, Maybe MonoType )` keeps its
3-tuple — an `MTuple 3` result is itself sret-eligible when let-bound). `putSchemeMono`,
`putCallMemo`, `noteAppliedStep`, `bump*` are `S -> S`. `liftIO` survives as a plain direct helper
`liftIO : IO.IO a -> S -> ( a, S )` (tuple-literal leaf) for the remaining store ops; with step 8
in, root reads use `UF.peekS` and no `S` copy.

##### 10g — deletion

Delete Engine.elm:1614-1738 except `liftIO` (kept, direct) and `traverseS`; delete `lift`, `liftU`,
`afterU`, `restoreScope`-style helpers that ended up unused; update the exposing list (lines 1-4)
and the three `exposing (Failure(..), Step)` imports (Store.elm:34, LssInfer.elm:59,
Translate.elm:32) to `exposing (Failure(..))`. Then the module doc of Engine ("STEP MONAD" section
header at 1588) and Translate.elm:13 ("returns `Engine.fail (Unsupported …)`") are reworded.

#### 5. Edit sequence

Every numbered edit leaves `elm make compiler/src/Terminal/Main.elm` green (1 s type-check) and the
unit suite runnable. Stage boundaries are loop entries.

**10a**
1. Backend.elm: `MonoIf` arm in `sretTailOk` (after 732) and `sretFreshTailOk` (after 597);
   docstring 405-416 and 656-660.
2. Expr.elm: `spineResultMlirType` extracted from `generateCase` 7005-7018; `generateCase` calls it.
3. Expr.elm: `generateIf` new parameter + condition hygiene + `emitSpineYield`/`finishSpineCase`
   (both-yield path only); thread the parameter through 4789/4808/4812/4855/4867/4913.
4. Expr.elm: `generateExpr` `MonoIf` arm 460-470 → `generateIf ctx branches final monoType`.
5. Build (`cmake --build build --target full` type-checks the backend and runs E2E); add an E2E
   Elm program `SretIfSpineTest` beside `PapCopyStampTest` (grep -rl PapCopyStampTest to find the
   directory): a top-level `step : Int -> S -> ( Int, S )` whose body is `if` on the spine, called
   at a `let ( a, s1 ) = step …` site; the test asserts the program's result only — the promotion
   is pinned by the count in §6.

**10b**
1. Engine.elm: `renderFailure` moved in, `crashFailure`, `lift`, `liftU`, `afterU` (+ exposing);
   Monomorphize.elm:158 → `Engine.renderFailure`, delete 5080-5098.
2. Store.elm: `loadTypeS` + `loadType` via it.
3. Store.elm: classify family 3522-3702 (one edit — the six functions call each other).
4. Translate.elm: `classify`/`classifyAs` and their 48 sites (`let` form or `Engine.lift`).
5. Translate.elm: `unifyBestEffortS`, `connectTypes`, the 16 callers.
6. Unit suite; loop Phase 1-3; probe counts (§6).

**10c**
1. Engine.elm: `ItemAux.pendingFailure`, `emptyItemAux`, `notePendingFailure`.
2. Engine.elm: `enqueueSpecCommit`, `enqueueSpec`, `enqueueSpecKeyed` → `( SpecId, S )`;
   Translate `enqueueSpecStamped` + 7 callers (via `Engine.lift` where the caller is still a chain).
3. Monomorphize.elm: `drain` check.
4. Store.elm: `unifyAnswer`/`unifyStep` (Bool)/`unifyStepOrCrash`/`mismatchMessage`; `unifyBestEffort`
   → `S -> S` (callers via `liftU`).
5. Translate.elm: delete `unifyStepCtx`; 102 and 5253 → `Store.unifyStepOrCrash`; `unifyStepBestEffort`
   → `S -> S`; `classifyRef` straight-line.
6. The 23 `crashFailure` sites; delete the 11 dead `Err _` arms (each inside the function it
   belongs to: `addSlotSource` 2035-2078 becomes straight-line here).
7. `SpecWatchdogTest` must still pass unchanged (the message is identical); `TestPipeline`.

**10d** — bottom-up so each edit compiles: Engine (2440, 2455, 2519, 2707, 2724; `modifyS` stays
until 10g) → Store (1137, 1224, 1269, 2035, 2136; 1034/1076 done) → LssInfer (the 30, leaves first:
2810/2815, 2574/2622/2662, 156/172, 327, 243/268, 1630/1645/1669, 2236, 2282, 2907-3222, 3411,
3466, 495/517, 663) → Translate (the 37, leaves first: 5385, 5264-deleted, 5284, 5329, 5238, 5192,
4770, 4542, 4477, 4451/4463, 4330/4351, 4312, 4249, 4163, 4125, 4085, 3831, 3797, 3512/3503, 3199,
2806-2843, 2165, 1469, 1244, 1108, 288, 186, 165-done, 112, 85, 5869). At each function: convert
the body, then every caller in the `case Ok/Err` style to `let`, and every caller that uses it as
a Step value to `liftU`/`afterU`. One loop entry for the stage (or `10d-i` Engine+Store+LssInfer,
`10d-ii` Translate if the first is too big to attribute).

**10e** — same bottom-up discipline: Store (205-260, 694, 2376) → Engine (1750, 574-940, 1777-2015,
2033, 2447-2570, 2702-2730) → LssInfer (1239 `walkExpr` and everything it calls; `signatureFor` 80
last) → Translate (leaves first, `translate`/`translateDispatch` last) → Monomorphize
(`specializeNode`, `defineFrom`, seeds; delete the 8 `runStep` uses). Split as `10e-i`
Store+Engine, `10e-ii` LssInfer, `10e-iii` Translate+driver if needed.

**10f** — per nest, hottest first (list in §4-10f); `translateList` and the scope inlining are the
first two edits because they gate the sret sites of everything that calls `translate`.

**10g** — delete, fix the exposing lists, rerun the §6 greps (must be empty), reword the two docs.

#### 6. Verification

Per stage: Phase 1-3 of `benchmarks/lss-compile-opt-loop.md` (three cold runs, medians, fixed-point
`cmp`), then on a win Phase 4: `cmake --build build --target elm-tests` (unit, includes
`SpecWatchdogTest`), `cmake --build build --target full` (E2E), `benchmarks/mlir-workload-rail.sh`
(633 workloads; for 10b–10g the sha256 rail and the LSS census must both be IDENTICAL; for 10a the
sha256s drift for every workload with an if-spine tuple return while the census is identical —
record the drift count in the entry).

**10a** is a codegen stage: Phase 1.5 applies (self-compile with `eco-opt10a` to `eco10a-b.mlir`,
lower to `eco-opt10a-b`, that is the candidate; gate B==C). Attribution counts on the two
artifacts (bytecode string tables):

```bash
for f in bin/eco-compiler.mlir bin/eco10a.mlir bin/eco10a-b.mlir; do
  printf '%s workers=%s monosolver=%s\n' "$f" \
    "$(strings -n 6 $BK/$f | grep -c '[$]sret$')" \
    "$(strings -n 6 $BK/$f | grep -c 'MonoSolver.*[$]sret$')"
done
```

`eco10a.mlir` (old backend, unchanged source) must equal the base 464/19; `eco10a-b.mlir` (new
backend) is strictly higher — the delta is the if-spine population.

**10b** (byte-identical stage; `ecoN.mlir` is produced by the kept 10a compiler): the same count on
`bin/eco10b.mlir` must show `Compiler_MonoSolver_Store_classifyGo_$_*$sret`,
`…classifyList…$sret`, `…classifyAliasArgs…$sret`, `…classifyRecordFields…$sret`,
`…classifyRecordExt…$sret`, `…classifyDirect…$sret`, `…Translate_classifyAs…$sret`,
`…Store_loadTypeS…$sret`, `…Engine_consS…$sret` (`strings -n 6 $BK/bin/eco10b.mlir | grep 'MonoSolver.*[$]sret$' | sort`),
and `Compiler_MonoSolver_Translate_connectTypes_$_*` must appear with NO `$sret` twin (it returns
`S`, nothing to promote). If `classifyGo` is missing, one of its leaves is not a tuple literal /
promoted call — find it with `ecoc --emit=mlir` (text dump on stderr) and rule 1 of §4-10e.

Allocation attribution (untimed, labelled leg, `ECO_INLINE_ALLOC=0` is a LOWERING flag):
```bash
ECO_INLINE_ALLOC=0 $BOOT $BK/bin/eco10b.mlir -o $BK/bin/eco-opt10b-alloc
rm -rf $BK/eco-stuff && ( cd $BK && env $ENV ./bin/eco-opt10b-alloc make --optimize \
   --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp \
   --output=bin/alloc10b-out.mlir /work/compiler/src/Terminal/Main.elm > alloc10b.stdout 2> alloc10b.stderr )
grep -a -A40 'Objects allocated' $BK/alloc10b.stdout | grep -a 'Tuple2\|Custom\|Closure'
```
against the same leg on `eco-opt-prev` (kept 10a). Expected: `Custom` and `Tuple2` down by roughly
the number of `connectTypes` + `classifyAs` calls (each was `Ok`+`Tuple2` = 2 objects), `Closure`
down by the `andThen` continuations those sites had.

**10c**: byte-identical; `SpecWatchdogTest` green; a deliberate `EngineBug` (temporarily point one
site at `crashFailure`, e.g. run a program that hits `Unsupported (nodeKind expr)`) prints
`MonoSolver.unsupported: …` / `MonoSolver.bug: …` and exits non-zero — check once by hand, not as
a pin.

**10d–10f**: byte-identical, unit + E2E + rail; the `strings … | grep -c 'MonoSolver.*[$]sret$'`
count grows stage by stage (record it in each entry — it is the mechanism's coverage); minor GC is
the judged stat. `grep -c 'Step ()'` = 0 after 10d; the `Step`-signature grep = 0 after 10e; the
combinator grep = 0 after 10f (adapters only).

**10g**: `grep -n '\bStep\b\|runStep\|Engine\.lift\|liftU\|afterU' compiler/src/Compiler/MonoSolver/*.elm`
returns only comments; `grep -n 'Result Failure' *.elm` returns only Monomorphize's `drain`,
`processItem`, `specializeNodeSaturating` and the top-level `monomorphizeWithReportAssigned`.

#### 7. Risks, gotchas, and what NOT to do

- **R1 — 10a can lose on wall.** More `$sret` workers is not free (T1.3.6's tail-func widening
  cost +4 %, Config.elm:708-712). Under the loop rule 10a is reverted if wall rises; then rule 2
  of §4-10e (no `if` on result spines) governs 10b–10f, and 10a is re-attempted as `10a'` after
  10e, when the population of if-spine tuple functions is the converted MonoSolver rather than the
  front end.
- **R2 — the crash policy is a behaviour change on FAILING builds only.** Today an `EngineBug`
  surfaces as `Exit.Generate`'s clean error; after 10c it is a process abort with the same text.
  The XHR/JS variant of `Eco.Crash.crash` throws — the JS self-compile route (memory:
  `eco-jsselfcompile-needs-16gb-heap`) reports it as an uncaught exception. `LimitExceeded` stays
  clean by design; do not move it to a crash "for simplicity" — `SpecWatchdogTest.elm:106,116`
  pins the clean path.
- **R3 — record caps.** `S` is 31 of 32 fields: `pendingFailure` goes in `ItemAux` (13 → 14), never
  in `S`. `LssStats` is AT 32. Do not add any field to `S` in this step (step 26 regroups it).
- **R4 — re-tuple leaves.** `case f x s of ( a, s1 ) -> ( a, s1 )` is required; `-> r` on a
  tuple-typed variable, `Tuple.mapFirst`, or returning a tuple-typed `let` binding silently
  demotes the whole function to a heap tuple (Backend.elm:722-737 accepts only `MonoTupleCreate`
  leaves and promoted calls). Likewise a helper that captures (local `let go`) or is called
  only through `List.foldl f` is never promoted.
- **R5 — LOAD-BEARING comments to preserve verbatim:** `consS`'s exact-size guard (Engine.elm:
  2761-2775 — the `withIntern` size test IS what keeps `S` un-copied on 10^7 hash-cons hits);
  `enqueueSpecCommit`'s D2 same-pointer return (2170-2183); `checkSpecWatchdogs`' thunked context
  (1240-1254); `unifyStepCtx`'s D3 thunk (5265-5268 — keep the thunk in `unifyStepOrCrash`);
  `clearedAux`'s NOTE (1521-1526: anything holding scratch-store Points must be cleared AND
  restored — `pendingFailure` holds none, so it flows through both).
- **R6 — order of effects.** The desugaring is sound only because `Step` is a strict state monad:
  `map2 f a b` runs `a` then `b`; `traverse` and `foldlS` run left-to-right; keep those orders
  (`List.foldl`, `traverseS`, the direct loops). A reordered mint changes Point indices, member
  ids, spec ids and intern insertion order — all visible in emission; the fixed-point `cmp`
  catches it, but only after a 12-minute build, so review every fold direction at edit time.
- **R7 — do not "optimise" while converting.** No skipping of census `S -> S` prefixes
  (`argDeepCensus`, `noteAppliedStep`, `bump*`), no merging of two `loadType`s, no dropping of the
  scope restore in `scoped` (N11: the copy IS the restore). Those are steps 7, 8, 9 and 26 —
  separate entries or the attribution is lost.
- **R8 — transitional adapters hide allocation.** `Engine.lift (f x)` costs one closure more than
  today at every site it is used; a stage measured with many `lift` sites can read flat. Keep the
  `lift`/`liftU`/`afterU` use counts in each entry and drive them to zero by 10g.
- **R9 — traversals through a function value box the tuple** (rule 6): `traverseS translate` is
  NOT the same as `translateList`; the memory note `hof-inline-undoes-lss-stamp` shows the
  post-mono inliner may or may not beta-reduce such a site — do not rely on it for the hot ones.
- **R10 — build hygiene.** `rm -rf $BK/eco-stuff` before every run; `build-kernel/src` is a
  symlink (the `Main.elm` path argument does not select the tree); `--target full` never re-runs
  Stage 5/6 (the 32-slot native-lowering cap is only checked by the loop's own lowering);
  `strings`, not `grep -c`, on the bytecode artifacts (§1).
- **Not in scope (plan §4):** N11's `resetItem`/`processItem` copies, N14's already-guarded paths,
  N9 tail recursion (`traverseGo`'s non-tail shape over `TOpt.List` literals is kept as is), GC
  tuning (N22), and `S` regrouping (step 26).
- **Invariants touched:** CGEN_064, CGEN_067, REP_AGG_001 are relied on, not amended (10a lowers
  an `if` to the same `eco.case`-on-`i1` join shape the Phase 3.4 #1 clause already admits);
  MONO_030 (watchdog semantics: the message and the clean failure are preserved; the trip point
  moves from "immediately" to "end of the item"); MONO_029 (stale-read barrier: `ItemAux` read
  lists are untouched); LSS_006/LSS_010 (mint order and the drain flush are unchanged by
  construction). No csv row changes; if the owner wants the "end of item" watchdog latency
  recorded, add it to MONO_030's text.

#### 8. Effort

**L overall** (the largest rewrite in the plan: 263 signatures, ~500 combinator uses, ~450
`Ok`/`Err` arms across four files), split into seven loop entries so each is attributable:
10a **S** (two files, ~60 lines, plus the extra bootstrap turn); 10b **S-M** (~70 sites, one day);
10c **M** (failure plumbing + 23 crash sites + 11 dead arms, one to two days, the only stage with a
semantic decision in it); 10d **L** (81 functions and all their callers; split `10d-i`
Engine/Store/LssInfer, `10d-ii` Translate if attribution needs it); 10e **L** (182 functions;
split `10e-i` Store+Engine, `10e-ii` LssInfer, `10e-iii` Translate+driver); 10f **M-L** (the
~20 hot nests, scope inlining, `translateList`, pure-read twins — this is where the `$sret`
coverage and the minor-GC drop mostly land); 10g **S**. Each sub-entry is judged against the last
win; a stage that reads flat on wall but drops minor GC is a win under rule 2 and is kept.

### Step 11 (was 6). Stop rendering and re-widening the whole demand type on every enqueue

#### 1. Goal and expected effect

Per `enqueueSpecStamped` (~141K/run: every global reference — `translateVarRef` T:1914 — and every
global call — T:3249/3346/3377/3448) the code today does THREE full walks of the demand type and up
to two multi-KB string renders:

1. `stampSelfSpine` T:4691-4705 runs the PURE `Mono.widenSets` (Mo:2056, non-interned rebuild of every
   node, `Dict.map` per record) and renders `Mono.toComparableMonoType` of it EAGERLY (T:4702-4703),
   although the string is consumed only in the depth-0 `Just _ -> case groundKey of Just tk` arm of
   `memberIdForDepth` (T:4664-4677) — i.e. only for Define/TrackedDefine/Link/Cycle heads with
   `declaredArity > 0` on an `MFunction` demand. Arity-0 globals, kernel-alias heads (T:4627),
   Ctor/Enum/Box (T:4634-4642), Kernel/Manager/Port nodes (T:4644-4654) and non-arrow demands never read it.
2. `enqueueSpecKeyed` E:2305-2400 runs a SECOND, interned `Intern.widenSets` (E:2329-2333) on the
   STAMPED type — consumed only under `created` (43K) via `recordSpecWidenedKey` E:2379-2381, or on the
   over-budget arm (`maxSpecsPerGlobal` default 0 = never, E:2318).
3. On creation the string is rendered AGAIN (E:2381 `Mono.toComparableMonoType keyType`) for
   `specWidenedKeys`; the same widened object was already rendered in (1).
4. `stampSpineGo` T:4708-4756 rebuilds every spine node (`Mono.mFunction anno2 args ret2`, T:4748) even
   in the `regid|alreadySet` arm where `anno2 == anno`, so the demand handed to the registry is NEVER
   pointer-identical to the stored type: `Registry.getOrCreateSpecIdKeyed` R:147 `storedType == storeType`
   walks structurally on every hit, and the object stored in `reverseMapping` is non-canonical.

Measured share (plan §1): `enqueueSpecStamped` 9.2 % inclusive of the mono window —
`stampSelfSpine` 4.0 %, `Intern.widenSets` 5.1 %, `enqueueSpecKeyed` 6.3 %. Plan estimate for this step: 5-7 %
of the mono window (~2.5-3.5 % of wall, i.e. ~10-14 s of 398.7 s).

Loop stats expected to move: **wall down**; **minor GC down** (the pure widen allocates a full tree copy
per enqueue — for `Step`-typed demands that embeds the 31-field `S` record, hundreds of nodes — and the
render allocates a KB-scale string; both become garbage immediately); promoted MiB and majors flat;
RSS flat-to-slightly-down (canonical stamped spines in `reverseMapping` share structure).

**BI: yes, required.** Argument, part by part:
- The widened type is annotation-blind (`widenSets` stamps `topWiden` on EVERY arrow), so widening the
  UNSTAMPED input produces the same structure as widening the STAMPED one; the K6 canonicalisation
  makes it the same OBJECT once interned. The Define-arm key string and the `specWidenedKeys` string are
  renders of that one object, so they are equal by construction (today's comment at T:4697-4700 asserts
  this equality between the pure and interned twins; ComparableKeyEncodingTest:136-158 pins
  `eqKeySpec (Intern.widenSets t) (Mono.widenSets t)`, and `eqKeySpec` ≡ `toComparableMonoType` equality).
- The intern table is a sharing cache, never iterated (`I` exports only `size`, `hashCons`, `widenSets`;
  no fold/toList exists — `grep -n "HashMap.foldl\|HashMap.toList" I` is empty). Inserting the stamped
  spines (new) or moving the widen earlier changes which `==`-equal object is canonical, which no consumer
  can observe (all consumers compare with `==`/`eqKeySpec`, both content-based).
- Member-id MINT ORDER is unchanged: the same `memberIdForDepth` calls happen, in the same order, with the
  same keys (see §7 for the one variant that would change it and is therefore NOT in this step).

#### 2. Preconditions

None hard. Step 6 (flag residue) is not required; if it has landed, the dead inner `Intern.widenSets` at
E:2126-2135 is already gone (it is unreachable either way: E:2114 routes `lss.enabled` to `enqueueSpecKeyed`).

Verify before starting:
```bash
# 1. the intern table is never iterated (the BI argument depends on it)
grep -n "HashMap.foldl\|HashMap.toList\|HashMap.values\|HashMap.map" /work/compiler/src/Compiler/AST/Intern.elm   # expect: no output
# 2. the two size-guard readers that must switch to `entries` (§4.1)
grep -rn "Intern.size" /work/compiler/src --include=*.elm      # expect exactly E:2781 and St:2255
# 3. every stampSelfSpine / enqueueSpecStamped caller (inventory below)
grep -n "stampSelfSpine\|enqueueSpecStamped\|Intern.widenSets\|Mono.widenSets" /work/compiler/src/Compiler/MonoSolver/*.elm
# 4. baseline census for the attribution leg (§6): the regid cells
#    (report on, UNTIMED, separate leg per benchmarks/lss-compile-opt-loop.md §5)
```

#### 3. Inventory of touched code

| file | function (lines) | what changes |
|---|---|---|
| I | `type Intern` 71-74, `empty` 79-82, `readOnly` 108-119, `size` 123-132 | second table (`widened` memo) inside the `Intern`/`ReadOnly` payloads; new `entries`; `size` keeps meaning "distinct structures" |
| I | `hashCons` 141-190, `probe` 194-201, `probeRO` 211-218 | pattern-match arity change only (two-field constructors) |
| I | `widenSets` 270-321, `widenList` 324-338 | per-composite memo probe/insert around today's body (11b) |
| I | module export list 1-4 | export `entries` |
| E | `withIntern` 2779-2785 | guard on `Intern.entries` (not `size`) |
| St | `consC` 2249-2260 | guard on `Intern.entries` |
| E | `enqueueSpecKeyed` 2305-2400 | split into `enqueueSpecKeyedWith widened preRendered global monoType` (body) + `enqueueSpecKeyed` (computes the widen, delegates); `recordSpecWidenedKey` call reuses `preRendered` |
| E | export list line 8 | export `enqueueSpecKeyedWith` |
| E | `enqueueSpec` 2110-2160 | unchanged (still calls `enqueueSpecKeyed`; callers T:993 Accessor, T:1193 port) |
| T | `memberIdForDepth` 4621-4689 | depth-0 classification extracted to pure `headKindOf`; mint arms unchanged |
| T | `stampSelfSpine` 4691-4705 | becomes a wrapper: interned widen + `stampSelfSpineWith`; the pure widen + eager render are deleted |
| T | new `stampSelfSpineWith` | takes the widened object; renders the key ONLY for `HeadGround` heads on `MFunction` demands with arity > 0; returns `( stamped, preRendered )` |
| T | `stampSpineGo` 4708-4756 | return the input by pointer when the frame changed nothing; `Engine.consS` the rebuilt node otherwise; `groundKey : Maybe String` stays |
| T | `enqueueSpecStamped` 4758-4765 | ONE `Intern.widenSets` + `withIntern`, then `stampSelfSpineWith`, then `Engine.enqueueSpecKeyedWith`; lss-off arm calls `Engine.enqueueSpec` directly |
| T | callers of `enqueueSpecStamped`: 1914 (`translateVarRef`), 3249 (`translateGlobalCallFast`), 3346 (`translateGlobalCallGroundMemo`), 3377 (GroundMemo miss/hit tail), 3448 (`translateGlobalCallSlow`) | NO change (signature kept) |
| M | callers of `stampSelfSpine`: 146 (main seed), 3964 (flags-decoder seed), 4279 (completion join L1 re-stamp; note it DISCARDS the returned `S`: `Ok ( stamped, _ )`) | NO change (wrapper kept) |
| tests | `ComparableKeyEncodingTest` 136-158 (`Intern.widenSets t Intern.empty`), 161-257 (`Intern.size` pins after `hashCons` only) | unchanged API, unchanged semantics; ADD a memo pin (§6) |
| tests | `LayoutQualTest` 60-100 (`Mono.widenSets` string pins), `LssRegIdentityTest` (pipeline-level regid pins) | unchanged; rerun |

Pure `Mono.widenSets` callers that can/cannot route through the interned memo (brief question):
- T:4703 — YES, this step (the whole point).
- M:3932 `seedSpec` — 1-2 calls per run; leave (routing would be correct but buys nothing).
- E:1946 `groundSetMembers` — NO: pure, called from `Store.zonkSetSlot` with only `table`/`nextId` in hand
  (LSS_019's "pure so Store's zonk can share it"); `ZonkCtx` does carry `intern` (St:2221) so it COULD be
  threaded, but step 13 replaces this string with a class id — do not touch here.
- `MonoInlineSimplify.elm:864` — NO: post-mono, no table in reach (step 25 territory).
- Mo:2216-2364 internal uses (`joinWidened`, `eqModuloTopLabel`, …) — NO: `Monomorphized` cannot import `Intern`.

#### 4. Design

##### 4.1 `Intern`: a second table, memoising `widenSets` per canonical input node (11b)

```elm
type Intern
    = Intern (HashMap.HashMap MonoType MonoType) (HashMap.HashMap MonoType MonoType)   -- nodes, widened
    | ReadOnly (HashMap.HashMap MonoType MonoType) (HashMap.HashMap MonoType MonoType)
    | Disabled

empty = Intern HashMap.empty HashMap.empty
readOnly intern = case intern of Intern m w -> ReadOnly m w ; _ -> intern

{-| Distinct structures canonicalised (report semantics; unchanged). -}
size intern = case intern of Intern m _ -> HashMap.size m ; ReadOnly m _ -> HashMap.size m ; Disabled -> 0

{-| EXACT "did the table change" stamp for the write-back guards (`Engine.withIntern`,
`Store.consC`): both tables only ever grow, so equal counts imply the same value. -}
entries : Intern -> Int
entries intern =
    case intern of
        Intern m w -> HashMap.size m + HashMap.size w
        ReadOnly m w -> HashMap.size m + HashMap.size w
        Disabled -> 0
```
`hashCons`/`probe`/`probeRO` keep their bodies; the `Intern m` / `ReadOnly m` patterns become `Intern m w` /
`ReadOnly m w`, and `probe`'s miss arm rebuilds `Intern (HashMap.insert … m) w`.

Memo keyed by the INPUT node — hash `Mono.specHashOf` (reads the packed Int already on the node, O(1);
leaves never reach the memo), eq `==` (pointer-fast on a canonical input, which every demand type is:
`classifyDirect`/`zonkFlatC`/`canTypeToMonoWithI` hash-cons bottom-up; stamped spines become canonical
via §4.3's `consS`). `==` separates `LTop`/`LVar`/`LSet` labels, so two differently-annotated inputs are
two memo entries that map to the same widened object — correct, since the memo is exact on the input.

```elm
widenSets : MonoType -> Intern -> ( MonoType, Intern )
widenSets monoType intern0 =
    case monoType of
        Mono.MFunction _ _ _ _ -> memoised monoType intern0
        Mono.MList _ _        -> memoised monoType intern0
        Mono.MTuple _ _       -> memoised monoType intern0
        Mono.MRecord _ _      -> memoised monoType intern0
        Mono.MCustom _ _ _ _  -> memoised monoType intern0
        _ -> ( monoType, intern0 )   -- leaves and MVar: identity, as today

memoised : MonoType -> Intern -> ( MonoType, Intern )
memoised mt intern0 =
    case intern0 of
        Disabled -> widenNode mt intern0
        Intern _ w ->
            case HashMap.get Mono.specHashOf eqExact mt w of
                Just widened -> ( widened, intern0 )          -- same table value back: withIntern stays a no-op
                Nothing ->
                    let ( widened, intern1 ) = widenNode mt intern0 in
                    ( widened, insertWidened mt widened intern1 )
        ReadOnly _ w ->
            case HashMap.get Mono.specHashOf eqExact mt w of
                Just widened -> ( widened, intern0 )
                Nothing -> widenNode mt intern0                -- probe-only view: never registers

insertWidened : MonoType -> MonoType -> Intern -> Intern
insertWidened mt widened intern = case intern of
    Intern m w -> Intern m (HashMap.insert Mono.specHashOf eqExact mt widened w)
    _ -> intern

-- `widenNode` = today's `widenSets` body (I:270-321) verbatim, arms recursing through `widenSets`
-- (so every composite child probes the memo before rebuilding) and ending in `hashCons`.
```
Determinism: a memo hit returns the object the FIRST computation produced; a recomputation would hash-cons
to the very same canonical object (I:194-201 returns the existing entry on a `==` hit), so hit and miss are
pointer-identical results. The memo is therefore a pure cache — no fixed-point risk.

Size accounting: with `entries`, a widen whose output nodes all pre-exist but whose INPUT is new still
grows `entries` by one (the memo row), so `withIntern`/`consC` write the table back and the memo is kept.
Had the guards stayed on `size`, exactly the common "already ⊤-widened demand" case would have had its
memo row dropped on every call.

##### 4.2 One widen per enqueue, shared (11a)

```elm
-- Translate.elm
{-| The depth-0 identity class of a global's spine head — the E9.2 reference-path chooser
(`memberIdForDepth`'s arms), separated from the mint so the caller can decide whether the
ground key must be rendered WITHOUT changing which key gets minted. -}
type HeadKind
    = HeadKernel ( Name, Name, Name )   -- kernel alias → k| (never needs the key)
    | HeadCtor                          -- Ctor/Enum/Box → c|
    | HeadNone                          -- Kernel/Manager/PortIncoming/PortOutgoing/absent → no identity
    | HeadGround                        -- Define/TrackedDefine/Link/Cycle → g|<g>|<widenedKey>

headKindOf : TOpt.Global -> Engine.S -> HeadKind
headKindOf g s =
    case LssInfer.kernelAliasOf g s of
        Just k -> HeadKernel k
        Nothing ->
            case HashMap.get TOpt.globalHash (==) g s.env.toptNodes of
                Just (TOpt.Ctor _ _ _) -> HeadCtor
                Just (TOpt.Enum _ _) -> HeadCtor
                Just (TOpt.Box _) -> HeadCtor
                Just (TOpt.Kernel _ _) -> HeadNone
                Just (TOpt.Manager _) -> HeadNone
                Just (TOpt.PortIncoming _ _ _) -> HeadNone
                Just (TOpt.PortOutgoing _ _ _) -> HeadNone
                Just _ -> HeadGround
                Nothing -> HeadNone

memberIdForDepth : TOpt.Global -> Int -> Maybe String -> Step (Maybe Int)
memberIdForDepth g d groundKey s0 =
    if d > 0 then Engine.map Just (Engine.papMemberIdFor g d) s0
    else
        case headKindOf g s0 of
            HeadKernel ( kernelPrefix, home, name ) -> {- T:4628-4630 verbatim -}
            HeadCtor -> Engine.map Just (Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g) s0
            HeadNone -> Ok ( Nothing, s0 )
            HeadGround ->
                case groundKey of
                    Just tk -> {- T:4671-4677 verbatim: groundStandaloneMemberIdFor g tk … -}
                    Nothing -> Engine.map Just (Engine.standaloneMemberIdFor ("g|" ++ TOpt.toComparableGlobal g) g) s0
```
(The `Nothing` arm under `HeadGround` is reachable only for `d == 0` with no key; today's `stampSelfSpine`
always passes `Just` at depth 0, and §4.2 keeps that: the key is rendered iff the head is `HeadGround`,
so the provisional `g|<g>` mint can never replace the ground mint. This is the one-identity rule of
`plans/lss-registration-self-identity.md` §1.3 — do not "optimise" the render away for `HeadGround`.)

```elm
{-| The stamp over an already-interned widened twin of `monoType`. Returns the stamped demand and the
ground key string IF it was rendered (so the created path can store it without a second render). -}
stampSelfSpineWith : Mono.MonoType -> TOpt.Global -> Mono.MonoType -> Engine.S -> Result Engine.Failure ( ( Mono.MonoType, Maybe String ), Engine.S )
stampSelfSpineWith widened g monoType s0 =
    let arity = LssInfer.declaredArityOf g 8 s0 in
    case monoType of
        Mono.MFunction _ _ _ _ ->
            if arity <= 0 then Ok ( ( monoType, Nothing ), s0 )
            else
                let
                    groundKey =
                        case headKindOf g s0 of
                            HeadGround -> Just (Mono.toComparableMonoType widened)   -- the ONLY render
                            _ -> Nothing
                in
                case stampSpineGo g groundKey arity 0 monoType s0 of
                    Err e -> Err e
                    Ok ( stamped, s1 ) -> Ok ( ( stamped, groundKey ), s1 )
        _ -> Ok ( ( monoType, Nothing ), s0 )      -- non-arrow demand: stampSpineGo's `_` arm, no key

{-| Kept for the three Monomorphize callers (seeds + completion re-stamp). -}
stampSelfSpine : TOpt.Global -> Mono.MonoType -> Step Mono.MonoType
stampSelfSpine g monoType s0 =
    if not s0.env.lss.enabled then Ok ( monoType, s0 )
    else
        let ( widened, intern1 ) = Intern.widenSets monoType s0.intern in
        case stampSelfSpineWith widened g monoType (Engine.withIntern intern1 s0) of
            Err e -> Err e
            Ok ( ( stamped, _ ), s1 ) -> Ok ( stamped, s1 )

enqueueSpecStamped : TOpt.Global -> Mono.MonoType -> Step Mono.SpecId
enqueueSpecStamped global monoType s0 =
    if not s0.env.lss.enabled then
        Engine.enqueueSpec (toptToMonoGlobal global) monoType s0        -- lss-off arm of enqueueSpec, as today
    else
        let ( widened, intern1 ) = Intern.widenSets monoType s0.intern in   -- THE one widen
        case stampSelfSpineWith widened global monoType (Engine.withIntern intern1 s0) of
            Err e -> Err e
            Ok ( ( stamped, preRendered ), s1 ) ->
                Engine.enqueueSpecKeyedWith widened preRendered (toptToMonoGlobal global) stamped s1
```
Note `headKindOf` runs twice per HeadGround enqueue (once here for the render decision, once inside
`memberIdForDepth`) — two HashMap probes; step 12 folds both into one `facts` read. Do not pre-empt that here.

```elm
-- Engine.elm
enqueueSpecKeyed : Mono.Global -> Mono.MonoType -> Step Mono.SpecId
enqueueSpecKeyed global monoType s0 =
    let ( keyType, intern1 ) = Intern.widenSets monoType s0.intern in
    enqueueSpecKeyedWith keyType Nothing global monoType (withIntern intern1 s0)

{-| `widened` = the interned `Intern.widenSets` of `monoType` (annotation-blind, so a caller that
widened the UNSTAMPED demand may pass it for the stamped one); `preRendered` = its
`toComparableMonoType` if the caller already rendered it. -}
enqueueSpecKeyedWith : Mono.MonoType -> Maybe String -> Mono.Global -> Mono.MonoType -> Step Mono.SpecId
enqueueSpecKeyedWith widened preRendered global monoType s0 =
    -- body = E:2307-2400 with these substitutions:
    --   * delete the `( maybeWidened, sPre )` let (E:2329-2333); use `s0` where `sPre` was
    --   * over-budget arm (E:2340-2343): `Registry.getOrCreateSpecIdKeyed global widened monoType s0.registry`
    --   * E:2377-2384:  s2 = if created then recordSpecWidenedKey specId (Maybe.withDefault (Mono.toComparableMonoType widened) preRendered) s1 else s1
```
`preRendered` is `Just` exactly when `stampSelfSpineWith` rendered for a `HeadGround` head, and that
render IS `toComparableMonoType widened` — the same object — so the stored `specWidenedKeys` string is
byte-equal to today's (LSS_024 write-once contract unchanged; `layoutQualKey` E:774-780 reads it unchanged).

##### 4.3 `stampSpineGo`: pointer return + canonical rebuild (11a)

```elm
stampSpineGo : TOpt.Global -> Maybe String -> Int -> Int -> Mono.MonoType -> Step Mono.MonoType
stampSpineGo g groundKey arity d monoType s0 =
    if d >= arity then Ok ( monoType, s0 )
    else
        case monoType of
            Mono.MFunction _ anno args ret ->
                case memberIdForDepth g d (if d == 0 then groundKey else Nothing) s0 of
                    Err e -> Err e
                    Ok ( Nothing, s1 ) -> Ok ( monoType, Engine.bumpArgFlowCensus "regid|noId" s1 )     -- as today: stops, input by pointer
                    Ok ( Just mid, s1 ) ->
                        let
                            ( anno2, stampedHere, s2 ) =
                                case anno of
                                    Mono.LSet _ -> ( anno, False, Engine.bumpArgFlowCensus "regid|alreadySet" s1 )
                                    _ -> ( Mono.LSet [ mid ], True, Engine.bumpArgFlowCensus "regid|stamped" s1 )
                        in
                        case stampSpineGo g groundKey arity (d + 1) ret s2 of
                            Err e -> Err e
                            Ok ( ret2, s3 ) ->
                                if not stampedHere && ret2 == ret then
                                    Ok ( monoType, s3 )                                   -- NOTHING changed below: input by pointer
                                else
                                    let ( node, s4 ) = Engine.consS (Mono.mFunction anno2 args ret2) s3 in
                                    Ok ( node, s4 )                                        -- rebuilt: canonicalised
            _ -> Ok ( monoType, s0 )
```
`ret2 == ret` is O(1) in both outcomes: unchanged ⇒ the recursion returned `ret` itself (pointer hit in
`eqHelp`); changed ⇒ `ret2` is a canonical `MFunction` whose FIRST field (the packed hash, which mixes
`annoHash`) differs, so `==` fails on the first slot. `consS` inserts the stamped spine into the intern
table (a new insertion class — see §1's BI argument) and `withIntern` copies `S` only on the first
occurrence of each distinct stamped spine.

Effect on the registry: `reverseMapping` now stores canonical stamped demands, and the next enqueue of
the same demand reaches R:147 `storedType == storeType` with the same pointer ⇒ `HitIdentical` in O(1)
(today: full structural walk on every one of the ~83K identical hits). `joinAnnotationsChanged` and the
completion join M:4261-4285 also gain the pointer fast path wherever they compare against the stored type.

##### 4.4 Order-of-evaluation / mint-order constraints (explicit)

- Member-id mints (`memberIdForDepth` per depth) happen in the SAME order with the SAME keys as today.
  Only the string's construction time moved, not the intern-by-key.
- Intern insertions: (a) the widen now precedes the stamp (was: after) — no member-table or registry
  operation in between reads the intern table; (b) stamped spines are now inserted (`consS`) — new rows;
  (c) memo rows — new rows. None is observable: the table is never iterated and canonical-object choice
  among `==`-equal objects is invisible. HashMap sequence numbers therefore differ from today with no
  emission consequence.
- `Point` indices, `SpecId`s, `ArrowId`s: untouched.
- The lss-off arm is byte-identical trivially (no widen, no stamp — `Engine.enqueueSpec` E:2137-2160).

#### 5. Edit sequence (each leaves `elm make` green)

1. `I`: two-field constructors + `entries`; `hashCons`/`probe`/`probeRO`/`size`/`readOnly`/`empty` adapt;
   export `entries`. `E:2781` and `St:2255` switch to `Intern.entries`. Build; run `ComparableKeyEncodingTest`.
   (Still no memo — this is the type change alone.)
2. `E`: add `enqueueSpecKeyedWith` (body of 2305-2400 with the three substitutions of §4.2); make
   `enqueueSpecKeyed` the two-line delegating wrapper; export. Build.
3. `T`: add `HeadKind`/`headKindOf`; rewrite `memberIdForDepth`'s depth-0 dispatch over it (mint arms
   verbatim). Build; this is a pure refactor.
4. `T`: add `stampSelfSpineWith`; rewrite `stampSelfSpine` as the wrapper and `enqueueSpecStamped` as in
   §4.2; delete the pure-widen `groundKey` let (T:4696-4703) and update the T:4697-4700 comment to state
   that the key string and `specWidenedKeys` are renders of ONE object. Build; **loop entry 11a candidate**
   — or continue to 5 first (5 is BI and small).
5. `T`: `stampSpineGo` pointer return + `consS` (§4.3). Build. Loop entry **11a** = edits 1-5.
6. `I`: the memo (`memoised`/`widenNode`/`insertWidened`, §4.1). Build; add the memo pin (§6). Loop entry **11b**.

Test pins to update in the same edit: none are broken by 1-5 (APIs kept). Edit 6 adds a pin; no existing
`Intern.size` pin changes value because no test calls `widenSets` before reading `size`
(ComparableKeyEncodingTest:152 discards the table with `Tuple.first`).

#### 6. Verification

- Unit: `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt` (once). Suites that pin
  this area: `ComparableKeyEncodingTest` (K6 twin equality 136-158, size/readOnly 161-257),
  `LayoutQualTest` (widened-key strings 60-100, `layoutQualKey` fallback/instTag), `LssRegIdentityTest`,
  `LssGroundingTest` (LSS_019 ground ids), `MuTieTest`, `LssRootFoldTest`, `SpecWatchdogTest`.
- New pin (add to `ComparableKeyEncodingTest`, next to the K6 twin test): over the corpus, for each `t`
  `let (w1, i1) = Intern.widenSets t i0; (w2, i2) = Intern.widenSets t i1 in w1 == w2 && Intern.entries i2 == Intern.entries i1`
  (second call is a hit: same object, no growth), and `Intern.size i1 == Intern.size (Tuple.second (Intern.widenSets t Intern.empty))`
  for a fresh table (memo rows do not count as structures).
- Byte identity + effect: the loop (`benchmarks/lss-compile-opt-loop.md` §1-2): Phase 1.3/1.4 build
  `eco-opt11a`, Phase 2 three cold runs, `cmp` r1/r2/r3 and `cmp r1-out.mlir eco11a.mlir` (fixed point —
  the BI gate), then verdict on medians vs the last kept row. Same again for 11b as its own entry.
- Attribution leg (UNTIMED, report on):
  `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_MONO_LSS_REPORT=1 ./bin/eco-opt11a make … 2> rep.txt; grep -a "regid|" rep.txt`
  — `regid|stamped` + `regid|alreadySet` = renders that still happen (HeadGround, arity>0);
  `regid|noId` and the enqueues that never reach `stampSpineGo` = renders saved. For 11b add, in
  `enqueueSpecStamped`, `Engine.bumpArgFlowCensus (if Intern.entries intern1 == Intern.entries s0.intern then "widen|hit" else "widen|miss")`
  (report-gated inside the bump; `LssStats` is at 32 fields — do NOT add a counter field there).
- Gates on a win (Phase 4): `elm-tests`, `cmake --build build --target full`, and the 633-workload rail
  `benchmarks/mlir-workload-rail.sh` (cheap; catches any precision drift the bytes miss).

#### 7. Risks, gotchas, what NOT to do

- **Do NOT skip the depth-0 mint when the head anno is already `LSet`** ("test anno before minting" in the
  plan text). `memberIdForDepth` INTERNS `g|<g>|<tk>` before the anno test (T:4671-4677 then T:4730-4740);
  skipping it changes the member-id supply order whenever that ground id has not been minted yet (LSS_003
  determinism holds, but ids shift ⇒ set sort order ⇒ spec keys ⇒ possibly `out.mlir`). If wanted, it is a
  separate ANALYSIS-ORDER entry (11c) needing the extra bootstrap turn (loop Phase 1.5) and the rail. The
  lazy render already removes the STRING for every non-HeadGround enqueue; 11c would only save the
  `Dict String` probe on `regid|alreadySet` heads.
- **Do NOT render for `HeadGround` lazily inside `memberIdForDepth` by passing `Nothing`** — that arm mints
  the PROVISIONAL `g|<g>` id instead of the ground one (one-identity rule, plan `lss-registration-self-identity.md`
  §1.3; LSS_019). The render decision must be `headKindOf == HeadGround`, nothing weaker.
- `Intern.size` semantics: keep it "distinct structures"; put the guards on `entries`. A guard on `size`
  silently drops memo rows for already-widened inputs (§4.1) — the memo would look built and be inert.
- `withIntern` E:2779-2785 doc says "equal counts imply the same table value" — that stays true only
  because BOTH tables are insert-only. Never add a remove.
- `Engine.consS` in `stampSpineGo` adds an `S` copy per FIRST occurrence of a stamped spine (table growth).
  If the 11a triple shows minor-GC up with wall flat, split: keep the pointer return, drop the `consS`
  (return `Mono.mFunction anno2 args ret2` uncanonicalised) and re-measure as 11a'.
- M:4279 discards the returned `S` (`Ok ( stamped, _ )`): memo rows and the consS'd spine minted there are
  dropped — harmless (cache), but do not "fix" it here; that site's state-drop is deliberate (AR-2 comment).
- The 32-slot record cap: no `S`, `Env`, `LssStats` or `ItemAux` field is added. `Intern` is a custom type,
  not a record — its second payload slot is fine.
- `build-kernel/src` is a symlink; the loop's Phase 1.3 compiles `/work/compiler/src/Terminal/Main.elm`
  from the live tree — edit only under `/work/compiler/src`.
- Plan §4 N12: the registry probe itself is cheap — do not touch `getOrCreateSpecIdKeyed`; N14: `withIntern`
  already avoids the copy on no-change — keep that shape.
- Invariants touched, none amended: LSS_024 (widened key captured write-once — same string), LSS_019
  (ground key annotation-widened — same string), LSS_003 (mint sites/order unchanged), LSS_010 (join on
  the stored type — now pointer-fast, same relation), MONO_030 (watchdog path unchanged).

#### 8. Effort

**S-M.** 11a (edits 1-5: ~150 changed lines in T/E, type-only change in I) is one loop entry; 11b (the
memo, ~60 lines in I) is a second entry so the memo's own effect is attributable. If 11a's `consS` proves
GC-negative, 11a' (pointer return without `consS`) is the fallback entry.

---

<details><summary>Conventions used in this spec (from spec-G)</summary>

All line numbers are as of the tree on 2026-09-19 (verified by `sed -n`/`grep -n` while writing this).
Files: `T` = `/work/compiler/src/Compiler/MonoSolver/Translate.elm`, `E` = `.../MonoSolver/Engine.elm`,
`M` = `.../MonoSolver/Monomorphize.elm`, `L` = `.../MonoSolver/LssInfer.elm`, `St` = `.../MonoSolver/Store.elm`,
`I` = `/work/compiler/src/Compiler/AST/Intern.elm`, `Mo` = `/work/compiler/src/Compiler/AST/Monomorphized.elm`,
`TO` = `/work/compiler/src/Compiler/AST/TypedOptimized.elm`, `R` = `/work/compiler/src/Compiler/Monomorphize/Registry.elm`.

---

</details>

### Step 12 (was 9). Global identity as a dense Int (`GlobalId`) and Int-keyed per-global memos

#### 1. Goal and expected effect

`TOpt.toComparableGlobal` (TO:313-315: `ModuleName.toComparableCanonical home ++ "." ++ name`, three
concatenations of a 25-50-char string) and `Mono.toComparableGlobal` (Mo:3324-3335, a 7-piece
`String.concat`) are rebuilt on EVERY probe of seven per-global tables, and each probe then does ~14-16
full string compares over a long shared prefix in a red-black `Dict String`:

| table | type today | built/probed where | multiplicity |
|---|---|---|---|
| `S.lssSignatures` | `Dict String LssSignature` (E:1321) | `L.signatureFor` L:80-123 (string at 84, get 86, `lssInProgress` member 94), called TWICE per translated global call (`lssFastOk` T:2998 and `instantiateLss` T:5228 → `instantiateWithSignature` L:129); `preResolveGo` L:528; `memoizedSignatureTrivial` E:1180 | ~2 per translated call (≈ 10^6/run) |
| `S.lssInProgress` | `Dict String ()` (E:1322) | L:94, L:373, L:391, L:1742 | per signatureFor miss + per walked call |
| `S.specCountByGlobal` | `Dict String SpecTally` (E:1310) | `enqueueSpecKeyed` E:2308-2312 (probe), 2360-2365 (insert on created); `specIdsForGlobal` E:80-86 ← T:7636 | per enqueue (141K) |
| `Registry.countByGlobal` | `Dict String Int` (Mo:2898) | `bumpCountByGlobal` R:79-83 on every create (R:117, R:182); `createdCount` R:88-90 ← `checkSpecWatchdogs` E:1257 (per created spec) and subst engine `Monomorphize/Monomorphize.elm:385` | 2 per created spec (86K) |
| `S.nodeResolution` | `Dict String NodeResolution` (E:1327) | `resolveGlobalNode` M:4533-4559 ← `processItem` M:4133 | per item (43K) |
| `MonoMemo.schemeMono` | `Dict String MonoType` (E:484) | `cachedSchemeMono` T:3160-3171 ← T:3262 (`TOpt.toComparableGlobal global`, Fast path); `lookupSchemeMono`/`putSchemeMono` E:2702-2715 | per Fast call |
| `Env.annotations` | `TOpt.AnnotationsByGlobal` = `Data.Map.Dict String Global Annotation` (TO:116-117; E:1274) | `sigSourceTypeFor` L:221-228 (per walked call L:1740, per unit member L:486), `lookupAnnotation` T:8225-8227 ← `translateCall` T:2006 (per translated call), T:2629 | per translated call + per walked call |

Plus, per translated call: `declaredArityOf` (L:2323-2370, a `HashMap` probe + Link hops) is called from
`needsPapSlow` T:2981 and again from `stampSelfSpine` T:4705 (and `injectPapMember` T:4550); `kernelAliasOf`
L:2475-2486 (HashMap probe + Link hops) from `memberIdForDepth` T:4627 and `injectArgLambdaMemberGo` T:4381;
`memberIdForDepth` re-probes `toptNodes` T:4634. And `toptToMonoGlobal` (T:8230-8232) allocates a FRESH
`Mono.Global` per enqueue, so `specKeyEq` (Mo:818-820: `g1 == g2 && eqKeySpec …`) compares four strings by
content on every registry hit.

Measured share (plan §1/§2): ~1-2 % of the mono window directly (`internMemberKey`'s string work is step
13's, not this); the reason this step is placed here is that steps 13, 16, 23 and 25 key on the id.
Loop stats: wall down ~1-2 % of mono (≈ 2-4 s), minor GC down a little (≈ 10^6 fewer 40-byte strings + 141K
`Mono.Global` allocs), promoted/majors flat, RSS flat (+ a few MB for the facts array).

**BI: yes, required.** The id is never rendered, never ordered, never folded into any emitted key; it is
only an index into memos/tallies whose CONTENT is unchanged. Member-key strings (`g|`, `c|`, `p|`,
`k|`) keep their exact spelling from `TOpt.toComparableGlobal` (LSS_017/019/024 name those shapes; step
13 changes them, not this step).

#### 2. Preconditions

- Step 11 in (so `enqueueSpecStamped`/`stampSelfSpineWith` have the shape §4 below extends). Not a hard
  dependency, but the edit list assumes it.
- Verify the closed-graph assumption the dense ids rest on (every `TOpt.Global` the engine sees is a key of
  `nodes`, or of `annotations`):
  ```bash
  grep -n "Unknown global" /work/compiler/src/Compiler/MonoSolver/LssInfer.elm     # L:421-423: today's tolerant arm
  ```
  and, in the attribution leg (§6), count `globalIdOf` misses: expect 0. The design still tolerates a miss
  (falls back to today's "unknown ⇒ trivial/none" behaviour) so a nonzero count is a report line, not a crash.
- Full call-site lists (regenerate; the tables in §3 were built from these):
  ```bash
  grep -n "toComparableGlobal" /work/compiler/src/Compiler/MonoSolver/*.elm /work/compiler/src/Compiler/Monomorphize/Registry.elm
  grep -n "lssSignatures\|lssInProgress\|nodeResolution\|specCountByGlobal\|specIdsForGlobal\|schemeMono\|env.annotations\|countByGlobal\|createdCount" /work/compiler/src/Compiler/MonoSolver/*.elm /work/compiler/src/Compiler/Monomorphize/*.elm /work/compiler/src/Compiler/GlobalOpt/*.elm
  grep -rn "countByGlobal = " /work/compiler/tests     # 8 registry literals to retype
  ```

#### 3. Inventory of touched code

| file | function (lines) | what changes |
|---|---|---|
| E | `type alias Env` 1272-1300 | + `globalIds : HashMap TOpt.Global Int`, `globalFacts : Array GlobalFacts`, `globalCount : Int`; − `annotations` (folded into facts) |
| E | new `type alias GlobalFacts`, `noFacts`, `globalIdOf`, `factsOf`, `factsOfGlobal`, `annotationOfId` | per-global facts record + accessors |
| E | `type alias S` 1302-1414: `lssSignatures` 1321, `lssInProgress` 1322, `nodeResolution` 1327, `specCountByGlobal` 1310 | retype: `Array (Maybe LssSignature)`, `BitSet`, `Array (Maybe NodeResolution)`, `SpecTallies` |
| E | `SpecTally`/`emptySpecTally`/`specIdsForGlobal` 66-86 | + `type alias SpecTallies = { globals : Array (Maybe SpecTally), accessors : Dict String SpecTally }`; `specIdsForGlobal : Int -> S -> List Int` |
| E | `MonoMemo` 483-491, `lookupSchemeMono`/`putSchemeMono` 2702-2715 | `schemeMono : Array (Maybe MonoType)`; key `Int` |
| E | `memoizedSignatureTrivial` 1178-1180 | via `globalIdOf` + `Array.get` |
| E | `checkSpecWatchdogs` 1236-1263 (`Registry.createdCount global reg` 1257) | unchanged call; `Registry.createdCount` is re-keyed (below) |
| E | `enqueueSpec` 2110-2160, `enqueueSpecKeyed`/`enqueueSpecKeyedWith` (step-11 shape) | + `Maybe Int` owner id param (`Just gid` for `Mono.Global`, `Nothing` for `Accessor`); tally on `SpecTallies` |
| R | `emptyRegistry` 67-73, `bumpCountByGlobal` 79-83, `createdCount` 88-90 | `countByGlobal : HashMap Mono.Global Int` keyed by `Mono.globalHash`/`(==)`; no string |
| Mo | `type alias SpecializationRegistry` 2894-2899 | field type change |
| M | registry literal 4865; `Monomorphize/Monomorphize.elm:304`; `Monomorphize/Prune.elm:329`; `GlobalOpt/CafHoist.elm:243` | `countByGlobal = HashMap.empty` (CafHoist copies the field — type-agnostic, no edit) |
| tests | `countByGlobal = Dict.empty` literals: `AbiCloningFenceTest:191`, `AbiCloningFlatPeelPassTest:224`, `AbiCloningPapFastPassTest:389`, `BorrowFenceTest:129`, `PostSettleDevirtTest:265`, `GlobalOpt/CafDedupeTest:189`, `GlobalOpt/CafHoistTest:179`; `SpecWatchdogTest:81-105` (`createdCount` pin, API kept) | `HashMap.empty` |
| M | `initState` 3852-3913 | mint ids; build `globalFacts`; retype the four `S` fields' initial values; `seedFlagsDecoder` 3947 unchanged |
| M | `resolveGlobalNode` 4533-4559, caller 4133 | `Int`-keyed; `Array.set` on miss |
| M | report readers of `lssSignatures`: 1431 (`Dict.size`), 1436-1443 (fold), 3131 (`Dict.get` by string), 3243 (fold) | `Array` folds / `globalIdOf` + get; render names via `factsOf gid .global` |
| L | `signatureFor` 80-123 → `signatureForId` + wrapper; `inferUnit` 364-411 (`gkey : String` → `gid : Int`); `UnitMember.gkey` (record 350-362) → `gid : Int` + `global : TOpt.Global`; `memberOf` 483-491; `preResolveCallees`/`preResolveGo` 495-537; `collectReferencedGlobals` 540-558; `loadMemberSlots` 623-637 (`String` → `Int` in the triple); `inferUnitInScratch`'s `sigs : List ( String, … )` → `List ( Int, … )`; `applyCalleeAt` 1733-1745 (`gkey`/`lssInProgress`); L:95 EngineBug text (render `TOpt.toComparableGlobal global` in the error arm only) | Int keys throughout the unit machinery |
| L | `sigSourceTypeFor` 221-228 | reads `annotationOfId`; + `sigSourceTypeForId` |
| L | `declaredArityOf` 2323-2325, `declaredArityGo` 2338-2370, `kernelAliasOf` 2475-2486 | bodies become pure functions over the `toptNodes` HashMap (`declaredArityIn`, `kernelAliasIn`) used by `initState`; the `S`-taking names become one-probe wrappers over `globalFacts`; + `declaredArityOfId`, `kernelAliasOfId` |
| T | `translateCall` 2000-2019 (`lookupAnnotation` 2006), `translateGlobalCall` 2922-2957, `lssFastOk` 2989-3002, `needsPapSlow` 2977-2982, `translateGlobalCallFast` 3213-3262 (`cachedSchemeMono (TOpt.toComparableGlobal global)` 3262), `translateGlobalCallGroundMemo` 3272, `translateGlobalCallSlow` 3392-3404, `instantiateLss` 5225-5231, `cachedSchemeMono`/`computeSchemeMono` 3160-3190 | thread `gid : Int` from ONE `globalIdOf` in `translateCall`; `cachedSchemeMono : Int -> …` |
| T | `enqueueSpecStamped` (step-11 shape), `stampSelfSpineWith`, `headKindOf`, `memberIdForDepth` 4621-4689, `stampSelfSpine` wrapper | take/derive `gid`; `headKindOf` reads `facts.kernelAlias`/`facts.node` (one array read instead of two HashMap probes); `toptToMonoGlobal global` → `facts.monoGlobal` |
| T | `lookupAnnotation` 8225-8227, callers 2006, 2629 | `Engine.annotationOfId` |
| T | `ctorFieldUnion` 7610-7636 (`specIdsForGlobal gkey`) | `globalIdOf (TOpt.Global ctorHome ctorName)` |
| T | cold `declaredArityOf`/`kernelAliasOf` callers 458, 1834, 2581, 3569, 4063, 4268-4274, 4381, 4550 | unchanged (wrappers) |
| M | cold `declaredArityOf`/`kernelAliasOf` callers 1241, 2113, 3291, 4224 | unchanged (wrappers) |
| L | cold callers 1262 (`kernelAliasOf`), 1802, 2582, 2630 (`declaredArityOf`) | unchanged (wrappers) |
| St | 119 (comment naming `s.env.annotations`) | comment |

NOT touched (out of scope, listed so nobody hunts them): `Registry`'s message formatters
(`prettyGlobal` R:202-210, uses the constructor, not the key); the settle chain's own string inversions
M:1198/2064/2327 (`compGlobals` from `toptNodes`, per round — plan step 24); census/report keys
(T:3262 is hot, the rest — T:3509, 3598, 3640-3643, 7283, 7614; St:1054, 2626; M:248, 1460, 3399, 4007;
L:264 — are report-gated or error-path); AbiCloning `specsByGlobal` (plan step 25: post-mono, no `Env`);
the member-key strings E:748, 1799, 1879; T:4386-4416, 4636-4670; L:1284-1313 (step 13).

#### 4. Design

##### 4.1 Where the id lives — evaluated both ways

(a) **Stamp it on occurrences in `AssignMVarIds`** (D3's suggestion). `TOpt.Meta id = { tipe, tvar }`
(TO: `type alias Meta`) is constructed as a literal at 108 sites in 11 files (`grep -rn "tvar = " compiler/src`),
and `VarGlobal`/`VarCycle`/`VarEnum`/`VarBox` appear in 311 patterns/constructions across LocalOpt,
GlobalOpt/PreMono (EtaExpand, AliasForward, Fresh, LiftClosedArgs), InlineSimplify, the encoders/decoders
and the whole MonoSolver. Either a Meta field or a constructor argument touches every one of them; the
pre-mono passes that COPY occurrences (`PreMono.Fresh`, the inliner) would also have to carry the id
correctly. That is an L-effort blast radius for no hot-path gain over (b) — the per-call cost of (b) is one
`HashMap` probe. Rejected.

(b) **`Env.globalIds : HashMap TOpt.Global Int`** built once in `initState`, probed ONCE per translated
call/reference (`globalIdOf`), the `Int` threaded through the hot path; every per-global table becomes an
`Array` indexed by it. `HashMap.get TOpt.globalHash (==)` = a char fold over the NAME (TO:329-340; lengths
of the module parts, not their chars) + a `Dict Int` descent + one `==` on `Global` (four short strings; the
`TOpt.Global` objects at two occurrences are distinct, so this is a memcmp each — still far below a
5-concat build + 14 long-prefix compares). Chosen. The existing `Env.toptNodes` (E:1273, "4c") is the
precedent and keeps working as is; the facts array carries its node so hot sites stop probing it.

##### 4.2 Minting: order and emission-independence

```elm
-- Monomorphize.initState (M:3852): `nodes : DMap.Dict String TOpt.Global (TOpt.Node …)` is the graph's
-- node map; `annotations : TOpt.AnnotationsByGlobal` the same shape.
( globalIds, globalsRev, globalCount ) =
    let
        addKey g ( ids, rev, n ) =
            if HashMap.member TOpt.globalHash (==) g ids then ( ids, rev, n )
            else ( HashMap.insert TOpt.globalHash (==) g n ids, g :: rev, n + 1 )
    in
    DMap.foldl TOpt.compareGlobal (\g _ acc -> addKey g acc) ( HashMap.empty, [], 0 ) nodes
        |> (\acc -> DMap.foldl TOpt.compareGlobal (\g _ a -> addKey g a) acc annotations)
```
Order: `Data.Map.foldl` is `Dict.foldl` over the underlying core `Dict comparable ( k, v )`
(`/work/compiler/src/Data/Map.elm:240-242` — the ordering argument is ignored), i.e. ASCENDING
`TOpt.toComparableGlobal` string order: ids 0..n-1 in lexicographic `author/project:Module.name` order,
then any annotation-only key (expected none) after. Deterministic across runs for the same program.

Why the order cannot reach emission: an id is (1) never rendered into any string — member keys, spec
keys, `specWidenedKeys`, symbol names all keep `toComparableGlobal`/`toComparableMonoType`; (2) never
compared for order (no sort keys on it); (3) only an `Array`/`BitSet` index or `Dict Int` key of memos
and tallies whose CONTENT is the same as today; (4) the only iterations over id-keyed tables are the
report folds M:1431-1443 / 3131 / 3243 and the report is neither the artifact nor in the config hash.
Ascending-comparable is chosen so those report lines keep today's lexicographic order. Because emission
is independent of the ids, the bootstrap fixed point holds by construction; the loop's `cmp` is the gate.

##### 4.3 The per-global facts record

```elm
-- Engine.elm
type alias GlobalFacts =
    { global : TOpt.Global                              -- id -> Global (report text; member-key strings until step 13)
    , monoGlobal : Mono.Global                           -- THE ONE Mono.Global object for this global (see 4.6)
    , node : Maybe (TOpt.Node TypeIds.MVarId)            -- toptNodes entry, unchased
    , annotation : Maybe (Can.Annotation TypeIds.MVarId) -- was Env.annotations
    , declaredArity : Int                                -- == LssInfer.declaredArityOf g 8 (Link-chased, fuel 8, floors at 1)
    , kernelAlias : Maybe ( Name, Name, Name )           -- == LssInfer.kernelAliasOf g (Link-chased)
    , annoMentionsArrow : Bool                           -- canTypeMentionsArrow of the annotation's type; False without one. Consumer: steps 16/23
    }

noFacts : TOpt.Global -> GlobalFacts    -- for a global with no id (never expected): node/annotation Nothing, arity 1, alias Nothing, arrow False

globalIdOf : TOpt.Global -> S -> Maybe Int
globalIdOf g s = HashMap.get TOpt.globalHash (==) g s.env.globalIds

factsOf : Int -> S -> GlobalFacts
factsOf gid s = case Array.get gid s.env.globalFacts of Just f -> f ; Nothing -> noFacts (TOpt.Global … ) -- unreachable by construction; crash-free

annotationOfId : Int -> S -> Maybe (Can.Annotation TypeIds.MVarId)
annotationOfId gid s = (factsOf gid s).annotation
```
Built in `initState` AFTER `toptNodes`: `globalFacts = Array.fromList (List.map (\g -> factsFor g) (List.reverse globalsRev))`
with `factsFor g = { global = g, monoGlobal = toptToMonoGlobal g, node = HashMap.get … g toptNodes,
annotation = DMap.get TOpt.toComparableGlobal g annotations, declaredArity = LssInfer.declaredArityIn toptNodes name g 8,
kernelAlias = LssInfer.kernelAliasIn toptNodes g, annoMentionsArrow = … }`. `declaredArityIn`/`kernelAliasIn`
are L:2338-2370 / L:2475-2486 with `s.env.toptNodes` replaced by the HashMap parameter — the wrappers keep
their exact arms and fuel (the `TrackedFunction` arm L:2355-2365 included), so `facts.declaredArity` equals
today's answer for every global. One-time cost: ~n HashMap probes and Link hops (n ≈ 10-20K) — negligible.
`Env` grows from 14 to 16 fields (+`globalIds`, +`globalFacts`, +`globalCount`, −`annotations`); `S` is untouched (31 fields).

##### 4.4 Each table's conversion

- `lssSignatures : Array (Maybe LssSignature)` — `Array.repeat globalCount Nothing` at init; read
  `Array.get gid |> Maybe.andThen identity`; write `Array.set gid (Just sig)`. `inferUnit` L:390's fold
  over `sigs : List ( Int, LssSignature )` sets each. Report: `sigCount = Array.foldl (\m n -> if m /= Nothing then n+1 else n) 0`,
  `trivialCount` likewise; M:3131 becomes `globalIdOf (TOpt.Global sfHome sfName) |> Maybe.andThen (\i -> Array.get i …)`.
- `lssInProgress : BitSet` — `BitSet.emptyWithSize globalCount`; `insertGrowing`/`removeGrowing`/`member`
  (`/work/compiler/src/Compiler/Data/BitSet.elm`: 65, 189, 201). L:373/391 fold over members' `gid`.
- `specCountByGlobal : SpecTallies` with `{ globals : Array (Maybe SpecTally), accessors : Dict String SpecTally }` —
  `Mono.Accessor` specs (enqueued at T:993) have no id: field names are not enumerable at init (the
  graph's `fields` slot is empty after decode, ECOT_001), so accessors keep a small string-keyed dict
  keyed by `Mono.toComparableGlobal` (`"A" ++ field`, short). `enqueueSpecKeyedWith` takes `owner : Maybe Int`
  and dispatches: `Just gid` → array; `Nothing` → dict. `specIdsForGlobal : Int -> S -> List Int` (only
  caller T:7636 has a ctor global).
- `Registry.countByGlobal : HashMap Mono.Global Int` keyed by `Mono.globalHash` (Mo:785-799) / `(==)` —
  the registry is engine-agnostic (the subst engine reads `createdCount` at `Monomorphize/Monomorphize.elm:385`),
  so it cannot use the solver's ids; the hash-keyed map removes the string build on both engines. With
  4.6 the solver's `(==)` on `Mono.Global` is a pointer hit. `emptyRegistry` R:70 → `HashMap.empty`
  (`Registry` gains `import Data.HashMap as HashMap`); MONO_030's text ("Registry.countByGlobal counts
  created specs…") is unchanged in substance — the key type is not part of the invariant.
- `nodeResolution : Array (Maybe NodeResolution)` — sized `globalCount`; `resolveGlobalNode : Int -> S -> ( NodeResolution, S )`;
  the miss path computes `nodeAnnotationIds` from `facts.node` (M:4564-4578 unchanged) and `Array.set`s.
  Caller M:4133: `globalIdOf (TOpt.Global home name)`; a `Nothing` id resolves to `{ node = Nothing, annIds = EverySet.empty }`
  (today's `MonoExtern` path M:4136).
- `MonoMemo.schemeMono : Array (Maybe Mono.MonoType)` — sized `globalCount`; `lookupSchemeMono : Int -> …`,
  `putSchemeMono : Int -> …`; `cachedSchemeMono : Int -> Can.Type … -> Step MonoType`, `computeSchemeMono` likewise.
- `Env.annotations` — removed; `annotationOfId`. `sigSourceTypeForId gid fallback s`; the `TOpt.Global`
  form stays as a wrapper for L:486 (`memberOf`) and L:1740 (`applyCalleeAt`, per walked call — one
  probe instead of one string + one DMap descent).

##### 4.5 The hot Translate path, threaded

```elm
translateCall region func args callCanType =
    case func of
        TOpt.VarGlobal funcRegion global funcMeta ->
            \s0 ->
                let
                    gid = Engine.globalIdOf global s0            -- THE probe (Maybe Int)
                    facts = case gid of Just i -> Engine.factsOf i s0 ; Nothing -> Engine.noFacts global
                    funcCanType = case facts.annotation of Just (Can.Forall _ t) -> t ; Nothing -> funcMeta.tipe
                in
                translateGlobalCall region funcRegion global gid funcCanType args callCanType s0
```
`translateGlobalCall`, `lssFastOk`, `needsPapSlow`, the three `translateGlobalCall*` bodies,
`instantiateLss` and `enqueueSpecStamped` gain a `gid : Maybe Int` parameter (kept as `Maybe` so the
unknown-global fallback is total; `Just` on every real path). Inside:
- `lssFastOk`: `LssInfer.signatureForId gid global s` (Array read on hit);
- `needsPapSlow`: `(Engine.factsOf gid s).declaredArity > List.length args` (no probe, no Link hops);
- `translateGlobalCallFast`: `cachedSchemeMono gid funcCanType`;
- `instantiateLss` → `LssInfer.instantiateWithSignatureId gid global funcCanType`;
- `enqueueSpecStamped gid global monoType`: `stampSelfSpineWith` uses `facts.declaredArity` for the arity
  and `headKindOfFacts facts` (kernelAlias then node — same arms as step 11's `headKindOf`, on the record);
  `memberIdForDepth` takes the `HeadKind` (already computed) instead of recomputing it; the registry
  global is `facts.monoGlobal` (4.6); `Engine.enqueueSpecKeyedWith widened preRendered gid facts.monoGlobal stamped`.

`translateVarRef` T:1905-1920 (every bare reference) does the same single probe and passes `gid` to
`enqueueSpecStamped`; `classifyRef` T:1945 → `injectArgLambdaMemberGo` T:4381 keeps calling the
`kernelAliasOf` WRAPPER (one probe; step 13/16 can thread the id further).

`signatureForId : Maybe Int -> TOpt.Global -> Step LssSignature`:
```elm
signatureForId gid global s0 =
    case gid of
        Nothing -> Ok ( Engine.trivialSignature 0, s0 )     -- == today's L:421-423 "unknown global: trivial" outcome (unmemoised; invisible)
        Just i ->
            case Array.get i s0.lssSignatures |> Maybe.andThen identity of
                Just sig -> Ok ( sig, s0 )
                Nothing ->
                    if not s0.env.lss.enabled then Ok ( Engine.trivialSignature 0, s0 )
                    else if BitSet.member i s0.lssInProgress then Err (EngineBug ("… re-entry …: " ++ TOpt.toComparableGlobal global))
                    else case (Engine.factsOf i s0).node of
                        Just (TOpt.Link target) -> {- L:100-116 with gid/target-id reads -}
                        _ -> inferUnit i global s0
signatureFor global s0 = signatureForId (Engine.globalIdOf global s0) global s0     -- cold callers unchanged
```

##### 4.6 One `Mono.Global` object per global

`facts.monoGlobal` is built once; every enqueue passes it, so `Registry.getOrCreateSpecIdKeyed`'s
`specKeyEq` (Mo:818-820) hits `g1 == g2` on the pointer, `reverseMapping` stores that shared object, and
`Registry.countByGlobal`'s `(==)` is a pointer hit. `toptToMonoGlobal` (T:8230, M:5062) stays for the seeds
(M:148/151/3966/3969 — 2 calls) — or route them through `factsOf` too; either is BI (same content).

##### 4.7 Order-of-evaluation constraints

- `initState` must build `toptNodes` BEFORE `globalFacts` (the arity/alias walks read it).
- Ids are minted BEFORE any `S` exists; nothing mints later (no lazy ids) — that is what makes `Env`
  immutable and the arrays fixed-size. An `Accessor` is not a global here and never needs an id.
- `signatureFor`'s memo-insert ORDER and `inferUnit`'s `lssInProgress` insert/remove ORDER are unchanged —
  the walk itself is untouched; only the key type changes.
- `resolveGlobalNode` M:4533 — same lazily-filled memo, same first-resolve point.

#### 5. Edit sequence (each compiles)

1. `E`: add `GlobalFacts`, `noFacts`, `globalIdOf`, `factsOf`, `annotationOfId`; `Env` gains the three
   fields (keep `annotations` for now). `L`: extract `declaredArityIn`/`kernelAliasIn` (HashMap-parameterised
   twins; the `S` versions call them on `s.env.toptNodes` — still byte-identical, no memo yet). `M.initState`:
   mint ids (§4.2), build facts. Build; run `elm-tests` (nothing reads the new fields yet).
2. `L`: `declaredArityOf`/`kernelAliasOf` bodies → `globalIdOf` + facts read (fuel param kept, ignored);
   + `declaredArityOfId`/`kernelAliasOfId`. Build. (Loop-measurable as **12a** on its own if desired: it
   already removes the Link hops on ~4 probes per call.)
3. `L`+`T`: `sigSourceTypeFor`/`lookupAnnotation` → `annotationOfId`; drop `Env.annotations`; St:119 comment. Build.
4. `E`+`T`: `schemeMono` → `Array`; `cachedSchemeMono : Int -> …`; T:3262 passes `gid`. Requires threading
   `gid` through `translateCall` → `translateGlobalCall` → `translateGlobalCallFast` (§4.5) — do the whole
   threading in this edit (`lssFastOk`, `needsPapSlow`, `…Slow`, `…GroundMemo`, `instantiateLss`,
   `enqueueSpecStamped`, `translateVarRef`) so the signatures change once. Build.
5. `L`: `signatureForId`, `inferUnit gid`, `UnitMember.gid/global`, `memberOf`, `preResolve*`,
   `collectReferencedGlobals : … -> Dict Int TOpt.Global`, `loadMemberSlots`, `applyCalleeAt`;
   `lssSignatures` → `Array`, `lssInProgress` → `BitSet`; `M.initState` initial values; `M` report readers
   1431-1443/3131/3243; `E.memoizedSignatureTrivial`. Build; run `elm-tests`. **Loop entry 12a** = edits 1-5.
6. `E`: `SpecTallies`; `enqueueSpec`/`enqueueSpecKeyed`/`enqueueSpecKeyedWith` owner param; `specIdsForGlobal : Int`;
   T:7636; T `enqueueSpecStamped` passes `facts.monoGlobal` (§4.6). Build.
7. `R`+`Mo`: `countByGlobal : HashMap Mono.Global Int`; `emptyRegistry`; M:4865, `Monomorphize/Monomorphize.elm:304`,
   `Prune.elm:329`; the 7 test literals + `SpecWatchdogTest` (API kept, only if it builds a registry
   literal). Build; run `elm-tests`.
8. `M`: `nodeResolution` → `Array`, `resolveGlobalNode : Int -> …`, caller 4133. Build. **Loop entry 12b** = edits 6-8.

#### 6. Verification

- Unit: `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt` (once; grep the file).
  Pins in the area: `SpecWatchdogTest` (81-105 `createdCount` semantics; 106+ breadth watchdog through the
  pipeline — exercises `checkSpecWatchdogs` + the re-keyed tally), `LssRegIdentityTest`, `LssRootFoldTest`,
  `LssGroundingTest`, `LssPapMembersTest`, `LssRefPapSpineTest`, `LssSigFlowTest`, `ArrowIdentityTest`
  (references `sigSourceTypeFor` in its rationale), the 7 registry-literal suites, `MonomorphizeTest`,
  `TestPipeline.runSolverMono*` (goes through `monomorphizeWithReportAssigned` → `initState`, so every
  pipeline-level suite exercises the minting).
- New pins (add to `SpecWatchdogTest` or a new `GlobalIdTest`): (i) `initState` on a two-module fixture
  yields ids `0..n-1` with `globalIdOf g == Just i ⇔ Array.get i globalFacts .global == g` and ids in
  ascending `TOpt.toComparableGlobal` order; (ii) for every global in the fixture,
  `facts.declaredArity == LssInfer.declaredArityIn toptNodes …` and `facts.kernelAlias == kernelAliasIn …`
  (pins the precompute against the walk); (iii) `Registry.createdCount` on a `Mono.Accessor` key still
  counts (the HashMap keys both constructors).
- BI + effect: the loop, entries 12a and 12b; Phase 2 `cmp` (determinism + fixed point). The report is
  NOT compared byte-for-byte (its per-global line order is preserved by the ascending mint but the
  `sigCount` line may differ by the number of formerly-memoised unknown globals — expected 0).
- Attribution leg (untimed, report on): temporary `Engine.bumpArgFlowCensus "gid|miss"` in `globalIdOf`'s
  `Nothing` arm (expect 0 occurrences); `grep -a "gid|" rep.txt`. No `LssStats` field (32-field cap).
- Gates on a win: `elm-tests`, `--target full`, and `benchmarks/mlir-workload-rail.sh`.

#### 7. Risks, gotchas, what NOT to do

- **32-slot cap**: `S` stays at 31 fields — every conversion is in-place retyping; `SpecTallies`, like
  `LssMemberTable`/`MonoMemo`, is a nested record precisely to avoid a new `S` field. `Env` 14 → 16, fine.
  `LssStats` is at 32: no counter fields.
- **Do not change the `Global` constructors** (`TOpt.Global`/`Mono.Global`): 311 + hundreds of sites;
  §4.1(a). The id is a side table, full stop.
- **Do not key member strings by id yet** (E:748, 1799, 1879; T:4386-4416, 4636-4670; L:1284-1313):
  LSS_017/019/024 pin the `l|`/`g|`/`p|` shapes and step 13 rewrites them with their tests
  (`LayoutQualTest`, `LssGroundingTest`). Using `facts.global` to AVOID rebuilding `toComparableGlobal`
  at those sites would be BI, but it needs the id in hand — leave to 13.
- `Registry.countByGlobal` is read by the SUBST engine too (`Monomorphize/Monomorphize.elm:385`): the
  re-key must stay engine-agnostic (hash-keyed on `Mono.Global`, never on a solver id). `Prune.elm:329`
  and M:4865 rebuild the registry with an EMPTY count ("not carried into the output graph") — keep that.
- `DMap.foldl`'s docstring says "least recently inserted" but the implementation folds the core `Dict`
  by comparable key (Data/Map.elm:240-242) — the ascending-string order in §4.2 is what actually happens;
  do not "fix" the doc by changing the fold.
- The `Maybe Int` id on the hot path: keep it `Maybe` (total) but make the `Nothing` arms EXACTLY today's
  unknown-global behaviour (trivial signature L:421-423; `MonoExtern` node M:4136; arity 1 / no alias
  L:2368-2370, L:2485). A crash there would turn a tolerated shape into a build failure.
- `signatureFor`'s `Link` chase L:100-116 memoises under BOTH the member's and the target's key; with
  arrays that is two `Array.set`s — keep both writes (the "prefer this gkey's freshly memoised signature"
  read at L:110 depends on it).
- `inferUnit`'s cycle-group handle (`_M$first`, L:396-411) is itself a node in `nodes` (the `Cycle` node is
  stored under that name; members map as `Link` to it) — it has an id; nothing special is needed. If the
  fixture pin (i) ever shows a `Link` target without an id, the closed-graph assumption is broken — stop
  and report, do not add lazy minting.
- Plan §4 N20: `canTypeMentionsArrow`-of-annotation is folded into `facts.annoMentionsArrow` for steps
  16/23 — compute it here (cheap, one-time) but do NOT wire consumers in this step (byte-identity of this
  step must not depend on step-16 logic).
- `ECO_MONO_LSS_REPORT` line order: report folds over the new arrays iterate by id = ascending comparable
  = today's `Dict String` order, so `renderLssReport` text is unchanged except where noted in §6.
- Invariants: LSS_003 (mint sites unchanged), LSS_006 (ordinals: `sigSourceTypeFor` returns the SAME
  annotation object as before — the facts record holds the very `Can.Annotation` value from the DMap, so
  H1 at St:114-124 still holds: "the same annotation value"), LSS_010/017/019/024 (keys unchanged),
  MONO_030 (watchdog counts unchanged; the "created path only" rule unchanged). No amendment needed; add
  a one-line note to MONO_030's `Registry.countByGlobal` clause only if the maintainer wants the key type
  recorded.

#### 8. Effort

**M** (two loop entries). 12a (facts + ids + signatures/annotations/arity/alias/schemeMono + the
`gid` threading through the Translate call path, ~300-400 lines across E/L/T/M) carries essentially all of
the direct win and is the prerequisite surface steps 13/16/23/25 key on. 12b (tallies, registry re-key,
`nodeResolution`, ~150 lines + 8 test literals) is mechanical and mostly enabling; measure it separately so
a GC-neutral result does not mask 12a.

<details><summary>Conventions used in this spec (from spec-G)</summary>

All line numbers are as of the tree on 2026-09-19 (verified by `sed -n`/`grep -n` while writing this).
Files: `T` = `/work/compiler/src/Compiler/MonoSolver/Translate.elm`, `E` = `.../MonoSolver/Engine.elm`,
`M` = `.../MonoSolver/Monomorphize.elm`, `L` = `.../MonoSolver/LssInfer.elm`, `St` = `.../MonoSolver/Store.elm`,
`I` = `/work/compiler/src/Compiler/AST/Intern.elm`, `Mo` = `/work/compiler/src/Compiler/AST/Monomorphized.elm`,
`TO` = `/work/compiler/src/Compiler/AST/TypedOptimized.elm`, `R` = `/work/compiler/src/Compiler/Monomorphize/Registry.elm`.

---

</details>

### Step 13 (was 5). Member identity: structural Int keys instead of strings

#### 1. Goal and expected effect

`LssMemberTable.byKey : Dict String Int` (Engine.elm:455) interns every non-lambda-raw member id
under a STRING key. On the self-compile it holds 62,647 keys; the hot producers are 83,233
layout-qualified lambda mints (each concatenates `"l|" ++ raw ++ "|" ++ <multi-KB widened spec
string>`, probes `byKey`, and is probed AGAIN by `lambdaInstanceMemberMaybe` at Translate.elm:1720),
every grounded set readback (`groundSetMembers` Engine.elm:1917 renders
`toComparableMonoType (widenSets (mFunction … [paramT] resultT))` once per slot with a provisional
member, then builds `"g|" ++ toComparableGlobal g ++ "|" ++ typeKey` PER member), every
`p|<global>|<n>` successor mint (`papMemberKey` Engine.elm:1797, ~50 chars, one per depth per
reference per spec at 5 Translate/LssInfer sites plus `varSuccRounds`), and every `g|`/`c|`/`k|`
standalone mint (a `toComparableGlobal` concat + probe per reference per spec). A `byKey` probe is
~16 string compares over keys that share a 40+-char prefix. Plan §1 attributes 6–8 % of the mono
window to this cluster (`internMemberKey` 3.6 % inclusive, `lambdaMemberLayoutQualified` 2.75 %,
`insertMemberKey` ~1 %) — the step attacks it whole.

After the step every mint is: an Int-keyed probe (nested `Dict Int`), no string built, no string
compared; the widened spec type is looked up by its dense CLASS id (an O(1) hash-field read plus a
pointer-equal bucket confirm on canonical input) instead of rendered; PAP successors are one
inner-dict fetch per global per walk. The strings survive only in the REPORT, reconstructed from a
per-id structural key so the report text is byte-identical.

Loop stats: wall down ~5–7 % of the mono window (~2.5–3.5 % of the run); minor GC count down (the
multi-KB key strings and their `++` intermediates are the largest short-lived allocations in the
mint path); max RSS down modestly (`byKey` retains 62,647 strings, many multi-KB — `specWidenedKeys`
alone retains one full type string per created spec, 43K). Major GC / promoted MiB: expected flat
to slightly down.

Emission must be BYTE-IDENTICAL (BI). Member ids reach emission: they are the `LSet` members of
every annotation, sort order of sets, `toComparableMonoType` fragments `A[1,2](`, hence spec keys,
spec ids, `lambda_N` symbols and AbiCloning stamps. The ids stay identical iff (a) every mint site
calls get-or-create in the same order as today and (b) the equivalence relation on keys is the same
(§4.10 proves both). This is a substrate step: gate = `cmp` of `-out.mlir`, plus a
report-text `diff` (§6) because the report is the second consumer of the key strings.

#### 2. Preconditions

- **Step 11 in** (one widen per enqueue). Interface this spec assumes from it — verify with
  `grep -n 'stampSelfSpine\|recordSpecWidenedKey\|memberIdForDepth' compiler/src/Compiler/MonoSolver/{Translate,Engine,Monomorphize}.elm`:
  - `enqueueSpecKeyed` (Engine.elm:2306) has the CANONICAL widened key type in hand on the created
    path (`keyType`, from `Intern.widenSets monoType s0.intern` at 2331–2333) and calls
    `recordSpecWidenedKey specId keyType` (today it passes `Mono.toComparableMonoType keyType`,
    2381) — if step 11 left the String argument, edit E5 changes it.
  - `stampSelfSpine` (Translate.elm:4692) holds the canonical widened whole demand `wide :
    Mono.MonoType` (lazily — only forced in the depth-0 `Just _` Define arm of `memberIdForDepth`
    4621) and passes `Maybe Mono.MonoType` (or a thunk) instead of `Maybe String`. If step 11 kept
    `Maybe String`, E5 changes the parameter type; nothing else about step 11 matters here.
  - `seedSpec` (Monomorphize.elm:3917) passes a widened MonoType (`Mono.widenSets monoType` is fine —
    pure, 1–2 calls per run) to `recordSpecWidenedKey`.
- **Step 12 in** (dense `GlobalId`). Interface assumed (names may differ — semantics must not):
  - `type alias GlobalId = Int`, dense from 0, minted ONCE in `initState` for every key of
    `env.toptNodes` (Monomorphize.elm:3853) so the two accessors below never allocate on the hot path;
  - `Engine.globalIdOf : TOpt.Global -> S -> ( GlobalId, S )` — get-or-create (the `S` comes back
    pointer-identical for every global that has a node; cycle members are `Link` nodes so they are
    present — LssInfer.elm:2323–2340 `declaredArityGo` relies on the same fact);
  - `Engine.globalOfId : GlobalId -> S -> TOpt.Global` (an `Array TOpt.Global`), total for minted ids;
  - both must be usable from `Monomorphize.elm` (report and `varSuccRounds`) — they read `S`.
  If step 12 shipped only a `HashMap TOpt.Global Int` in `Env`, write these two wrappers in E1.
- Verify the producer catalogue in §4.1 is still complete before starting:
  `grep -n '"l|\|"g|\|"c|\|"k|\|"a|\|"p|\|papMemberKey\|internMemberKey\|memberIdFor\b' compiler/src/Compiler/MonoSolver/*.elm compiler/src/Compiler/GlobalOpt/*.elm`
  must list exactly the sites in §3 (any new site is a new producer to migrate).
- Verify nothing outside the report reads `lssMemberKinds` as anything but text:
  `grep -rn 'lssMemberKinds\|memberKinds' compiler/src --include=*.elm` → Monomorphize.elm:4875–4888
  (producer), Prune.elm:354 (passthrough), MonoInlineSimplify.elm:832/885/903/944 (passthrough),
  AbiCloning.elm:740/897/1739/1917/2169–2238/2722 (`String.left 1` / `String.split "|"` on the
  RENDERED string, census only). Unchanged by this step.
- Baseline artefacts: `bin/eco-opt-prev` + `bin/ecoN-1.mlir` of the last kept step, and ONE
  untimed report run of the reference compiler (`ECO_MONO_LSS_REPORT=1`, stderr saved) for the
  report `diff` in §6.

#### 3. Inventory of touched code

| file | function (lines today) | what changes |
|---|---|---|
| Engine.elm | `MemberSource` 445–447 | unchanged (`SourceGlobal`/`SourceKernel`/`SourcePap`) |
| Engine.elm | `LssMemberTable` 454–462, `emptyMemberTable` 494–496 | `byKey` → `keys : MemberKeys` (nested per-kind Int maps) + `kinds : Dict Int MemberKey` (id → structural key, the report's inverse) + `classes : WidenedClasses`; `specWidenedKeys : Dict Int String` → `specWidenedClass : Dict Int Int`; `provisionalStandalone : Dict Int TOpt.Global` → `Dict Int ( GlobalId, TOpt.Global )` |
| Engine.elm | `insertMemberKey` 499–501 | deleted (E8); replaced by `insertMember : MemberKey -> Int -> LssMemberTable -> LssMemberTable` |
| Engine.elm | `insertMemberProvisional` 514–516 | takes `( GlobalId, TOpt.Global )` |
| Engine.elm | `withInstTag` 635–640 | deleted (E8); the tag becomes a key component |
| Engine.elm | `lambdaMemberLayoutQualified` 729–764, `layoutQualKey` 773–780, `mintLayoutQualifiedFold` 788–810, `mintLayoutQualified` 818–888 | key becomes `MemberKey` (§4.6); `layoutQualKey` → `lambdaKeyOf` (pure, pinned) |
| Engine.elm | `recordSpecWidenedKey` 896–906 | `Int -> Mono.MonoType -> S -> S`: classifies the widened type, stores the class id |
| Engine.elm | `internMemberKey` 1760–1767 | replaced by `internMember : MemberKey -> LssMemberTable -> Int -> ( Int, LssMemberTable, Int )` (pure; same get-or-create contract, same "hit returns table and supply unchanged" pin) |
| Engine.elm | `memberIdFor` 1777–1787 | `MemberKey -> Step Int` |
| Engine.elm | `papMemberKey` 1797–1799 | deleted (E8); `papMemberIdFor` 1811–1826 → structural `KPap gid n`, plus `papSuccessorIdsFor` (§4.8) |
| Engine.elm | `standaloneMemberIdFor` 1836–1846 | `StandaloneKind -> TOpt.Global -> Step Int` (`KGlobal`/`KCtor`) |
| Engine.elm | `groundStandaloneMemberIdFor` 1875–1885 | `GlobalId -> TOpt.Global -> Int (class) -> LssMemberTable -> Int -> ( Int, LssMemberTable, Int )` |
| Engine.elm | `groundSetMembers` 1917–1975 | takes and returns `Intern`; builds the class of the widened synthesized arrow instead of its string |
| Engine.elm | `kernelMemberIdFor` 1998–2009 | `( String, String, String ) -> Step Int` (key derived from `( home, name )`) |
| Engine.elm | new | `MemberKey`, `MemberKeys`, `WidenedClasses`, `classOf`, `probeMember`, `renderMemberKey`, `accessorMemberIdFor`, `lambdaKeyOf`, `papSuccessorIdsFor`, `memberKeyShadow` (E1–E7 only) |
| Engine.elm | export list line 8 | add the new names; drop `internMemberKey`, `insertMemberKey`, `layoutQualKey`, `papMemberKey`, `withInstTag` at E8 |
| Engine.elm | `enqueueSpecKeyed` 2306–2400 (2381) | `recordSpecWidenedKey specId keyType` (MonoType) |
| Translate.elm | `classifyLambdaHead` 1745–1889 (1843 `rootLamOf` insert; 1861 mint) | unchanged code path; `rootLamOf` stays `Dict Int TOpt.Global` |
| Translate.elm | `injectLocalMultiUsePap` 4126–4139 (4132) | `Engine.papMemberIdFor g k` — signature unchanged |
| Translate.elm | `injectArgLambdaMemberGo` 4352–4444: 4383, 4386, 4401, 4405, 4416, 4426, 4440 | drop the string arguments: `standaloneArgKernelMember ( kernelPrefix, home, name ) canVar`, `standaloneArgMember Engine.KindGlobal g canVar`, `… KindCtor g …`, `Engine.accessorMemberIdFor field` |
| Translate.elm | `standaloneArgMember` 4452–4457, `standaloneArgKernelMember` 4464–4468 | signatures lose the `String` key |
| Translate.elm | `injectPapMember` 4543–4611 (4593) | `Engine.papMemberIdFor global argCount` — unchanged call |
| Translate.elm | `memberIdForDepth` 4622–4676 (4630, 4636, 4639, 4642, 4665, 4670) | `Maybe Mono.MonoType` ground key; kernel/ctor/global arms lose string args; ground arm classifies then mints `KGround` |
| Translate.elm | `stampSelfSpine` 4692–4706, `stampSpineGo` 4709–4750 | pass the canonical widened MonoType (step 11's shape) |
| LssInfer.elm | export list line 15 `papMemberKey`, def 2554–2556 | deleted (E7) — only consumer is Monomorphize.elm:1244 |
| LssInfer.elm | `injectLambdaMemberQualified` 173–215 (199) | unchanged (`rootLamOf` read) |
| LssInfer.elm | `walkExpr` arms 1261–1324: 1278, 1284, 1296, 1301, 1313, 1320, 1324 | drop string args (kernel ×2, `KindGlobal` ×2, `KindCtor` ×2, accessor) |
| LssInfer.elm | `injectPapMemberInfer` 1798–1826 (1810) | unchanged call |
| LssInfer.elm | `standaloneMember` 2319–2320 | becomes `standaloneAccessorMember : String -> Meta -> Step WalkPoint` (only caller is the Accessor arm) |
| LssInfer.elm | `mintPapSuccessorIds` 2679–2689 | one call to `Engine.papSuccessorIdsFor g d arity` (§4.8); callers 2588, 2638, 2668 unchanged |
| Store.elm | `ZonkCtx` 2216–2223 (`memberTable`, `nextMemberId`, `intern` 2387/2485) | unchanged fields; `groundMembersC` 3330–3346 threads `c.intern` in and out |
| Store.elm | `bumpMixedFlexDemand` 3252 (3261 `membersClass`) | unchanged (`sources`-based) |
| Monomorphize.elm | `varSuccRounds` 1191–1415: `midKeys` 1193–1194, `compGlobals` 1196–1200, `papable` 1213–1225, `succKey` 1243–1244, `keysAcc` insert 1250 | read `s.lssMemberTable.kinds` live; delete `midKeys`/`compGlobals`/`succKey`/`keysAcc` |
| Monomorphize.elm | `renderLssReport` 1419: `internedCount` 1427–1428, `memberKeyOf` 1920–1921, `m2StageWalk` 2875 (`String.startsWith "l|"`), report line 3687 | `Dict.size kinds`; `renderMemberKey`; `isLambdaKey` on the structural key |
| Monomorphize.elm | `multiSetCensusBlock` 3807–3826 (`keyOf` 3813–3814) | render via `kinds` |
| Monomorphize.elm | `initState` 3853 (3865–3866) | `emptyMemberTable` shape |
| Monomorphize.elm | `seedSpec` 3917–3941 (3931) | `recordSpecWidenedKey specId (Mono.widenSets monoType)` |
| Monomorphize.elm | `demandQualifiedFor` 4382–4401 | unchanged (`lambdaQualified`) |
| Monomorphize.elm | `assembleRawGraph` 4806: 4874 `buildMemberOrigins`, 4875–4888 `lssMemberKinds` | fold `kinds`; render strings |
| Monomorphize.elm | `buildMemberOrigins` 4899–4942 | dispatch on `MemberKey` constructors, not `String.left 2` |
| AbiCloning.elm | all | UNCHANGED (consumes ids, `lssMemberOrigins`, `lssBlockedMembers`, and the rendered `lssMemberKinds` strings) |
| tests: `LayoutQualTest.elm` 98–124, 155–166 | `layoutQualKey`/`internMemberKey` pins → `lambdaKeyOf`/`internMember`/`renderMemberKey` pins (E6, E8) |
| tests: `LssGroundingTest.elm` 59–215, 269–283 (`mintProvisional`), 97 (`byKey` size) | mirror mints structurally; `Dict.size keys.ground`/`kinds` |
| tests: `ComparableKeyEncodingTest.elm` | add the `classOf` ⇔ string-equality pin (E5) |
| design_docs/invariants.csv | LSS_003, LSS_017, LSS_018, LSS_019, LSS_024, LSS_033, LSS_038 (+ the `lssMemberKinds` doc at Monomorphized.elm:2943 and Engine.elm:1323) | reword (§7) |

Call sites of every changed signature, from grep (all listed above): `internMemberKey` — Engine
1781, 1879, tests LayoutQualTest 159/162, LssGroundingTest 277; `memberIdFor` — Engine 820, 1813,
1838, 2000, LssInfer 2320, Translate 4426; `papMemberIdFor` — LssInfer 1810, 2684, Translate 4132,
4593, 4624, Monomorphize 1246; `standaloneMemberIdFor` — LssInfer 1284, 1296, 1301, 1313, Translate
4455, 4636, 4639, 4642, 4670; `kernelMemberIdFor` — LssInfer 1278, 1320, Translate 4467, 4630;
`groundStandaloneMemberIdFor` — Engine 1958, Translate 4665; `groundSetMembers` — Store 3333, tests
LssGroundingTest ×8; `recordSpecWidenedKey` — Engine 2381, Monomorphize 3931; `papMemberKey` —
LssInfer 2556, Monomorphize 1244; `layoutQualKey` — Engine 733, tests LayoutQualTest ×5;
`withInstTag` — Engine 777, 780; `specWidenedKeys` — Engine 460, 496, 733, 902, 906.

#### 4. Design

##### 4.1 Catalogue of key shapes today (every `x|` prefix)

`G` below = `TOpt.toComparableGlobal g` = `author ++ "/" ++ project ++ ":" ++ modName ++ "." ++ name`
(TypedOptimized.elm:313–315, ModuleName.elm:257–259). It is injective over `Global` (author/project
contain no `/` or `:`, `modName` no `:`, `name` no `.`, so the last `.` and the single `:`/`/` split
uniquely) and contains neither `|` nor `#`. `W` = `toComparableMonoType (widenSets t)` for some
`t`; its fragments (`I F B C S U V0\0ecovalue L( T3( R( X<names>( A( Av0( A[1,2]( -> )`,
Monomorphized.elm:3356 + ComparableKeyEncodingTest goldens 230–262) and the identifiers inside them
contain no `|` and no `#` (Elm identifiers/module/package names — LSS_038's own argument). Because
`|` never occurs inside a component, every key string decomposes UNIQUELY at its `|`s.

| shape | components | producers (file:line) | must stay DISTINCT by | must MERGE when |
|---|---|---|---|---|
| `l\|<raw>\|<W>` | raw = `srcLambdaKey lamId`; W = the enclosing spec's captured widened creation key | Engine.elm:777 `layoutQualKey` (via `lambdaMemberLayoutQualified` 729 ← `lambdaInstanceMemberId` 666 ← LssInfer 179 `injectLambdaMemberQualified` ← Translate 1861 `classifyLambdaHead`, 4355/4358 `injectArgLambdaMemberGo`, 4112 `injectLocalMultiUseMember`; and Translate 1720 `lambdaInstanceMemberMaybe` re-read) | raw; W | same raw and string-equal W (annotation-only spec splits — LSS_024's whole point) |
| `l\|<raw>\|<W>\|#<tag>` | + tag = `mixTag`-composed local-multi instance tag (≠ 0) | Engine.elm:640 `withInstTag` (LSS_038) | raw; W; tag | same triple |
| `l\|<raw>\|<specId>` (+ optional `\|#tag`) | FALLBACK when `specWidenedKeys` has no entry (expected 0, censused `layoutQual.fallback`) | Engine.elm:780 | raw; specId; tag; and from every `W` form (a digit never starts a `W`) | same triple |
| `g\|<G>` | plain provisional standalone (Define/Link/Cycle globals) | LssInfer 1284, 1313; Translate 4386, 4416, 4670 | G | same G |
| `c\|<G>` | provisional standalone CTOR (Enum/Box nodes, VarEnum/VarBox) | LssInfer 1296, 1301; Translate 4401, 4405, 4636/4639/4642 | G; and from `g\|<G>` (a Box reached as `VarGlobal` at 4386 vs as a `Box` node at 4642 are DIFFERENT ids today — keep the kind letter) | same G |
| `g\|<G>\|<W>` | GROUND standalone: W = widened arrow `mFunction topWiden [paramT] resultT` (LSS_019, Engine 1941–1943) OR widened whole demand (Translate 4696 → 4665) OR the root-folded lambda's `l|` tail (Engine 745–750: `"g|" ++ G ++ dropLeft (length ("l|"++raw)) plainKey`, i.e. `|W`) | Engine 1879 (from 1958 zonk grounding and Translate 4665); Engine 745–750 root fold | G; W; from plain `g\|<G>` (second `\|`) | string-equal W across all THREE producers (this is the {l\|, g\|} singleton collapse of the root-member fold and LSS_019's "all three converge on one id") |
| `g\|<G>\|<specId>` | root-folded lambda whose spec had no captured key (fallback; expected 0) | Engine 745–750 with `isFallback` | G; specId; from `g\|<G>\|<W>` (digit vs letter) | same pair |
| `p\|<G>\|<n>` | PAP of global with n args supplied (n ≥ 1) | Engine 1799 `papMemberKey` ← `papMemberIdFor` 1811 ← LssInfer 1810, 2684 (`mintPapSuccessorIds` for 2588/2638/2668); Translate 4132, 4593, 4624; Monomorphize 1246 | G; n | same pair |
| `k\|<home>.<name>` | kernel value (home = `Elm.Kernel.List`, name = `cons`) | LssInfer 1278, 1320; Translate 4383, 4440, 4630 (all via `kernelMemberIdFor` 1998) | (home, name) — note `home ++ "." ++ name` is injective because `name` has no `.` | same pair |
| `a\|<field>` | record accessor `.field` | LssInfer 1324 (`standaloneMember` 2319 → `memberIdFor`); Translate 4426 | field | same field |

Root-folded keys carry NO `#tag` in practice: `instanceQualTagFor` (Engine.elm:606–615) returns 0
whenever `raw ∈ rootLamOf`, and `lambdaMemberLayoutQualified` reads the SAME `rootLamOf` (its `s0`
differs from `instanceQualTagFor`'s input only in `lssStats`, 590–597). So `foldedTo = Just g ⇒
instTag = 0`. The structural key relies on this (§4.7) and the E6 unit pin asserts it.

Kind letters that are NOT keys: `srcLambdaKey lamId` raw ids are never interned (LSS_003 —
AssignMVarIds mints them); `memberClassOf` (Engine 1189) classifies by `sources`, never by key.

##### 4.2 New types (Engine.elm)

```elm
type alias GlobalId = Int          -- from step 12
type alias ClassId = Int           -- index into WidenedClasses.repr; NEGATIVE = -(specId + 1) fallback

{-| One interned member's structural identity — the inverse of the old `byKey`.
    Every constructor is injective over its components; distinct constructors never
    collide (they replace distinct kind letters). -}
type MemberKey
    = KLam Int ClassId Int             -- l|<raw>|<W or specId>[|#tag]      (raw, class-or-fallback, instTag)
    | KGlobal GlobalId                 -- g|<G>
    | KCtor GlobalId                   -- c|<G>
    | KGround GlobalId ClassId         -- g|<G>|<W or specId>   (LSS_019 ground, root fold, registration self-identity)
    | KPap GlobalId Int                -- p|<G>|<n>
    | KKernel String String            -- k|<home>.<name>
    | KAccessor String                 -- a|<field>

type StandaloneKind = KindGlobal | KindCtor

{-| Per-kind Int maps. Nested `Dict Int`, never tuple-keyed and never bit-packed:
    a tuple key goes through the generic kernel `compare` (resolves + a tuple allocated per
    probe) while `Dict Int` compares unboxed Ints through the `MInt` intrinsic; packing would
    need a bound on `raw`/class/tag that no invariant gives (`mixTag` is modBy 2^30 and is NOT
    injective — it can never be an identity component). Nesting is injective by construction. -}
type alias MemberKeys =
    { lam : Dict Int (Dict Int Int)                 -- raw -> class -> mid          (instTag 0: 83K of 83K mints today)
    , lamTagged : Dict Int (Dict Int (Dict Int Int)) -- raw -> instTag -> class -> mid (LSS_038, instApplied only)
    , gPlain : Dict Int Int                          -- gid -> mid
    , cPlain : Dict Int Int                          -- gid -> mid
    , ground : Dict Int (Dict Int Int)               -- gid -> class -> mid
    , pap : Dict Int (Dict Int Int)                  -- gid -> n -> mid   (the per-global successor cache, §4.8)
    , kernel : Dict String Int                       -- home ++ "." ++ name -> mid  (~150 keys; step 23 gives it an Int id)
    , accessor : Dict String Int                     -- field -> mid
    }

{-| Dense class ids for WIDENED types: `table` is a SpecMap (HashMap keyed by
    `specHashOf` / `eqKeySpec`), `repr` maps a class id back to ONE representative for the
    report. Keyed by key-equality, NOT by Intern identity: two canonical nodes that differ only
    in `MVar _ CEcoValue` ids, or `MVar _ CNumber` vs `MInt`, are different objects but render
    the SAME string (Monomorphized.elm:3336–3345, 566–571), and must be one class. -}
type alias WidenedClasses =
    { table : Mono.SpecMap Int
    , repr : Array Mono.MonoType          -- Array.length repr == next class id
    }

type alias LssMemberTable =
    { keys : MemberKeys
    , kinds : Dict Int MemberKey          -- mid -> key; written by every intern (step 21 -> Array)
    , classes : WidenedClasses
    , specWidenedClass : Dict Int ClassId -- LSS_024: SpecId -> class of the IMMUTABLE widened creation key (was specWidenedKeys : Dict Int String)
    , sources : Dict Int MemberSource
    , lambdaQualified : Dict Int ( Int, Int )
    , muTied : Dict Int ()
    , provisionalStandalone : Dict Int ( GlobalId, TOpt.Global ) -- gid captured at mint so the PURE zonk grounding needs no global lookup
    , rootLamOf : Dict Int TOpt.Global
    }
```

`LssMemberTable` goes from 7 to 9 fields; a mint copies it once (plus the one inner map it
touches) exactly as today's `insertMemberKey` + `insertMemberGlobal` do. `S` and `LssStats` field
counts are UNTOUCHED (both sit at the 32-slot cap; `LssStats` is at 31 — Engine.elm:189).

##### 4.3 Class table and `specWidenedClass`

```elm
{-| Get-or-create the class of a WIDENED type. Callers pass the output of
    `Intern.widenSets`/`Mono.widenSets` only — a set-bearing input would mint a class whose
    rendering is `A[..](`, which no widened key can ever equal (no collision, but a silent
    identity split); the E5 pin asserts `not (Mono.hasVarAnno t)` and no LSet on the corpus. -}
classOf : Mono.MonoType -> WidenedClasses -> ( ClassId, WidenedClasses )
classOf wide cls =
    case Mono.specMapGet wide cls.table of
        Just c -> ( c, cls )
        Nothing ->
            let c = Array.length cls.repr in
            ( c, { table = Mono.specMapInsert wide c cls.table, repr = Array.push wide cls.repr } )

classText : ClassId -> WidenedClasses -> String      -- report only
classText c cls =
    if c < 0 then String.fromInt (-1 - c)             -- the SpecId fallback tail
    else case Array.get c cls.repr of
        Just t -> Mono.toComparableMonoType t
        Nothing -> "?class" ++ String.fromInt c

recordSpecWidenedKey : Int -> Mono.MonoType -> S -> S
recordSpecWidenedKey specId wide s =
    let table = s.lssMemberTable in
    if Dict.member specId table.specWidenedClass then s
    else
        let ( c, classes1 ) = classOf wide table.classes in
        { s | lssMemberTable = { table | classes = classes1, specWidenedClass = Dict.insert specId c table.specWidenedClass } }
```

`specMapGet` = `HashMap.get specHashOf eqKeySpec` (Monomorphized.elm:851–853): `specHashOf` reads
the packed hash field of the node (350–356, O(1) for composites), the bucket confirm is
`eqKeySpec` = `identicalOr True` (550–587) which returns at the first pointer comparison when the
probe is the canonical object step 11 hands us. Class ids appear nowhere in emission; only their
EQUIVALENCE matters (§4.10).

##### 4.4 The interning primitive (replaces `internMemberKey` 1760–1767)

```elm
probeMember : MemberKey -> MemberKeys -> Maybe Int
probeMember key k =
    case key of
        KLam raw c 0      -> Dict.get raw k.lam |> Maybe.andThen (Dict.get c)
        KLam raw c tag    -> Dict.get raw k.lamTagged |> Maybe.andThen (Dict.get tag) |> Maybe.andThen (Dict.get c)
        KGlobal gid       -> Dict.get gid k.gPlain
        KCtor gid         -> Dict.get gid k.cPlain
        KGround gid c     -> Dict.get gid k.ground |> Maybe.andThen (Dict.get c)
        KPap gid n        -> Dict.get gid k.pap |> Maybe.andThen (Dict.get n)
        KKernel home name -> Dict.get (home ++ "." ++ name) k.kernel
        KAccessor field   -> Dict.get field k.accessor

insertMember : MemberKey -> Int -> MemberKeys -> MemberKeys      -- the matching nested inserts (insert2 = Dict.update outer (insert inner))

{-| The ONE interning path (LSS_003 / LSS_019: pure, shared by Step-level mints and Store's zonk
    grounding). A hit returns table and supply UNCHANGED (same pointers) — callers detect the
    fresh-intern branch as `nextId' /= nextId`, exactly as today. -}
internMember : MemberKey -> LssMemberTable -> Int -> ( Int, LssMemberTable, Int )
internMember key table nextId =
    case probeMember key table.keys of
        Just mid -> ( mid, table, nextId )
        Nothing ->
            ( nextId
            , { table | keys = insertMember key nextId table.keys, kinds = Dict.insert nextId key table.kinds }
            , nextId + 1
            )

memberIdFor : MemberKey -> Step Int      -- body identical to today's 1777–1787 with `internMember`
```

During migration (E1–E7) `internMember` is wrapped by the shadow (§4.11) which also runs the
string path on the still-present `byKey` and crashes on disagreement.

##### 4.5 Per-kind mints

```elm
papMemberIdFor : TOpt.Global -> Int -> Step Int
papMemberIdFor global argCount s0 =
    let ( gid, s0g ) = globalIdOf global s0 in
    case memberIdFor (KPap gid argCount) s0g of          -- then the SourcePap registration exactly as 1817–1826
        ...

standaloneMemberIdFor : StandaloneKind -> TOpt.Global -> Step Int
standaloneMemberIdFor kind g s0 =
    let ( gid, s0g ) = globalIdOf g s0
        key = case kind of KindGlobal -> KGlobal gid ; KindCtor -> KCtor gid
    in
    case memberIdFor key s0g of
        Err e -> Err e
        Ok ( mid, s1 ) ->
            if Dict.member mid s1.lssMemberTable.sources then Ok ( mid, s1 )
            else Ok ( mid, { s1 | lssMemberTable = insertMemberProvisional mid ( gid, g ) (insertMemberGlobal mid g s1.lssMemberTable) } )

kernelMemberIdFor : ( String, String, String ) -> Step Int
kernelMemberIdFor (( _, home, name ) as k) s0 = ... memberIdFor (KKernel home name) ... -- registration as 1998–2009

accessorMemberIdFor : String -> Step Int
accessorMemberIdFor field = memberIdFor (KAccessor field)
```

Call-site rewrites are mechanical (§3). `kernelMemberIdFor`'s old first argument was always
`"k|" ++ home ++ "." ++ name` of the same triple at all four sites — verified by reading each.

##### 4.6 Lambda mints (Engine 729–780)

```elm
{-| LSS_024/LSS_038 key of a layout-qualified lambda mint — PURE, exposed for the pins
    (replaces `layoutQualKey`). Second component = True on the SpecId fallback. -}
lambdaKeyOf : Dict Int ClassId -> Int -> Int -> Int -> ( ClassId, Bool )
lambdaKeyOf specWidenedClass raw instTag specId =
    case Dict.get specId specWidenedClass of
        Just c  -> ( c, False )
        Nothing -> ( -1 - specId, True )          -- fallback class: negative, never a real class

lambdaMemberLayoutQualified : Int -> Int -> Int -> Step Int
lambdaMemberLayoutQualified raw instTag specId s0 =
    let
        ( cls, isFallback ) = lambdaKeyOf s0.lssMemberTable.specWidenedClass raw instTag specId

        -- ROOT-MEMBER FOLD: same class, ground kind (instTag is provably 0 here — §4.1)
        ( key, foldedTo, s0g ) =
            case Dict.get raw s0.lssMemberTable.rootLamOf of
                Just g  -> let ( gid, s1 ) = globalIdOf g s0 in ( KGround gid cls, Just g, s1 )
                Nothing -> ( KLam raw cls instTag, Nothing, s0 )
    in
    case Dict.get (qualifiedRawKey raw instTag) s0g.itemAux.demandQualified of
        Just tiedId ->
            if probeMember key s0g.lssMemberTable.keys == Just tiedId then     -- was: Dict.get key byKey == Just tiedId (758)
                mintLayoutQualifiedFold foldedTo key raw instTag specId isFallback True s0g
            else
                Ok ( tiedId, recordMuTied tiedId s0g )
        Nothing ->
            mintLayoutQualifiedFold foldedTo key raw instTag specId isFallback False s0g
```

`mintLayoutQualifiedFold`/`mintLayoutQualified` (788–888) keep their bodies; `key` is a
`MemberKey`. The μ-tie compares ids, not keys — unaffected (LSS_018 bypass 756–760).
`unqualifiedLambdaMints`, `layoutQual.*` counters: unchanged.

##### 4.7 Ground standalone members and the fold

```elm
groundStandaloneMemberIdFor : GlobalId -> TOpt.Global -> ClassId -> LssMemberTable -> Int -> ( Int, LssMemberTable, Int )
groundStandaloneMemberIdFor gid g cls table nextId =
    let ( mid, table1, next1 ) = internMember (KGround gid cls) table nextId in
    if next1 == nextId then ( mid, table1, next1 ) else ( mid, insertMemberGlobal mid g table1, next1 )

groundSetMembers : Mono.MonoType -> Mono.MonoType -> List Int -> Intern.Intern -> LssMemberTable -> Int
    -> { members : List Int, table : LssMemberTable, nextId : Int, intern : Intern.Intern, grounded : Int, deferred : Int }
-- fast path and deferral arms as today (1919–1938), returning `intern` unchanged;
-- the grounding arm replaces `typeKey` (1941–1943) by:
--     ( wide, intern1 ) = Intern.widenSets (Mono.mFunction Mono.topWiden [ paramT ] resultT) intern0
--     ( cls, classes1 ) = classOf wide table0.classes
-- and the per-member rewrite calls `groundStandaloneMemberIdFor gid g cls` with
-- `Just ( gid, g )` from `provisionalStandalone`.
```

`Store.groundMembersC` (3330–3346) passes `c.intern` and writes back `r.intern` next to
`memberTable`/`nextMemberId` (ZonkCtx already threads `intern`, 2387/2396). `Intern.widenSets`
instead of `Mono.widenSets` so the class probe hits on pointer identity (the arrow is built from
already-canonical zonked children — one `hashCons` probe, Intern.elm:270–282); by the K6 pin
(ComparableKeyEncodingTest "Intern.widenSets keys identically to Mono.widenSets") the class is the
same either way.

`memberIdForDepth` (Translate 4622) depth-0 Define arm: `case groundKey of Just wide -> let ( gid,
s ) = globalIdOf g s0; ( cls, classes1 ) = classOf wide s.lssMemberTable.classes; ( mid, table1,
next1 ) = groundStandaloneMemberIdFor gid g cls { table | classes = classes1 } s.nextMemberId in
Ok ( Just mid, { s | lssMemberTable = table1, nextMemberId = next1 } )`. Three producers, one
class table, one `KGround gid cls` key — the convergence LSS_019 §1.3 and the root fold require.

##### 4.8 PAP successor id cache per global

`mintPapSuccessorIds g d arity` (LssInfer 2679–2689) today calls `papMemberIdFor` per depth (a
string build + 62K-key probe each). New, in Engine:

```elm
{-| Ids for depths d..arity-1 of global g, in DEPTH order, minting the missing ones in
    ascending depth (the same order the old per-depth loop minted them — §4.12). One outer probe
    per walk; the inner dict is written back once, only if something was minted. -}
papSuccessorIdsFor : TOpt.Global -> Int -> Int -> Step (List Int)
papSuccessorIdsFor g d0 arity s0 =
    let ( gid, s0g ) = globalIdOf g s0
        inner0 = Maybe.withDefault Dict.empty (Dict.get gid s0g.lssMemberTable.keys.pap)
        go d inner next acc srcs minted =
            if d >= arity then ( List.reverse acc, inner, next, srcs, minted )
            else case Dict.get d inner of
                Just mid -> go (d + 1) inner next (mid :: acc) srcs minted
                Nothing  -> go (d + 1) (Dict.insert d next inner) (next + 1) (next :: acc)
                                (Dict.insert next (SourcePap g d) srcs) ((next, KPap gid d) :: minted)
        ( ids, inner1, next1, sources1, minted1 ) = go d0 inner0 s0g.nextMemberId [] s0g.lssMemberTable.sources []
    in
    if List.isEmpty minted1 then Ok ( ids, s0g )
    else Ok ( ids, { s0g | nextMemberId = next1, lssMemberTable = <write pap[gid] = inner1, kinds += minted1, sources = sources1> } )
```

`mintPapSuccessorIds g d arity [] s` becomes `Engine.papSuccessorIdsFor g d arity s` returning the
list depth-ordered (callers `List.reverse` a reversed accumulator today at 2591/2641/2671 — keep
the callers' `List.reverse` by returning the reversed list, or drop both; pick one and be
consistent). `papMemberIdFor` (single-depth sites) is `papSuccessorIdsFor`'s degenerate case and
keeps its signature.

##### 4.9 Report reconstruction and the other consumers

```elm
renderMemberKey : S -> MemberKey -> String            -- Monomorphize.elm (needs globalOfId + classes)
renderMemberKey s key =
    let cls = s.lssMemberTable.classes ; gtext gid = TOpt.toComparableGlobal (globalOfId gid s) in
    case key of
        KLam raw c tag    -> "l|" ++ String.fromInt raw ++ "|" ++ classText c cls ++ (if tag == 0 then "" else "|#" ++ String.fromInt tag)
        KGlobal gid       -> "g|" ++ gtext gid
        KCtor gid         -> "c|" ++ gtext gid
        KGround gid c     -> "g|" ++ gtext gid ++ "|" ++ classText c cls
        KPap gid n        -> "p|" ++ gtext gid ++ "|" ++ String.fromInt n
        KKernel home name -> "k|" ++ home ++ "." ++ name
        KAccessor field   -> "a|" ++ field

memberKeyText : S -> Dict Int String                    -- = Dict.map (\_ k -> renderMemberKey s k) s.lssMemberTable.kinds
```

This reproduces every old string byte for byte (each arm is the old producer's concatenation with
the same `TOpt.toComparableGlobal`, `String.fromInt` and `Mono.toComparableMonoType`; `classText`
renders the class REPRESENTATIVE, which is `eqKeySpec`-equal to every type that was ever mapped
to the class, hence string-equal by the K4 pin). Consumers:

- Monomorphize 1193–1194 (`midKeys`), 1920–1921 (`memberKeyOf`), 3813–3814 (`keyOf`), 4885
  (`lssMemberKinds`): replace the four `byKey` inversions with `memberKeyText s` (report-gated at
  4885 as today; the other three are already inside report/census code).
- 1427–1428 `internedCount = Dict.size sFinal.lssMemberTable.kinds` (one `kinds` entry per interned
  id; raw lambda ids are never interned — same count).
- 2875 `String.startsWith "l|" mk` → `case Dict.get m kinds of Just (KLam _ _ _) -> …` (root-folded
  lambdas are `g|` today and `KGround` now — same classification).
- `varSuccRounds` 1213–1225 `papable`: `case Dict.get m sAcc.lssMemberTable.kinds of Just (KPap gid
  d) -> Just ( globalOfId gid sAcc, d ); Just (KGlobal gid) -> Just ( g, 0 ); Just (KGround gid _)
  -> Just ( g, 0 ); Just (KCtor gid) -> Just ( g, 0 ); _ -> Nothing`. This is exactly the old
  `String.split "|"` dispatch (`"g" :: gstr :: _` matched BOTH `g|G` and `g|G|W`, incl. the
  fallback `g|G|<specId>`; `"c"`; `"p" :: g :: d`; everything else `Nothing`). Read the table LIVE
  from `sAcc` — the old `midKeys` snapshot + `keysAcc` inserts equals the live table because the
  only mints inside the round are the `papMemberIdFor` calls at 1246 (ORDER 3 §4.6 comment).
  Delete `midKeys`, `compGlobals` (1196–1200), `succKey` (1243–1244), the `keysAcc` threading.
- `buildMemberOrigins` 4899–4942: fold `table.kinds`; `KGlobal`/`KGround` → the old `"g|"` arm
  (`SourceGlobal` → `globalOrigin`), `KCtor` → `"c|"`, `KKernel` → `"k|"`, `KAccessor field` →
  `OriginAccessor field` (was `String.dropLeft 2 key`), `KPap` → `"p|"`, `KLam` → skipped. Output
  is a `Dict Int MemberOrigin` keyed by mid, so fold order is irrelevant.
- `multiSetCensusBlock` (3807) takes `S` (or the rendered `Dict Int String`) instead of the table.
- AbiCloning: no change — `lssMemberKinds` strings are identical, and `memberIdentityOf`
  (2228–2238) / the `noteSite` shape parse (1905–1940) keep working on them.

##### 4.10 Byte-identical ids — the rule and the proof

RULE. Member ids are assigned by get-or-create against a supply (`nextMemberId`), in program
order of the mint calls. Two implementations assign IDENTICAL ids iff (i) the sequence of mint
calls is the same and (ii) their key-equivalence relations coincide on every pair of calls
(induction on the mint sequence: at call k both implementations hit iff an earlier equivalent call
exists, else both assign `nextId`).

(i) holds because this step changes no control flow at any producer site: every site in §4.1
calls the same function in the same position (the only restructured site, `papSuccessorIdsFor`,
mints depths in the same ascending order as the loop it replaces, and `varSuccRounds` mints
through it at the same points).

(ii) per kind — string equality on the left, structural equality on the right, using the unique
`|`-decomposition of §4.1:

- `KLam raw c tag`: `l|r1|W1[|#t1] = l|r2|W2[|#t2]` ⇔ r1=r2 ∧ t1=t2 ∧ W1=W2 (tag suffix present iff
  tag≠0, `#` never inside W). W1=W2 with both renderings ⇔ `eqKeySpec w1 w2` (K4 pin:
  ComparableKeyEncodingTest:69–78 "eqKeySpec is EXACTLY specialization-key equality") ⇔ `classOf`
  returns the same id (the SpecMap is keyed by `eqKeySpec`, and "equal keys imply equal hashes",
  test 89–100, guarantees the probe finds the existing bucket entry). W1 a rendering and W2 a
  SpecId are never equal (a rendering starts with a letter, LayoutQualTest:139–147) ⇔ `c ≥ 0` vs
  `c < 0`. Two fallbacks equal ⇔ same specId ⇔ same `-1-specId`.
- `KGlobal`/`KCtor gid`: `g|G1 = g|G2` ⇔ G1=G2 ⇔ same `Global` (injectivity of
  `toComparableGlobal`, §4.1) ⇔ same `GlobalId` (step 12's table is a bijection on the globals it
  has minted). `g|…` never equals `c|…`.
- `KGround gid c`: as `KLam` for the tail, as `KGlobal` for G; a plain `g|G` never equals a
  ground `g|G|W` (component count). The three ground producers all pass the class of a widened
  type whose rendering was the old string — root fold: `dropLeft (length "l|raw") plainKey` =
  `"|" ++ W` with W = the captured `specWidenedKeys` string = `toComparableMonoType keyType`
  (2381/3931), now `specWidenedClass = classOf keyType`; LSS_019: `toComparableMonoType (widenSets
  arrow)` now `classOf (Intern.widenSets arrow)` (K6 pin for the two widenSets); registration:
  `toComparableMonoType (Mono.widenSets monoType)` (4696) now the class of step 11's canonical
  widened demand (K6 again). Cross-producer equality: string-equal renderings ⇔ `eqKeySpec` ⇔ one
  class — so the {l|, g|} collapse and the "three converge on one id" are preserved.
- `KPap gid n`: ⇔ same G and same n (digits after the last `|`).
- `KKernel home name`: `home ++ "." ++ name` injective (name has no `.`) — same map key as before
  minus the `k|` prefix.
- `KAccessor field`: identity.
- Cross-kind: distinct prefix letters ⇔ distinct constructors / distinct maps.

Class-table subtlety that the proof needs and G9 got wrong: classes must be keyed by KEY equality
(`eqKeySpec`), not by hash-cons identity — `Intern.eqExact` (Intern.elm:234) is `==`, which
separates `MVar` ids and `CNumber`-vs-`MInt` that the string merges. Keying on Intern identity
would SPLIT ids that are equal today.

##### 4.11 Shadow (E1–E7 only)

```elm
memberKeyShadow : Bool      -- True until E8; the constant is deleted with byKey
memberKeyShadow = True

internMember key table nextId =            -- migration body
    let ( mid, table1, next1 ) = internMemberStructural key table nextId in
    if not memberKeyShadow then ( mid, table1, next1 )
    else
        let ( midS, byKey1, nextS ) = internMemberString (renderMemberKeyPure table key) table.byKey nextId in
        if midS /= mid || nextS /= next1 then
            Utils.Crash.crash ("member-id shadow mismatch: " ++ renderMemberKeyPure table key ++ " structural=" ++ String.fromInt mid ++ " string=" ++ String.fromInt midS)
        else ( mid, { table1 | byKey = byKey1 }, next1 )
```

`renderMemberKeyPure` needs `globalOfId` without `S`: during migration keep a `globalNames :
Array String` (the `toComparableGlobal` of each id — step 12 has the `Array TOpt.Global`; store
either on `LssMemberTable.keys` for the duration). `byKey`, `specWidenedKeys` (asserted equal to
`classText` of `specWidenedClass` on every `recordSpecWidenedKey`) and the string functions stay
until E8. `Utils.Crash.crash : String -> a` (Utils/Crash.elm:20) is the idiom
(Monomorphize.elm:559). The shadow is a correctness scaffold, never measured: a timed run with the
shadow on measures both key paths.

##### 4.12 Order-of-evaluation constraints (all preserved)

- Member ids: same get-or-create sequence (§4.10 (i)). In `papSuccessorIdsFor` mint ascending by
  depth; in `groundSetMembers` keep the `List.foldl` over `members` (1945–1966) and the final
  `dedupAscending (List.sort …)`.
- `nextMemberId` seeding (Monomorphize 3866) unchanged.
- Intern insertion order: `groundSetMembers` now calls `Intern.widenSets` on the synthesized arrow
  (one extra `hashCons` probe of a node whose children are canonical). A MISS inserts a node into
  the Intern table at zonk time — a new insertion the old code did not make. The Intern table is a
  sharing cache (K6: "canonicalisation is not rewriting"), so emission cannot change; step 11's
  own gate note ("move the widen under `if created` — verify on the bootstrap rail") is the same
  argument. If the rail shows drift, fall back to `Mono.widenSets` here (pure, no insertion; the
  class is identical by K6) — that is the E5 switch, one line.
- Class ids: unobservable; HashMap iteration over `classes.table` is never used.
- `kinds` fold order in `buildMemberOrigins`/`memberKeyText`: outputs are `Dict Int`, order-free.
- Report text: identical strings, same row order (rows are keyed by ArrowId/mid, not by key).

#### 5. Edit sequence

Each edit leaves `elm make compiler/src/Terminal/Main.elm` and `cmake --build build --target
elm-tests` green; the shadow crash is the assertion between E2 and E8 on every self-compile.

- **E1 — scaffolding, no behaviour change.** Add `MemberKey`, `StandaloneKind`, `MemberKeys`,
  `WidenedClasses`, the new `LssMemberTable` fields NEXT TO `byKey`/`specWidenedKeys`;
  `emptyMemberTable`; `classOf`, `classText`, `probeMember`, `insertMember`,
  `internMemberStructural`, the shadowed `internMember`, `renderMemberKeyPure`, `memberKeyShadow`;
  step-12 wrappers `globalIdOf`/`globalOfId` if absent. `provisionalStandalone` gains the
  `GlobalId` (update `insertMemberProvisional`, `standaloneMemberIdFor`, LssGroundingTest
  `mintProvisional` 269–283 and its `Dict.get n1 r.table.provisionalStandalone` reads). Nothing
  calls the new mints yet.
- **E2 — `p|`.** `papMemberIdFor` → `KPap`; add `papSuccessorIdsFor`; `mintPapSuccessorIds` →
  one call; `varSuccRounds` 1246 unchanged. Run LssPapMembersTest, LssRefPapSpineTest,
  LssVarSuccTest, PostSettleDevirtTest, AbiCloningPapFastPassTest.
- **E3 — `k|`, `a|`.** `kernelMemberIdFor ( prefix, home, name )`; `accessorMemberIdFor field`;
  seven call sites (§3). KernelLicenseTest, LssAccessAndLitFactsTest.
- **E4 — `g|`, `c|` plain.** `standaloneMemberIdFor kind g`; eleven call sites; `standaloneArgMember
  kind g canVar`; LssInfer `standaloneMember` → accessor-only. E9CtorDevirtTest, PostSettleDevirtTest.
- **E5 — classes and ground.** `recordSpecWidenedKey specId wide` (Engine 2381 passes `keyType`;
  Monomorphize 3931 passes `Mono.widenSets monoType`) writing `specWidenedClass` AND (shadow)
  `specWidenedKeys`; `groundStandaloneMemberIdFor gid g cls`; `groundSetMembers … intern …`;
  `groundMembersC` threads `intern`; `memberIdForDepth g d (Maybe Mono.MonoType)`; `stampSelfSpine`
  passes the canonical widened type. Rewrite LssGroundingTest's eight `groundSetMembers` calls
  (pass `Intern.empty`, read `.intern`); add the ComparableKeyEncodingTest pin "classOf: two widened
  corpus types share a class iff their toComparableMonoType strings are equal" (fold the corpus
  through `classOf`, compare the partition with the string partition). LssGroundingTest,
  LssRootFoldTest, LssInstanceQualTest.
- **E6 — lambdas.** `lambdaKeyOf`; `lambdaMemberLayoutQualified` per §4.6; delete `layoutQualKey`,
  `withInstTag` (kept only inside `renderMemberKeyPure` until E8). Rewrite LayoutQualTest pins
  98–124 in the SAME edit: `lambdaKeyOf (Dict.fromList [(7, 3)]) 42 0 7 == (3, False)`;
  `… 42 0 8 == (-9, True)`; tag pins become `renderMemberKey`-level goldens (`"l|42|A(I->I)"`,
  `"l|42|8"`, `"l|42|A(I->I)|#513"`) via a test table whose class 3 has repr
  `arrowWith topLegacy`-widened; the "distinct instance tags never collide" pin becomes four
  `internMember` calls yielding four ids; internMemberKey idempotence pin 155–166 →
  `internMember (KLam 42 3 0)` twice. Add the fold pin: a `rootLamOf` lambda minted under
  `currentLocalInstance ≠ 0` gets `instTag 0` (`instRootSkip` counts) — `LssRootFoldTest` +
  `LssInstanceQualTest` already exercise the pipeline; add the unit assertion on
  `instanceQualTagFor`. MuTieTest, LayoutQualTest spiral/split pins unchanged (they read counters).
- **E7 — consumers.** `memberKeyText`; the four `byKey` inversions; `internedCount`; `m2StageWalk`;
  `varSuccRounds` `papable` (delete `midKeys`/`compGlobals`/`succKey`/`keysAcc`);
  `buildMemberOrigins`; `multiSetCensusBlock`; `lssMemberKinds`; delete `LssInfer.papMemberKey`
  (line 15 export, 2554–2556). From here nothing reads `byKey` except the shadow.
- **Gate before E8:** one self-compile of the tree by the last kept compiler with
  `ECO_MONO_LSS_REPORT=1` (untimed) — no crash, and `diff` of the report against the reference
  report is EMPTY; `cmp` of `-out.mlir` against `bin/ecoN-1.mlir`.
- **E8 — remove the shadow.** Delete `byKey`, `specWidenedKeys`, `insertMemberKey`,
  `internMemberString`, `memberKeyShadow`, `renderMemberKeyPure`/`globalNames`, `papMemberKey`,
  `withInstTag`, the string `memberIdFor`; update `emptyMemberTable`, the export list, and the
  LssGroundingTest `Dict.size t1.byKey` read (97) → `Dict.size t1.kinds`. Reword the invariant rows
  (§7). This is the state the loop measures.

#### 6. Verification

- Unit: `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt` (once). Suites
  that pin this code: ComparableKeyEncodingTest (+ new classOf pin), LayoutQualTest,
  LssGroundingTest, MuTieTest, LssInstanceQualTest, LssRootFoldTest, LssPapMembersTest,
  LssRefPapSpineTest, LssVarSuccTest, LssVarLambdaTest, LssVarCtorRowsTest, PostSettleDevirtTest,
  AbiCloningFenceTest, AbiCloningPapFastPassTest, AbiCloningFlatPeelPassTest, KernelLicenseTest,
  E9CtorDevirtTest, LssHonestSourcesPipelineTest, LssSigFlowTest, LssDirectedFlowTest. Baseline
  is the 12-failure POST_010 set; no new failure.
- Shadow gate (between E7 and E8, untimed): `rm -rf $BK/eco-stuff; cd $BK && ECO_MONO_ENGINE=solver
  ECO_MONO_LSS=1 ECO_MONO_LSS_REPORT=1 ./bin/eco-opt-prev make --optimize --kernel-package
  eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp --output=bin/shadow.mlir
  /work/compiler/src/Terminal/Main.elm 2> shadow.stderr` — must not crash; `grep -a -A99999 '=== LSS
  census ===' shadow.stderr | diff - <reference report>` empty (this diff covers the `members:`
  line, `muTie:`, the `MSET` block and every `POS`/`ARGF` row that names a key).
- Byte identity (Phase 2 of benchmarks/lss-compile-opt-loop.md): the three `-out.mlir` identical
  to each other and to `bin/ecoN.mlir`. Plus, once, the same report `diff` with the CANDIDATE
  binary (report-on run is a separate untimed leg).
- Loop triple: five stats per §2 of the loop doc; expected wall −2.5–3.5 % of the run, minor GC
  down, RSS down; verdict per §4 of the loop doc.
- Rail: `benchmarks/mlir-workload-rail.sh` (633 workloads, sha256 + census) in Phase 4.
- Attribution leg if the wall move needs explaining: `perf record -g` on the candidate
  self-compile (the §1 method), compare inclusive shares of `Engine_internMember*`,
  `Engine_lambdaMemberLayoutQualified`, `Engine_groundSetMembers`, `Engine_papSuccessorIdsFor`
  against the reference's `internMemberKey` 3.6 % / `lambdaMemberLayoutQualified` 2.75 % /
  `insertMemberKey` ~1 %; and `ECO_INLINE_ALLOC=0` object census for the String/StringRope delta.

#### 7. Risks, gotchas, and what NOT to do

- **Never key classes by Intern identity or `==`** (§4.10): `eqExact`/`==` split what the string
  merges (`MVar` ids, `CNumber` vs `MInt`). Only `specMapGet`/`specMapInsert` (spec flavour, never
  the layout family — Monomorphized.elm:716–724 warns the two are the same TYPE).
- **`mixTag` is not injective** (modBy 2^30, Engine 552–554) — it is fine as the μ-tie key
  (`qualifiedRawKey`, `demandQualified`, `lambdaQualified` payload — unchanged) but must never
  become an identity component; the tag is its own nested level.
- **Only widened types enter `classOf`.** All three producers widen first today; keep it that way
  (E5 pin).
- **The fold has tag 0** (§4.1). If a future change tags root-folded lambdas, `KGround` must gain
  the tag — the E6 unit pin is what fails.
- **32-slot cap**: do not add fields to `S` or `LssStats` (31). Shadow-mismatch is a crash, not a
  counter; the class table lives inside `LssMemberTable`.
- **Report byte-identity is a gate here**, not a nicety: `benchmarks/multiset-census.py:43–65`
  splits MSET member lists on `|` (inside keys too) and joins arms by key text; LSS_033's cross-arm
  join rule depends on unchanged key strings.
- **`provisionalStandalone` payload change** touches LssGroundingTest's mirror (269–283) and the
  `Dict.get n1 r.table.provisionalStandalone` reads — update in E1, not later.
- **Intern insertion at zonk** (§4.12): if the rail or bootstrap shows drift, switch
  `groundSetMembers` to `Mono.widenSets` (one line) — the class is identical by K6.
- **Symlinked `build-kernel/src`** and stale `eco-stuff`: `rm -rf $BK/eco-stuff` before every
  compile (loop §5); the Main.elm path argument does not pick the tree.
- Do NOT: change lambda-set representation (plan N4), cache `demandQualifiedFor` (N6), optimise
  `buildMemberOrigins` beyond its input (N11, ~10 ms), touch AbiCloning's string parsers (step 25),
  or convert `kinds`/`sources`/`provisionalStandalone` to `Array`/BitSet here (step 21 — it
  depends on this step's `specWidenedClass : Dict Int Int` becoming `Array Int` there).
- Invariant rows to reword at E8 (same semantics, new spelling): **LSS_003** "`Engine.memberIdFor`
  interning … `Engine.internMemberKey`" → `Engine.internMember` (structural `MemberKey`, get-or-
  create, idempotent); **LSS_017** `interned "l|<srcLambdaKey L>|<S>"` → `KLam raw class tag`
  with the string as the report rendering; **LSS_018** unchanged except "`lambdaQualified`'s
  payload" text stays; **LSS_019** `g|<global>|<widened-arrow-typeKey>` → `KGround gid (classOf
  (widenSets arrow))`, "interned once via the shared pure `Engine.internMember`", "the key is
  annotation-widened" unchanged; **LSS_024** `l|<raw>|<widenedKey>, widenedKey =
  toComparableMonoType(widenSets keyType)` → `KLam raw (classOf (widenSets keyType)) tag`,
  `specWidenedKeys` → `specWidenedClass`, `layoutQualKey` → `lambdaKeyOf`, "every widened key
  starts with a letter code, a bare-integer SpecId suffix never equals one" → "fallback classes
  are negative (`-1 - specId`), real classes non-negative"; **LSS_033** add "member KEY strings are
  RENDERED from `LssMemberTable.kinds` (`renderMemberKey`) — the text is unchanged"; **LSS_038**
  "appended as `|#<tag>`" → "carried as the third `KLam` component; the report renders it as
  `|#<tag>`", KEY-STRING SAFETY paragraph → "the tag is a separate nesting level, so it cannot
  collide with a class". Also the `lssMemberKinds` doc (Monomorphized.elm:2943 "its FULL interned
  key" → "the RENDERED key") and Engine.elm:1323's field comment.

#### 8. Effort

**L** — nine files, ~40 call sites, three test suites rewritten, one new pin, seven invariant
rows; the shadow makes each kind independently verifiable but the win is only measurable after
E8. Split for the loop if needed: **13a** = E1–E5 + E7 + E8 for the non-lambda kinds (byKey keeps
ONLY `l|` strings; `kinds` gets a bridge arm `KLamLegacy String` rendered verbatim so consumers
switch once) — measurable (`p|`/ground/plain mints and the per-slot ground rendering gone);
**13b** = E6 + the rest of E8 (lambda mints, `specWidenedKeys` retirement) — the larger half of the
win (83K mints × multi-KB keys). Prefer the single entry unless 13a alone must be defended.

<details><summary>Conventions used in this spec (from spec-H)</summary>

All line numbers are from the tree as read on 2026-09-19 (before steps 11 and 12 land); the
functions are named so they can be re-located after those steps move lines.

</details>

### Step 14 (was 12). Inline the HPointer resolve in the kernel export path (runtime)

1. **Goal and expected effect**

`Allocator::resolve` is 7.7 % SELF time of the mono window (plan §1) and is an out-of-line call
from every kernel/runtime dereference: `hpointerToPtr` (RuntimeExports.cpp:56-64) → `resolve`
(Allocator.cpp:883-918) at 52 sites in RuntimeExports.cpp (including `eco_get_header_tag` :4164,
`eco_get_custom_ctor` :4172, `eco_store_field` :1796, `eco_clone_array` :4774, `eco_resolve_hptr`
:4723), and DIRECT `Allocator::instance().resolve(...)` calls in the kernel and runtime helpers
(grep counts: JsArrayExports.cpp 57, RuntimeExports.cpp 37, JsonExports.cpp 26, HeapHelpers.hpp 21,
List.cpp 14, BytesExports.cpp 12, Utils.cpp 6 — `safeResolve` :66-69, `resolveAndCompare` :89-90
(the `eqHelp` path), `dictEq`'s `resolveCustom` :742 — String.cpp 9, ListExports.cpp 8, …).
`Allocator::resolveFast` (Allocator.hpp:67-72) already IS the inline fast path but is used only by
StringOps.cpp (40 sites) and `Export::toPtr` (elm-kernel-cpp/src/ExportHelpers.hpp:66).

Expected: `resolve` self time → the cost of one header load + compare at each site (the loop's
first iteration, now inlined); mono window −3…−5 %, front end more (plan: "M, ~4-6 %"). Wall down;
GC counters and RSS identical. BI by construction (runtime-only).

2. **Preconditions**

- None. Verify the LTO claim: `grep -rn -i "flto\|INTERPROCEDURAL_OPTIMIZATION" --include=CMakeLists.txt --include=*.cmake . | grep -v "^./build\|snapshots"` → empty (verified). So an out-of-line `resolve` in Allocator.cpp can never be inlined into RuntimeExports.cpp or any `elm-kernel-cpp` TU: the fix MUST live in Allocator.hpp.
- Verify compaction is test-only (the GC-safety argument below depends on it):
  `grep -rn "scheduleCompaction\|incrementalCompactionSlice" runtime/src --include=*.cpp --include=*.hpp` → only OldGenSpace.cpp:3625/3694 definitions and the `OldGenSpaceTestAccess` trampolines at OldGenSpace.hpp:1364-1366 (verified).
- Confirm the validate-build option name: `grep -n "HEAP_VALIDATE" CMakeLists.txt runtime/src/CMakeLists.txt`.

3. **Inventory of touched code**

| file | function (lines) | what changes |
|---|---|---|
| runtime/src/allocator/Allocator.hpp | decl `void* resolve(HPointer ptr);` :58; `resolveFast` :60-72 | `resolve` becomes an inline member (fast check + call to new out-of-line `resolveSlow`); `resolveFast` becomes a one-line alias of `resolve` (keep the name: 41 call sites) |
| runtime/src/allocator/Allocator.cpp | `Allocator::resolve` :883-918 | renamed `resolveSlow`; body unchanged (ECO_HEAP_VALIDATE asserts + forward loop + final assert) |
| runtime/src/allocator/RuntimeExports.cpp | `hpointerToPtr` :56-64 | NO textual change needed (it calls `resolve`, now inline). Update the stale comment at :2465 only if desired |

No call site changes: all ~300 `resolve(` callers and all `resolveFast` callers keep compiling.
Generated code is untouched — it never calls `resolve` (inline `__eco_resolve_fwd` diamond,
EcoBackend.cpp:1140-1195, cold arm `eco_follow_forward` RuntimeExports.cpp:4742-4751).

4. **Design**

```cpp
// Allocator.hpp — replaces :58 and :60-72
    // Out-of-line: ECO_HEAP_VALIDATE asserts + the Tag_Forward follow loop.
    void* resolveSlow(HPointer ptr);

    // Inline resolve (plan D9, LSS step 14). Under HEAP_028 the word IS the
    // address; the common case is one header load + one predicted-not-taken
    // compare — exactly the first iteration of resolveSlow's loop. Header-
    // defined because there is no LTO: RuntimeExports.cpp and every kernel TU
    // could otherwise only CALL Allocator.cpp's copy.
    inline void* resolve(HPointer ptr) {
#if ECO_HEAP_VALIDATE
        return resolveSlow(ptr);          // validator builds check every dereference, as today
#else
        void* obj = fromPointerRaw(ptr);  // asserts ptr_ind == 0 (same first line as today, :884)
        if (__builtin_expect(getHeader(obj)->tag >= Tag_Forward, 0))
            return resolveSlow(ptr);      // Tag_Forward: follow; anything above: resolveSlow's
                                          // `assert(hdr->tag < Tag_Forward)` fires, as today
        return obj;
#endif
    }

    static inline void* resolveFast(HPointer ptr) { return Allocator::instance().resolve(ptr); }
```

`fromPointerRaw` (Allocator.hpp:459-465) and `getHeader` (AllocatorCommon.hpp:235) are already
header-inline; `Tag_Forward` comes from Heap.hpp (included via AllocatorCommon.hpp). Using `>=`
rather than `==` keeps the asserts-on `build` preset's coverage identical: today every resolve ends
in `assert(hdr->tag < Tag_Forward)` (Allocator.cpp:916); with `==` a corrupt tag above
`Tag_Forward` would pass silently on the inline path. `Tag_Forward` is the largest tag
(HEAP_032: "every live object stays < Tag_Forward"; GCStats.hpp:209 `NUM_ALLOC_TAGS = Tag_Forward + 1`),
so for every legal header `>=` and `==` are the same predicate and cost the same compare.

**GC-safety argument.** Invariants: HEAP_028 (word == address, so `fromPointerRaw` is a
reinterpret), HEAP_006 (forwarding pointers "exist only during GC and never while mutator code
runs"), HEAP_017 (no null word). When can a header read see `Tag_Forward`? (a) In the NURSERY, only
between `evacuate` writing the forward and the end of `minorGC` — while `g_in_minor_gc` is true and
the mutator (and every kernel export) is stopped; the only C++ that can resolve then is GC-internal
code and root-set external scanners, which today go through the same `resolve` loop — the inline
version follows the forward via `resolveSlow` in exactly that case. (b) In OLD GEN, only during
incremental compaction (`CompactionPhase::Evacuating/FixingRefs`, OldGenSpace.hpp:263-267), which
production never enters: `scheduleCompaction` (OldGenSpace.cpp:3625) and
`incrementalCompactionSlice` (:3694) have no callers outside `OldGenSpaceTestAccess`
(OldGenSpace.hpp:1364-1366). Even there the inline check is not a shortcut: it is the loop's first
iteration verbatim (`while (hdr->tag == Tag_Forward)` at Allocator.cpp:910 with the `__builtin_expect`
hint already present), so the observable behaviour is identical in every heap state — the change
moves the first compare into the caller and nothing else. The `resolveFast` comment (:60-66) already
made this argument; step 14 just applies it to `resolve` itself so all ~300 sites inherit it.

**TU / LTO note.** `hpointerToPtr` is in an anonymous namespace of RuntimeExports.cpp; `Export::toPtr`
(ExportHelpers.hpp:50-70) is the kernel's separate helper and additionally accepts raw non-heap
pointers via `isInHeap` (UtilsExports.cpp:37-40 documents that the two are NOT equivalent) — do not
try to unify them here. With `resolve` inline both become call-free on the hit path.

5. **Edit sequence**

1. Allocator.cpp:883 rename `Allocator::resolve` → `Allocator::resolveSlow` (body untouched; update
   the doc comment :874-882 to say "slow path of the inline resolve").
2. Allocator.hpp:58 → the `resolveSlow` declaration + inline `resolve` above; :67-72 → the alias.
   Build: every existing caller compiles unchanged.
3. Optional: RuntimeExports.cpp:2465 comment fix ("hpointerToPtr is a single load+compare on the fast path").

6. **Verification**

- `cmake --build build --target test 2>&1 | tee /tmp/test_output.txt` (AllocatorTest.cpp,
  HeapHelpersTest.cpp, StringOpsTest.cpp, GCPressureTest.cpp exercise resolve through forwarding
  during minor GC; OldGenSpace compaction tests drive `Tag_Forward` in old gen through the test
  accessors — they now exercise the inline `>=` path + `resolveSlow`).
- A validator configuration must still build (asserts path): configure a scratch dir with the
  `ECO_HEAP_VALIDATE` option ON (name from the precondition grep) and build the `test` target once.
- `cmake --build build --target check 2>&1 | tee /tmp/test_output.txt` (C++-only).
- Loop triple `ARM=eco-opt14` on the SAME `.mlir` as the reference (re-lowered with the rebuilt
  `$BOOT`); fixed point `cmp` against `bin/eco-compiler.mlir`; minor/major/promoted identical.
- Attribution: `perf report --no-children --sort symbol | grep -i "Allocator::resolve\|resolveSlow"`
  — `resolve` self time (7.7 % of the window) must vanish from the symbol table (inlined) and
  `resolveSlow` must be at the sampling floor; the callers (`eqHelp`, `eco_get_header_tag`,
  `Data_HashMap_scanBucket` …) absorb only the remaining load+compare.

7. **Risks, gotchas, what NOT to do**

- `fromPointerRaw`'s `assert(ptr.ptr_ind == 0)` (Allocator.hpp:460) is live in the `build` preset
  (`-UNDEBUG`); it was live before too (resolve's first line). Do not "optimise" it away.
- Do not drop the `#if ECO_HEAP_VALIDATE` dispatch: the nursery stale-pointer tripwire and the
  heap/permanent bounds asserts (Allocator.cpp:886-905) are the validator's whole point.
- Do not change `eco_follow_forward` (:4742) or the inline-deref expansion; they are the
  generated-code twin and already correct.
- HEAP_006's wording ("never while mutator code runs") predates incremental compaction; this step
  does not depend on it (the check is kept), so no invariant amendment is needed. If someone later
  wires `scheduleCompaction` into production, the inline path is still correct.
- Not worth doing here (plan §4 has no entry; add none): replacing the 52 `hpointerToPtr`
  sites with `Export::toPtr`, or routing `hpointerToPtr` through `resolveFast` only — that would
  silently lose the validator asserts, which the brief forbids.

8. **Effort:** S — two files, no call-site churn; one loop entry (`14`), can run in parallel with
Elm-side steps since it never touches `compiler/`.

---

<details><summary>Conventions used in this spec (from spec-I)</summary>

All line numbers verified against the tree on 2026-09-19 (HEAD, clean). None of the four steps
changes the LSS analysis; three of them (1, 14, 18b) are runtime/backend-only and are byte-identical
at the MLIR level by construction, two (18a, 20) change compiler SOURCE and therefore change the
workload (`out.mlir`) without changing the analysis — the loop's fixed-point rule (Phase 1.5:
A≠B is propagation, the gate is B==C) applies to those.

---

</details>

### Step 15 (was 16). `enqueueSpecKeyed` hit path

1. **Goal and expected effect.** On the ~98K keyed-registry HITS per run (83,196 identical + 14,865
   noop) `enqueueSpecKeyed` (Engine 2305-2400) pays: `Mono.toComparableGlobal` (a 5-concat string) + a
   `Dict String` probe for a budget that is never consulted at the default `maxSpecsPerGlobal = 0`
   (2308-2321); `Intern.widenSets` on the whole demand (2328-2333; consumed only when created or over
   budget — 5.1 % of the mono window inclusive across all enqueues, plan §1); `bumpKeyedHit` (S +
   LssStats — gone with step 7); and `s1` (2357-2372), a full `S` rebuild storing the pointer-identical
   registry/tally/stats that `enqueueSpecCommit` 2185-2192 then returns unaltered. Expected: −1-3 % of the
   mono window depending on whether the widen already moved in step 11 (see §2). **BI expected**: the hit
   path's inputs and outputs are unchanged; deferring the widen changes only intern insertion ORDER (which
   nothing observes — `grep -rn "Intern\.\(toList\|fold\|keys\|values\)" compiler/src/Compiler` is empty;
   `Intern` exposes only `size`, `hashCons`, `widenSets`), but the plan mandates the rail + bootstrap for
   any intern-order shift, so treat it as an analysis-order step for gating purposes.

2. **Preconditions.** Steps 7 (gated `bumpKeyedHit`) and 11 in. Read what step 11 did to
   `enqueueSpecKeyed`'s widen: `sed -n 2305,2345p compiler/src/Compiler/MonoSolver/Engine.elm`.
   Two cases: (i) step 11 passes ONE interned widened key (or a thunk) in from `enqueueSpecStamped` — then
   step 15 only forces/uses it in the created/over-budget arm and leaves the widen where step 11 put it;
   (ii) step 11 left the local `Intern.widenSets` at 2328-2333 — then step 15 moves it under
   `created || not underBudget` and MUST run the rail + one extra bootstrap turn (loop Phase 1.5).
   Also confirm `specIdsForGlobal` (Engine 80-87 ← Translate 7636) is the only reader of
   `specCountByGlobal.ids` — it is semantic (destrAnno ctor-demand union), so the tally insert on the
   CREATED path must stay.

3. **Inventory of touched code.**

| file | function (lines) | change |
|---|---|---|
| Engine.elm | `enqueueSpecKeyed` 2305-2400 | restructured (sketch §4) |
| Engine.elm | `bumpKeyedHit` 2217-2234 | already report-gated by step 7; called on both paths |
| Engine.elm | `enqueueSpecCommit` 2185-2202 | unchanged (the hit path no longer reaches it) |
| Engine.elm | `checkSpecWatchdogs` 1236-1266 | unchanged (created path only; see §7 for why `createdCount` stays) |
| Engine.elm | doc 2285-2303 | update the "`specCountByGlobal` counts CREATED specs" paragraph: probed only when budgeted or created |
| Monomorphize/Registry.elm | `getOrCreateSpecIdKeyed` 137-185 | unchanged |
| tests SpecWatchdogTest.elm, LayoutQualTest.elm | none expected — they drive the pipeline; pins are message text and `specWidenedKeys` (LSS_024) which the created path still records |

4. **Design.**
   ```elm
   enqueueSpecKeyed : Mono.Global -> Mono.MonoType -> Step Mono.SpecId
   enqueueSpecKeyed global monoType s0 =
       let
           budgetOn = s0.env.lss.maxSpecsPerGlobal > 0                      -- default 0 = no policy

           -- The tally is consulted ONLY when the budget policy is on (its string key is otherwise never built).
           ( gkeyB, tallyB ) =
               if budgetOn then
                   let g = Mono.toComparableGlobal global in
                   ( g, Maybe.withDefault emptySpecTally (CoreDict.get g s0.specCountByGlobal) )
               else ( "", emptySpecTally )

           underBudget = not budgetOn || tallyB.count < s0.env.lss.maxSpecsPerGlobal

           -- Key type: the annotated demand under budget (no widen), the widened key over budget.
           ( keyType, sPre ) =
               if underBudget then ( monoType, s0 )
               else let ( w, intern1 ) = Intern.widenSets monoType s0.intern in ( w, withIntern intern1 s0 )
               -- case (i) of §2: replace the widen by forcing step 11's shared key here.

           ( ( specId, reg1, hit ), created ) =
               let r = Registry.getOrCreateSpecIdKeyed global keyType monoType sPre.registry in
               ( r, (\( _, rg, _ ) -> rg.nextId > sPre.registry.nextId) r )
       in
       if not created && hit /= Registry.HitChangedJoin && BitSet.member specId sPre.scheduled then
           -- HIT (HitIdentical / HitNoopJoin): the registry is the SAME value (Registry 149, 158, 166),
           -- nothing is stored, nothing is scheduled — return sPre untouched (bumpKeyedHit is a no-op off report).
           Ok ( specId, bumpKeyedHit hit sPre )
       else
           let
               s = bumpKeyedHit hit sPre
               storedChanged = hit == Registry.HitChangedJoin
               gkey = if budgetOn then gkeyB else Mono.toComparableGlobal global      -- built once, created/changed path only
               tally = if budgetOn then tallyB else Maybe.withDefault emptySpecTally (CoreDict.get gkey s.specCountByGlobal)

               -- LSS_024 §2.2: the widened creation key, needed on the CREATED path only.
               ( widenedKey, sW ) =
                   if created && underBudget then
                       let ( w, intern1 ) = Intern.widenSets monoType s.intern in ( w, withIntern intern1 s )
                   else ( keyType, s )                                            -- over budget: keyType IS the widened key

               stats0 = sW.lssStats
               s1 = { sW | registry = reg1
                         , specCountByGlobal = if created then CoreDict.insert gkey { count = tally.count + 1, ids = specId :: tally.ids } sW.specCountByGlobal else sW.specCountByGlobal
                         , lssStats = if underBudget || not sW.env.lss.report then stats0 else { stats0 | widenedByBudget = stats0.widenedByBudget + 1 } }
               s2 = if created then recordSpecWidenedKey specId (Mono.toComparableMonoType widenedKey) s1 else s1
           in
           case (if created then checkSpecWatchdogs global monoType reg1 s2 else Nothing) of
               Just failure -> Err failure
               Nothing -> enqueueSpecCommit specId s2.registry storedChanged s2
   ```
   Equivalence with today, arm by arm:
   - Hit + scheduled: today `s1` stores `registry = reg1` (== `s.registry` by pointer for the two hit
     kinds), `specCountByGlobal` unchanged, `lssStats` unchanged (under budget); `s2 = s1`; no watchdog;
     `enqueueSpecCommit` returns `s` (2187-2192). New: returns `sPre` — the same value.
   - Hit + `HitChangedJoin`: `reg1` differs → general path → `markDirty` via commit (LSS_010) — unchanged.
   - Hit + NOT scheduled (cannot happen today — every registry id is created through a commit or `seedSpec`,
     which schedules — but kept for safety): general path, commit pushes as today.
   - Created: identical writes in identical order (tally insert, widened-key capture write-once —
     LSS_024, watchdog on `reg1` — MONO_030, commit). The widen for `specWidenedKeys` happens AFTER the probe
     instead of before; `Registry.getOrCreateSpecIdKeyed` does not touch the intern table, so the created
     spec's key string is byte-identical.
   - Over budget (only when `maxSpecsPerGlobal > 0`): the widen happens before the probe exactly as today.
   Where `Intern.widenSets` moves: from "every enqueue, before the probe" to "created (after the probe)
   or over-budget (before it)". Interaction with step 11: if step 11 made the widened key a shared thunk,
   the thunk is forced at `( widenedKey, sW )` and at `( keyType, sPre )` only; if step 11 already passes
   an eagerly-computed key, nothing moves and the rail is not needed for this step.

5. **Edit sequence.**
   1. Rewrite `enqueueSpecKeyed` as above, keeping the widen where it is today (or where step 11 put it)
      — i.e. compute `( maybeWidened, sPre )` unconditionally as at 2328-2333 and use it in both arms.
      (green; `elm-tests`; this part is BI with no intern-order shift → a clean loop entry `15a`.)
   2. Move the widen under `created || not underBudget` (`15b`) — requires the rail and the extra bootstrap
      turn (loop Phase 1.5); skip if step 11 already did it.

6. **Verification.** `elm-tests` (SpecWatchdogTest, LayoutQualTest, PostSettleDevirtTest); BI `cmp` triple;
   for `15b`: `benchmarks/mlir-workload-rail.sh` + bootstrap B==C; census leg with `ECO_MONO_LSS_REPORT=1`:
   `joins: identical=… noop=… changed=…` and `members: … interned` lines must be identical to the reference
   (the same hits are counted; the same member keys are interned). Attribution: `ECO_INLINE_ALLOC=0` —
   `S`-class records −98K and (`15b`) the `Intern.widenSets` closure/record share.

7. **Risks, gotchas, what NOT to do.**
   - Do NOT replace `Registry.createdCount` in `checkSpecWatchdogs` by `tally.count + 1`: the registry's
     `countByGlobal` also counts `seedSpec`-created specs (Monomorphize 3917, via `getOrCreateSpecId`)
     which `specCountByGlobal` never sees, so the breadth trigger point would shift by 1-2 for the entry
     global; MONO_030 names `Registry.countByGlobal` and the subst engine shares it. It runs on the created
     path only (43K) — leave it.
   - Do NOT drop `specCountByGlobal` (G3's suggestion to keep only one tally): its `ids` are semantic
     (`specIdsForGlobal`, Translate 7636).
   - Keep the `BitSet.member specId sPre.scheduled` test on the hit path; without it an unscheduled hit
     would silently never be translated.
   - `bumpKeyedHit`'s doc (2205-2215) says the hit copy is deliberate for Run A/B measurement — rewrite
     the comment; the count is still exact under report.
   - Plan §4 N12: the probe itself (`eqKeySpec` pointer path, `Array.get`) is not the cost — do not touch
     `getOrCreateSpecIdKeyed`.

8. **Effort: S** (`15a` one function, BI; `15b` a two-line move gated by the rail + bootstrap turn — only if
   step 11 left the widen here).

<details><summary>Conventions used in this spec (from spec-F)</summary>

Line numbers are from the tree as read on 2026-09-19 (Store.elm 3722 ln, Engine.elm 2823, Translate.elm
8263, Monomorphize.elm 5097, LssInfer.elm 3597, UnionFind.elm 299). Every writer/reader below was
verified by `grep -n "lssStats = " MonoSolver/*.elm` (34 hits), `grep -n "UF\.\(get\|repr\|equivalent\|set\)\b"`
(48 hits) and `grep -n "store = store[0-9]"` (31 hits), not from memory.

Shared finding that shapes all three steps: **every `LssStats`/`SigFlowStats` field except
`flexCtorSpecs`, `joinRounds` and `retranslations` is read ONLY inside `Monomorphize.renderLssReport`
(1418-…), which is rendered only when `lssConfig.report` (Monomorphize 197-201).** `setsZonked` is
"reconciled" against `sigStats.settled.zonked` at 1754 — but that reconciliation is itself a report
line, and `settled` is populated only under report (`rezonkSettled` 2450). So the census can be
report-gated wholesale at zero semantic cost, and `lss.report` is excluded from the config hash
(Engine 1172-1176: "a report-on run must produce the same artifact as a report-off one"), so gating
cannot move emission.

---

</details>

### Step 16 (was 13). Inference walk: skip work that cannot write a set

#### 1. Goal and expected effect

`LssInfer.signatureFor` is 8.4 % of the mono window inclusive (plan §1: `walkExpr` 8.0 %,
`applyCalleeAt` 4.8 %, `instantiateWithSignature` 3.5 %). The walk runs ONCE per global body
(memoised in `S.lssSignatures`), but per body it does, unconditionally:

- a fresh isolated instantiation of every global callee's whole annotation type plus a
  `Unify.unify` per argument and for the result (`applyCalleeAt` LI:1761-1771 →
  `instantiateWithSignature` LI:127-144 → `unifyCallShape` LI:1835-1852 →
  `unifyParamsBestEffort` LI:1927-1957), even when the callee's signature is trivial and every
  type involved is arrow-free — nothing this can do reaches a set slot (**D1**);
- a second walk of the callee `func` child of every `Call` (LI:1254), which for a named callee is
  the full standalone-VALUE treatment — `kernelAliasOf` HashMap probe, `g|`/`c|`/`k|` string +
  `byKey` probe, `Store.loadType` of the occurrence type, `injectSpineMemberId 1`, then
  `declaredArityOf` + `(arity-1)` `p|` string probes + a second set-write pass — whose head slot
  is an orphan in the scratch store (**D2**);
- a full store DFS (`storeMentionsArrow` LI:3113-3163, one 31-field `S` copy per visited node)
  at every container-typed directed flow, whose only reader is the report-gated
  `bumpFlowDegraded` (**D4**);
- the ordinal `Array` build in `Store.loadTypeIsolatedWithArrows` (ST:235-242) for callees
  whose signature is trivial, where `applyFacts` (LI:245) never reads it — on BOTH the inference
  path and the per-spec `Translate.instantiateLss` path (**D8**);
- scratch-store loads of `Let`/`TailDef` def types and of every record/tuple/list/update literal
  type when the type is arrow-free, whose only consumers are `canTypeMentionsArrow`-guarded
  (**D10**), plus a `Dict Name` lookup before that guard at every `VarLocal` (**D12**).

Expected movement (plan: ~3 % of the mono window): **minor GC count down** (isolated
instantiations mint Points into the persistent `Array` store and every `UF.get` site copies
`S`; `storeMentionsArrow` copies `S` per node; `Array.fromList (List.reverse ..)` per trivial
call), **wall down** ~1-2 % of the run. Major GC / promoted / RSS: flat (the scratch store is
per-unit garbage, not retained).

Byte-identity: **16a (D1, D2-mint-preserving, D4, D8, D10, D12) is BI** — the argument per item
is in §4 (each skipped operation either touches no `FunL` set slot, or touches a slot that is
UF-unreachable from every signature slot and every Point the walk hands upward). **16b (D2 with
the member-id mints dropped) is NOT BI**: it changes the first-seen interning order of `g|`/`c|`/
`k|`/`p|` keys on the shared `nextMemberId` supply, and member-id order is observable (§4 D2,
answer Q-c). 16b is a separate loop entry with the analysis-step gate (bootstrap turn, B==C, plus
the 633-workload rail).

#### 2. Preconditions

- Loop order: after step 15. Hard dependencies: none — D1/D4/D8/D10/D12 and D2-16a touch only
  `LssInfer.elm` (+ one `Store` export already present). Step 12's per-global facts memo would make
  `declaredArityOf`/`kernelAliasOf` (probed by D2-16a's mint replay) cheaper, but 16a does not
  need it.
- Verify the tree is the reference: `benchmarks/lss-loop-snap.sh verify <ref>`.
- Verify nothing has moved in the touched functions (all must print exactly the cited line):
  ```
  grep -n "^applyCalleeAt\|^instantiateWithSignature\|^degradeToSymmetric\|^storeMentionsArrow\|^walkLiteral\|^joinLetUse\|^walkChildren\|^withPapSuccessors\|^standaloneMemberWith\|^injectPapSuccessors " /work/compiler/src/Compiler/MonoSolver/LssInfer.elm
  # expect 1734 128 3093 3114 1517 2861 3467 2528 2498 2623
  grep -n "walkChildren letEnv (func :: args)" /work/compiler/src/Compiler/MonoSolver/LssInfer.elm   # expect 1254
  grep -n "loadTypeIsolated\b" /work/compiler/src/Compiler/MonoSolver/Store.elm | head -2            # exported at :4, defined :252
  ```
- If step 9 landed a fused ground/arrow-free `Can.Type` predicate in `Translate.elm`, reuse it for
  D10's Let arm instead of adding `canTypeGroundNoArrow` (grep `groundNoArrow` in `Translate.elm`;
  on the base tree it does not exist — `grep -rn "groundNoArrow" MonoSolver/` is empty).
- Sizing census (untimed, on the candidate, `ECO_MONO_LSS_REPORT=1`): D1 adds two constant
  `argFlowCensus` keys (`callee|inert`, `callee|instantiated`); read them off the `argflow:` block
  of the LSS report. Expect the inert class to be the majority of global calls.

#### 3. Inventory of touched code

| file | function (lines) | what changes |
|---|---|---|
| LI | `instantiateWithSignature` 127-144 | split into `instantiateWithSig g sig funcCanType` (takes the already-fetched signature; D8: `if sig.trivial then Store.loadTypeIsolated .. else loadTypeIsolatedWithArrows .. + applyFacts`) and a thin `instantiateWithSignature` = `signatureFor` ⟫ `instantiateWithSig` (kept exported: called by `TR:5228 instantiateLss`) |
| LI | `applyCalleeAt` 1733-1771, non-in-progress arm 1760-1771 | D1: force `signatureFor` FIRST (same point as today), then the inert predicate → `Ok ( WpNone, census )`; else `instantiateWithSig` → `unifyCallShape` → `injectPapMemberInfer` as today. In-progress arm 1742-1758 UNCHANGED |
| LI | `walkExpr` Call arm 1248-1259 | D2: `walkChildren letEnv (func :: args)` (1254) → `walkCalleeOccurrence letEnv func` then `walkChildren letEnv args` |
| LI | new `walkCalleeOccurrence`, `mintCalleeIds` (after `walkCall`, ~1731) | D2-16a: named callees replay ONLY the member-id mints of `standaloneMemberWith` (2497-2521) / `withPapSuccessors` (2527-2544) / `injectPapSuccessors` (2622-2645) in the same order; every other callee shape → `walkExpr` as before. 16b: named arms → no-op |
| LI | `degradeToSymmetric` 3092-3107 | D4: `if s0.env.lss.report then <today> else joinArrowSets onPoison src dst s0` |
| LI | `storeMentionsArrow`/`storeMentionsArrowGo` 3113-3163 | unchanged (now report-only) |
| LI | `walkExpr` Let/Def arm 1332-1353 | D10: `if canTypeGroundNoArrow defType then walk rhs; walk body with name REMOVED from letEnv else <today>` |
| LI | `walkExpr` TailDef arm 1355-1391 | unchanged (a TailDef type is a function type; `bindParamsFromSpine` needs the load) |
| LI | `walkLiteral` 1516-1587 | D10: arrow-free literal → walk base + elems in today's order, return `WpNone`, keep the `litFacts|` census (string built under `report` only) |
| LI | Tuple/List arms 1441-1445, `walkKeyed` 1615-1627, `joinLiteralElems` 1645-1666 | D10(c) optional: stop allocating `( String.fromInt i, e )` / `( "l", e )` pairs — carry `List Expr` + record field names only |
| LI | new `canTypeGroundNoArrow` (next to `canTypeMentionsArrow` 3281-3306) | D10's Let predicate |
| LI | `joinLetUse` 2860-2889 | D12: test `canTypeMentionsArrow meta.tipe` BEFORE `CoreDict.get name letEnv` |
| ST | `loadTypeIsolated` 252-259 | no change (already exported, ST:4); D8 calls it |
| TR | `instantiateLss` 5225-5231 | no change; it benefits from D8 via `LssInfer.instantiateWithSignature` |

Call sites (grep, base tree): `instantiateWithSignature` — LI:1761 (applyCalleeAt), TR:5228
(instantiateLss); `walkChildren` — LI:1254 (Call), 1426 (TailCall), 1454 (structural wildcard),
1519 (walkLiteral lss-off); `degradeToSymmetric` — LI:3056, 3059, 3062 (the three container arms
of `flowArrowSets`); `storeMentionsArrow` — LI:3094 only; `walkLiteral` — LI:1436, 1439, 1442,
1445, 1448; `joinLetUse` — LI:1327, 1330; `loadTypeIsolatedWithArrows` — LI:134 only;
`Store.loadTypeIsolated` — LI:2130 (kernel TransportsAs arm), TR:5217 (`instantiate`).
No unit test names `applyCalleeAt`, `instantiateWithSignature`, `storeMentionsArrow`,
`walkLiteral` or `joinLetUse` (grep of `tests/TestLogic` is empty for all five); the walk is
pinned behaviourally by `LssSigFlowTest`, `LssDirectedFlowTest`, `LssAccessAndLitFactsTest`,
`LssHonestSourcesTest`/`LssHonestSourcesPipelineTest`, `ArrowIdentityTest` (pins `slotsMinted`
through `LoadCtx` directly — unaffected), `KernelLicenseTest`, `MuTieTest`.

#### 4. Design

**Common facts the soundness arguments rest on** (all from the code):

- A set slot exists ONLY as the third field of a `Vars.FunL` node (LSS_007); it is minted in
  `loadTypeC`'s `TLambda` arm (ST:268-380) and NOWHERE else on the inference side. A type with no
  `TLambda` (aliases chased — `canTypeMentionsArrow` LI:3281-3306 chases `Filled` and `Holey`)
  loads to a structure with zero slots. Loading it mints Points but cannot mint a slot.
- `joinArrowSets` (LI:2907-2987) and `flowArrowSets` (LI:3017-3084) write a slot only in their
  `FunL × FunL` arms; on any other pair they recurse structurally, and on a variable or shape
  mismatch call `poisonBoth` (LI:3222-3240) → `Store.poisonArrowSets` (ST:2136-2141), whose
  `poisonGoC` writes only at `FunL` nodes. So a join between two arrow-free structures writes
  NOTHING; its only side effects are `S` copies and the report-gated `onPoison` bump
  (`bumpWidenedByCf` EN:975-988).
- `WalkPoint` consumers (LI:1216-1236 and every `wpPoint` site: `walkMembers` 695,
  `walkFunction` 1491, Let 1348, TailDef 1381, `joinLiteralBase` 1632, `joinKeyedSlots` 1676,
  `joinCfHub` 3373/3379) either JOIN the point (above: slot-free on arrow-free types) or test
  honesty. `hubHonest` (LI:3395-3408) is `False` for both `WpNone` and `WpOpaque`; `joinCfHub`
  is guarded on the HUB type (3364), and a hub's branches have the hub's type, so an arrow-free
  branch never reaches the honesty test. `elemHonest` (1553-1554) accepts an arrow-free element
  regardless of its class. Hence `WpNone` and `WpOpaque p` are interchangeable when `p`'s type is
  arrow-free.
- The scratch store dies with the unit (`withScratchStore` EN:2033-2100 restores
  `store/memo/revMemo` from `s0`); only `LssSignature` (member ids, top, sources — EN:107-139)
  survives, and it is built from the SIGNATURE slots by `zonkSigGo`. Point INDICES never leave the
  scratch store (they appear only in the report-gated `arrowOfSlot`/`qLog`/`zonkLog`). So an
  operation that mints Points but never connects a set slot to a signature slot is invisible to the
  artifact.

##### D1 — inert-callee instantiation skip (`applyCalleeAt`, non-in-progress arm only)

Predicate, evaluated AFTER `signatureFor` has been forced (memo/mint order must not move):

```elm
calleeInert : Engine.LssSignature -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> Bool
calleeInert sig args meta =
    sig.trivial
        && not (canTypeMentionsArrow meta.tipe)
        && List.all (\a -> not (canTypeMentionsArrow (TOpt.typeOf a))) args
```

New arm (replaces LI:1760-1771):

```elm
    else
        case signatureFor g s0 of
            Err e ->
                Err e

            Ok ( sig, s1 ) ->
                if calleeInert sig args meta then
                    -- The `Inert` kernel precedent (kernelCallBoundary LI:2112-2124): nothing
                    -- below could write or connect a set slot, so the whole isolated
                    -- instantiation + per-arg unify is a fixed cost buying nothing.
                    Ok ( WpNone, Engine.bumpArgFlowCensus "callee|inert" s1 )

                else
                    case instantiateWithSig g sig srcType (Engine.bumpArgFlowCensus "callee|instantiated" s1) of
                        Err e ->
                            Err e

                        Ok ( funcVar, s2 ) ->
                            case unifyCallShape funcVar args meta s2 of
                                Err e ->
                                    Err e

                                Ok ( callVar, s3 ) ->
                                    injectPapMemberInfer g (List.length args) callVar s3
```

Soundness — what the skipped code could have written, and why it is unreachable:

1. `loadTypeIsolatedWithArrows srcType` (ST:235-242) mints the callee's annotation structure with
   an EMPTY arrow memo that is never written back (LSS_027 (f)). Its Points are referenced only by
   `funcVar` and `slots`. `applyFacts` (LI:245) returns immediately for a trivial signature, so
   no fact, no `addSlotSource`, no `unifySlotWithSet` is applied to those slots.
2. `unifyParamsBestEffort` (LI:1927-1957) peels one arrow of the isolated structure per argument
   and unifies `pParam` with `Store.loadType (typeOf arg)` (SHARED memo). With every argument
   arrow-free, `argVar` has no slot; `pParam` is the isolated instantiation of the callee's
   parameter type — in well-typed code the solver already made the argument's solved type an
   instance of it, so the unify only merges structurally-equal ground nodes and variable Points.
   No `FunL × FunL` arm runs (that needs an arrow on the ARGUMENT side, which the predicate
   excludes; a bare `TVar` argument cannot unify with an isolated arrow in well-typed code because
   the solved argument type would then be that arrow, not a `TVar`). The merged variable classes
   can acquire a `FlexSuper` from the isolated side (`loadVarC` seeds supers from `superStatic`
   by MVarId) — a scratch-store fact that `zonkSigGo` never reads (it reads set slots) and that
   `harvestSuperTable` never sees (it runs at `finishNode` on the ITEM store; the scratch
   `revMemo` is dropped by `withScratchStore`).
3. `Store.loadType meta.tipe` + `unifyBestEffort restVar callVar`: `callVar` is arrow-free
   (predicate), `restVar` is the isolated residual = the callee's result type instance; same
   argument as 2 — no `FunL` pair, no slot.
4. `injectPapMemberInfer` (LI:1797-1825): with an arrow-free CALL type, a partial application
   is impossible (its residual type is an arrow), so either `declaredArityOf g <= argCount`
   (returns `WpOpaque callVar`, no write) or — for a `weird : Int -> a` shape where the declared
   arity exceeds the supplied count and the result is a `TVar` — `injectSpineMemberId 1` on a
   `FlexVar` content hits `spineGoC`'s non-arrow arm (LI:2854-2857) and writes nothing, and
   `injectPapSuccessorsFrom` likewise. The `p|g|n` mint it would perform DOES matter for id
   order — but `papMemberIdFor` is reached only when `declaredArityOf g 8 s0 > argCount`; for the
   inert class that happens only in the `TVar`-result shape. To keep 16a strictly BI, replay that
   mint: in the inert arm, `if declaredArityOf g 8 s1 > List.length args then Engine.papMemberIdFor g (List.length args) s1 |> ignore` before returning `WpNone`. (This is one HashMap probe — the same one today's path performs at LI:1802 — so it costs nothing extra.)
5. The returned class changes from `WpOpaque callVar` to `WpNone`: interchangeable for an
   arrow-free type (common facts, bullet 3).

Census consequences (report-only, expected, NOT precision): `set-writes: slotsMinted=` falls
(the isolated load's `writeBackIsolated` ST:178-200 no longer adds `c.slotsMinted`);
`sigflow: widenedByCf=` can fall (today's arrow-free `WpOpaque` joins hit `poisonBoth` on
variable leaves and bump it — no slot is involved); under `ECO_MONO_LSS_ARROW_CENSUS=1`,
`apply|attempt/noSlot/noArrowId/hit` fall (`noteApplied` LI:1870-1916 is inside the skipped
`unifyParamsBestEffort`). Two new keys `callee|inert` / `callee|instantiated` appear.

Do NOT apply the predicate in the in-progress arm (LI:1742-1758): there `Store.loadType srcType`
goes through the SHARED memo, so the loaded Points ARE the unit's signature slots and binding a
sibling annotation variable is observable (the Σ rule).

##### D8 — trivial-signature ordinal array

```elm
instantiateWithSignature : TOpt.Global -> Can.Type TypeIds.MVarId -> Step Vars.Variable
instantiateWithSignature global funcCanType s0 =
    case signatureFor global s0 of
        Err e ->
            Err e

        Ok ( sig, s1 ) ->
            instantiateWithSig global sig funcCanType s1


instantiateWithSig : TOpt.Global -> Engine.LssSignature -> Can.Type TypeIds.MVarId -> Step Vars.Variable
instantiateWithSig global sig funcCanType s1 =
    if sig.trivial then
        -- D8: the ordinal array feeds only `applyFacts`, which returns at once for a
        -- trivial signature (LI:245). Same `loadTypeC` call, same `isolatedLoadCtx`, same
        -- `writeBackIsolated` — only the `Array.fromList (List.reverse arrowSlots)` is gone.
        Store.loadTypeIsolated funcCanType s1

    else
        case Store.loadTypeIsolatedWithArrows funcCanType s1 of
            Err e ->
                Err e

            Ok ( ( funcVar, slots ), s2 ) ->
                case applyFacts global sig slots funcVar s2 of
                    Err e ->
                        Err e

                    Ok ( _, s3 ) ->
                        Ok ( funcVar, s3 )
```

BI: `loadTypeIsolated` (ST:252-259) and `loadTypeIsolatedWithArrows` (ST:235-242) run the
identical `loadTypeC superStatic canType (isolatedLoadCtx s)` and `writeBackIsolated c s`; the
`arrowSlots` list is still accumulated inside `LoadCtx` (the hit/miss contract at ST:292-305 is
about the ctx, untouched) — only the array materialisation is elided. Applies to both callers
(inference `applyCalleeAt`, translation `instantiateLss` TR:5225-5231 → per translated global
call, the majority class per the file's own comments).

##### D2 — callee child re-walk (`Call` arm)

Today (LI:1248-1259): `walkCall` handles the call, then `walkChildren letEnv (func :: args)`
walks the CALLEE as a value. For `VarGlobal`/`VarCycle`/`VarEnum`/`VarBox`/`VarKernel`/
`Accessor` that is `standaloneMemberWith` (LI:2497-2521): `if canTypeIsArrow meta.tipe then
mint; Store.loadType meta.tipe; injectSpineMemberId 1 mid funcVar; WpHonest funcVar`, and for
the four `Global`-keyed arms `withPapSuccessors` (2527-2544) then runs `injectPapSuccessors g
funcVar` (2622-2645): `declaredArityOf`; `arity <= 1` → census; else `mintPapSuccessorIds g 1
arity` (2678-2689, depths 1..arity-1 in order) then one `foldSetWrites (papSuccGoC ..)` pass.
`VarDebug` has no children (LI:3517) → nothing.

What the store writes could have reached:

- The occurrence's HEAD `FunL` node is minted fresh by `loadTypeC` (LSS_027 (e): nodes are never
  memoised, only slots). Its slot is keyed by the occurrence's `ArrowId`. The head arrow of a
  callee occurrence is the solver variable the typechecker created for THIS `Call` constraint
  (`funcVar = arg1 -> … -> result`); no other AST node carries that variable, so no other
  `Can.Type` in the def carries that `ArrowId`, so no other load can hit that slot in
  `arrowMemo`. The node itself is referenced only by the `WpHonest funcVar` that `walkChildren`
  discards (LI:3477 ignores the point). Nothing UF-reachable from any signature slot or from any
  point handed upward points at it → the `g|`/`c|`/`k|`/`a|` head write is dead. This holds in
  the in-progress arm too: `applyCalleeAt`'s shared load there is of `srcType` = the ANNOTATION
  (different type object, different `ArrowId`s), and even in the unannotated fallback
  (`srcType == funcMeta.tipe`, same `ArrowId`) `unifyParamsBestEffort` peels the arrow
  (`arrowParts` → param/rest) and never unifies the `FunL` node, so the slot stays orphan.
- Successor slots at depth `d ≥ 1` of the occurrence spine: for a SATURATED call every inner
  arrow of the occurrence's instantiated type is likewise private to the constraint (orphan). For
  a PARTIAL application the residual arrow at depth `argCount` IS the `Call` node's type variable
  (solver-unified), so under `arrowSolverRoots` (unconditional since LSS_041; ST:334-337) they
  share one `ArrowId` and the slot IS shared — and there `injectPapMemberInfer` (LI:1797-1825)
  writes the identical `p|g|argCount` into `callVar`'s head and `injectPapSuccessorsFrom g
  (argCount+1)` the identical `p|g|d` below it. This is precisely the `skip=61,453` class of the
  set-write census (a write of a member already present). Depths `1 .. argCount-1` are orphan as
  above. So the child walk's successor writes are either orphan or exact duplicates.
- `VarLocal`/`TrackedVarLocal` callees are NOT covered: `joinLetUse` (LI:2860-2889) at a callee
  occurrence performs the SYMMETRIC union-over-uses join with the family Point — see answer Q-b.
  Keep walking them.

16a (order-preserving) — replay the MINTS, drop the load and both set-write passes:

```elm
        TOpt.Call _ func args meta ->
            case walkCall letEnv func args meta s0 of
                Err e ->
                    Err e

                Ok ( wp, s1 ) ->
                    case walkCalleeOccurrence letEnv func s1 of
                        Err e ->
                            Err e

                        Ok ( (), s2 ) ->
                            case walkChildren letEnv args s2 of
                                Err e ->
                                    Err e

                                Ok ( _, s3 ) ->
                                    Ok ( wp, s3 )
```

```elm
{-| D2 (step 16a): the callee child of a `Call`. A NAMED callee's standalone walk writes only
into slots that are orphan in the scratch store or duplicates of `injectPapMemberInfer`'s, so
the store work is dead; the MEMBER-ID MINTS are replayed in exactly the order
`standaloneMemberWith` → `injectPapSuccessors` performs them, because `nextMemberId` is a
shared supply whose first-seen order is observable (LSS_003 / plan §6). Everything else is
walked as before.
-}
walkCalleeOccurrence : LetEnv -> TOpt.Expr TypeIds.MVarId -> Step ()
walkCalleeOccurrence letEnv func s0 =
    case func of
        TOpt.VarGlobal _ g meta ->
            case kernelAliasOf g s0 of
                Just ( kernelPrefix, home, name ) ->
                    mintCalleeIds (Engine.kernelMemberIdFor ("k|" ++ home ++ "." ++ name) ( kernelPrefix, home, name )) (Just g) meta s0

                Nothing ->
                    mintCalleeIds (Engine.standaloneMemberIdFor ("g|" ++ TOpt.toComparableGlobal g) g) (Just g) meta s0

        TOpt.VarCycle _ home name meta ->
            let
                g =
                    TOpt.Global home name
            in
            mintCalleeIds (Engine.standaloneMemberIdFor ("g|" ++ TOpt.toComparableGlobal g) g) (Just g) meta s0

        TOpt.VarEnum _ g _ meta ->
            mintCalleeIds (Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g) (Just g) meta s0

        TOpt.VarBox _ g meta ->
            mintCalleeIds (Engine.standaloneMemberIdFor ("c|" ++ TOpt.toComparableGlobal g) g) (Just g) meta s0

        TOpt.VarKernel _ kernelPrefix home name meta ->
            -- Head-only at LI:1316-1320: no successor walk.
            mintCalleeIds (Engine.kernelMemberIdFor ("k|" ++ home ++ "." ++ name) ( kernelPrefix, home, name )) Nothing meta s0

        TOpt.Accessor _ field meta ->
            mintCalleeIds (Engine.memberIdFor ("a|" ++ field)) Nothing meta s0

        TOpt.VarDebug _ _ _ _ _ ->
            -- Today: `directChildren` = [] → nothing.
            Ok ( (), s0 )

        _ ->
            -- Nested call, lambda, `Access`, VarLocal/TrackedVarLocal, …: the value walk is
            -- load-bearing (joinLetUse's symmetric use-join, lambda member injection).
            case walkExpr letEnv func s0 of
                Err e ->
                    Err e

                Ok ( _, s1 ) ->
                    Ok ( (), s1 )


{-| The mint half of `standaloneMemberWith` + `injectPapSuccessors`, verbatim in order:
head mint only when the occurrence type IS an arrow (`canTypeIsArrow`, LI:2499), then — for
the `Global`-keyed arms — `p|g|d` for d in 1..arity-1 (LI:2638), with the same report-gated
census keys so the `argflow:` block is unchanged.
-}
mintCalleeIds : Step Int -> Maybe TOpt.Global -> TOpt.Meta TypeIds.MVarId -> Step ()
mintCalleeIds mint maybeSuccGlobal meta s0 =
    if canTypeIsArrow meta.tipe then
        case mint s0 of
            Err e ->
                Err e

            Ok ( _, s1 ) ->
                case maybeSuccGlobal of
                    Nothing ->
                        Ok ( (), s1 )

                    Just g ->
                        let
                            arity =
                                declaredArityOf g 8 s1
                        in
                        if arity <= 1 then
                            Ok ( (), Engine.bumpArgFlowCensus "refspine|arity1" s1 )

                        else
                            case mintPapSuccessorIds g 1 arity [] s1 of
                                Err e ->
                                    Err e

                                Ok ( _, s2 ) ->
                                    Ok ( (), Engine.bumpArgFlowCensus "refspine|inject" s2 )

    else
        Ok ( (), s0 )
```

Order constraints, stated explicitly: (i) `walkCall` before the callee mints before the args —
identical to today's `walkCall` then `walkChildren (func :: args)`; (ii) inside a named callee:
head mint, then successor mints depth 1,2,…,arity-1 — identical to `standaloneMemberWith`
(mint at 2500 precedes the load) then `injectPapSuccessors` (`mintPapSuccessorIds g 1 arity`,
ascending). Interning is idempotent (`internMemberKey` EN:1760: hit returns the existing id;
`standaloneMemberIdFor`/`kernelMemberIdFor`/`papMemberIdFor` guard their `sources` inserts on
membership), so replaying the mint and skipping the write reproduces `nextMemberId`, `byKey`,
`sources` and `provisionalStandalone` byte-for-byte.

Census consequences (report-only): the `set-writes:` line moves (`skip`, `flex`, `union` fall —
the dead `foldSetWrites` passes no longer fold their counters, EN/ST:1224-1260); `slotsMinted`
falls (the occurrence load's slot); `argflow:` keys unchanged (replayed). `sigflow: edges=`
unchanged (no `addSlotSource` on this path).

16b (NOT BI — separate loop entry, gate = bootstrap turn B==C + rail): replace the six named
arms' bodies with `Ok ( (), s0 )`. What moves: every `g|`/`c|`/`k|`/`p|` key whose FIRST
occurrence in walk order is a callee position is interned later (at its first value occurrence,
or by `Translate.injectPapMember`/`varsucc` for `p|`, or never). Every id minted after that point
on the shared supply shifts. Where member-id VALUES are observable (answer Q-c): not in MLIR text
(no `Generate/` reader; `AbiCloning` uses them as `Dict Int` keys and in equality-only
fingerprints, `AbiCloning.elm:675/2086/3302`), but the settle chain iterates `Dict Int`s keyed by
member id and its read/write order is precision-bearing (plan §4 N1, step 24 `midKeys`), and
set members sort by id so `LSet` member order — though equality-preserving under relabelling —
changes the `toComparableMonoType` strings. Expect `out.mlir` to differ on the first bootstrap
turn and converge on the second; the rail's census artefact must show only id-relabelling
(`var`/`k1`/`kN`/`⊤` coverage lines identical). Value after step 13 (Int member keys) is small
— the surviving cost of 16a's replay is ~1 + (arity−1) string builds + `Dict String` probes per
named callee occurrence per BODY (not per spec). Recommendation: ship 16a; put 16b at the end of
the series or drop it once step 13 lands.

##### D4 — `storeMentionsArrow` gating

```elm
degradeToSymmetric : (Engine.S -> Engine.S) -> Vars.Variable -> Vars.Variable -> Step ()
degradeToSymmetric onPoison src dst s0 =
    if s0.env.lss.report then
        -- Census: `flowDegraded` counts only degrades whose src can CARRY a set
        -- (EN:1029-1045). The store DFS exists solely for that counter.
        case storeMentionsArrow src s0 of
            Err e ->
                Err e

            Ok ( carries, s1 ) ->
                joinArrowSets onPoison src dst (if carries then Engine.bumpFlowDegraded s1 else s1)

    else
        joinArrowSets onPoison src dst s0
```

Soundness: `storeMentionsArrow` is read-only apart from path-compression `UF.get`s (which
`joinArrowSets` performs anyway on the same nodes); its result feeds only `bumpFlowDegraded`,
whose sole reader is the `sigflow:` report line (`Monomorphize.elm:3751`). BI and CENSUS-identical
(report-on keeps today's path). Callers: the three container arms LI:3055-3062 only.

##### D10 — arrow-free Let loads and literal loads

Let/Def arm (LI:1332-1353). Predicate must be GROUND and arrow-free, not merely arrow-free: a
generalised let (`let xs = [] in …` : `List a`) can be USED at `List (Int -> Int)`, and today
that use loads the arrow-bearing occurrence type and `joinArrowSets rhsVar useVar` hits
`(var, FunL)` → `poisonBoth` → a real ⊤ write on the use's slot that flows to hubs/roots and into
signature facts (`top=True`). Skipping the env entry would delete that poison — a precision
change (more precise, still sound by LSS_005, but NOT BI). With a ground type no instantiation is
possible, every occurrence is arrow-free, and `joinLetUse`'s guard (LI:2867) fires on every
read — the entry is provably never consumed.

```elm
{-| No `TLambda` and no `TVar` anywhere (record extension counts as a var; alias args and Holey
bodies both checked). Such a type has exactly one instance, so every occurrence of a name bound
at it is arrow-free and `joinLetUse` (LI:2867) never reads its letEnv entry.
-}
canTypeGroundNoArrow : Can.Type TypeIds.MVarId -> Bool
canTypeGroundNoArrow t =
    case t of
        Can.TLambda _ _ _ ->
            False

        Can.TVar _ ->
            False

        Can.TType _ _ typeArgs ->
            List.all canTypeGroundNoArrow typeArgs

        Can.TRecord fields ext ->
            case ext of
                Just _ ->
                    False

                Nothing ->
                    CoreDict.foldl (\_ (Can.FieldType _ ft) acc -> acc && canTypeGroundNoArrow ft) True fields

        Can.TUnit ->
            True

        Can.TTuple a b rest ->
            canTypeGroundNoArrow a && canTypeGroundNoArrow b && List.all canTypeGroundNoArrow rest

        Can.TAlias _ _ aliasArgs (Can.Filled real) ->
            canTypeGroundNoArrow real

        Can.TAlias _ _ aliasArgs (Can.Holey real) ->
            canTypeGroundNoArrow real && List.all (\( _, at ) -> canTypeGroundNoArrow at) aliasArgs
```

```elm
                TOpt.Def _ name rhs defType ->
                    if canTypeGroundNoArrow defType then
                        -- D10: no load, no join, and the name is REMOVED (not left) so a
                        -- shadowed outer arrow-typed binding of the same name cannot be
                        -- found by an inner occurrence.
                        case walkExpr letEnv rhs s0 of
                            Err e ->
                                Err e

                            Ok ( _, s1 ) ->
                                walkExpr (CoreDict.remove name letEnv) body s1

                    else
                        <today, LI:1335-1353 verbatim>
```

Why `remove`, not "leave as is": with `let f = \x -> x in let f = 3 in …`, leaving `letEnv`
untouched would map the inner `f` to the OUTER lambda's Point; an inner occurrence is arrow-free
(ground type) so the guard fires anyway — but `remove` makes the invariant "an entry is present
iff today's code inserted it or the name is arrow-capable" true by construction and costs one
Dict op per ground let. `localCalleeJoin` (LI:1969) cannot see a ground-typed name as a callee
(a callee has an arrow type). What the skipped load minted: Points for a ground structure (no
slot); what the skipped `sigFlowJoinInto rhsVar (wpPoint rhsWp)` (LI:1348) could write: nothing
(ground × anything → structural recursion to leaves; a variable leaf on the RHS side meets a
ground leaf → `poisonBoth` on slot-free structure → census bump only). Census: `widenedByCf` may
fall (report-only).

TailDef arm (LI:1355-1391): unchanged.

`walkLiteral` (LI:1516-1587): arrow-free literal (predicate `canTypeMentionsArrow meta.tipe`
false — arrow-free suffices here because a literal's type is the solved type AT that occurrence,
never generalised; every join partner has the same solved type, so a variable leaf meets a
variable leaf and no slot exists on either side):

```elm
    else if not (canTypeMentionsArrow meta.tipe) then
        -- D10: the literal cannot carry a set. Walk base then elems in today's order
        -- (member mints inside them are unchanged); no load, no joins; `WpNone`.
        case walkMaybe letEnv maybeBase s0 of
            Err e ->
                Err e

            Ok ( baseWp, s1 ) ->
                case walkChildren letEnv (List.map Tuple.second elems) s1 of
                    Err e ->
                        Err e

                    Ok ( _, s2 ) ->
                        let
                            -- Same honesty the full path computes: every element is
                            -- arrow-free (elemHonest = True), so honest = baseHonest.
                            baseHonest =
                                case ( maybeBase, baseWp ) of
                                    ( Just _, Just wp ) ->
                                        isHonest wp

                                    ( Just _, Nothing ) ->
                                        False

                                    ( Nothing, _ ) ->
                                        True
                        in
                        Ok
                            ( WpNone
                            , if s2.env.lss.report then
                                Engine.bumpArgFlowCensus ("litFacts|" ++ form ++ (if baseHonest then "|honest" else "|opaque")) s2

                              else
                                s2
                            )

    else
        <today, LI:1527-1587 verbatim, with the census concat also moved under `report`>
```

`WpNone` vs today's `WpHonest litVar`/`WpOpaque litVar` for an arrow-free literal: interchangeable
(common facts bullet 3: `elemHonest` of a parent literal accepts arrow-free elements regardless;
`baseHonest` of a parent update sees the base only when the parent's type — which equals the
base's — mentions an arrow, i.e. never on this path; hub guard on the hub type; single-source
joins slot-free). The `litFacts|` census counts are preserved exactly (an arrow-free
base/elem literal is `honest` today iff `baseHonest`).

D10(c), optional, BI: `walkLiteral`'s `elems : List ( String, Expr )` exists only so
`joinLiteralElems`'s record arm can `CoreDict.get k fields`; the tuple arm allocates
`String.fromInt i` and the list arm `( "l", e )` per element (LI:1442, 1445) which
`joinLiteralElems` then ignores (1660, 1663). Change `walkLiteral` to take `elems : List Expr`
and `fieldNames : List Name` (`[]` for tuple/list/update-less), `walkKeyed` → `walkCollect`
(already exists, LI:3447 — note it returns wps REVERSED; use `List.reverse` or add an
order-preserving variant), and `joinLiteralElems form litVar fieldNames wps` zipping names only
in the record arm. Mint order unchanged (elements walked in the same order).

##### D12 — `joinLetUse` guard order

```elm
joinLetUse letEnv name meta s0 =
    if not (canTypeMentionsArrow meta.tipe) then
        Ok ( WpNone, s0 )

    else
        case CoreDict.get name letEnv of
            Nothing ->
                Ok ( WpNone, s0 )

            Just rhsVar ->
                <today's else branch, LI:2876-2889>
```

Pure reordering of two pure tests; BI. (`canTypeMentionsArrow` on a `TType Int []` is one
pattern match + `List.any` on `[]`.)

##### Answers to findings-D's open questions, from the code

- **Q-a (is `withScratchStore` re-entrant?)** Structurally yes: EN:2033-2100 captures
  `s0.store/memo/revMemo/itemAux`, installs a fresh store with `clearedAux` (clears the
  store-scoped `arrowMemo`, `arrowOfSlot`, `zonkLog`, `qLog`, `qSigRoot`, residual-read lists),
  runs the step, and restores exactly those four fields from `s0` via `restoredAux` (which also
  restores `currentLocalInstance`/`retranslating` from the OUTER side); every run-global field
  (`lssSignatures`, `lssInProgress`, `lssMemberTable`, `nextMemberId`, `lssStats`, `intern`,
  `nextMVarId`, registry) threads through. A nested call would save and restore the OUTER scratch
  state the same way. The rule "scratch stores never nest" (LI:375-376) exists to keep the
  `signatureFor` re-entry crash (LI:76-78, 94-95) unreachable: pre-resolution guarantees that no
  `signatureFor` runs while a unit is in flight. A lazy `signatureFor` inside `applyCalleeAt`
  would NOT trip that crash either — an in-flight callee takes the `lssInProgress` arm (LI:1742)
  before `signatureFor` is reached, and SCCs are module-local so an outside callee cannot reference
  an in-flight member — but it would interleave callee units INSIDE the caller's walk and thereby
  change member-id interning order (same class as 16b). So D9's re-entrant variant (ii) is
  sound but not BI; variant (i) (AssignMVarIds records referenced globals per node) is the BI
  route. Neither is part of step 16.
- **Q-b (symmetric `joinLetUse` at a local-callee occurrence — intentional?)** Yes, by the
  record: invariant LSS_023 lists the flipped sites (hub, local-callee arg/result, tunnels) and
  then "Kept symmetric: … joinLetUse (union-over-uses stays the let channel's v1 policy)", and
  `joinArrowSets`'s doc (LI:2892-2898) states the policy ("All uses of a let-bound function
  thereby share one set (union over uses — sound; per-use separation is the vNext upgrade"). At a
  callee occurrence the walk runs `localCalleeJoin`'s directed edges (LI:1967-2003) and THEN, via
  the `func` child, `joinLetUse`'s symmetric join, which subsumes them — that is the documented
  v1 behaviour, not an accident. Consequently D2 must keep walking `VarLocal`/`TrackedVarLocal`
  callees: skipping them would delete the union-over-uses at every local call site = a precision
  change. (Whether removing it would be a WIN is a separate analysis experiment with the
  analysis-step gate; it is not an optimisation.)
- **Q-c (does member-id interning order reach `out.mlir`?)** Ids are not printed into MLIR
  (no reader under `Generate/`), but they are observable through iteration order of `Dict Int`
  tables keyed by member id in the settle chain (order-bearing reads, plan §4 N1) and through the
  ascending sort of `LSet` members inside `toComparableMonoType` keys. Plan §6 already files
  "13/D2" under "analysis-order items … need the bootstrap 8c fixed point". So: 16a preserves
  order (BI); 16b does not (bootstrap turn + rail).
- **Q-d (does anything match `Vars.Chain`?)** `grep -rn "Chain\b" MonoSolver/ Monomorphize/`
  finds only `Zonk.lambdaChain`, `Closure.collectLetChain` and `Mono.Chain` (the decider); no
  MonoSolver/Monomorphize code pattern-matches `Vars.Chain`, so a non-compressing `UF.peekS` is
  safe for read-only sites (step 8's business; recorded here because the brief asked).

#### 5. Edit sequence (each leaves `elm make` green)

1. **D8**: split `instantiateWithSignature` into `instantiateWithSignature` + `instantiateWithSig`
   (LI:127-144). Type-check: `cd /work/compiler && elm make src/Terminal/Main.elm --output=/dev/null`
   (or the 1-second check the loop names). Byte-identical by construction; can be measured alone.
2. **D1**: rewrite the non-in-progress arm of `applyCalleeAt` (LI:1760-1771) with `calleeInert`
   and the `p|` mint replay from §4 D1 item 4; add the two census keys.
3. **D4**: rewrite `degradeToSymmetric` (LI:3092-3107).
4. **D12**: reorder `joinLetUse` (LI:2860-2889).
5. **D10 (Let)**: add `canTypeGroundNoArrow` after `canTypeMentionsArrow` (LI:3306); rewrite the
   `TOpt.Def` sub-arm (LI:1334-1353).
6. **D10 (literal)**: insert the arrow-free branch into `walkLiteral` after the lss-off branch
   (LI:1524); move the eager `"litFacts|" ++ …` concat of the full path (LI:1576-1586) under
   `if s5.env.lss.report`.
7. **D2-16a**: add `walkCalleeOccurrence` and `mintCalleeIds` after `walkCall` (LI:1730); change
   the `Call` arm (LI:1248-1259).
8. (Optional, same entry) **D10(c)** — the `walkLiteral` element-list refactor.
9. Snapshot: `benchmarks/lss-loop-snap.sh snap try-16 "step 16: inference walk skip set-inert work"`.
10. **16b** (separate entry `try-16b`, only if pursued): named arms of `walkCalleeOccurrence` →
    `Ok ( (), s0 )`; delete `mintCalleeIds`.

No test pin needs updating for 16a: the tests named in §3 assert set contents/coverage, not
`slotsMinted`/`set-writes`/`widenedByCf` values (`ArrowIdentityTest` reads `LoadCtx.slotsMinted`
through `Store.testLoadCtx` directly, untouched).

#### 6. Verification

- Unit: `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt` — expect the
  12-failure pre-existing baseline exactly (`grep -c "✗\|FAIL" /tmp/test_output.txt`), and the
  named suites green: `LssSigFlowTest`, `LssDirectedFlowTest`, `LssAccessAndLitFactsTest`,
  `LssHonestSourcesTest`, `LssHonestSourcesPipelineTest`, `ArrowIdentityTest`,
  `KernelLicenseTest`, `MuTieTest`, `PostSettleDevirtTest`.
- E2E: `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt` at the 893/895 (or
  current) baseline.
- Byte-identity (Phase 2 of the loop): three cold runs, `cmp` the three `-out.mlir` and
  `cmp bin/eco-opt16-r1-out.mlir bin/eco16.mlir` — must be identical for 16a.
- Rail: `benchmarks/mlir-workload-rail.sh` — `EMISSION: 0 workloads differ`. The CENSUS diff will
  be NON-ZERO and must be attributed line by line; the ONLY fields allowed to move are
  `set-writes: skip= flex= union= slotsMinted=`, `sigflow: widenedByCf=`, and the `argflow:`
  block's `callee|inert`/`callee|instantiated` (new) and `apply|*` (only under the arrow census).
  Any change to the `var`/`k1`/`kN`/`⊤` coverage lines, `sigflow: edges=`/`degraded=`, or
  `litFacts|*`/`refspine|*` counts is a defect.
- Loop triple: §2 of `benchmarks/lss-compile-opt-loop.md` with `ARM=eco-opt16`; judge minor GC
  first (deterministic), then wall.
- Attribution leg (untimed, `ECO_MONO_LSS_REPORT=1`, same command as Phase 1.3 with the
  candidate): read `callee|inert` vs `callee|instantiated` and the `slotsMinted` delta vs the
  reference's report; if `callee|inert` is not the majority the D1 win is capped and the plan
  entry should say so.

#### 7. Risks, gotchas, what NOT to do

- **Never move `signatureFor` later or skip it** in the D1 arm: it forces callee units and the
  interning inside them; its position is the mint-order anchor. Force it, THEN test the predicate.
- **Do not apply D1 to the in-progress arm** (LI:1742-1758) — shared-memo loads there are the
  signature slots (Σ rule).
- **D1's `p|` replay** (`declaredArityOf g > argCount` → `papMemberIdFor`) is what keeps the
  `TVar`-result shape BI; omitting it is a 16b-class order change.
- **D10 Let must use the GROUND predicate**, not `canTypeMentionsArrow`: the generalised-let poison
  (`(var, FunL)` → `poisonBoth`) is a real ⊤ that reaches signature facts.
- **D2 must keep `VarLocal` callees** (Q-b) and, in 16a, replay the mints in the exact order
  (head, then depths 1..arity-1); use `canTypeIsArrow` for the head guard (as
  `standaloneMemberWith` does), NOT `canTypeMentionsArrow`.
- Census parity is deliberately preserved where it is cheap (D4 report-gate, `litFacts|` and
  `refspine|` keys) so the rail's census diff is attributable; do not "clean up" those bumps.
- `LssInfer.elm` is written in explicit `case f s of Err/Ok` style — keep it; no `Engine.andThen`
  closures in the new code (agent A / step 10).
- `S` is at the 32-slot record cap (EN:1352-1356): step 16 adds NO field to `S`, `ItemAux` or
  `LssMemberTable`.
- Report-on vs report-off must still produce the same artifact (EN:1172-1176): D4 is the only
  report-conditional CONTROL-FLOW change and it differs only in a read-only DFS + a report-gated
  counter — acceptable; do not gate D1/D10 on `report` (that would make report-on mint different
  scratch Points, still artifact-identical, but it hides the timed path from the census).
- Plan §4 N16: `directChildren` is reached only for leaves/`Access`; the `Call` arm change must
  not reintroduce a per-node child list (the sketch above walks `args` directly).
- Do NOT delete `preResolveCallees` here (D9) — order-changing; and do NOT touch `storeMentionsArrow`'s
  per-node `S` copy (step 8 owns `UF.peekS`).

#### 8. Effort

**S-M** for 16a: ~150 lines in one file, five independent edits, all BI, one measured run. Split
if desired: `16a` = D1+D8 (the instantiation mass), `16a'` = D2-mint-preserving+D4+D10+D12
(walk-shape edits) — each is BI and separately attributable. `16b` (drop the callee mints) is
S to write but costs an extra bootstrap turn and the rail; recommended as a trailing optional
entry or dropped after step 13.

---

<details><summary>Conventions used in this spec (from spec-J)</summary>

All line numbers are as of the loop's `base` tree (2026-09-19), verified by reading the code. File
abbreviations: `LI` = `/work/compiler/src/Compiler/MonoSolver/LssInfer.elm`, `EN` = `.../Engine.elm`,
`ST` = `.../Store.elm`, `TR` = `.../Translate.elm`, `KSF` = `.../KernelSetFacts.elm`,
`KA` = `/work/compiler/src/Compiler/Monomorphize/KernelAbi.elm`.

---

</details>

### Step 17 (was 17). `Data.HashMap` buckets: `Dict Int` → array-backed table

#### 1. Goal and expected effect

Every `HashMap.get`/`member`/`insert`/`remove` (`/work/compiler/src/Data/HashMap.elm` 62-69,
88-95, 112-129, 154-184) begins with `Dict.get (hash key) buckets` — a red-black descent over
as many buckets as there are distinct hashes (~116 K for the intern table), ~17 levels of
`Int` compare + pointer resolve per probe. The profile attributes `Dict_get` 1.6 % self of the
window to this (plan §1 row "Intern.probe", `Dict 2.4 %` includes `dictEq` — after step 2 the
residue is this descent). Consumers: the intern table (every composite node built by the
producers in step 2 §4.1 — 10^7-10^8 probes/run), `SpecKeyMap` (registry: ~141 K keyed probes,
`Registry.elm:104, 115, 143, 180`; `getOrCreateSpecId` 98-118, `getOrCreateSpecIdKeyed` 137-185), `Env.toptNodes` (`Engine.elm:1273`; read per global
occurrence — `Translate.elm:2743, 2766, 4634`, `LssInfer.elm:98, 420, 2344, 2477`,
`Monomorphize.elm:232, 360, 2167, 3286, 4482, 4546, 4671, 4977`), `MonoMemo.callMemo`
(`Engine.elm:491, 2721, 2732`), and the codegen `LayoutMap`s. Replace the `Dict Int` with an
`Array` of buckets indexed by `modBy capacity hash`, doubling at load 1.0: an `Array.get` is
≤ 4 trie levels for 131 072 slots with no comparisons.

Expected: wall −1..−2 %; minor GC ≈ identical (a `Dict.insert` allocates ~17 nodes × 6 words,
an `Array.set` path-copies ≤ 4 nodes × 33 words — same order; grows are amortised O(1) and
allocate 2n entries' worth over the run); major/promoted ≈ identical (the table's retained size
drops: 116 K Dict nodes ≈ 5.6 MB vs a 131 K-slot array ≈ 1 MB + entries); RSS neutral.

**Byte-identical: YES, required** (substrate change). Iteration (`orderedEntries` 206-209)
sorts on the per-entry sequence number, a total order assigned at insert and independent of
bucket placement; the representation therefore cannot change any fold/`toList`/`values`
order. §4.6 lists every consumer whose order reaches emission.

#### 2. Preconditions

- No plan step is a prerequisite. If step 2 has landed, `getBy` (step 2 §4.5) is carried over
  unchanged in API.
- Verify nothing compares or pattern-matches a `HashMap` structurally (its payload changes):
  ```bash
  grep -rn "HashMap" /work/compiler/src --include=*.elm | grep -v "HashMap\.\(HashMap\|get\|getBy\|insert\|member\|remove\|size\|isEmpty\|foldl\|map\|toList\|values\|fromList\|empty\)\b" | grep -v "^/work/compiler/src/Data/HashMap.elm" | grep -v "import Data.HashMap"
  ```
  must print only type-annotation lines (`HashMap.HashMap …` in signatures) and comments.
- Verify every caller-supplied `hash` is an `Int` the index function can take (it can take any
  `Int`; `modBy` is floored, so negatives are safe): `Mono.specHashOf`/`layoutHashOf`
  (Monomorphized.elm 326-369, results in `[0, 2^26)`), `specKeyHash` (813-815), `globalHash`
  (785-797), `TOpt.globalHash` (`/work/compiler/src/Compiler/AST/TypedOptimized.elm:329-338`).

#### 3. Inventory of touched code

| file | function (lines now) | what changes |
|---|---|---|
| `/work/compiler/src/Data/HashMap.elm` | `type HashMap` 49-50 | `HashMap Int Int Int (Array (List (Entry k v)))` — count, nextSeq, capacity, buckets; new `type Entry k v = Entry Int Int k v` (seq, hash, key, value). |
| same | `empty` 55-57 | `HashMap 0 0 initialCapacity (Array.repeat initialCapacity [])`, a CAF. |
| same | `get` 62-69, `scanBucket` 72-83, `getBy` (from step 2) | index by `modBy cap h`; bucket scan compares the STORED hash before calling `eq`. |
| same | `member` 88-95, `bucketMember` 98-105 | same. |
| same | `insert` 112-129, `replaceInBucket` 138-149 | hash-compare-then-eq membership; grow when `count == cap`; `Array.set`. |
| same | `remove` 154-184 | `Array.set` with the filtered bucket; no shrink. |
| same | `size` 189-191, `isEmpty` 196-198 | unchanged (read `count`). |
| same | `orderedEntries` 206-209, `foldl` 214-216, `map` 221-225, `toList` 231-233, `values` 238-240, `fromList` 245-247 | `Array.foldl`/`Array.map` over buckets; `Entry` patterns; order unchanged. |
| same | module docs 8-40, 45-47 | describe the array table, the stored hash, the load factor; keep the INSERTION-ORDERED paragraph (27-33) verbatim — it is the contract. |
| `/work/compiler/tests/Compiler/Data/HashMapTest.elm` | (new in step 2, or new here) | pins in §6, written against the CURRENT implementation first. |

Callers — ALL unchanged (the exported API is identical): `/work/compiler/src/Compiler/AST/Monomorphized.elm`
183, 706-777 (`LayoutMap`), 809-840 (`SpecKeyMap`), 846-898 (`SpecMap`);
`/work/compiler/src/Compiler/AST/Intern.elm` 43, 72-73, 81, 127, 130, 196, 201, 213;
`/work/compiler/src/Compiler/MonoSolver/Engine.elm` 44, 1273, 2776 (doc), 2781;
`/work/compiler/src/Compiler/MonoSolver/Monomorphize.elm` 57, 232, 360, 1197, 2063, 2167, 3286, 3875-3880, 4482, 4546, 4671, 4898, 4962, 4971, 4977;
`/work/compiler/src/Compiler/MonoSolver/Translate.elm` 46, 2743, 2766, 4634;
`/work/compiler/src/Compiler/MonoSolver/LssInfer.elm` 65, 98, 420, 2344, 2477.
`src-xhr` has no users (`grep -rln HashMap /work/compiler/src-xhr` is empty).

#### 4. Design

```elm
type HashMap k v
    = HashMap Int Int Int (Array (List (Entry k v)))
      -- count, nextSeq, capacity (a power of two), buckets (length == capacity)


{-| seq (insertion order, the iteration key), the key's FULL hash (so a slot shared
by two different hashes rejects on an `Int` compare and never calls `eq`), key, value.
-}
type Entry k v
    = Entry Int Int k v


initialCapacity : Int
initialCapacity =
    8


empty : HashMap k v
empty =
    HashMap 0 0 initialCapacity (Array.repeat initialCapacity [])


slotOf : Int -> Int -> Int
slotOf capacity h =
    -- `modBy` is floored: any Int, negative included, lands in [0, capacity).
    modBy capacity h


getBy : (q -> Int) -> (q -> k -> Bool) -> q -> HashMap k v -> Maybe v
getBy hash eq probe (HashMap _ _ capacity buckets) =
    let
        h =
            hash probe
    in
    case Array.get (slotOf capacity h) buckets of
        Just bucket ->
            scanBucketBy eq probe h bucket

        Nothing ->
            -- Unreachable: buckets has exactly `capacity` slots.
            Nothing


scanBucketBy : (q -> k -> Bool) -> q -> Int -> List (Entry k v) -> Maybe v
scanBucketBy eq probe h bucket =
    case bucket of
        [] ->
            Nothing

        (Entry _ eh k v) :: rest ->
            if eh == h && eq probe k then
                Just v

            else
                scanBucketBy eq probe h rest


get : (k -> Int) -> (k -> k -> Bool) -> k -> HashMap k v -> Maybe v
get hash eq key m =
    getBy hash eq key m


member : (k -> Int) -> (k -> k -> Bool) -> k -> HashMap k v -> Bool
member hash eq key m =
    case getBy hash eq key m of
        Just _ ->
            True

        Nothing ->
            False


insert : (k -> Int) -> (k -> k -> Bool) -> k -> v -> HashMap k v -> HashMap k v
insert hash eq key value ((HashMap count nextSeq capacity buckets) as m) =
    let
        h =
            hash key

        idx =
            slotOf capacity h

        bucket =
            Maybe.withDefault [] (Array.get idx buckets)
    in
    if bucketMember eq key h bucket then
        -- Replace in place: the entry keeps its seq and therefore its iteration
        -- position, exactly as `Dict.insert` keeps a replaced key's position.
        HashMap count nextSeq capacity (Array.set idx (replaceInBucket eq key h value bucket) buckets)

    else if count == capacity then
        insert hash eq key value (grow m)

    else
        HashMap (count + 1) (nextSeq + 1) capacity (Array.set idx (Entry nextSeq h key value :: bucket) buckets)


{-| Double the table. With power-of-two capacities an entry in old slot `i` lands in
new slot `i` or `i + oldCapacity`, so each new bucket is a filter of exactly one old
bucket and the whole rebuild is ONE `Array.initialize` — no per-entry path copies,
no intermediate `Dict`. Sequence numbers and stored hashes travel unchanged.
-}
grow : HashMap k v -> HashMap k v
grow (HashMap count nextSeq capacity buckets) =
    let
        capacity2 =
            capacity * 2

        bucketAt i =
            Maybe.withDefault [] (Array.get (modBy capacity i) buckets)
    in
    HashMap count
        nextSeq
        capacity2
        (Array.initialize capacity2
            (\i -> List.filter (\(Entry _ eh _ _) -> slotOf capacity2 eh == i) (bucketAt i))
        )


remove : (k -> Int) -> (k -> k -> Bool) -> k -> HashMap k v -> HashMap k v
remove hash eq key ((HashMap count nextSeq capacity buckets) as m) =
    let
        h =
            hash key

        idx =
            slotOf capacity h

        bucket =
            Maybe.withDefault [] (Array.get idx buckets)
    in
    if bucketMember eq key h bucket then
        HashMap (count - 1)
            nextSeq
            capacity
            (Array.set idx (List.filter (\(Entry _ eh k _) -> not (eh == h && eq key k)) bucket) buckets)

    else
        m


orderedEntries : HashMap k v -> List (Entry k v)
orderedEntries (HashMap _ _ _ buckets) =
    Array.foldl (\bucket acc -> bucket ++ acc) [] buckets
        |> List.sortBy (\(Entry seq _ _ _) -> seq)


foldl : (k -> v -> b -> b) -> b -> HashMap k v -> b
foldl step init m =
    List.foldl (\(Entry _ _ k v) acc -> step k v acc) init (orderedEntries m)


map : (k -> a -> b) -> HashMap k a -> HashMap k b
map f (HashMap count nextSeq capacity buckets) =
    HashMap count nextSeq capacity (Array.map (List.map (\(Entry seq h k v) -> Entry seq h k (f k v))) buckets)
```

`bucketMember eq key h` and `replaceInBucket eq key h value` are today's 98-105 / 138-149 with
the `eh == h &&` pre-test and `Entry` patterns; `toList`/`values`/`fromList` follow `foldl`.

**Invariants of the structure** (state them in the module doc): `count` = number of entries;
`capacity` is a power of two and `Array.length buckets == capacity`; every `Entry _ h _ _`
sits in slot `modBy capacity h` and `h == hash key` for the map's `hash`; seqs are unique and
increase with insertion; `count <= capacity` (load ≤ 1.0, so the expected number of entries
scanned per hit is ≈ 1 + count/(2·capacity) ≤ 1.5, and a non-matching co-resident entry costs
one `Int` compare).

**Why a stored hash.** Under `Dict Int` a bucket held only entries with the SAME 26-bit hash,
so `eq` ran only on real collisions. Under `modBy capacity` a slot also holds entries with
different hashes; without the stored hash each of them would run `eq` — for the intern table
a structural compare of two unrelated records. The one extra unboxed `Int` per entry keeps
the `eq` count exactly what it is today.

**Mint-order / emission constraints.** None arise from bucket placement: `orderedEntries`'s
`List.sortBy` on unique seqs is a total order, so `foldl`/`toList`/`values` return the same
sequence as today for any bucket arrangement, and `map` preserves seqs. The emission-reaching
consumers (all unchanged code): `Analysis.elm:585` (`layoutMapFoldl` over the collected custom
types, building the `ctorShapes` `LayoutMap` whose `layoutMapValues` at `Patterns.elm:1193`
orders pattern-shape emission), `Prune.elm:236` (`layoutMapMap`), `Specialize.elm:1018, 1351,
3316, 3453, 3613` and `Translate.elm:5724, 5953, 6295, 7368` (`specMapValues`/`specMapToList`
of local-multi instances — `7368` is an `indexedMap`, i.e. ORDINALS), `Engine.elm:2488`
(`List.head` of instances), `Monomorphize.elm:1197, 2063` (order-insensitive `Dict` builds),
`CafCensus.elm:518`, `CseCensus.elm:387`, `CafDedupe.elm:146`, `MonoCse.elm:243`
(`specMapFoldl`; CafDedupe/MonoCse are emission-affecting). All of them see the seq order.

Determinism: same hashes, same insertion sequence ⇒ same table; `modBy` is pure. The
JS-hosted build (elm-test-rs, Stage 5) uses elm/core's `Array` (the same 32-way trie in both
hosts), so unit tests and the JS path behave identically.

#### 5. Edit sequence

1. **Pin the contract first, against the CURRENT `Dict Int` implementation.** Create
   `/work/compiler/tests/Compiler/Data/HashMapTest.elm` (module `Compiler.Data.HashMapTest`,
   next to `BitSetTest.elm`) with the tests in §6. Run
   `build/toolchain/bin/elm-test-rs --project build/compiler/build-xhr --fuzz 1 --filter HashMap`
   — green on the old code.
2. **Swap the representation** in `/work/compiler/src/Data/HashMap.elm` per §4 in one edit (the
   type change forces every function; the file is 247 lines). Keep the exported names and
   signatures byte-for-byte. `elm make` green; re-run the filtered tests, then the full
   `elm-tests`.
3. `try-17` snapshot; loop Phases 1-4.

#### 6. Verification

**Unit — `HashMapTest`** (deterministic corpus, `--fuzz 1`; use `hash = modBy 5` on `Int` keys
so slots and hashes collide heavily, plus `identity` as the honest hash):
- insertion-ordered `toList`/`values`/`foldl` for 1 000 keys inserted in a pseudo-random order,
  compared with the insertion list;
- replacing an existing key keeps its position and does not change `size`;
- `remove` drops exactly the key, keeps the others' order, `size` decrements; removing an absent
  key returns the same content;
- `get`/`member` agree with a reference `Dict` for 5 000 keys through several doublings
  (8 → 8 192): every inserted key found, 5 000 absent keys not found;
- `getBy` with a probe type different from the key type (e.g. probe `( Int, String )` against
  `Int` keys via `Tuple.first`);
- `map` preserves order and `size`;
- `fromList` equals sequential inserts.

Then `cmake --build build --target elm-tests` (full suite: `ComparableKeyEncodingTest`'s K6/K7
tests exercise the intern table through the new map; `LayoutQualTest`/`MuTieTest`/registry
tests exercise `SpecKeyMap`).

**Loop.** `try-17`; Phase 2 triple; `cmp` r1/r2/r3 and `cmp r1-out.mlir bin/eco17.mlir` (BI —
no extra bootstrap turn). Expect minor/major GC and promoted MiB within ±1 of the reference
(`Array.initialize` at each doubling is the only new allocation pattern); wall is the verdict.

**Attribution (untimed).** `perf record -F 199 -g`: `Dict_get`/`Dict_getHelp` frames under
`Data_HashMap_get`/`getBy` vanish; `Array_get` (or the inlined trie walk) appears in their
place. If wall is flat, count grows: add a temporary `Debug.log`-free counter only in a census
build — the number of doublings for the intern table is `log2(116K/8) = 14`, i.e. negligible;
the cost then lives in `List.sortBy` of `orderedEntries` (unchanged) or the probes were never
`Dict`-bound.

#### 7. Risks, gotchas, and what NOT to do

- **Never iterate in bucket order.** The module doc (27-33) is the contract: emission folds
  these maps (§4 list). `orderedEntries` keeps `List.sortBy seq`.
- **Do not use `Bitwise.and (capacity - 1)`** for the slot: the JS host truncates to 32 bits
  and negative hashes from a future caller would index out of range; `modBy` costs one
  division and is total.
- **`empty` must carry a real 8-slot array**, not `Array.empty` — `slotOf` assumes
  `Array.length buckets == capacity`; the `Nothing` arms of `Array.get` are kept total but
  must be unreachable.
- Grow when `count == capacity` BEFORE placing a NEW key, never on replace, never on `remove`;
  never shrink (a shrink would be correct but is wasted work and churns memory).
- `map` must keep `seq` AND the stored hash (keys are untouched, so the hash is still valid —
  same reasoning as the old 219-225 comment).
- Keep `size`/`isEmpty` O(1) from `count`: `Engine.withIntern` (2779-2785) and `Store.consC`
  (2249-2259) call `Intern.size` per composite.
- Tiny maps: every `specMapSingleton`/`specMapEmpty` (`Monomorphized.elm:846-888`) now holds
  an 8-slot leaf (~10 words) instead of an empty `Dict`. The local-multi instance maps are
  per-let and numerous; if max RSS moves outside the 0.03 % spread on all three runs, lower
  `initialCapacity` to 4 (a power of two is all `grow` needs) — do not add a special-case
  empty representation (it would put a `case` on every probe).
- Plan §4 N3 (per-item `arrowMemo` as an `Array` loses) does not apply: these maps are
  run-wide or per-let, not reset per item, and the array here is the bucket vector, not a
  sparse id-indexed table.
- **Invariants touched:** none. `LSS_003`/`LSS_017`-`LSS_024` name member-key SHAPES and
  minting ORDER; neither depends on `HashMap` placement, and iteration order is preserved.
- Do not combine with step 2 in one candidate (loop hygiene: one step per iteration); if
  step 2 already landed, `getBy` must keep its signature.

#### 8. Effort

**S-M.** ~150 lines in one file plus a ~120-line test module; one loop entry (`17`). No
sensible split — the representation change is atomic.

<details><summary>Conventions used in this spec (from spec-A)</summary>

Line numbers are as of 2026-09-19 (`/work`, clean tree). Every cited line was read, not
remembered. "Window" = the mono-phase window of the DWARF profile in plan §1.

---

</details>

### Step 18 (was 14). String-pattern `case` arms in `normalizePrimHome`, `classifyApp`, `Zonk`

1. **Goal and expected effect**

Plan §1: 2.2 % of the mono window (`normalizePrimHome` 1.6 % + `classifyApp` inclusive). Three
Elm sites test a type name against six string literals after testing the module against two:

- `Store.normalizePrimHome` (Store.elm:590-621): `case canonical of ModuleName.Canonical ( "elm", "core" ) _ -> case name of "Int"|"Float"|"Bool"|"Char"|"String"|"List"`; called from `loadTypeC` (:401) for EVERY `App1` load.
- `Store.classifyApp` (:3449-3484), via `classifyAppC` (:3444) from `zonkFlatC` (:2778) and directly from `classifyGo` (:3585): `isElmCore` (:3452-3458, two string patterns) is evaluated FIRST for every `TType`, then the six-arm `case name`.
- `Zonk.canTypeToMonoWithI` `TType` arm (Zonk.elm:80-118): same shape, `isElmCore` (:85-91) before the six arms (:94-118).

Grep confirms these are the only string-literal `case` arms in `Compiler/MonoSolver/*.elm`
(`grep -n -E '^\s+"[A-Za-z][A-Za-z0-9_.]*" ->' compiler/src/Compiler/MonoSolver/*.elm` → Zonk 95-110,
Store 595-615, Store 3462-3477; `( "elm", "core" )` → Zonk:87, Store:593, :3454). Outside MonoSolver
the same pattern exists at Monomorphize/KernelAbi.elm:423 (`convertTType`, kernel types only, one
caller :357) and Monomorphize/TypeSubst.elm:405-417/847 (subst engine) — not on the LSS path.

**How the backend lowers one string pattern today** (every evaluation, not once):
`ModuleName.Canonical ( "elm", "core" ) _` becomes two single-pattern `eco.case {case_kind="str"}`
ops (one `Test.IsStr` per tuple field, Expr.elm:6809-6836 `generateFanOutGeneralWithJumps`), and
`case name of` one six-pattern op. `CaseOpLowering` (EcoToLLVMControlFlow.cpp:138; string branch
:429-538) emits PER PATTERN: `llvm.mlir.addressof @__eco_str_case_<id>_<i>` + a call to
`eco_alloc_string_literal_utf8(bytes, len)` (:471-477; the global itself is pre-created once in
`preMaterializeStringCases` :1185-1258) + the `__eco_value_eq` marker (:429-431, :495-512), expanded
by `expandValueEqFastPath` (EcoBackend.cpp:1817) into word-compare → constant-bit test →
`Elm_Kernel_Utils_equal`. The runtime call is `internLiteral` (RuntimeExports.cpp:673-692):
`syncEpoch(Allocator::instance().heapGeneration())` + `std::unordered_map<const void*,HPointer*>::find`
on a `thread_local` table (:599-639), and — because `getOrCreateAllocStringLiteralUtf8`
(EcoToLLVMRuntime.cpp:226-231) is declared WITHOUT `gcLeaf` — the call is a statepoint: every live
`ptr addrspace(1)` value in the function is spilled/reloaded around it. Nested string cases inside
SCF regions take `CaseStringToScfIfChainPattern` (EcoControlFlowToSCF.cpp:727-880), which creates
a `StringLiteralOp` per pattern (:810-811, :851-852) → `StringLiteralOpLowering`
(EcoToLLVMTypes.cpp:94-165) → the same per-evaluation call (:139-146).

So a core type named e.g. `Maybe` costs at an `App1` load: 2 + 6 = 8 intern probes + 8 statepoint
calls + up to 8 `Utils.equal` calls; a non-core type costs 1-2 of each.

Two fixes, in this order:

- **18b (backend, first):** cache the interned HPointer per literal in a zero-initialised global
  slot; the hit path becomes one load + one compare + branch, no call, no statepoint. Benefits
  every string `case` and every string literal in every program (including the LSS key builders'
  literal prefixes). BI at the MLIR level (`out.mlir` unchanged) — a clean loop entry.
- **18a (Elm, second):** dispatch on `String.length name` first, then the name, and only THEN the
  module; a non-primitive name costs one inline Int switch and zero string compares.

Expected: 18b alone removes the probe + statepoint (most of the 2.2 %; also trims every other
string-literal evaluation in the compiler); 18a removes the residual ≤ 8 `Utils.equal` calls per
node down to ≤ 3 (and 0 for non-primitive names). Wall down; minor GC count may drop slightly
(fewer statepoint spills do not allocate, so likely flat); RSS unchanged.

2. **Preconditions**

- No plan dependency. Verify defaults that 18a relies on: `ECO_STRING_LEN_INLINE` is default-on
  (EcoToLLVMInternal.h:842-846) so `String.length` lowers to `__eco_string_len_inline` → header
  `u32` load (EcoBackend.cpp:1765-1780, 1893) — no call, no allocation; `ECO_VALUE_EQ_STRCASE`
  default-on (EcoToLLVMControlFlow.cpp:34-42, and the duplicate at EcoControlFlowToSCF.cpp:716-724 —
  "both MUST be switched together").
- Verify PermanentSpace objects are immortal across `Allocator::reset` (18b's cache never needs
  invalidation): `grep -n "reset\|clear" runtime/src/allocator/PermanentSpace.hpp` → none
  (verified: only `contains`, :44); `LiteralTable::newSlot` comment :628-631 states the same.
- Verify no fixture checks the LLVM text of string cases: `grep -rl "__eco_str_case\|eco_alloc_string_literal_utf8" test/` → none (verified; `test/codegen/eco-case-string-patterns.mlir` checks the MLIR `eco.case` attrs only, :11-49).

3. **Inventory of touched code**

18b:

| file | function (lines) | what changes |
|---|---|---|
| runtime/src/allocator/RuntimeExports.cpp | after `eco_alloc_string_literal_utf8` :715-733 (and `eco_alloc_string_literal` :695-707) | add `eco_string_literal_utf8_fill` / `eco_string_literal_fill` (slot-filling wrappers) |
| runtime/src/allocator/RuntimeExports.h | :206 area | declare both |
| runtime/src/codegen/RuntimeSymbols.cpp | :54-61 | register both in the JIT symbol map |
| runtime/src/codegen/Passes/EcoToLLVMInternal.h | :535-536 | getters `getOrCreateStringLiteralFill{,Utf8}` + `getOrCreateStrLitCacheMarker` |
| runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp | :220-231 (decls), `materializeAllRuntimeDecls` :1270-1274 | define the getters; pre-declare all three (a miss after `freeze()` asserts, :129-137) |
| runtime/src/codegen/Passes/EcoToLLVMTypes.cpp | `preMaterializeStringLiterals` :180-…; `StringLiteralOpLowering` :94-165 (:125-146) | create sibling slot global `__eco_str_N_hp`; emit the marker instead of the alloc call |
| runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp | `preMaterializeStringCases` :1185-1258; `CaseOpLowering` string branch :460-489 | sibling slot `__eco_str_case_<id>_<i>_hp`; emit the marker |
| runtime/src/codegen/EcoBackend.cpp | new `expandStrLitCacheMarkers` next to `expandValueEqFastPath` :1817; call it at :3111 (before every RS4GC flavour) | the load/branch/call/phi expansion |

18a:

| file | function (lines) | what changes |
|---|---|---|
| compiler/src/Compiler/MonoSolver/Store.elm | `normalizePrimHome` 590-621 | length-first, name-then-module |
| compiler/src/Compiler/MonoSolver/Store.elm | `classifyApp` 3449-3484 | same; `isElmCore` computed only after a name hit |
| compiler/src/Compiler/MonoSolver/Zonk.elm | `canTypeToMonoWithI` TType arm 80-118 | same |
| compiler/src/Compiler/MonoSolver/Zonk.elm (new, exported) | `isElmCore : ModuleName.Canonical -> Bool` | shared helper. Zonk imports only Can/Intern/Mono/TypeIds/Id/ModuleName/Vars/Dict (Zonk.elm:30-37) and Store imports only Engine from MonoSolver (Store.elm:34), so `import Compiler.MonoSolver.Zonk as Zonk` in Store is cycle-free |

Callers unchanged: `loadTypeC` :401, `zonkFlatC` :2778, `classifyGo` :3585; `canTypeToMonoWithI`
callers (`canTypeToMono` Zonk.elm:44, Monomorphize.elm:134/3961, Translate, Engine) — no
signature change.

4. **Design**

**18b runtime side** (RuntimeExports.cpp, next to :733):

```cpp
// Slot-filling twins of the interning entry points (LSS step 18b). The slot is a
// zero-initialised global in the generated module; the hit path in generated code
// loads it and never calls here. We publish the word ONLY when the interned object
// landed in the PermanentSpace (HEAP_036: immortal, GC-invisible, never moves, shared
// by every thread), so a plain global needs no GC root. On the old-gen fallback the
// slot stays 0 and every evaluation keeps calling through (rooted by internLiteral).
extern "C" HPtr eco_string_literal_utf8_fill(const uint8_t* bytes, uint32_t byteLen,
                                             uint64_t* slot) {
    HPtr r = eco_alloc_string_literal_utf8(bytes, byteLen);
    uint64_t raw = r.toBits();
    if (Elm::PermanentSpace::instance().contains(reinterpret_cast<void*>(raw)))
        __atomic_store_n(slot, raw, __ATOMIC_RELAXED);
    return r;
}
extern "C" HPtr eco_string_literal_fill(const uint16_t* chars, uint32_t length, uint64_t* slot) { /* same over eco_alloc_string_literal */ }
```

Cross-thread: the table is `thread_local` (:636-639) but permanent objects are process-wide, so a
word written by one thread is valid for all; two threads racing publish the same or two equivalent
immortal objects — either is a correct String value. Relaxed atomics keep it formally race-free.
`Allocator::reset` (test harness only) does not free the PermanentSpace, so a stale slot still
denotes a live immortal object (the table's `syncEpoch` drop exists only for the ROOTED old-gen
fallback, :607-611).

**18b codegen side.** Marker `__eco_str_lit_cached(ptr bytes, i32 len, ptr slot) -> ptr addrspace(1)`
declared like `__eco_string_len_inline` (EcoToLLVMRuntime.cpp:972-979) but NOT gc-leaf (its slow arm
allocates). Slot global: `LLVM::GlobalOp` of type `ptr addrspace(1)` (HPTR_TY), `isConstant=false`,
`Linkage::Internal`, zero initializer, created in the two pre-materialisers right after the bytes
global with the same name + `_hp` (names derive from the same deterministic counters →
byte-identical symbol order). Lowering (both `StringLiteralOpLowering` :139-146 and the string-case
branch :471-477; the UTF-16 branches likewise with the UTF-16 fill): replace the alloc call with
`llvm.call @__eco_str_lit_cached(addrof bytes, len, addrof slot)`. The SCF path needs no edit (it
emits `StringLiteralOp`). Expansion in EcoBackend.cpp, shape copied from `expandInlineDerefs`
(:1150-1195):

```
head:  %hp  = load ptr addrspace(1), ptr @slot, align 8      ; relaxed is enough
       %z   = icmp eq ptr addrspace(1) %hp, null
       br %z, slow, cont                                     ; weights fwd=1 / cont=1<<20
slow:  %r   = call @eco_string_literal_utf8_fill(bytes, len, @slot)   ; real call → RS4GC statepoints it
       br cont
cont:  %v   = phi ptr addrspace(1) [%hp, head], [%r, slow]
```

The loaded value is a base pointer for RS4GC (a load result), exactly like today's call result; it
is a PermanentSpace address, for which relocation is a no-op — same as every literal today. The
expansion MUST run before every `RewriteStatepointsForGC` flavour and before
`propagateGcFreeLeafAttrs` (same constraint as `expandValueEqFastPath`, EcoBackend.cpp:1798-1800):
insert the call at :3111 next to it. Internal globals already cross partition splits
(`__eco_str_N` does), so the sibling does too.

**18a Elm side.** `String.length` is the cheapest discriminator: inline header read
(`__eco_string_len_inline`), no allocation; `String.uncons`/`String.toList` allocate a
`Maybe`/`Tuple`/list per call (kernel exports, no intrinsic — `grep '"uncons"' Intrinsics.elm` is
empty) and are NOT to be used. No `Maybe` in the helper (a `Just` is a 16-byte allocation per call):

```elm
{-| elm/core home test, called only after a primitive NAME matched (18a): the two
string patterns are then paid at most once per App1 instead of for every type. -}
isElmCore : ModuleName.Canonical -> Bool
isElmCore canonical =
    case canonical of
        ModuleName.Canonical ( "elm", "core" ) _ -> True
        _ -> False


normalizePrimHome : ModuleName.Canonical -> String -> ModuleName.Canonical
normalizePrimHome canonical name =
    -- Length-first (inline header read), then name, then module. Same predicate
    -- as before — core ∧ name ∈ {Int,Float,Bool,Char,String,List} — so the result is
    -- identical for every input; only the evaluation order changes.
    case String.length name of
        3 -> if name == "Int" && isElmCore canonical then ModuleName.basics else canonical
        4 ->
            if name == "Bool" then (if isElmCore canonical then ModuleName.basics else canonical)
            else if name == "Char" then (if isElmCore canonical then ModuleName.char else canonical)
            else if name == "List" then (if isElmCore canonical then ModuleName.list else canonical)
            else canonical
        5 -> if name == "Float" && isElmCore canonical then ModuleName.basics else canonical
        6 -> if name == "String" && isElmCore canonical then ModuleName.string else canonical
        _ -> canonical
```

`classifyApp` (:3449) and the Zonk arm (:80-118) get the same skeleton with `Mono.MInt`/`MFloat`/
`MBool`/`MChar`/`MString`/`Mono.mList inner` (keeping the `[ inner ] -> … | _ -> mList MUnit`
sub-case, :3475-3480) in the hit arms and `Mono.mCustom canonical name args` (Zonk:
`Intern.hashCons (Mono.mCustom …) intern1`) as the single fall-through. Each `name == "…"` is a
`ValueEq` intrinsic (`boxedComparable MString`, Intrinsics.elm:706-716, gated at Expr.elm:1417-1425)
→ word compare + `Utils.equal`; the literal is an `eco.string_literal` (cached after 18b). `&&` is
rewritten to `If` by TypedOptimized, so `isElmCore` runs only on a name hit.

Order-of-evaluation / emission constraints: none of the three functions mints Points, member ids
or intern entries in the changed region (`classifyApp` is pure; the Zonk arm's `Intern.hashCons`
calls stay in the same arms with the same `intern1`), so intern insertion order is unchanged.

5. **Edit sequence**

18b (each step builds; run the `test` target at 4 and 6):
1. Runtime: the two `_fill` exports + `.h` declarations + `RuntimeSymbols.cpp` registration.
2. `EcoToLLVMRuntime.cpp`: getters for the two fills and the marker; add all three to
   `materializeAllRuntimeDecls` (:1270-1274).
3. `EcoBackend.cpp`: `expandStrLitCacheMarkers` + its call at :3111 (no markers exist yet — it is a no-op; builds).
4. `EcoToLLVMTypes.cpp`: slot global in `preMaterializeStringLiterals`, marker in `StringLiteralOpLowering` (both UTF-8 and UTF-16 branches). Run `test` + `TEST_FILTER=StringLiteral cmake --build build --target check`.
5. `EcoToLLVMControlFlow.cpp`: same for string cases (:1185-1258 and :460-489).
6. Full `check` (C++-only). Loop entry `18b`.

18a (each step `elm make`-green; run `elm-tests` after 3):
1. Add exported `isElmCore` to Zonk.elm and `import Compiler.MonoSolver.Zonk as Zonk` to Store.elm (cycle-free, see inventory).
2. Rewrite `normalizePrimHome` (Store.elm:590-621).
3. Rewrite `classifyApp` (:3449-3484) and the Zonk TType arm (:80-118).
4. Loop entry `18a` with the extra bootstrap turn (Phase 1.5).

6. **Verification**

- 18b: `cmake --build build --target test 2>&1 | tee /tmp/test_output.txt`; then
  `cmake --build build --target check 2>&1 | tee /tmp/test_output.txt` — pins:
  test/elm/src/StringLiteralTest.elm, HofStringCaseInlineTest.elm, TailRecNestedStringCaseTest.elm,
  plus every string-case E2E. Fixed point: `cmp bin/eco-opt18b-r1-out.mlir bin/eco-compiler.mlir`
  (MLIR unchanged by construction). Attribution: `perf report --no-children --sort symbol | grep -i "internLiteral\|eco_alloc_string_literal\|scanBucket"` — the literal symbols must fall to the floor; `Elm_Kernel_Utils_equal` stays (18a's target).
- 18a: `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt` (Store/Zonk unit
  pins: `grep -rl "classifyApp\|normalizePrimHome\|canTypeToMono" compiler/tests/TestLogic` and run those
  first with `build/toolchain/bin/elm-test-rs --project build/compiler/build-xhr --filter <name>`).
  Then `cmake --build build --target full`. Loop: Phase 1.5 extra bootstrap; gate B==C; and the
  workload-diff check — `diff <(grep -o 'func.func @[^(]*' bin/eco-compiler.mlir | sort) <(… bin/ecoN-b.mlir …)` must be empty (same spec set), with body diffs confined to the specs of `normalizePrimHome`, `classifyApp`, `canTypeToMonoWithI` and their lifted lambdas.
- Purpose-built census (only if the effect needs attribution): none needed; `perf` on
  `Elm_Kernel_Utils_equal` / `StringOps::equal` before/after 18a is the differential.

7. **Risks, gotchas, what NOT to do**

- Do NOT stamp the marker or the `_fill` exports `gc-leaf`: the slow arm allocates (interning on
  first evaluation). The hit path has no call, so RS4GC inserts no statepoint there — that is the win.
- The literal-bytes globals are `isConstant=true` (ControlFlow :1213-1215); the slot MUST be
  `isConstant=false` or LLVM folds the load to null and every evaluation takes the slow arm forever
  (silently correct, zero gain — check the LLVM text of one string case after edit 4).
- `preMaterializeStringCases`/`preMaterializeStringLiterals` are the ONLY places allowed to create
  globals (symbol table is frozen/read-only during the parallel body stage — assert at
  EcoToLLVMRuntime.cpp:135-137 and the comments at ControlFlow :442-445, Types :125-127).
- Empty-string patterns are embedded constants (ControlFlow :450-456, Types :128-134): no slot, no marker.
- `ECO_VALUE_EQ_STRCASE=0` kill-switch path (boxed `Utils.equal` + True-word decode, :503-512) must
  still work with the marker value — it only consumes `patternValue`, so it does.
- 18a must keep the exact predicate: `List` with ≠ 1 arg still maps to `mList MUnit` (:3478-3480);
  `Char`/`String`/`List` homes are `ModuleName.char/string/list`, NOT `basics` (LOAD-BEARING comment
  Store.elm:604-609 — Unify's super checks compare homes).
- Do not hoist the `"Int"` literals into top-level constants "to make them CAFs" — after 18b a
  literal is already one load; a CAF read is the same load plus a possible inliner re-materialisation.
- Plan §4 has no entry for this; nothing here is measured-out.

8. **Effort:** 18b M (six backend files, one runtime export pair, an LLVM expansion; all mechanical
and pinned by the existing E2E string tests); 18a S. Two loop entries: `18b` (BI) then `18a`
(fixed-point B==C).

---

<details><summary>Conventions used in this spec (from spec-I)</summary>

All line numbers verified against the tree on 2026-09-19 (HEAD, clean). None of the four steps
changes the LSS analysis; three of them (1, 14, 18b) are runtime/backend-only and are byte-identical
at the MLIR level by construction, two (18a, 20) change compiler SOURCE and therefore change the
workload (`out.mlir`) without changing the analysis — the loop's fixed-point rule (Phase 1.5:
A≠B is propagation, the gate is B==C) applies to those.

---

</details>

### Step 19 (was 18). `revMemoSetIfAbsent` per var mint

1. **Goal and expected effect**

`revMemo : Array (Maybe TypeIds.MVarId)` (Engine.elm:1345 — "Point index → first MVarId that minted it")
is written once per VAR mint by `Store.recordVarC` 510-517 → `revMemoSetIfAbsent` 524-540. On the mint
path `pk` is always ≥ `Array.length arr` (structure Points minted between two var mints never write
`revMemo`, so the array is shorter than the point count — findings-C C13), which means the two "already
present" arms (`Just (Just _) -> arr`, `pk < len -> Array.set`) are dead and EVERY mint runs
`Array.append arr (Array.push (Just mvarId) (Array.repeat (pk - len) Nothing))`: a `repeat` allocation, a
`push` (tail copy), an `append` (tail copy, O(gap)). Plan §1: 2.2 % of the mono window inclusive, 1.1 %
of it generic dispatch into the array kernel. 824,834 var-slot mints per self-compile is the multiplicity
(plan §1 "slot mints"; every `loadTypeC` TVar miss is one).

The change (with step 3 in): `revMemo` becomes a second `Eco.CellStore.Store (Maybe TypeIds.MVarId)` with
the SAME lifecycle as the store (it is stashed/restored/reset at exactly the same four sites), so a mint is
`gap` in-place `push Nothing` calls plus one `push (Just mvarId)` — no array allocation, no tail copies —
and a read is one `get`. Expected: the 2.2 % → ~0.3 % (one C call per push; the `Just` box stays);
objects down by ~3 per mint (~2.5 M); wall −1…−2 % of the mono window. BI = yes: same first-writer-wins
contents at the same indices, harvest iterates the same ascending index order.

Subsumption check the plan asked for: folding `revMemo` INTO the union-find cell (a field on `Descriptor`
or a second lane of the same store) is NOT recommended — `Descriptor` (Vars.elm 85-90) is the
typechecker's type and plan §4 N17 already declined touching it; a second lane would put a
`TypeIds`-typed value into `System.TypeCheck.IO` (a layering inversion). A separate store with paired
lifecycle gets all of the win.

2. **Preconditions**

- Step 3 (3a at least: the `Eco.CellStore` module and its pure twin) is in. Without step 3 build the
  fallback **19′** in §4 instead.
- Verify the mint-path claim once with a temporary counter (gap histogram) before building, or accept
  findings-C C13: add `Debug.log` is NOT allowed in the loop; instead run
  `grep -n "revMemoSetIfAbsent\|recordVarC" compiler/src/Compiler/MonoSolver/Store.elm` → 510-517, 524-540
  only (one caller), and read `loadTypeC`'s TVar arm to confirm `freshVarC` is the only path into
  `recordVarC` (it is: 493-506).
- Verify the consumer list is still exactly: `grep -n "revMemo" compiler/src/Compiler/MonoSolver/*.elm`
  → Engine 1300 (doc), 1345, 2029 (doc), 2042, 2100, 2435, 2662 (doc), 2693; Store 19/56 (doc), 61, 84,
  103, 130, 155, 162, 183, 190, 250 (doc), 514-517, 524-540, 691 (doc), 2210-2211 (doc), 2387, 2475,
  2685-2698, 2703-2734, 2744-2761, 2770-2840, 3388-3426, 3514 (doc); Monomorphize 3903, 4750;
  Translate 6006, 6016. Tests: none (`grep -rn revMemo compiler/tests` is empty).

3. **Inventory of touched code**

| file | function (lines) | what changes |
|---|---|---|
| Engine.elm | `S.revMemo` 1345 | type `Array (Maybe MVarId)` → `RevMemo` (alias below); doc line 1345 |
| Engine.elm | new `type alias RevMemo = CellStore.Store (Maybe TypeIds.MVarId)` + `freshRevMemo : () -> RevMemo`, `revMemoGet : Int -> RevMemo -> Maybe MVarId`, `revMemoSetIfAbsent : Int -> MVarId -> RevMemo -> RevMemo` (moved here from Store so Monomorphize 4750 and Store share one reader) | new |
| Engine.elm | `resetItem` 2435 (`revMemo = Array.empty`) | `revMemo = CellStore.renew s.revMemo` |
| Engine.elm | `withScratchStore` 2042 (`revMemo = Array.empty`), 2100 (`revMemo = s0.revMemo`) | `freshRevMemo ()` / `CellStore.release s3.revMemo s0.revMemo` |
| Engine.elm | `harvestSuperTableExcept` 2659-2690 (`Array.foldl step ( 0, ( s.store, s.superTable ) ) s.revMemo` 2693) | index loop `0 .. CellStore.size s.revMemo - 1` over `revMemoGet`, same ascending order, same skip of `Nothing` |
| Store.elm | `LoadCtx.revMemo` 61; `testLoadCtx` 84 (`revMemo = Array.empty`); `sharedLoadCtx` 103; `isolatedLoadCtx` 130; `writeBackShared` 155/162; `writeBackIsolated` 183/190 | type only; `testLoadCtx` takes a `RevMemo` argument (or calls `Engine.freshRevMemo ()`) |
| Store.elm | `recordVarC` 510-517; `revMemoSetIfAbsent` 524-540 | call `Engine.revMemoSetIfAbsent`; delete the local definition |
| Store.elm | `zonkToMono` 2387, `rezonkSettled` 2475 (pass `s.revMemo`); `zonkToMonoC` 2685, `residualWithTaintC` 2731, `residualIdC` 2758, `zonkFlatC` 2770, `zonkListC` 3388, `zonkRecordFieldsC` 3408, `zonkRecordExtC` 3425 (parameter type) | `revMemo : RevMemo`; the two reads 2749 and 2761 (`Maybe.andThen identity (Array.get (Engine.pointKey var) revMemo)`) → `Engine.revMemoGet (Engine.pointKey var) revMemo` |
| Monomorphize.elm | initial `S` 3903 (`revMemo = Array.empty`); `staleVarRead` 4750 (`Array.get … s.revMemo`) | `Engine.freshRevMemo ()`; `Engine.revMemoGet` |
| Translate.elm | `retranslateWithTag` 6006 (`revMemo = Array.empty`), 6016 (`revMemo = s0.revMemo`) | `freshRevMemo ()` / `CellStore.release s1.revMemo s0.revMemo` |
| tests | `ArrowIdentityTest.elm:124` (`Store.testLoadCtx True arrowIdOn seedMemo store`) | unchanged if `testLoadCtx` builds its own `freshRevMemo ()`; if the signature grows a `RevMemo` argument, this is the only caller (grep) |

4. **Design**

```elm
-- Engine.elm (next to the S definition)
type alias RevMemo = CellStore.Store (Maybe TypeIds.MVarId)

freshRevMemo : () -> RevMemo
freshRevMemo () = CellStore.new 64

{-| Point index -> first MVarId that minted it, or Nothing for structure Points and indices past the
last var mint. Bounds-safe like the former `Array.get`. -}
revMemoGet : Int -> RevMemo -> Maybe TypeIds.MVarId
revMemoGet pk rm =
    if pk < CellStore.size rm then CellStore.get pk rm else Nothing

{-| A2 keep-first semantics, in place: a filled slot is left untouched; the store is padded with
`Nothing` up to `pk`. Same contents at every index as the former Array version. -}
revMemoSetIfAbsent : Int -> TypeIds.MVarId -> RevMemo -> RevMemo
revMemoSetIfAbsent pk mvarId rm =
    let len = CellStore.size rm in
    if pk < len then
        case CellStore.get pk rm of
            Just _ -> rm
            Nothing -> CellStore.set pk (Just mvarId) rm
    else
        CellStore.push (Just mvarId) (padNothing (pk - len) rm)

padNothing : Int -> RevMemo -> RevMemo
padNothing n rm = if n <= 0 then rm else padNothing (n - 1) (CellStore.push Nothing rm)
```
`Nothing` is the embedded Empty constant (HEAP_010/REP_CONSTANT_001), so a pad push stores a constant
word (the scanner skips non-heap words via `evacuate`'s own constant check, as MVar's `evacField` relies on).
`Just mvarId` is one 2-word box per mint exactly as today. The two formerly dead arms are kept (they are
correct and cost one `size` compare) — under a scratch/renew lifecycle they stay dead, but a future writer
outside the mint path must not silently overwrite (keep-first is the LSS_006/`residualIdC` identity
contract, Store.elm 19-21 and 3514).

Lifecycle pairing (the load-bearing part): `revMemo` and `store` are reset, stashed and restored at the
SAME four sites (§3) because a `revMemo` index is a Point index of THAT store (Engine.elm 1345 "Point
indices are DENSE from 0 in a fresh per-item store"). Every site that does `store = freshStore ()` does
`revMemo = freshRevMemo ()`; every `release`/`renew` of the store has its twin on `revMemo`. The `Err`
exits leak one small store like the main one (§4.5 of step 3).

`harvestSuperTableExcept` 2659-2690 (ascending Point-index fold, skipping `Nothing`) becomes:

```elm
harvestSuperTableExcept excluded s =
    let
        n = CellStore.size s.revMemo
        go pointIdx super =
            if pointIdx >= n then super else
            case CellStore.get pointIdx s.revMemo of
                Nothing -> go (pointIdx + 1) super
                Just mvarId ->
                    if EverySet.member identity (mvarIdKey mvarId) excluded then go (pointIdx + 1) super
                    else
                        let desc = UF.peekS s.store (Vars.Pt pointIdx) in      -- spec-F; before spec-F: `Tuple.second (UF.get (Vars.Pt pointIdx) s.store)` (compression dropped, as today)
                        case desc.content of
                            Vars.FlexSuper Vars.Number _ -> go (pointIdx + 1) (CoreDict.insert (mvarIdKey mvarId) Vars.Number super)
                            Vars.RigidSuper Vars.Number _ -> go (pointIdx + 1) (CoreDict.insert (mvarIdKey mvarId) Vars.Number super)
                            _ -> go (pointIdx + 1) super
    in
    { s | superTable = go 0 s.superTable }
```
Same visit order (0,1,2,… ascending), same skips, same inserts ⇒ byte-identical harvest. `go` is
self-tail-recursive (TCO'd).

**Fallback 19′ (step 3 not in): keep the Array, grow geometrically.** Replace 524-540's else-arm with
`Array.set pk (Just mvarId) (Array.append arr (Array.repeat (max len (pk - len + 1)) Nothing))` — one
`repeat` + one `append` + one `set` per GROWTH instead of per mint; the array is then longer than the point
count, which every reader tolerates (`Array.get` past the last mint returns `Nothing` either way; harvest
skips `Nothing`). The `pk < len` arm then becomes LIVE (a mint into pre-grown capacity is one `Array.set`,
a path copy). BI. Gain: allocation drops from 3 objects + O(gap) copying per mint to ~1 path copy per mint
plus amortized O(1) growth — roughly half of the 2.2 %. Not worth a separate loop run if step 3 lands
within the series; do 19 proper.

Order-of-evaluation: `revMemoSetIfAbsent` is called from `recordVarC` right after `freshVarC` returns the
Point (Store 504-506, 510-517) — the sequence "mint Point, then record" is a data dependency on `pt`;
unchanged. No mint order changes anywhere.

5. **Edit sequence**

1. Engine.elm: add `RevMemo`, `freshRevMemo`, `revMemoGet`, `revMemoSetIfAbsent`, `padNothing`; change the
   `S.revMemo` field type (1345). This alone does not compile (Array literals remain) — do 2-4 in the same
   `elm make` cycle, or temporarily keep the old field and add the new one (NOT recommended: `S` would hit
   32 fields — Engine.elm 187-189/261/281 "32-slot record GC-scan cap").
2. Engine.elm 2042/2100/2435 + `harvestSuperTableExcept`; Monomorphize 3903, 4750; Translate 6006/6016.
3. Store.elm: `LoadCtx.revMemo` type (61), `testLoadCtx` 84 (`revMemo = Engine.freshRevMemo ()`), the
   zonk-family parameter types (2685, 2731, 2758, 2770, 3388, 3408, 3425), the two reads (2749, 2761),
   `recordVarC` 510-517 → `Engine.revMemoSetIfAbsent`, delete 524-540. Green under both roots;
   `elm-tests` green (ArrowIdentityTest, LssHonestSourcesTest, LssDirectedFlowTest exercise the load/zonk
   paths on the pure twin).
4. Docs: Engine.elm 1300, 1345, 2029, 2662; Store.elm 19, 56, 250, 691, 2210-2211 — replace "Array indexed
   by point" wording with "CellStore indexed by point". Snapshot `try-19`.

6. **Verification**

- `cmake --build build --target elm-tests` (the twin — the reads/writes are what the pins exercise;
  `LssHonestSourcesTest` pins `residualId` stamping through `revMemo`, Store.elm 3514).
- `cmake --build build --target full`.
- The loop triple with `cmp` (BI) and the fixed-point `cmp`. The report-on `diff` of step 3 §6 is worth
  repeating once here: `harvestSuperTable` feeds `superTable`, which the report prints indirectly through
  `CNumber` residual counts — a harvest-order slip would show there before it shows in bytes.
- Attribution: `ECO_INLINE_ALLOC=0` object census — the `Array.repeat`/`append` intermediates (small
  Array objects + their 32-slot nodes) per mint should vanish; `Just` count unchanged.

7. **Risks, gotchas, and what NOT to do**

- **Pairing**: a `revMemo` handle from a different store's lifetime is a silent wrong-id (not a crash —
  indices are just Ints). The four sites in §3 are the complete list today; re-grep before building and
  keep `store`/`revMemo` edits on the same line as they are now (2042, 2100, 2435, 3901-3903, 6006, 6016).
- **`Store (Maybe MVarId)`** is a boxed instantiation (`Maybe`/`Id` are customs) — the KernelAbi fail-stop
  arms of step 3 §4.7 do not fire. Never change it to `Store Int` "for speed".
- **Harvest order** is byte-identity-relevant (Engine.elm 2662-2666: ascending index == the former
  `Dict.foldl` key order); keep `go 0`.
- **Do not** put the MVarId into the union-find cell / `Descriptor` (N17, layering), and do not dedupe
  or re-sort `revMemo` — keep-first is the identity contract for residual ids (Store.elm 3510-3516).
- `testLoadCtx` (Store 80-92) is named by `ArrowIdentityTest.elm:124` only — if its signature changes,
  update that call in the same edit.

8. **Effort**

**S** (with step 3 in): ~25 mechanical type/site edits plus one 30-line harvest rewrite; one loop entry
`19`. The fallback `19′` is also S but half the win; it is the entry to run only if step 3 has been slid
to the end of the series.

<details><summary>Conventions used in this spec (from spec-B)</summary>

Written 2026-09-19 from full reads of `Compiler/Type/UnionFind.elm` (299 ln), `Data/IORef.elm` (151 ln),
`System/TypeCheck/IO.elm` 55-110, `Compiler/Type/Vars.elm` 38-105, `Compiler/Type/Solve.elm` 60-185,
`Compiler/Type/Unify.elm` 25-180 and 285-330, `Compiler/MonoSolver/Engine.elm` 1296-1350, 1725-1760,
2025-2100, 2405-2436, 2631-2690, `Compiler/MonoSolver/Store.elm` 40-200, 465-560, 1036-1100, 1135-1262,
1385-1470, 1678-1692, 1860-1872, 2030-2080, 2136-2170, 2200-2240, 2375-2500, 2682-2692, 2860-2872,
3038-3048, 3288-3298, `Compiler/MonoSolver/Translate.elm` 1940-1972, 3815-3824, 3864-3871, 4330-4360,
4691-4732, 4826-4832, 5164-5170, 5259-5295, 5360-5366, 5960-6016, `Compiler/MonoSolver/LssInfer.elm`
828-845, 1060-1075, 1114-1130, 1162-1176, 1645-1652, 1840-1856, 1898-1915, 1930-1958, 2015-2030,
2586-2600, 2905-2932, 3015-3030, 3128-3142, 3322-3336, `Compiler/MonoSolver/Monomorphize.elm` 140-156,
1238-1258, 3893-3908, 3952-3972, 4268-4290, 4685-4712, 4728-4770, plus every `grep` cited inline.
Kernel side: `eco-kernel-cpp/src/Eco/MVar.elm`, `src/Eco/Kernel/MVar.js`, `src/eco/MVar.{hpp,cpp}`,
`src/eco/MVarExports.cpp`, `src/eco/RuntimeExports.cpp` 20-55, `src/eco/KernelExports.h` 200-250,
`eco-kernel-cpp/CMakeLists.txt` 158-270, `compiler/src-xhr/Eco/MVar.elm`, `compiler/CMakeLists.txt`
100-130, 195-215, 240-300, 748-850, 1040-1060, `runtime/src/allocator/RootSet.hpp` 80-110,
`runtime/src/allocator/RuntimeExports.cpp` 4380-4415 (the HEAP_040 scratch-stack scanner),
`runtime/src/codegen/ecoc.cpp` 340-356, `runtime/src/codegen/EcoOps.cpp` 970-990,
`Compiler/Generate/MLIR/KernelAbi.elm` 1-420, `Compiler/GlobalOpt/KernelFacts.elm` 1-215,
`Compiler/GlobalOpt/CsePurity.elm` 88-96 and 276-284, `Compiler/GlobalOpt/CafHoist.elm` 395-410,
`Compiler/GlobalOpt/InlineSimplify.elm` 37, `Compiler/Type/KernelIntrinsics.elm` 1-140,
`test/eco-kernel/*`, `test/CMakeLists.txt` 130-225, `design_docs/invariants.csv` (HEAP_*, REP_*,
FORBID_*, KERN_006, LSS_004 rows).

Composition with the sibling specs (read): spec-F (step 8) adds `UF.peekS`/`rootQ`/`equivalentQ` and drops
`store` from `ZonkCtx` — every one of its sites is a READ and is unaffected by this step (a pure read on an
in-place store is the same call with no copy). spec-I (step 20) compares `Pt` indices — unaffected. spec-E
(step 10) makes every Step `S -> ( a, S )` and names exactly three `UnifyMismatch` recovery sites
(`unifyBestEffort`, `unifyStepBestEffort`, `classifyRef`) — those are precisely this step's rollback sites,
and the API below (`pushMark`/`rollback`/`commit`, handle-threaded) is what spec-E's `unifyBestEffortS`
must call (§4.6 gives the body in both the current `Result` shape and spec-E's shape).

---

</details>

### Step 20 (was 15). Point equality through the generic `==`

1. **Goal and expected effect**

`Vars.Point = Pt Int` (Vars.elm:48-49; `Variable = Point` :38-39) is a boxed single-field Custom, so
`point2 /= point1` in `reprS` (UnionFind.elm:171), `point1 == point2` in `unionS` (:250) and
`v1 == v2` in `equivalentS` (:286) lower through the `ValueEq` intrinsic (Point is `MCustom` ⇒
`boxedComparable`, Intrinsics.elm:818-837; `Intrinsics.elm:549/552` specialise only `MInt`/`MFloat`)
→ `__eco_value_eq` diamond (EcoBackend.cpp:1797-1815): pointer compare (fails: two `Pt` boxes),
constant-bit test (fails), then `Elm_Kernel_Utils_equal` → `eqHelp` → `resolveAndCompare`
(Utils.cpp:75-93, two resolves) → tag switch → unboxable-slot compare. Plan §1: `eqUnboxableSlot`
1.85 % self, plus the call chain. The `Pt n` payload is an UNBOXED Int field (only Int/Float/Char
are unboxed — REP invariants), so `case p of Pt n` is one field load. Compare the Ints.

Where the compares are: `reprS` :171 (once per Chain hop, i.e. per non-root read that reaches
`reprS`; `getS`/`setS`/`modifyS` :182-236 only fall into `reprS` for chains ≥ 2), `unionS` :250
(once per union, after two `reprS`), `equivalentS` :286 (per `equivalent` query — `repOrdinal`'s
O(n²) probes, plan §4 N15). Grep of `==`/`/=`/`List.member`/`Dict.member` on Point values across
`Compiler/Type`, `MonoSolver`, `Monomorphize`, `System/TypeCheck/IO.elm`: UnionFind.elm:171/250/286
are the only direct `==`; `Occurs.occursHelp` (Occurs.elm:44-45) does `List.member var seen` on
Variables (typechecker path — the FRONT-END window, 51 % of wall; same mechanism per element);
Store.elm:2092 and Unify.elm:1017-1022 already compare `IO.pointKey` Ints. `pointKey` twins exist at
IO.elm:491-493 and Engine.elm:2821-2823.

Expected: L-M (~1-2 % of the mono window per the plan; the three sites are on every `unionS`).
Wall down slightly; GC counters identical (no allocation change); RSS unchanged.

**Backend-intrinsic alternative, evaluated and rejected:** an `eco.value.eq` specialisation for
"single-ctor custom whose only field is unboxed" would need ctor-layout knowledge at the intrinsic
site (Intrinsics.elm sees only the argument `MonoType`s; ctor arity/unboxing lives in the registry),
a second shape for sites where aggregate promotion has already split the `Pt` into a loose scalar
(Expr.elm:1417-1425 declines `ValueEq` there), a codegen change affecting every program and the
bootstrap, and it pays only for newtype-like customs. The Elm rewrite is three expressions with no
backend risk. Do the Elm rewrite.

2. **Preconditions**

- None. Verify the site list is still exactly this before editing:
  `grep -n "==\|/=" compiler/src/Compiler/Type/UnionFind.elm` → :171, :250, :286 (verified);
  `grep -n "List.member\|Dict.member" compiler/src/Compiler/Type/Occurs.elm` → :45.

3. **Inventory of touched code**

| file | function (lines) | what changes |
|---|---|---|
| compiler/src/Compiler/Type/UnionFind.elm | `reprS` 160-178 | compare the two `Pt` refs (Ints) |
| compiler/src/Compiler/Type/UnionFind.elm | `unionS` 239-274 | `ref1 == ref2` (both already bound at :242-246) |
| compiler/src/Compiler/Type/UnionFind.elm | `equivalentS` 277-286 | destructure both reps, compare Ints |
| compiler/src/Compiler/Type/Occurs.elm (20b) | `occursHelp` 43-… | `seen : List Int` of `IO.pointKey`; `List.member` on Ints |
| compiler/tests/TestLogic/Type/UnionFindTest.elm (new) | — | pins semantics (see §6) |

Callers: none change signature (`reprS`/`unionS`/`equivalentS` keep their types; `occursHelp` is
internal to Occurs.elm — its `seen` type changes but `occurs` :38-40 passes `[]`).

4. **Design**

```elm
reprS : IO.State -> Vars.Point -> ( Vars.Point, IO.State )
reprS s ((Vars.Pt ref) as point) =
    case IORef.readPointCellS s ref of
        Vars.Root _ _ ->
            ( point, s )

        Vars.Chain ((Vars.Pt ref1) as point1) ->
            let
                ( ((Vars.Pt ref2) as point2), s1 ) =
                    reprS s point1
            in
            -- Int compare on the raw indices (step 20): `Pt` is a boxed
            -- single-Int ctor, so `/=` on Points went through Utils.equal.
            if ref2 /= ref1 then
                ( point2, IORef.writePointCellS ref (IORef.readPointCellS s1 ref1) s1 )

            else
                ( point2, s1 )
```

`unionS` :250: `if ref1 == ref2 then` (the `Pt ref1`/`Pt ref2` bindings at :242-246 already exist;
the LOAD-BEARING comment about self-union weight at :251-254 stays verbatim).

```elm
equivalentS : IO.State -> Vars.Point -> Vars.Point -> ( Bool, IO.State )
equivalentS s p1 p2 =
    let
        ( Vars.Pt r1, s1 ) =
            reprS s p1

        ( Vars.Pt r2, s2 ) =
            reprS s1 p2
    in
    ( r1 == r2, s2 )
```

20b (Occurs.elm:43-45): `occursHelp : List Int -> Vars.Variable -> Bool -> IO Bool`, test
`List.member (IO.pointKey var) seen`, and at the one extension site (`newSeen = var :: seen`,
Occurs.elm:65-68, `Vars.Structure` arm) cons `IO.pointKey var` with `newSeen : List Int`. `IO` is
already imported there.

Invariants/order: the union-find tree shape, weights, Point indices and path compression are
untouched — only the predicate's implementation changes (`Pt a == Pt b ⇔ a == b` by construction:
`Pt` is the only ctor). No mint-order effect.

5. **Edit sequence**

1. UnionFind.elm:160-178 `reprS`; `elm make`; run `elm-test-rs --filter Lss` (the three
   Monomorphize tests that import `UF`: LssDirectedFlowTest, LssHonestSourcesTest, LayoutQualTest).
2. `unionS` :250 and `equivalentS` :277-286; same check.
3. Add `compiler/tests/TestLogic/Type/UnionFindTest.elm` (below) — same edit as 2 so the pin lands with the change.
4. (20b) Occurs.elm `occursHelp`; run `--filter OccursCheck` (compiler/tests/TestLogic/Type/OccursCheckTest.elm exists).

6. **Verification**

- Unit: new `UnionFindTest.elm` driving the IO-monad wrappers (`UF.fresh`, `UF.union`,
  `UF.equivalent`, `UF.repr`) under `IO.unsafePerformIO` exactly as LssDirectedFlowTest.elm:48-62
  does (`UF.set … |> IO.andThen …`), or the direct-state twins (`freshS`/`unionS`/`reprS`/`equivalentS`)
  on the state that `IO.unsafePerformIO`'s runner threads; keys via `IO.pointKey`:
  (a) `a,b,c` fresh; `unionS a b`, `unionS b c` ⇒ `equivalentS a c == True`, `equivalentS a d == False`;
  (b) compression: chain `a→b→c` (build by unions with chosen weights), `reprS a` then a second
      `reprS a` returns the same key and the intermediate cell now points at the root (read via `UF.getS`
      / a second `reprS` of `b` giving the same key with no further write — compare states with `==`
      on `ioRefsPoint` before/after the second call if the record is comparable, else assert keys only);
  (c) the LOAD-BEARING self-union weight rule (UnionFind.elm:251-254): make `b` weight 2 (`unionS b c`),
      `a` weight 1, self-union `unionS a a d`, then `unionS a b d'` ⇒ `pointKey (reprS a) == pointKey b`
      (a is chained under the heavier b; a doubled weight would have made a the root).
- Suites: `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt`; then
  `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`.
- Byte identity expectation: the compiler's OUTPUT for any program other than itself is identical
  (the analysis is untouched); for the self-compile the workload changed, so use the loop's
  Phase 1.5 extra bootstrap turn and gate on B==C. Workload-diff check as in step 18a: identical
  spec sets; body diffs confined to `reprS`, `unionS`, `equivalentS` (and `occursHelp` for 20b) and
  the specs that inline them (the post-mono inliner does inline small callees — expect the diff to
  touch `getS`/`setS`/`modifyS` callers' specs too; anything OUTSIDE UnionFind/Occurs callers is a red flag).
- Attribution if needed: `perf report --no-children --sort symbol | grep -i "Utils_equal\|eqHelp\|eqUnboxableSlot"` before/after.

7. **Risks, gotchas, what NOT to do**

- `reprS` is recursive and the compare sits after the recursive call — keep the `as point2` alias
  so the returned Point is the callee's object (no re-boxing `Pt ref2`, which would allocate).
- Do not "simplify" `unionS`'s self-union arm to write `newWeight` — comment :251-254 is load-bearing.
- Do not replace `Point` by a bare `Int` alias (the plan's N17 notes the descriptor fields are
  shared with the typechecker; a representation change here is step 3's territory).
- 20b changes a typechecker file: the front-end window is not in the loop's judged window, but its
  wall is; it is still a source change ⇒ Phase 1.5 applies. Keep 20b as a separate entry if 20a's
  triple is wanted clean.
- `Occurs.elm:45` builds `seen` per recursion level; `List.member` on Ints is `eco.int.eq` per
  element — no allocation change.

8. **Effort:** S — three expressions plus a unit test; entries `20` (UnionFind) and optionally `20b` (Occurs).

<details><summary>Conventions used in this spec (from spec-I)</summary>

All line numbers verified against the tree on 2026-09-19 (HEAD, clean). None of the four steps
changes the LSS analysis; three of them (1, 14, 18b) are runtime/backend-only and are byte-identical
at the MLIR level by construction, two (18a, 20) change compiler SOURCE and therefore change the
workload (`out.mlir`) without changing the analysis — the loop's fixed-point rule (Phase 1.5:
A≠B is propagation, the gate is B==C) applies to those.

---

</details>

### Step 21 (was 19). `LssMemberTable`/`ItemAux` Int dicts → `Array`/`BitSet`

#### 1. Goal and expected effect

Replace the dense-Int-keyed `Dict Int _` tables of `LssMemberTable` and `LssStats.flexCtorSpecs`
by O(1)/O(log32) structures, and stop `processItem` from growing the never-populated
`dirtySpecs` BitSet per item. Attacks the per-zonk `provisionalStandalone` membership test
(one `Dict.member` per member per set zonk — 654,140 zonks × |members|, i.e. ~1M red-black
descents of ~13 Int compares each), the per-mint `specWidenedKeys`/`rootLamOf`/`lambdaQualified`
probes (83,233 mints × 3-4 Dict ops on 43K/12K/30K-entry dicts), the per-devirt / per-successor
`sources` probes, and `demandQualifiedFor`'s per-item member loop (§4 N6: 1-4M Int-dict ops).
Plan impact L (~1 % of the mono window). Loop stats: wall flat-to-down, minor GC down slightly
(Dict node garbage on inserts becomes Array path copies; net allocation is roughly neutral on the
insert side, the win is the read side). **Emission must stay byte-identical (BI):** nothing here
changes a member id, a mint ORDER, or a table's contents — only the container. The report's
`members:` line, `muTie:` line and `grounding:` line must also print identical numbers.

`ItemAux`: NO field is converted. `demandQualified : Dict Int Int` is keyed by
`qualifiedRawKey raw instTag` = `mixTag …` (Engine.elm:552-553, values up to 2^30 — NOT dense);
`arrowMemo` is per-item and tiny (plan §4 N3: a run-wide Array LOSES); `arrowOfSlot` is
report-gated. State this in the entry so nobody re-opens it.

`muTied` is NOT converted either: it is written only on a real μ-tie (`recordMuTied`, cold —
`muTied=0` on the self-compile), read by one `CoreDict.member` at the same site, `Dict.size` in
the report, and exported verbatim as `MonoGraph.lssBlockedMembers : Dict Int ()` which
`AbiCloning.abiCloningPass` (AbiCloning.elm:786-796) FOLDS over — `BitSet` has no iteration.
Converting it would touch 12 test fixtures for zero hot-path gain.

#### 2. Preconditions

- Plan step 13 is NOT required: `specWidenedKeys` is converted to `Array (Maybe String)` here;
  step 13 later narrows the payload to `Int` (class id) — same index discipline. Do this step
  before or after 13; if after, the payload type in §4 is `Array Int` with `-1` = absent.
- Density of the two id ranges (proved in §4) — verify on any report run:
  `ECO_MONO_LSS_REPORT=1 … 2>&1 | grep -a "^members:"` prints
  `members: <total> total (<lambdas> source lambdas, <interned> interned)` with
  `total == lambdas + interned` (Monomorphize.elm:3687, 1424-1428). That equality IS the density
  statement (`nextMemberId == Dict.size lamLabels + Dict.size byKey`).
- `grep -rn "\.sources\b\|lambdaQualified\|provisionalStandalone\|specWidenedKeys\|rootLamOf\|flexCtorSpecs" compiler/src compiler/tests --include=*.elm` must list exactly the sites in §3 (re-run it before editing; the list below is from that grep today).

#### 3. Inventory of touched code

| file | function (lines) | what changes |
|---|---|---|
| Engine.elm | `LssMemberTable` alias (447-462) | field types per §4; add `base : Int`, `provisionalBits : BitSet` |
| Engine.elm | `emptyMemberTable` (495-496) | becomes `emptyMemberTableFrom 0`; new `emptyMemberTableFrom : Int -> LssMemberTable` |
| Engine.elm | `insertMemberKey` (499-501) | unchanged (byKey stays a `Dict String Int` until step 13) |
| Engine.elm | `insertMemberGlobal` (504-506), `insertMemberKernel` (509-511) | `sources` write via `setSource` |
| Engine.elm | `insertMemberProvisional` (514-516) | writes Dict AND `provisionalBits` |
| Engine.elm | `LssStats.flexCtorSpecs` (146), `emptyLssStats` (521) | `Dict Int ()` → `BitSet` |
| Engine.elm | `instanceQualTagFor` (607-613) | `rootLamOf` read at 610 |
| Engine.elm | `lambdaMemberLayoutQualified` (727-758) | `specWidenedKeys` read (733), `rootLamOf` read (745) |
| Engine.elm | `layoutQualKey` (774-780) | first param `Array (Maybe String)`; exported pin used by LayoutQualTest |
| Engine.elm | `mintLayoutQualifiedFold` (786-806) | `sources` member test (797) |
| Engine.elm | `mintLayoutQualified` (816-888) | `lambdaQualified` get (827), member (884), insert (888) |
| Engine.elm | `recordSpecWidenedKey` (897-906) | Array write-once |
| Engine.elm | `markFlexCtorSpec` (1092-1098) | `BitSet.insertGrowing` |
| Engine.elm | `memberClassOf` (1189-1207) | `sources` get (1191) |
| Engine.elm | `papMemberIdFor` (1810-1826) | `sources` member (1818) + write (1826) |
| Engine.elm | `standaloneMemberIdFor` (1836-1847) | `sources` member (1843) |
| Engine.elm | `standaloneMemberGlobal` (1853-1862) | `sources` get (1856) |
| Engine.elm | `groundStandaloneMemberIdFor` (1874-1883) | via `insertMemberGlobal` — no edit |
| Engine.elm | `groundSetMembers` (1917-1975) | membership tests at 1919 and 1932 → `BitSet.member`; payload get at 1951 stays `CoreDict.get` |
| Engine.elm | `kernelMemberIdFor` (1998-2010), `standaloneMemberKernel` (2015-2025) | `sources` member (2005) / get (2018) |
| Engine.elm | new `arraySetGrowing`, `sourceOf`, `setSource`, `isProvisional`, `specWidenedKeyOf`, `rootLamGlobalOf`, `lambdaQualifiedOf` | accessors (§4) |
| Monomorphize.elm | `initState` (3855-3911) | `lssMemberTable = Engine.emptyMemberTableFrom (Id.toComparable mvarState.nextLam)` (3865); `nextMemberId` (3866) unchanged |
| Monomorphize.elm | `processItem` (4048-…) | `dirtySpecs` at 4088: guard the `removeGrowing` |
| Monomorphize.elm | `settleVarCtorRows` (464) | `Dict.member idx s.lssStats.flexCtorSpecs` → `BitSet.member` |
| Monomorphize.elm | `renderLssReport` (3729) | `Dict.size …lambdaQualified` → `Engine.lambdaQualifiedCount` (report only) |
| Monomorphize.elm | `demandQualifiedFor` (4381-4402) | `Dict.get mid …lambdaQualified` (4389) → accessor |
| Monomorphize.elm | `buildMemberOrigins` (4897-4940) | four `Dict.get mid table.sources` (4904, 4912, 4920, 4931) → `Engine.sourceOf` |
| Monomorphize.elm | `assembleRawGraph` (4889) | `lssBlockedMembers = s.lssMemberTable.muTied` — unchanged |
| Store.elm | `groundMembersC` (3329-3345) | no edit (calls `groundSetMembers`) |
| Store.elm | `ZonkCtx.memberTable`/`nextMemberId` (2223, 2387, 2396, 2403, 2485) | no edit (opaque threading) |
| LssInfer.elm | `injectLambdaMemberQualified` (172-215) | `rootLamOf` get at 199 → accessor |
| Translate.elm | `classifyLambdaHead` (1843) | `rootLamOf` insert → `Engine.setRootLam` |
| Translate.elm | `memberIdForDepth` (4665-4667) | no edit (`groundStandaloneMemberIdFor`) |
| tests/…/LssGroundingTest.elm | 68, 72, 141, 142 (`Dict.get … .sources` / `.provisionalStandalone`), `mintProvisional` 275-284 | use accessors / `insertMemberProvisional` |
| tests/…/LssHonestSourcesTest.elm | `gcMemberTable` 201-212 | `Engine.setSource 4 (SourceGlobal …) Engine.emptyMemberTable` |
| tests/…/LayoutQualTest.elm | 101, 105, 111, 115, 120 (`layoutQualKey (Dict.fromList …)`) | `Engine.specWidenedKeysFromList [ ( 7, "A(I->I)" ) ]` |
| tests/…/LssDirectedFlowTest.elm 189, LssHonestSourcesTest 320-330, LssGroundingTest 211/266 | `Engine.emptyMemberTable` with `nextMemberId = 0`/`100` | unchanged (base 0 fixtures) |
| tests/Compiler/Data/BitSetTest.elm | — | no change; no new BitSet API is needed |

`lssMemberOrigins`/`lssMemberKinds`/`lssBlockedMembers` consumers (AbiCloning, Borrow, MapTemplate,
MonoInlineSimplify, Prune, 10 test fixtures) are untouched: the `MonoGraph` record does not change.

#### 4. Design

**Density proof (the licence for index = id − base).**
- Source-lambda ids: `AssignMVarIds` starts at `TypeIds.firstSrcLambdaId = Id.first = Id 0`
  (TypeIds.elm:52-54, Id.elm:34-36) and every mint is `Id.succ` = `n + 1`
  (AssignMVarIds.elm:99, 129; `PreMono.Fresh` mints from the same state, Fresh.elm:38-40).
  So raw ids are exactly `0 .. nextLam-1`.
- Interned ids: `initState` seeds `nextMemberId = Id.toComparable mvarState.nextLam`
  (Monomorphize.elm:3866). The ONLY allocation is `internMemberKey` (Engine.elm:1760-1767):
  a miss returns `nextId` and bumps by exactly 1. Its callers are `memberIdFor` (1778-1787,
  writes `nextMemberId` back only when it grew) and `groundStandaloneMemberIdFor` (1874-1883),
  reached from `Translate.memberIdForDepth` (4665-4667, writes back) and from the zonk via
  `ZonkCtx.nextMemberId` (Store.elm 3333, written back at 2396/2403). `rezonkSettled`
  (Store.elm:2485-2505) discards its ctx's `nextMemberId` AND its `memberTable` together (the
  comment at 2504 says so), so no id it allocated is ever referenced. Hence live interned ids are
  exactly `nextLam .. nextMemberId-1`, contiguous. LSS_003 states the two supplies never collide.
- SpecIds: `Registry.getOrCreateSpecIdKeyed` allocates `registry.nextId` sequentially; spec ids
  are array indices (Prune.elm doc: "Spec ids are array INDICES and are never renumbered").

**New types (Engine.elm).**

```elm
type alias LssMemberTable =
    { byKey : CoreDict.Dict String Int                      -- unchanged until step 13
    , base : Int                                           -- first interned id (= nextLam at initState; 0 in fixtures)
    , sources : Array (Maybe MemberSource)                 -- index = mid - base   (was Dict Int MemberSource)
    , lambdaQualified : Array (Maybe ( Int, Int ))         -- index = mid - base   (was Dict Int ( Int, Int ))
    , muTied : CoreDict.Dict Int ()                        -- UNCHANGED (see §1)
    , provisionalStandalone : CoreDict.Dict Int TOpt.Global -- UNCHANGED payload (slow path only)
    , provisionalBits : BitSet                             -- NEW membership twin, absolute mid
    , specWidenedKeys : Array (Maybe String)               -- index = SpecId       (was Dict Int String)
    , rootLamOf : Array (Maybe TOpt.Global)                -- index = raw SrcLambdaId, pre-sized to base
    }

emptyMemberTableFrom : Int -> LssMemberTable
emptyMemberTableFrom base =
    { byKey = CoreDict.empty, base = base, sources = Array.empty, lambdaQualified = Array.empty
    , muTied = CoreDict.empty, provisionalStandalone = CoreDict.empty, provisionalBits = BitSet.empty
    , specWidenedKeys = Array.empty, rootLamOf = Array.repeat base Nothing }

emptyMemberTable : LssMemberTable
emptyMemberTable = emptyMemberTableFrom 0

-- Same shape as Monomorphize.arraySetGrowing (5063-5072) but with the sequential-append
-- fast path: ids arrive as base, base+1, … so index == length is the common case.
arraySetGrowing : Int -> Maybe a -> Array (Maybe a) -> Array (Maybe a)
arraySetGrowing index value arr =
    let len = Array.length arr in
    if index < len then Array.set index value arr
    else if index == len then Array.push value arr
    else Array.set index value (Array.append arr (Array.repeat (index - len + 1) Nothing))

sourceOf : Int -> LssMemberTable -> Maybe MemberSource
sourceOf mid t =
    if mid < t.base then Nothing else Maybe.andThen identity (Array.get (mid - t.base) t.sources)

setSource : Int -> MemberSource -> LssMemberTable -> LssMemberTable
setSource mid src t = { t | sources = arraySetGrowing (mid - t.base) (Just src) t.sources }
-- (fixtures insert id 4 into a base-0 table: index 4 pads to length 5 — fine.)

isProvisional : Int -> LssMemberTable -> Bool
isProvisional mid t = BitSet.member mid t.provisionalBits

insertMemberProvisional : Int -> TOpt.Global -> LssMemberTable -> LssMemberTable
insertMemberProvisional mid g t =
    { t | provisionalStandalone = CoreDict.insert mid g t.provisionalStandalone
        , provisionalBits = BitSet.insertGrowing mid t.provisionalBits }

specWidenedKeyOf : Int -> Array (Maybe String) -> Maybe String
specWidenedKeyOf specId keys = Maybe.andThen identity (Array.get specId keys)

rootLamGlobalOf : Int -> LssMemberTable -> Maybe TOpt.Global
rootLamGlobalOf raw t = Maybe.andThen identity (Array.get raw t.rootLamOf)

setRootLam : Int -> TOpt.Global -> LssMemberTable -> LssMemberTable
setRootLam raw g t = { t | rootLamOf = arraySetGrowing raw (Just g) t.rootLamOf }

lambdaQualifiedOf : Int -> LssMemberTable -> Maybe ( Int, Int )
lambdaQualifiedOf mid t =
    if mid < t.base then Nothing else Maybe.andThen identity (Array.get (mid - t.base) t.lambdaQualified)

specWidenedKeysFromList : List ( Int, String ) -> Array (Maybe String)   -- test convenience
specWidenedKeysFromList = List.foldl (\( i, k ) a -> arraySetGrowing i (Just k) a) Array.empty
```

`layoutQualKey : Array (Maybe String) -> Int -> Int -> Int -> ( String, Bool )` — body unchanged
except `case specWidenedKeyOf specId specWidenedKeys of`.

`recordSpecWidenedKey specId wkey s`: `case specWidenedKeyOf specId table.specWidenedKeys of
Just _ -> s; Nothing -> { s | lssMemberTable = { table | specWidenedKeys = arraySetGrowing
specId (Just wkey) table.specWidenedKeys } }` — keeps the "only write back when it grew" rule
the doc at 897-900 states.

`mintLayoutQualified` (827/884/888): one `lambdaQualifiedOf mid table` read serves BOTH the
`sharedInc` census and the first-mint-wins test (today it is a `get` then a `member` on the
same key); insert via `arraySetGrowing (mid - table.base) (Just ( qualifiedRawKey raw instTag,
specId ))`.

`groundSetMembers` (1919, 1932): `CoreDict.member mid table0.provisionalStandalone` →
`isProvisional mid table0`. Line 1951 keeps `CoreDict.get mid acc.table.provisionalStandalone`
(needs the Global; runs only on the slow path). Grounded ids are never inserted into either
structure (1874-1883 writes `sources` only) — LSS_019 idempotence preserved.

`LssStats.flexCtorSpecs : BitSet`; `markFlexCtorSpec` → `BitSet.insertGrowing specId`;
Monomorphize.elm:464 → `BitSet.member idx s.lssStats.flexCtorSpecs`. `LssStats` keeps 32 fields
(counted: 32 today), so the slot-cap comment stays true.

`processItem` (Monomorphize.elm:4088):
```elm
, dirtySpecs =
    if BitSet.member specId s.dirtySpecs then BitSet.remove specId s.dirtySpecs else s.dirtySpecs
```
(`removeGrowing` on a never-populated set pads the word array and path-copies it once per item
— 42,955 times for nothing; `remove` on a member is in range by construction.)

`renderLssReport` 3729: `Dict.size sFinal.lssMemberTable.lambdaQualified` →
`Array.foldl (\e n -> if e == Nothing then n else n + 1) 0 sFinal.lssMemberTable.lambdaQualified`
(report only; prints the same number).

**Order-of-evaluation constraints:** none introduced. Every mint site keeps the same
`internMemberKey` call in the same place; the arrays are written exactly where the dicts were
written. `sources`, `lambdaQualified`, `specWidenedKeys` and `rootLamOf` are all write-once per
index (guarded today by `member` tests — keep those guards, they now read the array).

**Invariants touched:** LSS_003 (member-id minting sites — unchanged; the density it implies is
what this step consumes), LSS_017/018/019/024 (name the tables by role, not by container —
no wording change needed). No HEAP/REP/CGEN invariant is involved (compile-time data only).

#### 5. Edit sequence

Each edit leaves `elm make compiler/src/Terminal/Main.elm` green.

1. Engine.elm: add `arraySetGrowing`, `emptyMemberTableFrom`, the accessors, and the two new
   fields (`base`, `provisionalBits`) to `LssMemberTable` — keep the old Dict fields for now.
   `emptyMemberTable = emptyMemberTableFrom 0`. Monomorphize.elm:3865 →
   `Engine.emptyMemberTableFrom (Id.toComparable mvarState.nextLam)`. Export the new names.
2. `flexCtorSpecs` → `BitSet` (Engine 146, 521, 1092-1098; Monomorphize 464). Grep tests for
   `flexCtorSpecs` first (none read it directly today).
3. `processItem` `dirtySpecs` guard (Monomorphize 4088).
4. `provisionalBits`: `insertMemberProvisional` writes both; `groundSetMembers` 1919/1932 →
   `isProvisional`. LssGroundingTest `mintProvisional` (275-284) → call
   `Engine.insertMemberProvisional mid g (Engine.setSource mid (SourceGlobal g) table1)` instead
   of the record update; line 72 → `Expect.equal False (Engine.isProvisional n1 r.table)`.
5. `specWidenedKeys` → Array: `layoutQualKey` signature, 733, 897-906; LayoutQualTest 101, 105,
   111, 115, 120 → `Engine.specWidenedKeysFromList [ ( 7, "A(I->I)" ) ]` (same edit).
6. `rootLamOf` → Array: Engine 610, 745 (`rootLamGlobalOf raw s0.lssMemberTable`), LssInfer 199,
   Translate 1843 (`Engine.setRootLam (Engine.srcLambdaKey lamId) g tbl`).
7. `lambdaQualified` → Array: Engine 827/884/888, Monomorphize 3729, 4389.
8. `sources` → Array: Engine 506, 511, 797, 1191, 1818/1826, 1843, 1856, 2005, 2018;
   Monomorphize 4904/4912/4920/4931; tests LssGroundingTest 68, 141, 142 →
   `Engine.sourceOf n1 r.table`; LssHonestSourcesTest 201-212 →
   `Engine.setSource 4 (Engine.SourceGlobal …) Engine.emptyMemberTable`.
9. Delete the now-unused `insertMemberProvisional`-style record updates in tests; run the unit
   suite.

Loop entries: `21a` = edits 1-4 (BitSets + guard; the hot zonk read), `21b` = edits 5-8 (Arrays).

#### 6. Verification

- Unit: `cmake --build build --target elm-tests`; the pins that exercise these tables are
  `LssGroundingTest` (pure `groundSetMembers` + pipeline), `LssHonestSourcesTest`,
  `LssDirectedFlowTest`, `LayoutQualTest`, `MuTieTest`, `LssVarCtorRowsTest` (flexCtorSpecs
  gate), `BitSetTest`.
- BI: loop Phase 2 `cmp` (three runs identical AND equal to `bin/ecoN.mlir`).
- Report equality (separate untimed leg, `ECO_MONO_LSS_REPORT=1`): the `members:`, `muTie:`,
  `grounding:`, `layoutQual:` lines must be identical to the reference's — they prove the tables
  hold the same contents.
- Loop triple per benchmarks/lss-compile-opt-loop.md §2; expect wall flat/−, minor GC −.

#### 7. Risks, gotchas, and what NOT to do

- `S` is at the 32-slot cap (Engine.elm:1302 doc) — do NOT add fields to `S`; the two new
  fields go on `LssMemberTable` (7 → 9 fields, far from the cap). `LssStats` is AT 32 — the
  `flexCtorSpecs` change replaces a field, it does not add one.
- `BitSet.member` on an index ≥ `size` returns False (BitSet.elm:60-69) — correct for
  "not provisional"; do not pre-size with `fromSize` (the member count is unknown up front and
  `insertGrowing` amortises by 64 bits).
- `Array.get` on a never-written index of a growing array returns `Nothing` — every accessor
  wraps with `Maybe.andThen identity`; never `Array.get … |> Maybe.withDefault`.
- Fixtures build tables with ids 1-5000 on `emptyMemberTable` (base 0): `arraySetGrowing 5000`
  pads 5000 slots once — fine for tests, never happens in production (ids are sequential).
- Do NOT touch `byKey` (step 13), `muTied` (cold, iterated), `demandQualified` (not dense),
  `arrowMemo` (plan §4 N3), the set representation (N4), or the DFS visited sets (N5).
- Agent B's `lssMemberOrigins` → BitSet idea (findings-B F10) is wrong: it is a `Dict Int
  MemberOrigin` with a payload, iterated by `LssFacts.buildMemberTable` — leave it.

#### 8. Effort

S-M: mechanical container swap over ~35 sites + 4 test files; no algorithm changes. `21a`/`21b`
as above if two measured entries are wanted.

---

<details><summary>Conventions used in this spec (from spec-K)</summary>

All line numbers are as of the current tree (2026-09-19), verified by reading. "Mono" =
`Compiler.AST.Monomorphized`, "Engine" = `Compiler.MonoSolver.Engine`, "Translate" =
`Compiler.MonoSolver.Translate`, "Monomorphize" = `Compiler.MonoSolver.Monomorphize` (the solver
driver, NOT `Compiler.Monomorphize.Monomorphize`). Multiplicities are the plan §1 / brief-common
figures: 654,140 set zonks, 83,233 layout-qualified lambda mints, 62,647 interned member strings,
74,837 members (so `nextLam` = 12,190 source lambdas), ~43K specs, 42,955 items, 46.6K
`joinAnnotationsChanged` calls, 31,797 completion joins.

---

</details>

### Step 22 (was 20). `specializeLambda`/`classifyLambdaHead` waste and non-canonical overlay/enrich rebuilds

#### 1. Goal and expected effect

Four sub-items, (a)-(d) as in the plan:
(a) `specializeLambda` (Translate 1660-1724) classifies every parameter type
(`Engine.traverse … classifyAs Mono.tkClassParam`, 1723) and then DISCARDS the result whenever
the peel of the head type succeeds (1675-1683: `monoParams` takes only the NAMES from
`classifiedParams`). (b) the lambda's member id is minted TWICE per lambda: once inside
`classifyLambdaHead` → `LssInfer.injectLambdaMemberQualified` (Translate 1857, LssInfer 172-215)
and again by `Engine.lambdaInstanceMemberMaybe` (Translate 1720) — each call runs
`instanceQualTagFor` + `layoutQualKey` (multi-KB string concat, Engine 774-780) + the
`rootLamOf` fold + a `byKey` probe (Engine 727-758) + `memberIdFor`; `lambdaMemberLayoutQualified`
is 2.75 % of the mono window, `classifyLambdaHead` 6.5 % inclusive. (c) the lss-on head builds
three trees (zonk 1861, classify 1877, overlay 1882). (d) `Mono.overlayAnnotations` (2526-2561)
and `enrichAnnotationsWith` (1543-1580) rebuild the WHOLE tree through the pure smart
constructors at every one of 13 overlay + 5 enrich sites, so the node/binder types they produce
are never pointer-identical to the canonical (K6) nodes — every later `==`, `eqKeySpec`,
`Intern.probe` and `Registry.elm:147 storedType == storeType` loses the pointer short-circuit
and walks; both also allocate `Dict.keys a == Dict.keys b` per record node (1566, 2547; and
2229, 2325 in the join family). `joinAnnotationsChanged` (2277-2353) has no `a == b` entry test
and `joinListChanged` (2373-2393) conses every element even when nothing changed.

Expected: minor GC down (fewer rebuilt trees, fewer key strings), wall down ~1-2 % of the mono
window. **BI: yes for all four** — (a) and (b) are argued exactly in §4; (c)/(d) return
structurally identical trees. The REPORT changes for (a)/(b) (fewer zonks and mints are
counted): see §6.

#### 2. Preconditions

- No plan-step dependency for (a), (c), (d). (b) is specified here WITHOUT step 13 (return the
  id from the first mint instead of re-deriving it); step 13 makes the remaining single build
  cheap.
- Verify the two-mint claim with a report run: `layoutQual: mints=<n>` (Monomorphize 3741) is
  today ≈ 2 × the number of translated lambda instances; after (b) it halves.
- Verify the site list: `grep -n "Mono.overlayAnnotations\|Mono.enrichAnnotations\b\|Mono.enrichAnnotationsTopOnly\|joinAnnotationsChanged" compiler/src/Compiler/MonoSolver/*.elm compiler/src/Compiler/Monomorphize/Registry.elm` — must match §3.

#### 3. Inventory of touched code

| file | function (lines) | what changes |
|---|---|---|
| Translate.elm | `specializeLambda` (1660-1724) | (a) classify params only when the peel is short; (b) take the member from `classifyLambdaHead`; drop `lambdaInstanceMemberMaybe` |
| Translate.elm | `classifyLambdaHead` (1744-1893) | (b) returns `( MonoType, Maybe Int )`; (c)/(d) 1882 → `Engine.overlayS` |
| LssInfer.elm | `injectLambdaMemberQualified` (172-215) | returns `Step (Maybe Int)` (the minted id) |
| Engine.elm | `lambdaInstanceMemberMaybe` (929-942) | delete (sole caller was Translate 1720) — or keep exported; no other callers |
| Mono (Monomorphized.elm) | `overlayAnnotations` (2526-2561) | reimplemented over a new `overlayAnnotationsWith` core (pointer-preserving, pluggable cons) |
| Mono | `enrichAnnotationsWith` (1543-1580), `enrichAnnotations` (1517-1519), `enrichAnnotationsTopOnly` (1522-1540) | same, over `enrichAnnotationsWithC` |
| Mono | `joinAnnotationsChanged` (2277-2353) | entry `a == b` fast path; `sameFieldKeys` at 2325 |
| Mono | `joinListChanged`/`Help` (2373-2393) | allocation-free when unchanged |
| Mono | `joinAnnotations` (2208-2247) | `Dict.keys` at 2229 → `sameFieldKeys` (no external caller — grep — optional) |
| Mono | new `sameFieldKeys` next to `eqFieldsBy` (677-692) | allocation-free key-set equality |
| Engine.elm | new `overlayS`, `enrichS`, `enrichTopOnlyS : MonoType -> MonoType -> S -> ( MonoType, S )` | the S-threaded, `consS`-canonicalising entry points |
| Translate.elm | overlay sites 702, 1517, 1531, 1882, 2882, 5434, 5682, 5827, 5834 | → `Engine.overlayS` where `S` is in hand (all nine) |
| Translate.elm | overlay sites 6949, 7104 (`olmExpr`/`olmChain`, pure) | → `Mono.overlayAnnotationsChanged`; use the Bool for the `Nothing` return |
| Translate.elm | enrich sites 7624 (`ctorFieldUnion` fold, `s` read-only), 7874 (destructor, `sD` in hand) | 7874 → `Engine.enrichS`; 7624 keeps `Mono.enrichAnnotations` (now pointer-preserving) |
| Monomorphize.elm | enrich sites 265 (settleCtorRows union), 2199 (varfix census), 3419 (census) | keep `Mono.enrichAnnotations` (pointer-preserving via the core) |
| Registry.elm | 157 `joinAnnotationsChanged` | no edit (benefits) |
| Monomorphize.elm | 4209 completion join | no edit (benefits from the entry fast path) |
| Closure.elm | `computeClosureCaptures` (143-193) | NOT touched (plan §4 N10: 0.18 %) |

#### 4. Design

**(a) Skip the discarded parameter classify.** New `specializeLambda` body (only the shape;
the inner `Engine.andThen` nest for `allocLambdaId`/body/`MonoClosure` is unchanged):

```elm
specializeLambda srcLam params body canType =
    let
        arity = List.length params
    in
    Engine.andThen
        (\( monoType0, maybeMember ) ->
            let
                peeled = extractFieldTypes arity monoType0          -- Translate 1621-1631
            in
            Engine.andThen
                (\monoParams -> … as today from `Engine.andThen (\lambdaId -> …) allocLambdaId`,
                                 with `lssMember = maybeMember` …)
                (if List.length peeled == arity then
                    \s -> Ok ( List.map2 (\( nm, _ ) pt -> ( nm, pt )) params peeled, s )
                 else
                    Engine.traverse
                        (\( name, paramCanType ) -> Engine.map (\mt -> ( name, mt )) (classifyAs Mono.tkClassParam paramCanType))
                        params)
        )
        (Engine.andThen (\_ -> classifyLambdaHead arity srcLam canType) (m2ShapeCensus params body))
```

Why this is BI — the discarded classify's side effects, one by one (all run against the SAME
`S` the head classify ran against, because `classifyLambdaHead` ends with
`classifyAs Mono.tkClassLambda canType s3` at 1877 and nothing touches the store between 1882
and 1723):
- MONO_029 read logs. `Store.classifyGo`'s TVar arm (Store.elm:3535-3557) appends to
  `itemAux.ecoResidualKeyReads` on a memo MISS and calls `zonkToMono pt` on a memo HIT (which
  appends canonical-backed vars to `ecoReads` → `ecoResidualReads`, Store 2743-2753). The
  head classify already visited every parameter subtree (the params are the `from` positions of
  the same `Can.TLambda` chain), so every key/point the param classify would log is ALREADY in
  the list. The consumer `staleResidualRead` (Monomorphize 4732-4744) is `List.any` over both
  lists — SET semantics; duplicates change nothing. That is the "list-vs-set" point.
- Residual ids. `residualIdC` (Store 2757-2766) returns the CANONICAL `MVarId` for any var
  with a `revMemo` entry and mints from `c.next` only for unrecorded vars; a memo'd param var is
  canonical-backed, and any per-call instantiation var inside it was already numbered by the
  head zonk of the same store — re-zonking allocates the same way twice today, i.e. the second
  allocation is garbage that no emitted type references (the classified params are dropped).
  The `nextMVarId` counter therefore ends LOWER after (a); MVar ids never reach emission
  (`MVar _ CEcoValue` lowers to `!eco.value`; keys merge MVar ids — `leafKeyTag`,
  Monomorphized 610-616; `Registry.elm:147`'s `==` compares whole trees and the dropped ids
  never appear in a stored type).
- Grounding mints (`groundSetMembers` via the memo-hit zonk): interning is idempotent and the
  head zonk grounded the same slots first — hits only.
- Intern table. The param classify stamps `LTop tkClassParam` on arrows inside param types;
  the head classify stamped `tkClassLambda`. `Intern.eqExact` is `==` and `LTop k` compares `k`,
  so those are DISTINCT entries that the param classify inserts and later sites (e.g. Translate
  1531, the let-params site, also `tkClassParam`) would hit. After (a) they are inserted by the
  first such later site instead. Nothing iterates `S.intern` (`Intern.size` is its only reader:
  Engine 2781, Store 2255 — growth tests), so canonical-object identity is invisible to
  emission. The `Intern.size` census number changes (report only).
- `lssStats` counters (`setsZonked`, `sizeHist`, zonkLog under report) — report only.
The peel fails only when `monoType0` is not an arrow chain with ≥ `arity` parameter positions
(an erased head); that arm keeps today's classify verbatim.

**(b) One mint per lambda.**
- `LssInfer.injectLambdaMemberQualified : Int -> Maybe SrcLambdaId -> Variable -> Step (Maybe Int)`:
  `Nothing` srcLam → `Ok ( Nothing, s0 )`; the `Just lamId` arm ends with `Ok ( Just mid, sN )`
  in both the root-folded and the plain branch (it already has `mid` in scope at 179).
- `classifyLambdaHead : Int -> Maybe SrcLambdaId -> Can.Type -> Step ( MonoType, Maybe Int )`:
  lss-on arm threads the `Maybe Int` from the injection (1857) to the return at 1882
  (`Ok ( ( overlaid, maybeMid ), s5 )`); lss-off arm returns `( classified, Nothing )` — exactly
  what `lambdaInstanceMemberMaybe` returns when lss is off (Engine 929-942), so
  `ClosureInfo.lssMember` is unchanged in both regimes.
- `specializeLambda` uses that `maybeMember` (see the sketch) and stops calling
  `Engine.lambdaInstanceMemberMaybe`. Delete it (Engine 929-942 + the export at line 8).
- Exactness: the second call today is state-idempotent — `memberIdFor` hits (key equal),
  `mintLayoutQualified` inserts `lambdaQualified` only if absent (884), `mintLayoutQualifiedFold`
  inserts `sources` only if absent (797), the μ-tie arm returns the same `tiedId` and
  `recordMuTied` is idempotent (912-922), `instanceQualTagFor` reads only. The ONLY state it
  changes is census (`layoutQual.mints/shared/fallback/tieBypass/instApplied/instRootSkip`,
  `rootFold|folded`, `unqualifiedLambdaMints`). LSS_017's "stamped IDENTICALLY in its set
  injection and its `ClosureInfo.lssMember`" holds by construction now (one id, one source).

**(c) The three-tree head.** A lambda head is always an arrow, so the plan-9-style
ground/arrow-free shortcut never applies here; `classified` (byte-path ABI structure, the guard
documented at Mono 2505-2525) and `zonked` (annotations) are both required. What (c) buys is
entirely through (d): `Engine.overlayS classified zonked s4` returns `classified` by pointer for
every subtree whose annotations the zonk did not change and canonicalises the rebuilt spine —
the "third tree" becomes a spine over shared, canonical children instead of a full copy.

**(d) Pointer-preserving, canonicalising overlay/enrich; join fixes.**

Mono cannot import `Intern` (Intern imports Mono), and `Engine.consS : MonoType -> S ->
( MonoType, S )` (Engine 2753-2758) is exactly a "cons" of the right shape — so the core is
written ONCE in Mono, parameterised by the cons function and its accumulator; the pure entry
points pass an identity cons with `()`, Engine passes `consS` with `S`.

```elm
-- Monomorphized.elm
{-| Allocation-free "same key set" — the `Dict.keys a == Dict.keys b` replacement.
Equal size + every key of a present in b ⇒ equal key sets (unique keys). -}
sameFieldKeys : Dict Name a -> Dict Name b -> Bool
sameFieldKeys a b =
    Dict.size a == Dict.size b && Dict.foldl (\k _ ok -> ok && Dict.member k b) True a


{-| Structure from `structural`, annotations from `annoSource` where layouts agree pointwise —
exactly `overlayAnnotations`' result — but returns `( False, structural )` BY POINTER when the
result would equal `structural`, rebuilds only changed spines, and offers every REBUILT node to
`cons` (bottom-up, children first — `Intern.hashCons` considers only the top node). -}
overlayAnnotationsWith : (MonoType -> acc -> ( MonoType, acc )) -> MonoType -> MonoType -> acc -> ( Bool, MonoType, acc )
overlayAnnotationsWith cons structural annoSource acc0 =
    if structural == annoSource then
        -- O(1) on pointer identity; O(1) on a packed-hash mismatch (the leading Int differs);
        -- a full walk only for hash-equal distinct trees, where the walk is cheaper than a rebuild.
        ( False, structural, acc0 )
    else
        case ( structural, annoSource ) of
            ( MFunction _ annoA argsA retA, MFunction _ annoB argsB retB ) ->
                if List.length argsA == List.length argsB then
                    let
                        ( chArgs, args, acc1 ) = overlayListWith cons argsA argsB acc0
                        ( chRet, ret, acc2 ) = overlayAnnotationsWith cons retA retB acc1
                    in
                    if chArgs || chRet || annoA /= annoB then
                        let ( node, acc3 ) = cons (mFunction annoB args ret) acc2 in ( True, node, acc3 )
                    else
                        ( False, structural, acc2 )
                else
                    ( False, structural, acc0 )   -- today: `mFunction annoA argsA retA`, a copy of `structural`

            ( MList _ xa, MList _ xb ) ->
                case overlayAnnotationsWith cons xa xb acc0 of
                    ( True, x, acc1 ) -> let ( n, acc2 ) = cons (mList x) acc1 in ( True, n, acc2 )
                    ( False, _, acc1 ) -> ( False, structural, acc1 )

            ( MTuple _ xsa, MTuple _ xsb ) ->
                if List.length xsa == List.length xsb then
                    case overlayListWith cons xsa xsb acc0 of
                        ( True, xs, acc1 ) -> let ( n, acc2 ) = cons (mTuple xs) acc1 in ( True, n, acc2 )
                        ( False, _, acc1 ) -> ( False, structural, acc1 )
                else ( False, structural, acc0 )

            ( MRecord _ fieldsA, MRecord _ fieldsB ) ->
                if sameFieldKeys fieldsA fieldsB then
                    case overlayFieldsWith cons fieldsA fieldsB acc0 of        -- joinFieldsChanged pattern: fold changed values into fieldsA
                        ( True, fields, acc1 ) -> let ( n, acc2 ) = cons (mRecord fields) acc1 in ( True, n, acc2 )
                        ( False, _, acc1 ) -> ( False, structural, acc1 )
                else ( False, structural, acc0 )

            ( MCustom _ homeA nameA argsA, MCustom _ homeB nameB argsB ) ->
                if homeA == homeB && nameA == nameB && List.length argsA == List.length argsB then
                    case overlayListWith cons argsA argsB acc0 of
                        ( True, args, acc1 ) -> let ( n, acc2 ) = cons (mCustom homeA nameA args) acc1 in ( True, n, acc2 )
                        ( False, _, acc1 ) -> ( False, structural, acc1 )
                else ( False, structural, acc0 )

            _ ->
                ( False, structural, acc0 )


overlayListWith : (MonoType -> acc -> ( MonoType, acc )) -> List MonoType -> List MonoType -> acc -> ( Bool, List MonoType, acc )
overlayListWith cons xsA xsB acc0 =
    case ( xsA, xsB ) of
        ( x :: ra, y :: rb ) ->
            let
                ( c1, x1, acc1 ) = overlayAnnotationsWith cons x y acc0
                ( c2, rest, acc2 ) = overlayListWith cons ra rb acc1
            in
            if c1 || c2 then ( True, x1 :: rest, acc2 ) else ( False, xsA, acc2 )
        _ ->
            ( False, xsA, acc0 )   -- arity-bounded lists (plan §4 N9): direct recursion is fine


overlayAnnotationsChanged : MonoType -> MonoType -> ( Bool, MonoType )
overlayAnnotationsChanged a b =
    let ( ch, t, () ) = overlayAnnotationsWith (\t u -> ( t, u )) a b () in ( ch, t )

overlayAnnotations : MonoType -> MonoType -> MonoType      -- keeps its name and every caller
overlayAnnotations a b = Tuple.second (overlayAnnotationsChanged a b)
```

`enrichAnnotationsWithC : (LambdaSetAnno -> LambdaSetAnno -> LambdaSetAnno) -> (MonoType -> acc
-> ( MonoType, acc )) -> MonoType -> MonoType -> acc -> ( Bool, MonoType, acc )` is the same walk
with `let merged = merge annoA annoB in … if chArgs || chRet || merged /= annoA then cons
(mFunction merged args ret)`. The entry `structural == annoSource` fast path is valid for both
merges: `enrichAnno a a = a` in every arm (`LSet xs ∪ xs = xs` — `unionSortedInts` of equal
sorted lists; `LPartial` likewise; every other arm returns `a`), and the top-only merge returns
`a` for `LVar` and defers to `enrichAnno` otherwise. `enrichAnnotationsWith merge a b =
Tuple.second (enrichAnnotationsWithChanged merge a b)`; `enrichAnnotations`/
`enrichAnnotationsTopOnly` keep their definitions on top of it; add
`enrichAnnotationsTopOnlyChanged` (used by step 24).

```elm
-- Engine.elm
overlayS : Mono.MonoType -> Mono.MonoType -> S -> ( Mono.MonoType, S )
overlayS structural annoSource s =
    let ( _, t, s1 ) = Mono.overlayAnnotationsWith consS structural annoSource s in ( t, s1 )

enrichS : Mono.MonoType -> Mono.MonoType -> S -> ( Mono.MonoType, S )       -- merge = Mono.enrichAnno (export it)
enrichTopOnlyS : …                                                          -- merge = the top-only merge (export it as Mono.enrichAnnoTopOnly)
```
`consS` only writes `S` back when the table grew (`withIntern`, Engine 2779-2783), so a hit
costs no `S` copy. Canonicality argument: the unchanged subtrees returned by pointer are the
inputs' subtrees; at every S-threaded site both inputs come from `classifyAs`/`zonkToMono`/
`peelResultAnno` of canonical types (classifyGo and zonkFlatC hash-cons bottom-up), so the whole
result is canonical after the spine is consed bottom-up.

`joinAnnotationsChanged` (2277-2353): insert `if a == b then ( False, a ) else` before the
`case`; replace `Dict.keys fieldsA == Dict.keys fieldsB` (2325) with `sameFieldKeys`. New
`joinListChanged` — no accumulator, no reverse, allocates only when something changed:
```elm
joinListChanged xsA xsB =
    case ( xsA, xsB ) of
        ( x :: ra, y :: rb ) ->
            let ( c1, j ) = joinAnnotationsChanged x y
                ( c2, rest ) = joinListChanged ra rb
            in if c1 || c2 then ( True, j :: rest ) else ( False, xsA )
        _ -> ( False, xsA )
```
(Exactness law at 2258-2276 preserved: the flag is still exactly `result /= a`.)

**Site edits (Translate).** 702: `Engine.consS (Mono.overlayAnnotations monoType0 (Mono.mList …)) s3`
→ `Engine.overlayS monoType0 (Mono.mList (joinedElem first rest)) s3`. 1517/1531: thread —
`( funcType, s2b ) = Engine.overlayS classifiedType zonkedType s2`, then the per-param
`Engine.map (\mt -> ( name, Mono.overlayAnnotations mt peeledType )) (classifyAs …)` becomes
`Engine.andThen (\mt s -> let ( o, s1 ) = Engine.overlayS mt peeledType s in Ok ( ( name, o ), s1 )) (classifyAs …)`.
1882, 2882 (`s0` in hand), 5827/5834 (`s3`): same pattern. 5434 and 5682: `S` is in scope in
both enclosing functions (check the name of the threaded state at each — they are inside
`Step`-shaped bodies); if a site turns out to be in a pure helper, use
`Mono.overlayAnnotationsChanged` (value only) there. 6949/7104 (`olmExpr`, pure by design):
`case Mono.overlayAnnotationsChanged t src of ( False, _ ) -> Nothing; ( True, t1 ) -> Just (Mono.MonoVarLocal n t1)`
— returning `Nothing` when nothing changed is what `olmExpr`'s protocol means (6940-6942) and
is structurally identical to today's always-`Just` rebuild. 7874: `Engine.enrichS monoType0
(Mono.getMonoPathType monoPath) sD`.

**Order constraints.** (b) removes the second mint — no id is minted earlier or later than
today (the first mint is already inside `classifyLambdaHead`, before the params and the body).
(d) changes WHICH site first inserts a canonical node (a rebuilt spine is now consed at the
overlay site instead of at the next `classifyGo` that builds the same structure) — as with
(a), intern identity is not emission-visible.

**Invariants:** MONO_029 (the read-log argument above; the barrier's set semantics is what
makes (a) exact), LSS_017 (one member id for injection and `ClosureInfo.lssMember` — now by
construction), LSS_010 (`joinAnnotationsChanged` exactness law kept), MONO_003/REP_HEAP_001
untouched (overlay never changes structure — the ABI guard at Mono 2505-2525 still holds
because `structural`'s structure is returned unchanged in every arm).

#### 5. Edit sequence

1. Mono: add `sameFieldKeys`; edit `joinAnnotationsChanged` (entry test, 2325) and
   `joinListChanged`. Green; run `elm-tests` (JoinAnnotations pins live in the Monomorphize
   suites — `grep -rl joinAnnotationsChanged compiler/tests`).
2. Mono: add `overlayAnnotationsWith`/`overlayListWith`/`overlayFieldsWith`/
   `overlayAnnotationsChanged`, redefine `overlayAnnotations` over it. Green (callers unchanged).
3. Mono: same for enrich (`enrichAnnotationsWithC`, `…Changed`, `enrichAnnotationsTopOnlyChanged`);
   export `enrichAnno` and the top-only merge. Green.
4. Engine: `overlayS`, `enrichS`, `enrichTopOnlyS`; export. Green.
5. Translate: the nine S-threaded overlay sites + 7874; the two `olm` sites. Green.
6. LssInfer 172-215 return type; Translate `classifyLambdaHead` return type; `specializeLambda`
   takes the member from it; delete `Engine.lambdaInstanceMemberMaybe`. Green.
7. `specializeLambda`: (a) — the conditional classify. Green.

Loop entries: `22d` = edits 1-5 (the substrate), `22b` = edit 6, `22a` = edit 7. Measure `22a`
separately — it is the only one whose BI rests on a semantic argument rather than on
"structurally identical output".

#### 6. Verification

- Unit: `elm-tests`; specifically `LssLocalMultiEnrichTest` (the `olm` overlay), `LssDestrAnnoTest`,
  `LssLPartialTest` (enrich lattice), `LayoutQualTest`/`MuTieTest` (member ids), `LssLocalMultiUseInjectTest`.
- BI: loop `cmp` for each entry. For `22a` additionally run the 633-workload rail
  (`benchmarks/mlir-workload-rail.sh`): MLIR sha256 identical for every workload; the census
  diff is EXPECTED on `sets zonked`, the size histogram, `ledger … total=`, and (for `22b`)
  `layoutQual: mints=…` (halved), `instRootSkip`, `rootFold|folded`. Any diff on a `varsucc|`,
  `varctor|`, `varlam|`, `grounding:` or `members:` line is NOT expected and means a real change.
- Attribution leg (untimed, `ECO_INLINE_ALLOC=0` lowering): the Custom/Cons/Tuple deltas under
  `Mono.overlayAnnotations*`/`joinAnnotationsChanged` frames; and `grep -c` of
  `Intern_probe` samples in a short `perf` run before/after (fewer non-canonical rebuilds ⇒
  fewer probes reaching `eqHelp`).

#### 7. Risks, gotchas, and what NOT to do

- The overlay ABI guard (Mono 2505-2525, Translate 1868-1873, 1512-1515): the STRUCTURE must
  come from `structural` in every arm. The `Changed` core never takes structure from
  `annoSource` — keep it that way; in particular the arity-mismatch arm must return
  `structural`, not `annoSource`.
- `annoA /= annoB` must be exact `==` on `LambdaSetAnno` (kinds included), NOT `annoKeyEq`
  (kind-blind): today's overlay copies `annoB` verbatim, kind and all; a kind-blind test would
  keep `annoA`'s kind and change the `LTop Int` payload → different intern entries and a
  different `toComparableMonoType` only if the renderer prints kinds (it does not, but do not
  rely on it).
- Do NOT put the `Changed` core in Engine/Intern and leave a pure copy in Mono — one walk, two
  entry points (the `cons` parameter) is the whole point; two copies drift.
- The `structural == annoSource` entry test is cheap ONLY because the leading packed hash Int
  differs whenever annotations differ (K4); if a future change stops hashing annotations into
  the leading Int, the test degrades to a full walk — note it in the function doc.
- `olmExpr` returning `Nothing` more often is correct; do not "optimise" `olmChain`'s
  `memberType` (7104) the same way — it needs the type value, use `Tuple.second`.
- (a): keep the classify in the peel-failure arm; do not replace `extractFieldTypes` (1621-1631)
  — it handles multi-param arrows (`args ++ …`).
- `Closure.computeClosureCaptures` (three body walks): plan §4 N10 — leave it.
- `Engine.scoped`'s per-lambda `S` copy is step 10's business.

#### 8. Effort

S for (a)+(b) (two signature changes, ~40 lines); S-M for (d) (one ~120-line core + 12 site
edits + join fixes). Three loop entries as in §5.

---

<details><summary>Conventions used in this spec (from spec-K)</summary>

All line numbers are as of the current tree (2026-09-19), verified by reading. "Mono" =
`Compiler.AST.Monomorphized`, "Engine" = `Compiler.MonoSolver.Engine`, "Translate" =
`Compiler.MonoSolver.Translate`, "Monomorphize" = `Compiler.MonoSolver.Monomorphize` (the solver
driver, NOT `Compiler.Monomorphize.Monomorphize`). Multiplicities are the plan §1 / brief-common
figures: 654,140 set zonks, 83,233 layout-qualified lambda mints, 62,647 interned member strings,
74,837 members (so `nextLam` = 12,190 source lambdas), ~43K specs, 42,955 items, 46.6K
`joinAnnotationsChanged` calls, 31,797 completion joins.

---

</details>

### Step 23 (was 22). Kernel-boundary translation

#### 1. Goal and expected effect

Every translated kernel CALL (`translateKernelCall` TR:3712-3742 via `deriveKernelAbiTypeCall`
TR:3783-3788, the devirt path TR:2316) and every bare kernel REFERENCE (`deriveKernelAbiTypeRef`
TR:4910-4912 from the `VarKernel`/`VarDebug` arms TR:613-627) goes through
`deriveKernelAbiTypeWith` (TR:4915-5012), which today, per invocation:

- allocates three `Engine.andThen` closure layers plus `Engine.succeed` boxes (TR:4917-4921,
  4925, 4932);
- builds a `State.MVarEnv` via `currentMVarEnv` (TR:5393-5399, `Engine.getS` → `initMVarEnv`
  record) on EVERY path, although `KernelAbi.deriveKernelAbiMode` ignores its third argument
  (KA:93-94, `_`) and the env is consumed only by `canTypeToMonoType_preserveVars` in the
  `PreserveVars`-and-not-suffix-selecting branch (TR:4988) — and `KernelAbi` never reads
  `env.superVars` (grep is empty), only `nextId`;
- probes `KernelAbi.suffixSelectingKernels` (an `EverySet (List String)`, i.e. a `Dict` keyed by
  two-element string LISTS) TWICE (TR:4929, 4934) and `alwaysPolymorphicModules` once (KA:96),
  and `KernelSetFacts.factFor` (a `Dict (Name, Name)` over ~150 rows, KSF:656-658) once in
  `poisonKernelArrowsThen` (TR:5057) — plus once more in `recordRefusedLicense` under `report`
  (TR:2702);
- walks `hasAnyFreeVar` with `Dict.toList fields` per record node (KA:244);
- rebuilds the whole ABI `MonoType` in `remapEcoVarsFresh` (TR:1281-1379: a non-interning
  reconstruction through `Mono.mFunction/mCustom/mRecord/…`) even when the type has no
  `MVar _ CEcoValue` (TR:4970, 5001);
- bumps `widenedByKernel` (EN:948-954: `S` + `LssStats` copy, ungated) on every rowless or
  refused boundary, read only by the report line `Monomorphize.elm:3715`.

Plan impact L: expect minor GC down slightly (closures, env records, rebuilt ABI types, `S`
copies) and wall flat-to-down ≤ 1 %. **BI: yes** — every change is a pure refactor or elides a
computation whose result is discarded or structurally equal; `nextMVarId` advances identically
(`remapEcoVarsFresh` with zero eco vars returns `nextId0`).

#### 2. Preconditions

- Step 12 is listed as a dependency ("kernel-fact table keyed by an Int id"). Decision below: NOT
  needed. Kernels are `TOpt.VarKernel prefix home name` occurrences, not `TOpt.Global`s; step 12's
  `GlobalId` (minted from `env.toptNodes`) never covers them, and a dense kernel id would have to be
  stamped on the AST occurrence (`AssignMVarIds`) to avoid the string probe — a representation
  change out of scope. Step 23 therefore stands alone after step 7 (which may already have gated
  `bumpWidenedByKernel`; check `sed -n 948,955p Engine.elm` — if it already tests `report`,
  skip edit 5).
- Verify: `grep -n "^deriveKernelAbiTypeWith\|^poisonKernelArrowsThen\|^currentMVarEnv\|^remapEcoVarsFresh\|^monoTypeMentionsEco" TR` → 4915 5039 5393 1281 1971; `grep -n "^factFor\|^facts " KSF` → 656 716; `grep -n "^deriveKernelAbiMode" KA` → 93; callers of `deriveKernelAbiMode`: TR:4923, `Monomorphize/Specialize.elm:5454`, test `tests/TestLogic/Monomorphize/MonomorphizeTest.elm:136`.

#### 3. Inventory of touched code

| file | function (lines) | what changes |
|---|---|---|
| KSF | new `KernelInfo`, `kernelInfo` table, `kernelInfoFor` (after `factFor` 656-658) | one two-level `Dict Name (Dict Name KernelInfo)` fusing `facts` + `suffixSelectingKernels`; `factFor` kept as `.fact` of it (callers: LI:2097, TR:5057→removed, TR:2702, `Monomorphize.elm:3297, 4656`, `KernelLicenseTest.elm:120,133,363`) |
| KA | `deriveKernelAbiMode` 93-105 | drop the unused `MVarEnv` parameter: `( String, String ) -> Can.Type MVarId -> KernelAbiMode`; callers TR:4923, Specialize:5454, MonomorphizeTest:136 |
| KA | `hasAnyFreeVar` 226-256 | `TRecord` arm: `Dict.foldl` instead of `List.any … (Dict.toList fields)` |
| TR | `deriveKernelAbiTypeWith` 4915-5012 | direct state-passing; `kernelInfoFor` once; env built lazily in the one branch that uses it; `remapIfEco` guard at both remap sites |
| TR | `poisonKernelArrowsThen` 5039-5151 | takes the resolved `Maybe KernelSetFact` as a parameter instead of probing `factFor` (5057); `recordRefusedLicense` call (5051) likewise takes it |
| TR | `recordRefusedLicense` 2700-2723 | signature gains the fact; drops its own `factFor` |
| TR | `currentMVarEnv` 5393-5399 | deleted (sole caller was 5008) — or kept if any other caller appears (`grep -n currentMVarEnv TR` shows 5008 only) |
| TR | new `remapIfEco` (next to `remapEcoVarsFresh` 1281) | `if monoTypeMentionsEco t then remapEcoVarsFresh n t else ( t, n )` |
| EN | `bumpWidenedByKernel` 948-954 | report-gate (readers: report only — `Monomorphize.elm:3715`; other sites TR:1121 port poison, TR:5064/5082/5112/5143, LI:2185/2279 keep calling it) |
| tests | `MonomorphizeTest.elm:130-136` (`testDeriveAbiMode`) | drop the `env` argument |

Unchanged: `translateKernelCall`, `deriveKernelAbiTypeCall`, `deriveKernelAbiTypeRef`,
`poisonKernelPerParam` 5159-5189, `joinKernelTunnels` 5192-5207, `remapEcoVarsFresh` itself,
`KernelSetFacts.facts`/`rows`/`licensedFiles`, `LssInfer.kernelCallBoundary` (its one
`factFor` per kernel call per BODY is fine — plan §4 N19).

#### 4. Design

**Kernel-id keyed fact cache — the decision.** `(home, name)` is the only identity a kernel
occurrence carries. Options weighed: (a) step 12's `GlobalId` — does not apply (kernels are not
`Global`s); (b) a dense `KernelId` stamped on `TOpt.VarKernel` by `AssignMVarIds` — zero-probe
but changes a 5-field constructor matched in ~40 places in `MonoSolver` alone (not S); (c) a
`HashMap (Name, Name)` — hashes both strings per probe, no cheaper than the tuple `Dict`; (d) a
static two-level `Dict Name (Dict Name KernelInfo)` that fuses the FOUR probes made today
(`factFor`, `suffixSelectingKernels` ×2, `alwaysPolymorphicModules`) into ONE probe of ~5 short
`home` compares + ~3 `name` compares, allocation-free, no `S` field (32-slot cap untouched), no
`Env` change. **(d) is the design.** It lives in `KernelSetFacts` (which may import `KernelAbi`;
`KernelAbi` must not import `KernelSetFacts` — check `grep -n "^import" KA` shows no MonoSolver
import, so the direction is fine).

```elm
-- KernelSetFacts.elm (exposing kernelInfoFor, KernelInfo)

type alias KernelInfo =
    { fact : Maybe KernelSetFact
    , suffixSelecting : Bool -- KernelAbi.suffixSelectingKernels membership
    }


noKernelInfo : KernelInfo
noKernelInfo =
    { fact = Nothing, suffixSelecting = False }


{-| ONE probe per kernel occurrence in place of `factFor` + two `EverySet.member`s.
Keyed home-first because the ~20 distinct homes are short and mostly differ at the
first character; the second level is the handful of names under one home.
-}
kernelInfoFor : Name -> Name -> KernelInfo
kernelInfoFor home name =
    case Dict.get home kernelInfo of
        Nothing ->
            noKernelInfo

        Just byName ->
            Maybe.withDefault noKernelInfo (Dict.get name byName)


kernelInfo : Dict.Dict Name (Dict.Dict Name KernelInfo)
kernelInfo =
    let
        withFact ( ( home, name ), fact ) acc =
            upsert home name (\i -> { i | fact = Just fact }) acc

        withSuffix ( home, name ) acc =
            upsert home name (\i -> { i | suffixSelecting = True }) acc

        upsert home name f acc =
            Dict.update home
                (\m -> Just (Dict.update name (\mi -> Just (f (Maybe.withDefault noKernelInfo mi))) (Maybe.withDefault Dict.empty m)))
                acc
    in
    List.foldl withSuffix
        (List.foldl withFact Dict.empty (Dict.toList facts))
        (EverySet.toList (\a b -> compare (KernelAbi.comparePair a) (KernelAbi.comparePair b)) KernelAbi.suffixSelectingKernels)


factFor : Name -> Name -> Maybe KernelSetFact
factFor home name =
    (kernelInfoFor home name).fact
```

(`EverySet` is `Data.Set as EverySet` in `KernelAbi`; its `toList : (a -> a -> Order) ->
EverySet c a -> List a` (`Data/Set.elm:129`) takes the comparator, hence the `comparePair` lambda.
`KernelAbi` imports nothing from `MonoSolver` (KA:53-62), so `KernelSetFacts` importing
`Compiler.Monomorphize.KernelAbi` and `Data.Set as EverySet` creates no cycle.)

`alwaysPolymorphicModules` is one entry (`"Debug"`, KA:200-202); keep `deriveKernelAbiMode`'s
`EverySet.member` for it (single-element `Dict` probe) — or replace with `home == "Debug"`; either
is BI.

**`deriveKernelAbiMode` signature.** `( String, String ) -> Can.Type MVarId -> KernelAbiMode`
(drop the ignored env). Callers: TR (below), `Specialize.elm:5454`
(`KernelAbi.deriveKernelAbiMode kernelId canFuncType mvarEnv` → drop the last arg; it still has
`mvarEnv` in scope for `TypeSubst.applySubstPureRO`), `MonomorphizeTest.elm:136`.

**`deriveKernelAbiTypeWith`, direct-state, lazy env, guarded remap.** Ordering is preserved
exactly: `funcVarStep` → `poisonKernelArrowsThen` (the ordering note TR:5030-5035 — poison runs
AFTER the arg unification the step contains) → `zonkToMono` → mode → branch. `nextMVarId` is
read AFTER the zonk in both the old (`currentMVarEnv` ran last, TR:5008) and new code.

```elm
deriveKernelAbiTypeWith : ( String, String ) -> Can.Type TypeIds.MVarId -> Step Vars.Variable -> Step Mono.MonoType
deriveKernelAbiTypeWith (( kHome, kName ) as kernelId) canFuncType funcVarStep s0 =
    let
        info =
            KernelSetFacts.kernelInfoFor kHome kName
    in
    case funcVarStep s0 of
        Err e ->
            Err e

        Ok ( funcVar0, s1 ) ->
            case poisonKernelArrowsThen info.fact kernelId canFuncType funcVar0 s1 of
                Err e ->
                    Err e

                Ok ( funcVar, s2 ) ->
                    case Store.zonkToMono funcVar s2 of
                        Err e ->
                            Err e

                        Ok ( monoAfterSubst, s3 ) ->
                            case KernelAbi.deriveKernelAbiMode kernelId canFuncType of
                                KernelAbi.UseSubstitution ->
                                    Ok ( monoAfterSubst, s3 )

                                KernelAbi.PreserveVars ->
                                    if info.suffixSelecting then
                                        if not (Mono.containsAnyMVar monoAfterSubst) then
                                            Ok ( monoAfterSubst, s3 )

                                        else
                                            -- Store-truth branch (comment block TR:4935-4966 kept
                                            -- verbatim above this point).
                                            let
                                                ( abi2, nextId2 ) =
                                                    remapIfEco s3.nextMVarId monoAfterSubst
                                            in
                                            Ok ( abi2, { s3 | nextMVarId = nextId2 } )

                                    else
                                        -- Preserved-vars branch (comment TR:4975-4984 kept). The
                                        -- MVarEnv is built HERE, the only consumer; KernelAbi
                                        -- reads its nextId only (superVars unused — grep).
                                        let
                                            ( abiType, env1 ) =
                                                KernelAbi.canTypeToMonoType_preserveVars
                                                    (State.initMVarEnv s3.nextMVarId s3.env.superStatic)
                                                    canFuncType

                                            ( finalAbi, nextId2 ) =
                                                if kHome /= "Debug" then
                                                    remapIfEco env1.nextId abiType

                                                else
                                                    ( abiType, env1.nextId )
                                        in
                                        Ok ( finalAbi, { s3 | nextMVarId = nextId2 } )
```

```elm
{-| `remapEcoVarsFresh` rebuilds the WHOLE type through the non-interning `Mono.m*`
constructors (a fresh, non-canonical copy — every later `==` on it descends). With no
`MVar _ CEcoValue` the rebuild is the identity on structure and on `nextId`; return the
canonical input instead.
-}
remapIfEco : TypeIds.MVarId -> Mono.MonoType -> ( Mono.MonoType, TypeIds.MVarId )
remapIfEco nextId t =
    if monoTypeMentionsEco t then
        remapEcoVarsFresh nextId t

    else
        ( t, nextId )
```

BI argument for the guard: `remapEcoVarsFresh`'s `go` (TR:1284-1374) mints a fresh id ONLY in the
`MVar mid CEcoValue` arm (1286-1294); with none present `finalNext == nextId0` and `result` is
structurally equal to the input. Downstream consumers compare `MonoType`s structurally or hash
them by content (K4 packed hashes are recomputed by the `m*` constructors identically), so the
canonical pointer and the copy are indistinguishable in emission; the pointer is cheaper.

`poisonKernelArrowsThen`: signature becomes `Maybe KernelSetFacts.KernelSetFact -> ( String,
String ) -> Can.Type … -> Vars.Variable -> Step Vars.Variable`; line 5057's `case
KernelSetFacts.factFor kHome kName of` → `case fact of`; line 5051's `recordRefusedLicense (
kHome, kName ) canFuncType s0` → `recordRefusedLicense fact ( kHome, kName ) canFuncType s0`, and
`recordRefusedLicense` (2700-2723) matches on the passed fact instead of probing. All three arms'
bodies unchanged.

`hasAnyFreeVar` (KA:238-244): `Nothing -> Dict.foldl (\_ (Can.FieldType _ t) acc -> acc ||
hasAnyFreeVar t) False fields` — same truth value, no list.

`bumpWidenedByKernel` (EN:948-954): wrap in `if s.env.lss.report then … else s` with a doc line
naming the sole reader (`Monomorphize.renderLssReport`, `widened: … byKernel=`). The count under
report is unchanged (every caller still calls it), so the report and the rail census are
identical; report-off the `S` + `LssStats` copy disappears at TR:1121, 5064, 5082, 5112, 5143
and LI:2185, 2279. (If step 7 already moved this counter into a folded `ItemAux.counters`, leave
it.)

#### 5. Edit sequence

1. **KSF**: add `KernelInfo`, `noKernelInfo`, `kernelInfo`, `kernelInfoFor`; redefine `factFor`
   on top of it; export `KernelInfo`, `kernelInfoFor`. (`elm make` green; `KernelLicenseTest`
   unchanged — `rows`/`licensedFiles` still read `facts`.)
2. **KA**: drop `deriveKernelAbiMode`'s env parameter; fix `Specialize.elm:5454` and
   `MonomorphizeTest.elm:136` in the same edit; `hasAnyFreeVar` record arm.
3. **TR**: add `remapIfEco`; thread `fact` into `poisonKernelArrowsThen` and
   `recordRefusedLicense`; rewrite `deriveKernelAbiTypeWith` as above; delete `currentMVarEnv`
   (and its `State` import if now unused — `grep -n "State\." TR` first).
4. Type-check + `elm-tests`.
5. **EN**: report-gate `bumpWidenedByKernel` (skip if step 7 did).
6. Snapshot `try-23`.

#### 6. Verification

- Unit: `MonomorphizeTest` (`deriveKernelAbiMode` suite, line 212 on), `KernelLicenseTest` (rows,
  `factFor` miss = `Nothing` at :133, `licensedFiles` manifest coverage), `ConsNumberTaintTest`
  (the remap's raison d'être, named at TR:4939), `KernelIntrinsicsTest`; full `elm-tests` at the
  baseline. Also run `test/scripts/check-kernel-license-manifest.sh` (it harvests `facts`; the
  table itself is untouched).
- Add one unit pin: `kernelInfoFor` agrees with the two sources it fuses — for every `( h, n )`
  in `rows`, `.fact == Just fact`; for every element of `suffixSelectingKernels`,
  `.suffixSelecting == True`; and `kernelInfoFor "NoSuchHome" "x" == noKernelInfo`.
- E2E `--target full`; loop Phase 2 `cmp`s (BI); rail EMISSION 0 and CENSUS 0 diff lines (nothing
  report-visible changes: `widened: byKernel=` counts are preserved under report).
- Loop triple with `ARM=eco-opt23`. Expect minor GC down by a small amount; wall inside the noise
  band is acceptable under rule 2 if a counter improved.

#### 7. Risks, gotchas, what NOT to do

- **Ordering is load-bearing** (TR:5025-5035): `poisonKernelArrowsThen` must run after
  `funcVarStep` (which contains `unifyParamsWithArgExprs` on the call path) and before the zonk.
  The direct-state rewrite keeps that; do not hoist the poison.
- **Do not cache `licenseApplies`** per kernel: it is an OCCURRENCE check (LSS_022 — the type
  differs at every site); only the row lookup is per-kernel.
- **`suffixSelectingKernels` is load-bearing** (KA:114-142); fusing it into `kernelInfo` must
  derive from the same list, never a hand copy (hence the `toList`/shared-list note).
- `remapWanted` for `Debug` (TR:4996-4997) stays: Debug WANTS the taint.
- `Mono.containsAnyMVar` (any constraint) vs `monoTypeMentionsEco` (`CEcoValue` only) are
  different predicates; the guard uses the latter deliberately (a `CNumber`-only residual must
  not be remapped, exactly as today — the old code rebuilt it and changed nothing).
- The 32-slot `S` cap: nothing added to `S`; `kernelInfo` is a module-level constant.
- `TYPE_KERNEL_001` notes `(home,name)` collides on `File.size`; a license tolerates that and so
  does `kernelInfo` (same key as `facts`).
- Plan §4 N19: leave `LssInfer.kernelCallBoundary`'s `factFor` alone (once per body).
- `recordKernelMiss`/`recordKernelArityMiss` (TR:2679-2735) are on the DEVIRT path and belong to
  step 7 (F12), not here.

#### 8. Effort

**S**: ~120 lines across four files, one test-pin argument drop, one new unit pin; BI; a single
loop entry. If split: `23a` = `kernelInfoFor` + direct-state `deriveKernelAbiTypeWith` + lazy env
+ `remapIfEco`; `23b` = the `bumpWidenedByKernel` gate (or fold it into step 7 if that step is
still open).

<details><summary>Conventions used in this spec (from spec-J)</summary>

All line numbers are as of the loop's `base` tree (2026-09-19), verified by reading the code. File
abbreviations: `LI` = `/work/compiler/src/Compiler/MonoSolver/LssInfer.elm`, `EN` = `.../Engine.elm`,
`ST` = `.../Store.elm`, `TR` = `.../Translate.elm`, `KSF` = `.../KernelSetFacts.elm`,
`KA` = `/work/compiler/src/Compiler/Monomorphize/KernelAbi.elm`.

---

</details>

### Step 24 (was 21). Settle chain and post-drain walks

#### 1. Goal and expected effect

Plan §1: `settle*` 2.0 % inclusive, `pruneGraph` 2.1 %, `typeHasResidualNumber` 1.4 %
(0.7 % of it generic dispatch). Seven sub-items:
(i) the four whole-registry TYPE REBUILDS that write nothing — `settleVarCtorRows.rewriteWalk`
(Monomorphize 510-637) rebuilds every ctor row, `settleVarLambda.rewrite` (716-857) rebuilds
EVERY row, `varSuccRounds.succType` (1266-1370) rebuilds every row per round (×3 rounds ×2
invocations) — pre-scan `Mono.hasVarAnno` per row and return unchanged subtrees by pointer;
(ii) `varSuccRounds`' verification round is a provable no-op — one pass, with a report-gated
verification pass; (iii) `midKeys`/`compGlobals` (1190-1199: a 62,647-entry `byKey` inversion
plus a `toComparableGlobal` string per global, per round) replaced by a `sources` decode;
(iv) `varArgIds` (1066-1094) is dead — `varCellWalk` (1097-1151) never reads its `argIds`
parameter — delete; (v) the ctor-row sweeps probe `toptNodes` for EVERY registry row four times
(settleVarCtorRows 355-367 ×2 passes, settleCtorRows 222-234 ×2) and build `gkeyOf` strings
per row per pass — index the ctor rows once; (vi) `lambdaHomesOf` (890-1030) and
`assembleRawGraph`'s edge/effect fold (4824-4859) both walk every node — one fold;
(vii) Prune: `typeHasResidualNumber` (Mono 2723-2750) allocates a PAP per list-bearing node,
and `Analysis.collectAllCustomTypes` (326-360) probes the layout map once per `MCustom`
OCCURRENCE in every live node type (Analysis 61-93).

Expected: wall −1-1.5 % of the mono window, minor GC down (the settle rebuilds are ~4 registry
copies of ~43K types; Prune's PAPs are one per visited container node). **BI: yes** — every
change returns structurally identical registry types and an identical graph; §4 gives the
argument per item. The `varsucc|rounds` census value changes (report only).

Agent B's possible precision bug — `settleVarCtorRows.gkeyOf` (382-388) keys cells by ctor
NAME only, unlike its docstring and `settleCtorRows.gkeyOf` (243-249, full global) — is
OUTPUT-CHANGING and is NOT part of this step. The ctor-row index in (v) carries BOTH strings
so the two passes keep their current keys byte for byte; fixing the key is a separate,
analysis-changing entry with its own fixed-point run.

#### 2. Preconditions

- No plan-step dependency. (v)'s per-row `hasTopAnno`/enrich in `settleCtorRows` uses step 22's
  `enrichAnnotationsTopOnlyChanged` if it has landed; otherwise keep the `enriched == monoType`
  compare (it is one rebuild per ⊤-carrying ctor row, a minority).
- Confirm the round count on a report run: `grep -a "varsucc|rounds" <report>` = 3 today
  (2 from the first `settleVarSuccessors` invocation — one writing pass + one empty
  verification — and 1 from the second invocation).
- Confirm `varArgIds` is dead: `grep -n "argIds" compiler/src/Compiler/MonoSolver/Monomorphize.elm`
  shows it only as a pass-through parameter of `varCellWalk` (1097-1151) and the two
  `varArgIds` calls at 1000.

#### 3. Inventory of touched code

| file | function (lines) | what changes |
|---|---|---|
| Monomorphize.elm | driver (177-196) | build `ctorRows` + `graphFacts` once; pass to the sweeps and to `assembleRawGraphWith` |
| Monomorphize.elm | `settleCtorRows` (222-347) | takes `List CtorRow`; both passes iterate it |
| Monomorphize.elm | `settleVarCtorRows` (350-682) | takes `List CtorRow`; pass 1 iterates it; pass 2 pre-scan + unchanged-return `rewriteWalk` |
| Monomorphize.elm | `settleVarLambda` (685-887) | takes the precomputed `homes`; pass pre-scan + unchanged-return `rewrite` |
| Monomorphize.elm | `lambdaHomesOf` (890-912), `lambdaHomesExpr` (915-965), `lambdaHomeDeciderExprs` (972-985) | keep for the report-only m2 census (2864); production uses `graphFacts` |
| Monomorphize.elm | `recordLambdaHome` (988-1024) | drop the `varArgIds` calls (1000) |
| Monomorphize.elm | `varArgIds` (1066-1094) | delete |
| Monomorphize.elm | `varCellWalk` (1097-1151) | drop the dead first parameter |
| Monomorphize.elm | `settleVarSuccessors` (1178-1187), `varSuccRounds` (1190-1411) | single pass `varSuccPass`; report-gated verification; `sources` decode; pre-scan; unchanged-return `succType` |
| Monomorphize.elm | `assembleRawGraph` (4805-4895) | becomes `assembleRawGraphWith facts …`; the fold at 4824-4859 moves into `graphFacts` |
| Monomorphize.elm | new `graphFacts`, `CtorRow`, `ctorRowIndex` | §4 |
| Mono (Monomorphized.elm) | `typeHasResidualNumber` (2723-2750) | direct recursion helper `anyResidualNumber` |
| Analysis.elm | `collectCustomTypesFromMonoType` (61-93), `…FromPath` (98-114), `…FromExpr` (119-…), `…FromDecider`/`…FromDtPath` (…-321), `collectAllCustomTypes` (326-360), `computeCtorShapesForGraph` (554-587) | accumulator becomes `( LayoutMap (), SeenSet )`; composite-level seen memo |
| Prune.elm | `pruneUnreachableSpecs` (…) | no edit (benefits) |
| Engine.elm | — | `sourceOf` from step 21 (or `CoreDict.get m s.lssMemberTable.sources` if 21 has not landed) |

Test pins: `LssVarCtorRowsTest`, `LssVarLambdaTest`, `LssDestrAnnoTest`, `LssLPartialTest` drive the
whole pipeline (they do not call the sweeps directly — `grep -n "Monomorphize\.\|Engine\."` is
empty in both var tests); `LssVarLambdaTest` reads the `varlam|wrote` counter. No test reads
`varsucc|rounds`.

#### 4. Design

**(v) Ctor-row index, built once.**
```elm
type alias CtorRow = { idx : Int, name : Name, gkey : String, moduleName : String }
   -- name       = settleVarCtorRows.gkeyOf today (382-388)   — ctor NAME only (kept as-is, see §1)
   -- gkey       = settleCtorRows.gkeyOf today (243-249)      — Mono.toComparableGlobal
   -- moduleName = settleVarCtorRows.moduleOf today (390-396)

ctorRowIndex : S -> List CtorRow      -- ascending idx (Array.foldl order), the order both sweeps use today
```
One `Array.foldl` over `s.registry.reverseMapping` with the `toptNodes` probe (`TOpt.Ctor`/`Box`
— 355-367); accumulate by consing and `List.reverse` once. Both sweeps then `List.foldl` over
the index and re-read the CURRENT type with `Array.get row.idx reg.reverseMapping` (the type
changes between passes — never cache it). Ascending order is load-bearing for
`settleCtorRows` pass 1: `enrichAnno` is NOT symmetric in its `( LTop, LPartial )`/`( LPartial,
LTop )` arms (Mono 1583-1618), so the union fold must visit rows in the same order as today.
Cost: 4 × 43K `toptNodes` probes (each allocating a `TOpt.Global` and hashing two strings)
become 1 × 43K; `gkeyOf` strings are built once per ctor row instead of once per row per pass.

**(i) Pre-scan + unchanged-subtree return.** In all three rewriting walks the only mutation
is `LVar → LSet` at an arrow (`rewriteWalk` 528-548, `rewrite` 720-745, `succType` 1275-1300),
so:
- Row gate: `if not (Mono.hasVarAnno monoType) then <skip row>` (Mono 1626-1657, allocation-free;
  it also returns True for `LPartial`, which can never be written — a harmless over-approximation
  that only costs the walk). Skipped rows bump NO counters today either: every `skipTop/
  skipFlexVar/skipNoInfo/blocked/varsucc|skip*` bump sits inside an `LVar` arm (528-548,
  720-745, 1275-1300 via `succSetFor`), so the census is identical.
- Subtree gate: the `wrote` counter is the change detector. `rewriteWalk`'s `MFunction` arm
  ends `( Mono.mFunction anno1 args1 result1, st3 )` — replace with
  `if st3.wrote == st.wrote then ( t, st3 ) else ( Mono.mFunction anno1 args1 result1, st3 )`;
  same test (`st1.wrote == st.wrote → ( t, st1 )`) in the MList/MTuple/MRecord/MCustom arms.
  Identical for `settleVarLambda.rewrite` (its `st` has `wrote`/`blocked`; compare `wrote`).
  `succType` already threads `ch`; make every arm return `t` (not a rebuilt copy) when its
  `ch` is False: `( if chW || chR || chA then Mono.mFunction anno args1 result1 else t, sA, … )`.
  Exactness: a subtree with no write beneath it is structurally equal to the rebuilt copy
  (every arm rebuilds with the same constructor over the same children) — returning the input
  is BI and shares the subtree with the row's previous type. `Registry.updateRegistryType`
  (Registry 246-256) is still called only when `wrote > 0`/`ch`.

**(ii)+(iii) `varSuccRounds` → one pass, `sources` decode.**

Idempotence proof (why the verification round writes nothing): (1) rows are independent —
`succType` reads only its own row's type and the member table, never another row; (2) within a
row the walk is top-down on the result spine (1266-1274 comment): after writing `LSet succ` at
an arrow it immediately descends into the rewritten result (1302), so a chain of any depth is
completed in one pass; argument subtrees are walked independently (1305-1315); (3) the member
table is monotone and `succSetFor`'s outcome for a member is a pure function of that member's
key/source, the arg count and `declaredArityOf` — all round-invariant; freshly minted successor
ids are visible immediately (1249-1251 threads `keysAcc`); (4) after the pass every position
that could be written IS `LSet` and every position that was skipped is skipped again for the
same reason. Hence pass 2 finds `changed = False`. The comment at 1401-1407 ("a row rewritten
late can expose a head an earlier row's walk passed over") describes a cross-row dependency
that does not exist in this code. The observed `rounds=3 = 2+1` is exactly: first invocation
1 writing + 1 empty, second invocation (after `settleVarLambda`, which CAN expose pap-able
heads — the cells it writes are the lambda bodies' sets, which may contain `p|`/`g|` members)
1 pass that wrote nothing.

```elm
settleVarSuccessors : S -> S
settleVarSuccessors s0 =
    if not s0.env.lss.enabled then s0
    else
        let
            ( s1, _ ) = varSuccPass s0
        in
        if s0.env.lss.report then
            -- Verification rail: the pass is idempotent (rows independent, top-down, monotone table);
            -- a second pass must find nothing. Its registry is DISCARDED so report-on and report-off
            -- outputs stay identical; only its counters are kept.
            let ( s2, changed2 ) = varSuccPass s1 in
            Engine.bumpArgFlowCensus (if changed2 then "varsucc|verifyCHANGED" else "varsucc|verifyClean")
                (Engine.bumpArgFlowCensus "varsucc|rounds" { s1 | lssStats = s2.lssStats })
        else
            s1

varSuccPass : S -> ( S, Bool )   -- = today's varSuccRounds body minus the recursion, with:
```
- `midKeys`/`compGlobals` (1190-1199) deleted; `succSetFor` (1206-1259) decodes a member as
  ```elm
  papableOf m s =
      case Engine.sourceOf m s.lssMemberTable of      -- step 21; else CoreDict.get m s.lssMemberTable.sources
          Just (Engine.SourceGlobal g) -> Just ( g, 0 )
          Just (Engine.SourcePap g d) -> Just ( g, d )
          _ -> Nothing
  ```
  Equivalence with the string decode (1220-1233): `p|` ids are minted ONLY by `Engine.papMemberIdFor`
  (callers: Translate 4132, 4593, 4624; LssInfer 1810, 2684; Monomorphize 1246 — there is no
  bare `memberIdFor (papMemberKey …)`), which registers `SourcePap g d` (1818-1826); `g|`/`c|`
  ids are minted by `standaloneMemberIdFor` (keys built as `"g|" ++ …`/`"c|" ++ …` at LssInfer
  1284/1296/1301/1313 and Translate 4636-4670; the Translate 4455 caller `standaloneArgMember`
  receives a key built by the same `"g|"`/`"c|"` arms), by `groundStandaloneMemberIdFor`
  (`"g|"…`, 1874-1883) and by `mintLayoutQualifiedFold` (folded `"g|"…`, 786-806) — all three
  register `SourceGlobal g` and today decode to `( g, 0 )` via `"g" :: gstr :: _`. `k|` →
  `SourceKernel` → `Nothing` (today: falls to `_ -> Nothing`); `a|`/`l|` → no source →
  `Nothing`. `compGlobals` also returned `Nothing` for a global string absent from `toptNodes`;
  a `SourceGlobal` is only ever registered from a resolved `TOpt.Global`, so that arm was
  unreachable — the BI `cmp` is the check.
- `keysAcc` threading disappears (the table itself is threaded through `S`).
- Row gate `Mono.hasVarAnno` and the `succType` unchanged-return from (i).

**(iv)** delete `varArgIds`; `varCellWalk : String -> MonoType -> Dict String VarCell -> Dict …`;
`recordLambdaHome` 1000 → `varCellWalk "/r" bodyType Dict.empty`.

**(vi) One node walk for lambda homes + call edges + effects.**
`collectEdgesAndEffectsFromNode` (5039-5056) folds each node with `Traverse.foldExpr`
(bottom-up, `foldChildren` order, MonoTraverse 700-771); `lambdaHomesExpr` is a hand walk over
the same constructors. Fuse into one `Traverse.foldExprAccFirst` per node with the accumulator
`( List Int, Bool, Dict Int Home )`:
```elm
graphFacts : Int -> Array (Maybe Mono.MonoNode)
          -> { edges : Array (Maybe (List Int)), effects : BitSet, valueUsed : BitSet, homes : Dict Int Home }
-- per node: foldExprAccFirst step ( [], False, homesAcc ) expr, where
step ( edges, effects, homes ) expr =
    case expr of
        Mono.MonoVarGlobal _ specId _ -> ( specId :: edges, effects, homes )
        Mono.MonoVarKernel _ _ "Debug" _ _ -> ( edges, True, homes )
        Mono.MonoClosure info body t -> ( edges, effects, recordLambdaHome info body t homes )
        _ -> ( edges, effects, homes )
```
Then `edges`/`effects`/`valueUsed` are assembled exactly as at 4824-4859 (same `Array.set`,
`BitSet.insertGrowing` per neighbour, `Array.repeat nextId Nothing` initial array). BI:
edge cons ORDER is the `foldChildren` visit order in both versions (same fold, same step on
`MonoVarGlobal`); `homes` is order-independent (`varMapMerge`/`varCellMerge` 1034-1057 are
commutative — `unionSortedInts`, `||`; the `arity` check is symmetric); coverage is identical —
`foldChildren` additionally visits `info.captures`, which are `MonoVarLocal` nodes only
(`computeClosureCaptures` returns `( name, MonoVarLocal name t, False )`, Closure 174-186), so
no extra closure is recorded. `s.nodes` is not modified by any sweep (they write `registry`
only), so computing `homes` before the chain and reading `edges` after it is the same data.
Driver:
```elm
facts   = graphFacts sDrained.registry.nextId sDrained.nodes
rows    = ctorRowIndex sDrained
sFinal  = settleVarSuccessors (settleVarLambda facts.homes (settleVarSuccessors (settleCtorRows rows (settleVarCtorRows rows sDrained))))
graph   = pruneGraph sFinal (assembleRawGraphWith facts sFinal mainSpecId maybeFlagsSpecId)
```
`assembleRawGraphWith` keeps everything in 4805-4895 except the fold; `nodesArray` padding stays
(the fold iterated the padded array; padded entries are `Nothing` and contribute nothing, so
iterating `s.nodes` in `graphFacts` is identical). The m2 census (2864) keeps `lambdaHomesOf`.

**(vii) Prune.**
```elm
typeHasResidualNumber isNumber monoType =
    case monoType of
        MVar mvarId constraint -> …unchanged…
        MList _ inner -> typeHasResidualNumber isNumber inner
        MTuple _ elems -> anyResidualNumber isNumber elems
        MRecord _ fields -> Dict.foldl (\_ t acc -> acc || typeHasResidualNumber isNumber t) False fields
        MCustom _ _ _ args -> anyResidualNumber isNumber args
        MFunction _ _ args result -> anyResidualNumber isNumber args || typeHasResidualNumber isNumber result
        _ -> False

anyResidualNumber isNumber xs =
    case xs of
        [] -> False
        x :: rest -> typeHasResidualNumber isNumber x || anyResidualNumber isNumber rest
```
(`List.any (typeHasResidualNumber isNumber)` built a PAP at every MTuple/MCustom/MFunction node
and dispatched it per element — the 0.7 % generic-dispatch share in plan §1.)

`collectAllCustomTypes`: thread a second map `seen : HashMap MonoType ()` (key
`Mono.specHashOf`, eq `(==)` — pointer-fast on canonical nodes) through every
`collectCustomTypes*` function (accumulator `( LayoutMap (), HashMap MonoType () )`). In
`collectCustomTypesFromMonoType`, for every COMPOSITE arm (`MCustom`, `MList`, `MTuple`,
`MRecord`, `MFunction`): `if HashMap.member specHashOf (==) monoType seen then acc else` insert
into `seen` and proceed as today (the `MCustom` arm keeps its `layoutMapMember` test and
`layoutMapInsert`). BI: the set of inserted layouts and their INSERTION ORDER are unchanged —
invariant "a composite in `seen` has every `MCustom` layout of its subtree already in the
layout map" holds by induction (the first visit of any composite walks its whole subtree
before anything else is inserted; the `MCustom` short-circuit at 68-69 already relied on the
same property one level down), so a `seen` hit skips exactly the nodes that would have
inserted nothing; `computeCtorShapesForGraph`'s `layoutMapFoldl` (585) therefore sees the same
sequence. Effect: a node type occurrence costs one probe instead of one probe per `MCustom`
inside it (the compiler's `S`/`Env` records carry dozens). `pruneAfterInline` shares nothing
here (it does not recompute shapes).

**Invariants touched:** LSS_001 (sets stay ascending — `unionSortedInts` unchanged), LSS_013
(successor writes still bounded by declared arity — `succSetFor`'s `d + j < declaredArityOf`
kept verbatim), LSS_010 (settle runs post-drain, unchanged), MONO_028 (Prune's fused closing —
`typeHasResidualNumber` semantics unchanged), MONO_002 (the residual crash check unchanged).
The settle ORDER (driver comment 177-196; plan §4 N1) is untouched: the five calls stay in the
same sequence; only per-row work inside each pass changes.

#### 5. Edit sequence

1. `varArgIds` delete + `varCellWalk` parameter drop (iv). Green.
2. `typeHasResidualNumber` direct recursion (vii-a). Green.
3. `settleVarCtorRows` / `settleVarLambda` / `succType`: unchanged-subtree return via the
   `wrote`/`ch` test; row pre-scan `Mono.hasVarAnno` (i). Green.
4. `varSuccPass` + report-gated verification + `sources` decode (ii, iii). Green.
5. `CtorRow`/`ctorRowIndex`; both ctor sweeps take the index (v). Green.
6. `graphFacts`; `settleVarLambda` takes `homes`; `assembleRawGraphWith` (vi). Green.
7. Analysis `seen` memo (vii-b). Green.

Loop entries: `24a` = edits 1-6 (settle chain + fusion), `24b` = edit 7 (Prune's layout walk;
its win is a different mechanism and worth its own row).

#### 6. Verification

- Unit: `elm-tests` — `LssVarCtorRowsTest`, `LssVarLambdaTest` (`varlam|wrote` count must be
  unchanged), `LssDestrAnnoTest` (settleCtorRows union order), `LssLPartialTest`,
  `PostSettleDevirtTest`, `MuTieTest`; the Prune/ctor-shape pins under
  `tests/TestLogic/Monomorphize/` and `tests/TestLogic/GlobalOpt/` (`grep -rl computeCtorShapes\|pruneUnreachable compiler/tests`).
- BI: loop `cmp`; rail: MLIR sha256 identical for all 633 workloads; the census diff must be
  EXACTLY the `varsucc|rounds` line (3 → 1 per report; plus the two new `varsucc|verify*`
  lines) — `varctor|*`, `varlam|*`, `varsucc|wrote1/wroteN/skip*`, `grounding:`, `ledger:` must
  be identical. `varsucc|verifyCHANGED` must be 0 everywhere; a non-zero value falsifies the
  idempotence proof and the change must not ship.
- Loop triple; expect minor GC −, wall flat to −1 %.

#### 7. Risks, gotchas, and what NOT to do

- ORDER IS LOAD-BEARING on reads as well as writes (driver 177-196; plan §4 N1): do NOT fuse
  passes across the chain, do not move `settleVarCtorRows` after `settleCtorRows`, do not
  reorder the `succSetFor` mint sequence (member-id numbering) — the only thing that changes
  per row is skipping rebuilds that produced equal values.
- The ctor-row index must keep BOTH key strings (`name` for the var-ctor cells, `gkey` for the
  ⊤-heal unions): unifying them is agent B's precision fix, output-changing, separate entry.
- `Mono.hasVarAnno` is True for `LPartial` (1632-1637): the pre-scan must be "skip when
  False", never "write when True".
- Keep the verification pass's registry OUT of the returned state (report-on vs report-off must
  stay byte-identical — benchmarks/lss-compile-opt-loop.md §5 measures with the report off).
- `graphFacts` must iterate `s.nodes` with the SAME `Traverse.foldExpr` the old fold used —
  a hand-rolled walk would change edge cons order and `reachableFromMain`'s DFS order (Prune
  61-92), which does not change the live SET but would change nothing else either; still, do not
  risk it.
- The `seen` memo must key on `specHashOf` with `==` (exact), NOT on `layoutHashOf`/`eqKeyLayout`
  — two layout-equal but annotation-different types have different `MCustom` argument nodes
  only in annotations, so either key works for the layout SET, but `==` is the one that hits by
  pointer on canonical nodes without a structural walk.
- Do not touch `Prune.rebuild`'s `closeNode`/`anyNodeType` gating (MONO_028's stated design).
- `bumpN` (`List.repeat n ()` per counter, 663-664/876-877) is report-gated inside
  `bumpArgFlowCensus` (Engine 1104-1117) but the `List.repeat` runs regardless — replace with
  `Engine.bumpArgFlowCensusBy key n` (Engine 1126) while there; zero emission effect.

#### 8. Effort

S-M: ~250 lines changed across Monomorphize/Mono/Analysis, no new data structures beyond a
record and a HashMap; the only reasoning-heavy part is the idempotence proof in (ii), which the
`varsucc|verify*` rail keeps honest. `24a`/`24b` as in §5.

<details><summary>Conventions used in this spec (from spec-K)</summary>

All line numbers are as of the current tree (2026-09-19), verified by reading. "Mono" =
`Compiler.AST.Monomorphized`, "Engine" = `Compiler.MonoSolver.Engine`, "Translate" =
`Compiler.MonoSolver.Translate`, "Monomorphize" = `Compiler.MonoSolver.Monomorphize` (the solver
driver, NOT `Compiler.Monomorphize.Monomorphize`). Multiplicities are the plan §1 / brief-common
figures: 654,140 set zonks, 83,233 layout-qualified lambda mints, 62,647 interned member strings,
74,837 members (so `nextLam` = 12,190 source lambdas), ~43K specs, 42,955 items, 46.6K
`joinAnnotationsChanged` calls, 31,797 completion joins.

---

</details>

### Step 25 (was 24). AbiCloning fingerprints and spec scans

1. **Goal and expected effect**

AbiCloning is post-mono: it runs inside "GlobalOpt + MLIR emission ≈ 28 s" of the 6:47 run (plan
§1 timeline), i.e. outside the profiled mono window. Four per-site costs are removed, none of which
changes a decision:

| cost today | where | per what |
|---|---|---|
| `siteFingerprint` = `String.join` of depth-4 `shallowLayoutKey` strings + a `Dict String` probe (16 long-common-prefix compares) | `AbiCloning.elm:293-297`, probed at `2392`, `2436`, `2535`; built at index time per INSTANCE at `561` | every singleton-head site; TWICE for an over-applying site (`flattenedResolution` 2535 then `resolveStagedFirstStage` 2436) |
| `List.concat (Dict.values memberInfo.buckets)` | `2584` (`resolvePapSuffix`) | every bucket-miss / layout-miss site |
| `List.map specFunctionRow` over ALL specs of the global (1,939 for `List.foldl`) + `Dict.get (Mono.toComparableGlobal g)` (a 5-concat string) | `2852-2856` (`papResolve`) | every `p|` noInstance site (2,418) |
| `List.filter eqLayout` over all specs + `toComparableGlobal` | `3061-3064` (`matchSpec`) | every `g1` origin site with a `MonoVarLocal` callee |
| `hostGlobalAt` = `toComparableGlobal` per spec | `880`, `913-920` | 43K specs, unconditionally, read only under `census` |

Expected loop stats: wall down by well under 1 % (the pass is a few seconds of the 28 s), minor GC
count down slightly (fewer transient strings). This is a SUBSTRATE step: emission must be
byte-identical (BI) — the stamps (`closureKind`/`captureAbi`/`fastEvaluator`/`fastPapPrefix`/
`fastEvaluatorSpec`) and the E9.5 direct-call rewrites must be the same at every site, AND the
report text must be identical, because the workload rail (`benchmarks/mlir-workload-rail.sh:76`)
diffs everything from `=== LSS census ===` to end-of-stderr, which includes the
`lss globalopt:` line (`Builder/Generate.elm:1833`) and `abiCensusLines` (`:1882`, `:1910`) —
so `memberReps` ORDER (via `memberRepsOf`, `AbiCloning.elm:2250`) is load-bearing for the rail
even though it is print-only.

`MonoInlineSimplify.elm:857-866` (`Traverse.mapNodeTypes Mono.widenSets` over every node) is
named by the plan's step description but runs only `if inlineConfig.arityRaise`, and
`arityRaise = False` by default (`Compiler/Eco/Config.elm:673`). Dead on the default path — nothing
to do in this step; recorded so it is not re-investigated.

2. **Preconditions**

- The plan places this after step 12 (`specsByGlobal` keyed by `GlobalId`). VERIFIED: no
  `GlobalId` exists in the tree today (`grep -rn "GlobalId\|globalId" compiler/src --include=*.elm`
  returns nothing), and post-mono `Mono.Global` (`Monomorphized.elm:2869`, `Global ModuleName.Canonical Name | Accessor Name`)
  carries no id — AbiCloning reads `Mono.Global` out of `registry.reverseMapping`
  (`:2897`, `Array (Maybe ( Global, MonoType ))`) and out of `MemberOrigin` (`OriginGlobal g`,
  `OriginCtor g`, `OriginPap g k`). This spec therefore keys on `Mono.globalHash`
  (`Monomorphized.elm:785-798`, exported) through `Data.HashMap` (`HashMap.get : (k -> Int) -> (k -> k -> Bool) -> k -> HashMap k v -> Maybe v`, `Data/HashMap.elm:62`) — the exact pattern `initState` already uses for `toptNodes` (`Monomorphize.elm:3875`). It does NOT depend on step 12. If step 12 lands a dense id reachable from a `Mono.Global` on the graph record, `specsFor` (below) is the one function to swap to `Dict Int`/`Array`.
- Verify the writer/reader gating assumption for `hostGlobal` before editing:
  `grep -n "ctx.hostGlobal" compiler/src/Compiler/GlobalOpt/AbiCloning.elm` must list exactly lines
  1867, 1981, 2017, 2117, 2137, each inside a function whose first test is `if not ctx.census`
  (1852, 1899, 1999, 2106, 2126) — confirmed today.
- Verify the order-sensitivity claim: `grep -n "Dict.values memberInfo.buckets\|Dict.foldl" compiler/src/Compiler/GlobalOpt/AbiCloning.elm` — the only bucket-ORDER consumers are `papScan`'s input (2584), `memberRepsOf` (2252), `indexSummary` (2037, census-only), `countMultiInstanceGroups` (925-941, order-free sum).
- Loop hygiene: `benchmarks/lss-loop-snap.sh verify <ref>` first.

3. **Inventory of touched code**

| file | function (lines now) | what changes |
|---|---|---|
| `Compiler/AST/Monomorphized.elm` | after `layoutHashOf` (326-346); exposing list line 3 | ADD `layoutRowHash : List MonoType -> MonoType -> Int` (export it); no existing function changes |
| `Compiler/GlobalOpt/AbiCloning.elm` | module doc 34-41 ("one bounded fingerprint … one Dict.get") | reword: Int fingerprint, `Dict Int` |
| same | `MemberInfo` 228-232 (doc 209-227) | `buckets : Dict Int (List LayoutGroup)`; ADD `groups : List LayoutGroup` (flattened, today's order), ADD `nextSeq : Int` |
| same | `LayoutGroup` 254-264 (doc 235-253) | ADD `seq : Int` (creation ordinal within the member) |
| same | `fingerprintDepth` 288-290 (doc 284-287), `siteFingerprint` 293-297 | DELETE `fingerprintDepth`; `siteFingerprint` returns `Int`; ADD `siteFingerprintText` (the old body, used ONLY by `finalizeMember`) |
| same | `collectInstances` 300-318 | wrap result in `Dict.map (\_ mi -> finalizeMember mi)` |
| same | `collectClosure` 395-450 (417, 428, 431) | record literals gain `groups = []`, `nextSeq = 0`; `insertInstance` call threads `mi.nextSeq` |
| same | `insertInstance` 536-563 | signature takes/returns `( buckets, nextSeq )`; key = Int fingerprint |
| same | `joinGroup` 566-624 | takes `seq`; new-group literal gains `seq` |
| same | `abiCloningPass` 783-909: blocked literal 794, `specsByGlobal` 850-869, `hostGlobalAt` call 880, ctx literal 884-905 | blocked literal gains `groups = []`, `nextSeq = 0`; `specsByGlobal` becomes `HashMap Mono.Global (List SpecRow)` with rows precomputed from `record.nodes`; `hostGlobal` computed only `if census`; ctx gains nothing else |
| same | `StampCtx` 699-760 (715) | `specsByGlobal : HashMap Mono.Global (List SpecRow)` |
| same | `hostGlobalAt` 913-920 | unchanged body; call gated |
| same | `countMultiInstanceGroups` 923-944, `indexSummary` 2026-2062 (2037), `memberRepsOf` 2250-2255 | fold over `mi.groups` instead of `mi.buckets` |
| same | `resolveRepresentative` 2343-2400 (2392) | `Dict.get (siteFingerprint fargs fret)` — same shape, Int key |
| same | `resolveStagedFirstStage` 2434-2441 (2436), `flattenedResolution` 2528-2540 (2535) | same |
| same | `resolvePapSuffix` 2582-2584 | `papScan … memberInfo.groups noMatch` |
| same | `papResolve` 2825-2940 (2852-2878) | `specsFor g ctx`; rows come precomputed; no `specFunctionRow` per site |
| same | `specFunctionRow` 2943-2979 | signature becomes `Array (Maybe MonoNode) -> SpecId -> Maybe (…)`; called ONCE per spec at index build |
| same | `matchSpec` 3057-3080 (3061) | `specsFor target ctx`; Int layout-hash pre-reject before `eqLayout` |
| same | `AbiCloningStats` 102-165, `emptyStats` 170-200 | ADD ONE nested field `scan : { sites : Int, bucketProbes : Int, papSpecsScanned : Int, matchSpecScanned : Int }` (28 top-level fields today, 102-165; nested keeps it away from the 32-slot cap) |
| `Builder/Generate.elm` | `abiCensusLines` 1910-2010 | ADD one line `lss abicloning scan: …`, emitted ONLY when `abi.scan.sites > 0` (i.e. under `lss.stamp.census`) so the rail's census artefact is unchanged |
| callers of changed signatures | `insertInstance`: 428, 431 only. `specFunctionRow`: 2856 only (moves to the index build). `siteFingerprint`: 561, 2392, 2436, 2535 only. `abiCloningPass`: `MonoGlobalOptimize.elm:155` (+ tests: `AbiCloningFlatPeelPassTest.elm:209`, `PostSettleDevirtTest.elm:296`, `AbiCloningFenceTest.elm:175`, `AbiCloningPapFastPassTest.elm:440`) — signature UNCHANGED | |

4. **Design**

*4.1 The Int fingerprint.* Every composite `MonoType` carries a packed `layoutHash * hashBase + specHash` (K4, `Monomorphized.elm:277-304`); `layoutHashOf` (326-346) extracts the layout half in O(1) and returns `leafKeyTag` for leaves (`MVar _ CNumber` keys as `MInt`, `MVar _ CEcoValue` drops its id — the SAME two merges `shallowLayoutKey` makes at 2160-2163). Add to `Monomorphized.elm`, next to `layoutHashOf`:

```elm
{-| Layout hash of a parameter row plus return type — the AbiCloning bucket
key. Contract (the same one-directional contract as `layoutHashOf`):
`eqLayoutList ps qs && eqLayout r t` implies equal hashes, never the converse;
a bucket hit MUST still be confirmed with `eqLayout`.
-}
layoutRowHash : List MonoType -> MonoType -> Int
layoutRowHash params ret =
    mixHash
        (List.foldl (\t h -> mixHash h (layoutHashOf t)) (mixHash 19 (List.length params)) params)
        (layoutHashOf ret)
```

Soundness of the bucketing contract: `eqLayout` (2089-2109) is STRICTER than `eqKeyLayout`
(564-565): its arrow arm ignores the annotation like the key, its `MCustom`/`MRecord`/`MList`/`MTuple`
arms recurse structurally like the key, and its leaf fallback `a == b` implies key equality. So
`eqLayout a b ⇒ eqKeyLayout a b ⇒ layoutHashOf a == layoutHashOf b` (K4: "equal keys imply
equal hashes", pinned by `ComparableKeyEncodingTest`). Hence two `eqLayout`-equal instance rows
always share a bucket, exactly the property the String key had. Collisions (different rows, same
Int) are separated by the per-group `eqLayout` confirm that already exists in every scan
(`resolveInGroups` 2410, `stagedScan` 2451, `flattenedScan` 2550, `papScan` 2598, `joinGroup`
via `sameSignatureLayout` 627) — the module comment "collisions only cost an extra eqLayout
confirm, never soundness" is unchanged in meaning.

In `AbiCloning.elm`:

```elm
siteFingerprint : List Mono.MonoType -> Mono.MonoType -> Int
siteFingerprint params ret =
    Mono.layoutRowHash params ret


{-| The former String key. Used ONLY by `finalizeMember` to reproduce the
pre-2026-09 group order (see there); never per site, never per instance.
-}
siteFingerprintText : List Mono.MonoType -> Mono.MonoType -> String
siteFingerprintText params ret =
    String.join "," (List.map (Mono.shallowLayoutKey 4) params)
        ++ "->"
        ++ Mono.shallowLayoutKey 4 ret
```

*4.2 Group partition and `rep` are bucket-independent (proof for the emission gate).*
A group is the set of a member's instances that are `eqLayout`-equal in (params, return)
(`joinGroup` 566-624 joins iff `sameSignatureLayout g.rep inst`, else recurses to the tail and
creates a new group at the END: `g :: joinGroup inst rest` / `[] -> [ new ]`). Because every
bucketing that respects the contract of 4.1 puts a whole `eqLayout` class in ONE bucket, the
class's members meet the same group regardless of how many other classes share that bucket;
`rep` = the first instance of the class in `collectInstances`'s node-walk order (unchanged walk),
`unanimous`/`charFree`/`multi`/`fpUnanimous`/`count` are folds over the class in walk order
(unchanged). The depth-4 collapse of the old key only made buckets COARSER (deep-different classes
shared a bucket); the hash makes them finer; neither moves an instance between classes. So every
exact/flat/staged resolution (which scans a bucket for THE class matching the site) is identical.

*4.3 The one order-sensitive consumer, and how today's order is kept.* `papScan` (2587-2614)
scans ALL of the member's groups in `Dict.values` order (ascending String key) and takes the
FIRST group whose k-dropped suffix matches — several groups can match one site (different `k`,
or different full rows with the same suffix), so the scan order decides the stamp. The report
line's `repsFor` (`Generate.elm:1918`, `List.take 4` of `memberRepsOf`) depends on the same
order. Keep it BY CONSTRUCTION: each `LayoutGroup` records `seq` (its creation ordinal within
the member, threaded through `insertInstance` as `nextSeq`), and `finalizeMember` builds the
flattened list ONCE per member sorted by `( siteFingerprintText rep.paramTypes rep.returnType, seq )`:

```elm
finalizeMember : MemberInfo -> MemberInfo
finalizeMember mi =
    { mi
        | groups =
            Dict.foldl (\_ gs acc -> gs ++ acc) [] mi.buckets
                |> List.sortBy (\g -> ( siteFingerprintText g.rep.paramTypes g.rep.returnType, g.seq ))
    }
```

Why this reproduces today's list exactly: today's `List.concat (Dict.values buckets)` = groups
ordered by (String key ascending under `compare`, then within-bucket creation order). The
String key of a group is `siteFingerprintText` of its rep (the key it was inserted under at
561); `List.sortBy` on a `( String, Int )` key uses the same `compare`; `seq` is the
within-bucket creation order (groups in a bucket are created in `seq` order — 4.2). The tuple
key makes stability irrelevant (the kernel's `List.sortBy` is a `std::stable_sort`,
`elm-kernel-cpp/src/core/ListExports.cpp:805`, but do not rely on it). Cost: one string per
GROUP per compile (groups ≪ instances: "members have very few groups", 2578) instead of one per
instance (561) plus one or two per site.

`memberRepsOf` today folds `Dict.foldl` over buckets consing reps ⇒ REVERSED (String key
descending) list; rewrite as `List.foldl (\g a -> g.rep.lambdaId :: a) [] mi.groups` — the same
fold over the same sequence ⇒ the same list. `indexSummary`'s `n` (2037) and
`countMultiInstanceGroups` are sums ⇒ order-free; fold them over `mi.groups` too so `buckets`
has exactly three readers left (the three `Dict.get` probes).

`MemberInfo`/`LayoutGroup`:

```elm
type alias MemberInfo =
    { blocked : Bool
    , blockedBy : Maybe Mono.LambdaId
    , buckets : Dict Int (List LayoutGroup) -- Int = Mono.layoutRowHash of (params, return); hit confirmed by eqLayout
    , groups : List LayoutGroup -- every group of the member, in the order the String-keyed Dict.values used to give (finalizeMember); the PAP-suffix scan and the report's rep list read THIS
    , nextSeq : Int -- creation ordinal supply for LayoutGroup.seq
    }

-- LayoutGroup gains:  , seq : Int -- creation ordinal within the member (finalizeMember's tie-break)
```

`insertInstance` becomes `Maybe SpecId -> ClosureInfo -> MonoExpr -> Int -> Dict Int (List LayoutGroup) -> ( Dict Int (List LayoutGroup), Int )` — it returns `nextSeq + 1` only when a NEW group was created. Simplest exact form: give `joinGroup` the candidate `seq` and have it return `( groups, created : Bool )`; `insertInstance` returns `( buckets1, if created then seq + 1 else seq )`. `collectClosure` 428/431 thread `mi.nextSeq` / `0`.

*4.4 Registry inversion with precomputed rows.*

```elm
type alias SpecRow =
    { specId : Mono.SpecId
    , specType : Mono.MonoType
    , specLayoutHash : Int -- Mono.layoutHashOf specType: the cheap reject before eqLayout in matchSpec
    , row : Maybe ( List Mono.MonoType, Mono.MonoType ) -- specFunctionRow, computed ONCE here
    }

-- StampCtx: , specsByGlobal : HashMap Mono.Global (List SpecRow)

specsFor : Mono.Global -> StampCtx -> List SpecRow
specsFor g ctx =
    Maybe.withDefault [] (HashMap.get Mono.globalHash (==) g ctx.specsByGlobal)
```

Build (replacing 850-869; same `Array.foldl` over `reverseMapping`, so per-global lists stay
in DESCENDING SpecId order — irrelevant to both consumers, which decide by UNIQUENESS: `matchSpec`
matches `( [ one ], _ )`/`( [], [ one ] )`, `papResolve` matches `[ one ]`; `nonFn = List.any`;
`PsAmbiguous (List.length many)` is a count):

```elm
specsByGlobal =
    Tuple.second
        (Array.foldl
            (\maybeEntry ( i, acc ) ->
                case maybeEntry of
                    Just ( global, specType ) ->
                        let
                            rowI =
                                { specId = i
                                , specType = specType
                                , specLayoutHash = Mono.layoutHashOf specType
                                , row = specFunctionRow record.nodes i
                                }
                        in
                        ( i + 1
                        , HashMap.insert Mono.globalHash (==) global
                            (rowI :: Maybe.withDefault [] (HashMap.get Mono.globalHash (==) global acc))
                            acc
                        )

                    Nothing ->
                        ( i + 1, acc )
            )
            ( 0, HashMap.empty )
            record.registry.reverseMapping
        )
```

`specFunctionRow` keeps its body (2943-2979: closure params / tailfunc params / ctor fields
≤ `ctorTypedSlotCap` = 24, `Nothing` otherwise) but takes the nodes array instead of `ctx`
(`Array.get specId nodes`). One call per spec (43K) instead of per site × specs-of-global.

`papResolve` 2852-2878 becomes:

```elm
rows =
    specsFor g ctx

matches =
    List.filterMap
        (\r ->
            case r.row of
                Just ( params, ret ) ->
                    if List.length params == k + List.length fargs
                        && eqLayoutLists (List.drop k params) fargs
                        && Mono.eqLayout ret fret
                    then Just ( r.specId, params, ret ) else Nothing

                Nothing ->
                    Nothing
        )
        rows

nonFn =
    List.any (\r -> r.row == Nothing) rows
```

with `if List.isEmpty rows then no "papNoSpec" …` in place of `List.isEmpty specs`. Every guard
(P1-P7) and every census key string is verbatim.

`matchSpec` 3057-3080 becomes:

```elm
matchSpec target isCtor calleeType ctx =
    let
        calleeHash =
            Mono.layoutHashOf calleeType

        layoutMatches =
            specsFor target ctx
                |> List.filter (\r -> r.specLayoutHash == calleeHash && Mono.eqLayout r.specType calleeType)

        exactMatches =
            List.filter (\r -> r.specType == calleeType) layoutMatches
    in
    case ( exactMatches, layoutMatches ) of
        ( [ r ], _ ) -> PsStamp r.specId isCtor
        ( [], [ r ] ) -> PsStamp r.specId isCtor
        ( [], [] ) -> PsNoSpec
        ( _, many ) -> PsAmbiguous (List.length many)
```

The hash pre-reject is sound by the 4.1 contract (`eqLayout r.specType calleeType ⇒` equal
hashes), so `layoutMatches` is the same set; `exactMatches` unchanged.

*4.5 `hostGlobal` gating.* Line 880: `hostGlobal = if census then hostGlobalAt record.registry.reverseMapping specId else "?"`. All five readers are census-gated (precondition check). The `hostSpecId` write stays (an Int).

*4.6 Scan counters (the evidence gap G7 names).* One nested record on `AbiCloningStats`:
`scan : { sites : Int, bucketProbes : Int, papSpecsScanned : Int, matchSpecScanned : Int }`,
zero in `emptyStats`. Increment ONLY under `ctx.census` (a `bumpScan : (Scan -> Scan) -> StampCtx -> StampCtx` with the `if not ctx.census then ctx` head like `bumpHost` 2124-2139), so timed runs pay nothing: `sites` in `stampCall`'s `LSet [ m ]` arm entry, `bucketProbes` at the three `Dict.get` sites (count 1 per probe — the over-applying path shows as 2), `papSpecsScanned += List.length rows` in `papResolve`, `matchSpecScanned += List.length (specsFor target ctx)` in `matchSpec`. Render in `abiCensusLines` as one extra line guarded by `abi.scan.sites > 0`.

*4.7 Order-of-evaluation constraints (emission).* (a) `collectInstances`'s node walk order is
untouched — it decides `rep`. (b) `finalizeMember` runs AFTER the whole walk (in
`collectInstances`'s return), never incrementally. (c) `kindIdFor` (2617-2630) mints
`ClosureKindId`s in site order — the stamping walk is untouched. (d) Blocked members (794, 417)
get `groups = []` — they never resolve. (e) `HashMap.insert` with `(==)` on `Mono.Global`
replaces in place on a repeat key (`replaceInBucket`, `Data/HashMap.elm:138`), so the per-global
list is built by read-modify-write exactly as the `Dict.update` was.

5. **Edit sequence** (each leaves `elm make compiler/src/Terminal/Main.elm` green)

- E1 `Monomorphized.elm`: add `layoutRowHash` after `layoutHashOf` (346); export it on line 3 next to `layoutHashOf`. Add a pin to the existing `ComparableKeyEncodingTest` (`grep -rl ComparableKeyEncodingTest compiler/tests`): for a few rows (`[MInt, MList MString]`/`MBool`, an `MFunction` with two different `LSet`s in arg position, an `MRecord` with two field sets, `MVar _ CNumber` vs `MInt`), `eqLayoutList ps qs && eqLayout r t` ⇒ `layoutRowHash ps r == layoutRowHash qs t`. Loop entry: none (no behaviour).
- E2 `AbiCloning.elm` (index side): `LayoutGroup.seq`; `MemberInfo.groups`/`nextSeq`; `siteFingerprint : … -> Int` + `siteFingerprintText`; delete `fingerprintDepth` (and its doc 284-287); `insertInstance`/`joinGroup` threading; the three literals (417, 431, 794); `finalizeMember` + `Dict.map` in `collectInstances`; `resolvePapSuffix` over `groups`; `memberRepsOf`, `indexSummary`, `countMultiInstanceGroups` over `groups`; the three probes 2392/2436/2535 compile unchanged (same call shape, Int key). Update the module doc 34-41 and the `MemberInfo` doc 209-227. Run the six AbiCloning unit suites (§6). **Loop entry 25a.**
- E3 `AbiCloning.elm` (registry side): `SpecRow`; `StampCtx.specsByGlobal` type; the build at 850-869; `specsFor`; `specFunctionRow` signature (nodes array); `papResolve`; `matchSpec`. `import Data.HashMap as HashMap exposing (HashMap)`. Unit suites again (PostSettleDevirtTest, AbiCloningPapFastPassTest pin exactly these two functions). **Loop entry 25b** (or fold into 25a if one measured run is preferred — both are BI, so a single entry is legitimate; keep them separable for diagnosis).
- E4 `AbiCloning.elm:880`: gate `hostGlobal` on `census`. Part of 25b.
- E5 counters: `AbiCloningStats.scan` + `emptyStats` + `bumpScan` + four increments + the `abiCensusLines` line. No timed entry (census-gated instrumentation); run the census leg of §6 once to record the numbers in the plan entry.

6. **Verification**

- Unit: `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt` (once), then `grep -n "AbiCloning\|PostSettleDevirt\|E5Keyed\|ComparableKey\|LssInstanceQual" /tmp/test_output.txt`. The pins: `compiler/tests/TestLogic/Monomorphize/AbiCloningFenceTest.elm` (dispatchUpgraded/bodyMismatch/abiMismatch/multiInstanceGroups), `AbiCloningFlatPeelPassTest.elm` (dispatchUpgraded, declinedShapeArityOver, declinedBodyMismatch), `AbiCloningFlatPeelTest.elm` (`peelStages`, unchanged), `AbiCloningPapFastPassTest.elm` (stampedPapGlobal/declinedNoInstance — exercises `papResolve`), `PostSettleDevirtTest.elm` (devirtPost fn/ctor/noSpec/ambiguous — exercises `matchSpec`), `compiler/tests/TestLogic/Generate/CodeGen/E5KeyedDispatchTest.elm`, `LssInstanceQualTest.elm` (reads only `graph.registry`). None constructs `AbiCloningStats` literally (only `emptyStats` does), so the new `scan` field breaks no pin.
- E2E: `TEST_FILTER=PapStamp cmake --build build --target full 2>&1 | tee /tmp/test_output.txt` covers `test/elm/src/PapStampTest.elm` and `test/elm/src/PapCopyStampTest.elm` (E2E stamp pins); a full `--target full` in Phase 4.
- Byte identity (the gate): loop Phase 2 `cmp` triple + fixed point (`cmp bin/eco-opt25-r1-out.mlir bin/eco25.mlir`). Additionally, in an UNTIMED leg with `ECO_MONO_LSS_REPORT=1` on both `eco-opt-prev` and `eco-opt25`: `diff <(grep -a "^lss globalopt:\|^lss census" prev.stderr) <(grep -a "^lss globalopt:\|^lss census" new.stderr)` must be empty — this is the `memberReps`-order check (4.3) that the MLIR `cmp` cannot see.
- Rail: `benchmarks/mlir-workload-rail.sh` — zero manifest moves and ZERO census diff lines (the extra `lss abicloning scan:` line prints only under `ECO_MONO_LSS_CENSUS=1`, which the rail does not set).
- Dispatch-stats rail (only if `cmp` FAILS, to localise which site moved): build both binaries with the site-counter lowering, run with `ECO_DISPATCH_STATS=1`, feed stderr to `benchmarks/dispatch-census.sh`; a byte-identical artifact makes this redundant.
- Attribution census leg (untimed): `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_CENSUS=1 ./bin/eco-opt25 make … 2> census.stderr; grep -a "lss abicloning scan:" census.stderr` — record `sites`, `bucketProbes`, `papSpecsScanned` (expect ≈ Σ over the 2,418 `p|` sites of specs-of-global, i.e. millions before E3 is meaningful; after E3 it is the same count but each is a field read, not a `specFunctionRow`), `matchSpecScanned`.

7. **Risks, gotchas, and what NOT to do**

- LOAD-BEARING: the PAP-suffix scan order (4.3). Do NOT "simplify" `finalizeMember` to creation order or to `Dict.values` of the Int dict — either can move a stamp at a site where two groups' suffixes both match, and the MLIR `cmp` is the only thing that would tell you. The tuple sort is the by-construction guarantee.
- Do NOT replace `eqLayout` with `eqKeyLayout` anywhere in the scans to "match the hash": `eqKeyLayout` merges `MVar` ids and `MVar _ CNumber` with `MInt` (Monomorphized.elm 555-563 doc) — a group could then span layouts that MONO_029 keeps distinct. The hash is a pre-filter; `eqLayout` stays the decision.
- `fingerprintDepth` is deleted; `shallowLayoutKey` (Monomorphized 2138-2182) stays exported for `siteFingerprintText`. Its doc's `~` marker note (UTF-8 widen cliff) is still true and still matters at finalize time.
- `Mono.Global` equality inside `HashMap.get … (==)` is four string compares per HIT (the plan's step-12 complaint) — per SITE that is cheaper than the 5-concat `toComparableGlobal` + `Dict String` probe it replaces; it is not the target of this step. Swap to step 12's Int id when it exists.
- 32-slot cap: `AbiCloningStats` has 28 top-level fields (76-165); the new counters go in ONE nested record (the `devirtPost`/`instQual` precedent, comment at 120-124). `StampCtx` is 11 fields — fine.
- Report text: `abiCensusLines` (Generate.elm 1910-2010) is in the rail's census artefact; the new line must be guarded by `abi.scan.sites > 0` (census-only) or the rail shows 633 spurious diff lines.
- Invariants touched, none amended: LSS_009 (representative over verbatim copies — group semantics identical, 4.2), LSS_011 (PAP-suffix stamp — scan order preserved, 4.3), LSS_014 (staged stamp), LSS_025 (post-settle devirt — `matchSpec` set-identical, 4.4), LSS_036 (`topLevelSpec` untouched), LSS_039 (`peelStages` untouched), LSS_040 (`papResolve` guards verbatim), ABI_CLONE_001 (no stamp changes). The AbiCloning module doc lines 34-41 describe the mechanism and must be reworded (String → Int, "one Dict.get" still true).
- `Data.HashMap` iteration is sequence-ordered (`orderedEntries`, HashMap.elm:206) — not used here; only `get`/`insert`.
- Plan §4 items NOT to do here: N9 (the `olm*`/`goList` recursion), N11 (`buildMemberOrigins`). The `fp*` fingerprint family (3201-3659) is lazy per multi-join and is not a per-site cost — leave it.

8. **Effort**

M — three mechanical rewrites in one 3,659-line file plus a 6-line addition to `Monomorphized.elm`; the only thinking is 4.3. Split: **25a** = E1+E2 (fingerprint + flattened groups), **25b** = E3+E4 (registry rows + hostGlobal gate); E5 is census-only instrumentation with no timed entry.

---

<details><summary>Conventions used in this spec (from spec-L)</summary>

All line numbers verified against the tree on 2026-09-19 (`/work/compiler/src/...`). "Mono." =
`Compiler.AST.Monomorphized`. The loop protocol is `/work/benchmarks/lss-compile-opt-loop.md`.

---

</details>

### Step 26 (was 23b). Regroup `S` by co-update (M7 rule)

1. **Goal and expected effect**

`Engine.S` (`Compiler/MonoSolver/Engine.elm:1302-1360`) has **31 top-level fields** (counted:
`worklist nodes inProgress scheduled dirtySpecs dirtyList specCountByGlobal registry ports
lambdaCounter superTable nextMVarId lssSignatures lssInProgress lssMemberTable nextMemberId
lssStats monoMemo nodeResolution intern env currentGlobal store memo revMemo varEnv numberMulti
localMulti derivedDestructors localCanTypes itemAux`; the comments at 1323, 1326 and 1353-1355
say "at the 32-slot cap" — it is one below). Every `{ s | x = … }` allocates a fresh record with
one slot per top-level field and stores all 31 (the compiler copies every top-level field on
record update, brief §"Elm here"). Nesting fields that are written rarely AND written together
into sub-records makes every hot copy 31 → 18 slots (−13 words, −104 B per copy) while a write to
a nested group pays one extra small record. Stats expected to move: minor GC count (allocation
volume) and, less, wall (13 fewer stores + 13 fewer GC-scan slots per copy). BI: yes — pure
data-layout change inside the solver; no analysis order changes.

Why LAST (formula): the win is `ΔBytes = 8 · Σ_w N_w · (31 − T) − 8 · Σ_g N_g · |g|`, where `T`
= new top-level field count (18; 16 with the optional 26d), `N_w` = dynamic count of `S` copies
at writers whose fields stay top-level, `N_g` = dynamic count of writes touching nested group
`g` (each also allocates that group's `|g|`-slot record). `N_w` is exactly what steps 7 (every
`lssStats` bump = one `S` copy: 654K zonks, 205K `foldSetWrites`, 98K keyed hits, 83K lambda
mints, 43K completion joins — gone), 8 (`writeBackShared` `Store.elm:150-176` = 2 copies + an
`ItemAux` copy per `loadType`, ~30 pure-read `{ s | store = … }` sites — gone) and 10 (every
`Ok ( (), { s | … } )` site rewritten — 150 update sites move) reduce; the driver-level copies
that survive them are ~10 per item × 42,955 items ≈ 0.43 M (plan N11, "two orders below the
per-node writers"). Doing this before 7/8/10 would (a) be measured against copies that are about
to disappear and (b) be re-done site by site when step 10 rewrites the same lines.

2. **Preconditions**

- Steps 7, 8, 10 kept (loop §7 rows). Then re-run the census in §2 below on the CURRENT tree —
  the site list in §3 is today's and WILL have moved.
- Site census (the co-update groups), re-runnable: the script
  `benchmarks/lss-coupdate-census.py` (was written to a session scratchpad; copied into the
  repo 2026-09-20 so this reference does not dangle)
  (`python3 benchmarks/lss-coupdate-census.py` from `/work`) parses every `{ x | f = …, … }` in
  `compiler/src/Compiler/MonoSolver/*.elm` whose field names are ALL `S` fields and prints
  per-site field sets, co-update groups and per-field counts. Today: 150 sites; groups and
  counts in §4.1.
- Dynamic copy count (the `N_w` of the formula) — one untimed leg: lower the last kept compiler
  with `ECO_INLINE_ALLOC=0` (so every record allocation goes through the export;
  `RuntimeExports.cpp:434 eco_alloc_record(uint32_t field_count, uint64_t unboxed_bitmap)`), then
  count 31-field record allocations with a uprobe (pattern: session `scratchpad/uprobe/run.sh`):
  `sudo -n bpftrace -e 'uprobe:<BIN>:eco_alloc_record /arg0 == 31/ { @s = count(); } END { print(@s); }'`
  around a self-compile. `S` is the only 31-field record in the solver (`ItemAux` 13, `Env` 14,
  `LssStats` 32, `LoadCtx` 11, `ZonkCtx` 10, `LssZonkAcc` 22 — findings-A). After the step,
  count `arg0 == 18` (S) and `arg0 == 6` / `4` (groups; note `sched` and `runMemo` are both 6
  wide — distinguish by return-address symbolisation if needed). The `.mlir` artefacts are
  bytecode, so `field_count = 31` cannot be grepped from them; use the uprobe.
- Decision threshold: with a 512 MiB nursery (HEAP_043 default) each 1 M surviving copies is
  ≈ 104 MB ≈ 0.2 minor GCs; the base row has 1,825 minors. Build the step only if the leg shows
  ≥ ~10 M copies (≥ 2 minors, ≥ 1 GB less allocation); below that the win is inside the noise
  band and the entry will read FLAT.

3. **Inventory of touched code** (today's sites; re-census after 7/8/10)

| file | function (lines now) | what changes |
|---|---|---|
| `MonoSolver/Engine.elm` | `S` 1302-1360 | three (optionally four) nested aliases; comments 1323, 1326, 1353-1355 (and 479) corrected ("31 of 32") |
| same | `resetItem` 2433-2435 | `letCtx = emptyLetCtx` (constant), other fields as now |
| same | `withScratchStore` 2033-2100 (2042, 2100) | unchanged (store/memo/revMemo/itemAux stay top-level) |
| same | sched writers: `enqueueSpecCommit` 2175-2200 (2181 via `markDirty`, 2197), `markDirty` 2270-2280 (2275, 2278), `enqueueSpecKeyed` 2305-2400 (2358) | `{ s | sched = { sc | … } }` |
| same | runMemo writers: `harvestSuperTableExcept` 2659-2695 (2695), `putSchemeMono` 2708-2716, `putCallMemo` 2725-2733 | `{ s | runMemo = { rm | … } }` |
| same | letCtx writers: `pushNumberMulti` 2455-2457, `popNumberMulti` 2462-2466, 2513, `pushLocalMulti` 2521, `popLocalMulti` 2528, 2559 | `{ s | letCtx = { lc | … } }` |
| same | reads: `s.registry` ×7, `s.scheduled` ×2, `s.worklist` ×1, `s.dirtySpecs` ×2, `s.dirtyList` ×1, `s.specCountByGlobal` ×4, `s.lssSignatures` ×2, `s.nodeResolution` ×1, `s.monoMemo` ×4, `s.superTable` ×2, `s.numberMulti` ×6, `s.localMulti` ×5 (grep counts; `lookupSchemeMono` 2703, `lookupCallMemo` 2720, `isNumberMultiTarget`/`isLocalMultiTarget`, `specIdsForGlobal`) | one extra projection |
| `MonoSolver/LssInfer.elm` | 115 (`lssSignatures`), 373 (`lssInProgress`), 389 (both), 410 (`lssSignatures`); reads `lssSignatures` ×7, `lssInProgress` ×4 | runMemo |
| `MonoSolver/Monomorphize.elm` | `initState` 3852-3937 (the ONLY `S` literal in the tree) | nested literals |
| same | settle passes writing `registry` alone: 320, 636, 874, 1384 | sched |
| same | `seedSpec` 3939 (`registry, worklist, scheduled`), `drain` 4024 (`worklist, dirtyList, lssStats`), 4031 (`worklist`), `processItem` 4079 (`inProgress, currentGlobal, lssStats, dirtySpecs`), 4159 (`inProgress, currentGlobal, itemAux`), `finishNode` 4336 (`registry, lambdaCounter`), 4559 (`nodeResolution`), 4709 (`nodes, inProgress, currentGlobal, itemAux`); reads `registry` (S-typed subset of the 32 `.registry` hits — the `MonoGraph` record also has a `registry` field; the compiler's errors enumerate the S ones), `inProgress` ×4, `nodes` ×9, `lssSignatures` ×4, `nodeResolution` ×3, `superTable` ×1, `ports` ×1, `lambdaCounter` ×2 | sched / runMemo / (26d) drv |
| `MonoSolver/Translate.elm` | 1477 (`ports`), 1895 `allocLambdaId` (`lambdaCounter` — STAYS top-level, see 4.2), 6233 (`derivedDestructors`), 6774 (`localCanTypes`), 6922 (`localMulti`); reads `superTable` ×2, `lambdaCounter` ×1, `ports` ×2, `numberMulti` ×1, `localMulti` ×4, `derivedDestructors` ×2, `localCanTypes` ×2 | runMemo / letCtx |
| `MonoSolver/Store.elm` | reads `superTable` ×3 (loadType var mint) | runMemo projection |
| `MonoSolver/Diff.elm`, `Zonk.elm` | no `S` field access (Diff reads the `MonoGraph` record's `registry`/`ports`) | none |
| tests | no test constructs an `S` literal (`grep -rn "nodeResolution = \|specCountByGlobal = " compiler/tests` → none) and no test reads a nested-group field on an `S` value (the `.registry`/`.ports` hits in `compiler/tests/TestLogic/**` are on `MonoGraph` records, e.g. `LssPapMembersTest.elm:296 g.registry.reverseMapping`, `CafDedupeTest.elm:66 g1.ports`) | none expected; the compiler will say otherwise |
| outside `MonoSolver/` | no consumer of `Engine.S` (`grep -rln "Engine\.S\b" compiler/src` → only a comment in `AbiCloning.elm`) | none |

Signature changes: none (all `Step`/`S -> S` signatures keep their shapes; only field paths move).

4. **Design**

*4.1 The census, and the plan's grouping validated against it.* Per-field WRITE-site counts
(today): store 41, lssStats 40, itemAux 25, lssMemberTable 12, registry 11, memo 10, revMemo 10,
intern 7, localMulti 5, nextMVarId 5, nextMemberId 4, worklist 4, numberMulti 4, varEnv 3,
lssSignatures 3, inProgress 3, currentGlobal 3, scheduled 2, dirtySpecs 2, dirtyList 2,
derivedDestructors 2, localCanTypes 2, monoMemo 2, lssInProgress 2, lambdaCounter 2,
specCountByGlobal 1, superTable 1, nodeResolution 1, nodes 1, ports 1, env 0. Co-update groups
(sets written in ONE update, with site counts): `lssStats` 34, `store` 29, `itemAux` 17,
`lssMemberTable` 8, `registry` 6, `intern` 5, `store+memo+revMemo+itemAux` 4, `localMulti` 4,
`numberMulti` 3, `nextMVarId` 3, `lssMemberTable+nextMemberId` 2, `registry+scheduled+worklist` 2,
`varEnv` 2, `monoMemo` 2, `lssSignatures` 2, `memo` 2, and singletons:
`registry+dirtySpecs+dirtyList`, `registry+specCountByGlobal+lssStats`, resetItem's nine,
`superTable`, `lssInProgress`, `lssSignatures+lssInProgress`, `worklist+dirtyList+lssStats`,
`worklist`, `inProgress+currentGlobal+lssStats+dirtySpecs`, `inProgress+currentGlobal+itemAux`,
`registry+lambdaCounter`, `nodeResolution`, `nodes+inProgress+currentGlobal+itemAux`,
`store+memo+revMemo`, `store+lssStats+memo+revMemo`, `store+revMemo`, `store+revMemo+lssStats`,
`memo+revMemo`, `store+lssStats`, `store+nextMVarId+intern+lssMemberTable+nextMemberId` (+itemAux),
`ports`, `lambdaCounter`, `derivedDestructors`, `localCanTypes`.

Dynamic cadence per writer (findings-A/plan): per node — store, memo, revMemo, itemAux, intern,
nextMVarId, lssStats (until step 7); per binder — varEnv; per member mint (75K) —
lssMemberTable/nextMemberId; per LAMBDA (83K, `allocLambdaId` Translate 1895) — lambdaCounter;
per created spec (43K) — registry+scheduled+worklist(+specCountByGlobal); per item (43K) —
worklist pop (4031), inProgress/currentGlobal (4079, 4159/4709), registry+lambdaCounter
(4336), superTable (4177 → 2695), nodes (4709); per global (10-20K) — nodeResolution (4559),
schemeMono; per inference unit (~10K) — lssSignatures/lssInProgress; per settle PASS (4 per run)
— registry (320, 636, 874, 1384); per let-bound multi def — numberMulti/localMulti push/pop;
per destructor/let — derivedDestructors/localCanTypes; once — ports.

Validation of the plan's three groups (the M7 rule: nest only what is written TOGETHER, or
rarely enough that the extra group record is cheaper than the refs it removes from every hot
copy):

- **`sched` {registry, scheduled, worklist, dirtySpecs, dirtyList, specCountByGlobal} — KEEP as
  planned.** Every write to any of the six is either sched-only (2197, 3939, 2275, 2278, 320,
  636, 874, 1384, 4031) or sched + a field that stays top-level (2358 +lssStats, 4024 +lssStats,
  4079 +inProgress/currentGlobal/lssStats, 4336 +lambdaCounter). Cadence ≤ per created spec /
  per item.
- **`runMemo` {lssSignatures, lssInProgress, nodeResolution, monoMemo, superTable, ports} —
  KEEP, MINUS `lambdaCounter`.** `lssSignatures`/`lssInProgress` are co-written (389);
  the rest are written alone, all at ≤ per-item cadence. `lambdaCounter` is written per LAMBDA
  (Translate 1895) and once per item together with `registry` (4336) — never with any runMemo
  member; per the rule it stays top-level. (Arithmetic if one insists: nesting it costs
  `N_lam × |runMemo|` = 83K × 7 words at the lambda writer and saves 1 word on every other copy —
  a wash at N_w ≈ 0.6 M copies; not worth the rule violation.)
- **`letCtx` {numberMulti, localMulti, derivedDestructors, localCanTypes} — KEEP.** They are
  NOT co-written (each push/pop/insert is alone; only `resetItem` writes all four) — this group
  is justified by the second clause: writers are per let-bound-multi def / per destructor
  (thousands to low tens of thousands) against millions of hot copies, so
  `N_g × 4 ≪ N_w × 3`; and `resetItem` (43K) writes the whole group as the shared constant
  `emptyLetCtx` (no allocation).
- **Optional `drv` {inProgress, currentGlobal, nodes} — 26d.** Strictly co-written (3 of 3 sites:
  4079, 4159, 4709), per item. Reads of `currentGlobal` (Store ×2, Translate ×4, Engine ×1) and
  `nodes` (Monomorphize ×9, incl. `nodeAlreadyDone`) gain one projection. Takes T from 18 to 16.

Fields that stay top-level and why: per-node/per-binder/per-mint writers (`store`, `memo`,
`revMemo`, `varEnv`, `itemAux`, `intern`, `nextMVarId`, `lssMemberTable`, `nextMemberId`,
`lssStats`, `lambdaCounter`), the immutable `env` (already the M7 sub-record), and the
per-item `currentGlobal`/`inProgress`/`nodes` unless 26d.

*4.2 Types.* In `Engine.elm`, replacing the flat fields:

```elm
type alias Sched =
    { worklist : List WorkItem
    , scheduled : BitSet
    , dirtySpecs : BitSet
    , dirtyList : List Mono.SpecId
    , specCountByGlobal : CoreDict.Dict String SpecTally
    , registry : Mono.SpecializationRegistry
    }


type alias RunMemo =
    { lssSignatures : CoreDict.Dict String LssSignature
    , lssInProgress : CoreDict.Dict String ()
    , nodeResolution : CoreDict.Dict String NodeResolution
    , monoMemo : MonoMemo
    , superTable : Dict Int Vars.SuperType
    , ports : List Mono.PortRegistration
    }


type alias LetCtx =
    { numberMulti : List NumberMultiEntry
    , localMulti : List NumberMultiEntry
    , derivedDestructors : CoreDict.Dict String (Can.Type TypeIds.MVarId)
    , localCanTypes : CoreDict.Dict String (Can.Type TypeIds.MVarId)
    }


emptyLetCtx : LetCtx
emptyLetCtx =
    { numberMulti = [], localMulti = [], derivedDestructors = CoreDict.empty, localCanTypes = CoreDict.empty }


type alias S =
    { sched : Sched
    , runMemo : RunMemo
    , letCtx : LetCtx
    , nodes : Array (Maybe Mono.MonoNode)
    , inProgress : BitSet
    , currentGlobal : Maybe Mono.Global
    , lambdaCounter : Int
    , nextMVarId : TypeIds.MVarId
    , lssMemberTable : LssMemberTable
    , nextMemberId : Int
    , lssStats : LssStats
    , intern : Intern
    , env : Env
    , store : IO.State
    , memo : Dict Int Vars.Variable
    , revMemo : Array (Maybe TypeIds.MVarId)
    , varEnv : CoreDict.Dict String Mono.MonoType
    , itemAux : ItemAux
    }
-- 18 fields (26d: drv {inProgress, currentGlobal, nodes} → 16)
```

Field DOC comments move with the fields (the `specCountByGlobal` §9.6 note, the `dirtySpecs`
LSS_010 note, the `nodeResolution` D13 note, the `lssMemberTable`/`monoMemo` "ONE field: 32-slot
cap" notes — rewrite the latter two: the cap is real (`runtime/src/codegen/EcoOps.cpp:450-456`
`field_count (N) exceeds Record's 32-slot GC scan limit`; `TypeInfo.hpp:36`;
`HeapHelpers.hpp:1459`) but `S` is now 18).

*4.3 Writer sketches (the shapes every site takes).*

```elm
-- Engine.elm 2433: resetItem
resetItem s =
    { s | store = freshStore, memo = CoreDict.empty, revMemo = Array.empty, varEnv = CoreDict.empty, letCtx = emptyLetCtx, itemAux = emptyItemAux }

-- Engine.elm 2197: enqueueSpecCommit, created arm
let sc = s.sched in
Ok ( specId, { s | sched = { sc | registry = reg1, scheduled = BitSet.insertGrowing specId sc.scheduled, worklist = SpecializeGlobal specId :: sc.worklist } } )

-- Engine.elm 2270: markDirty
markDirty specId reg1 s =
    let sc = s.sched in
    if BitSet.member specId sc.dirtySpecs then
        { s | sched = { sc | registry = reg1 } }
    else
        { s | sched = { sc | registry = reg1, dirtySpecs = BitSet.insertGrowing specId sc.dirtySpecs, dirtyList = specId :: sc.dirtyList } }

-- Engine.elm 2455/2462: number-multi stack
pushNumberMulti defName s =
    let lc = s.letCtx in
    Ok ( (), { s | letCtx = { lc | numberMulti = { … } :: lc.numberMulti } } )

-- LssInfer.elm 389
{ s4 | runMemo = let rm = s4.runMemo in { rm | lssSignatures = …, lssInProgress = … } }

-- Monomorphize.elm 4336: finishNode (crosses S and sched — one S copy + one 6-slot Sched)
{ s1 | sched = { sc | registry = registry2 }, lambdaCounter = newLambdaCounter }
```

Reads are mechanical: `s.registry` → `s.sched.registry`, `s.monoMemo.schemeMono` →
`s.runMemo.monoMemo.schemeMono`, `s.localMulti` → `s.letCtx.localMulti`, etc. `initState`
(Monomorphize 3852-3937) is the single literal; rewrite it with the three nested literals.

*4.4 Copy-size change per hot writer (slots, today → after; a copy allocates and stores one
slot per top-level field of each record it rebuilds):*

| writer (cadence) | today | after 26a-c | after 26d |
|---|---|---|---|
| `store`/`memo`/`revMemo`/`itemAux`/`intern`/`nextMVarId`/`varEnv`/`lssMemberTable`/`lssStats` (per node / binder / mint) — `N_w` | 31 | 18 | 16 |
| `lambdaCounter` (per lambda, 83K) | 31 | 18 | 16 |
| `registry`/`scheduled`/`worklist` (per created spec, 43K) | 31 | 18 + 6 | 16 + 6 |
| `worklist` pop (per item) | 31 | 24 | 22 |
| `inProgress`/`currentGlobal` (2 per item) | 31 | 18 (26d: 16 + 3) | 19 |
| `registry`+`lambdaCounter` (per item) | 31 | 24 | 22 |
| `superTable` (per item) | 31 | 24 | 22 |
| `nodeResolution`/`schemeMono`/`callMemo` (per global / memo insert) | 31 | 24 | 22 |
| `lssSignatures`(+`lssInProgress`) (per inference unit) | 31 | 24 | 22 |
| `numberMulti`/`localMulti` push/pop, `derivedDestructors`, `localCanTypes` | 31 | 22 | 20 |
| `resetItem` (per item) | 31 | 18 (`emptyLetCtx` shared) | 16 |
| whole-registry settle rebuilds (4 per run) | 31 | 24 | 22 |

Nothing gets larger than 31 + |group| = 37 and only the per-created-spec and per-item writers do;
every per-node writer drops by 13 (15).

*4.5 Order-of-evaluation / emission.* None: no mint order, Point index, intern insertion or
member id changes — pure record nesting. Fixed point and byte identity are expected without an
extra bootstrap turn.

5. **Edit sequence** (each compilable; each its own loop entry if measured separately)

- 26a `sched`: add the `Sched` alias and field; remove the six flat fields; fix `initState`; fix
  every compile error the type-checker lists (writers: Engine 2181/2197/2275/2278/2358,
  Monomorphize 320/636/874/1384/3939/4024/4031/4079/4336; readers: the `s.registry`… sites).
  `elm make compiler/src/Terminal/Main.elm` green; `cmake --build build --target elm-tests`.
- 26b `runMemo`: same for the six (Engine 2695/2715/2732, LssInfer 115/373/389/410,
  Monomorphize 4559, Translate 1477; readers incl. `Store.elm` `s.superTable` ×3 in the var mint,
  `Engine.lookupSchemeMono`/`lookupCallMemo`, `LssInfer.signatureFor`).
- 26c `letCtx` (+ `emptyLetCtx`): Engine 2433/2455/2462/2513/2521/2528/2559, Translate
  6233/6774/6922; readers `isNumberMultiTarget`/`isLocalMultiTarget`/`numberMultiRootType`.
- 26d (optional) `drv`: Monomorphize 4079/4159/4709 + readers.
- In the same edits: correct the three "at the 32-slot cap" comments (Engine 1323, 1326,
  1353-1355, 479) and the `Config.elm:343-349` remark that names `Engine.S` as the cap example.

6. **Verification**

- Unit: `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt` (once); expect
  the same pass count as the reference (no pin names a nested field).
- E2E: `cmake --build build --target full` in Phase 4.
- Byte identity: loop Phase 2 `cmp` triple + fixed point — must hold WITHOUT an extra bootstrap
  turn (4.5). Any `cmp` failure means a site was mis-transcribed (a `sc`/`rm` captured before an
  earlier update in the same `let` — the classic stale-alias bug; see §7).
- Effect attribution: the `eco_alloc_record /arg0 == 31/` uprobe count from §2 versus
  `/arg0 == 18/` after; the predicted `ΔBytes` from the formula; the judged stat is minor GC
  count (deterministic per binary × tree) — if it does not move by ≥ 1 and wall is flat, the
  entry is FLAT and the step is a documented no-op, not a loss.
- Rail: not required for a no-analysis-change step but cheap; run it in Phase 4 anyway.

7. **Risks, gotchas, and what NOT to do**

- STALE ALIAS: in a `let` that reads `sc = s.sched` and later updates `s` twice, the second
  update must read `s1.sched`, not `sc`. Every site of the form `{ s1 | registry = …, worklist = … }`
  where `s1` came from a helper that may itself have written `sched` (e.g. `seedSpec` 3939 after
  `recordSpecWidenedKey`) needs its group re-read from the LATEST `S`. This is the one way this
  step can break emission silently (a lost `registry` write → missing spec → fixed-point failure
  at best).
- Do NOT move `store`/`memo`/`revMemo`/`itemAux` into a group "because they co-update" (4
  sites): they are the per-node hot writers — nesting them would ADD a record per node.
- Do NOT put `lambdaCounter` in `runMemo` (4.1) and do NOT put `lssStats` anywhere (per-node
  until step 7; 32 fields, at the cap itself).
- `withScratchStore` (2033-2100) and `restoredAux`/`clearedAux` are untouched — they name only
  top-level fields.
- The `MonoGraph` record ALSO has `registry`/`ports`/`nodes` fields; a global search-and-replace
  of `.registry` would corrupt graph-level reads (Monomorphize has 32 `.registry` hits, most on
  `S`, some on the graph; `Diff.elm:172` is graph). Let the type-checker enumerate the `S` ones.
- Comments that say "S is AT the 32-slot cap" are wrong today (31) and must not be re-copied;
  the cap (`EcoOps.cpp:450-456`) stays a hard rule for `LssStats` (32) and any future group.
- Invariants: none touched (no MONO_*/LSS_* row names `S`'s layout). HEAP: only the verifier's
  32-slot rule, satisfied by every new record (6/6/4/3 fields).
- Plan §4 not to do here: N11 (driver copies are two orders below per-node writers — this step
  is worthwhile only through the per-node writers that survive 7/8/10, which is the formula's
  point); N3 (`arrowMemo` array); do not re-open `ItemAux` (13) or `Env` (14).

8. **Effort**

M — ~45 write sites and ~90 read sites across four files, all compiler-driven, plus one literal;
no design risk beyond the stale-alias trap. Split naturally into **26a** (sched), **26b**
(runMemo), **26c** (letCtx), **26d** (drv, optional), each a compilable, measurable entry; if the
§2 uprobe leg shows fewer than ~10 M surviving `S` copies, record that number in the plan entry
and skip the step.

<details><summary>Conventions used in this spec (from spec-L)</summary>

All line numbers verified against the tree on 2026-09-19 (`/work/compiler/src/...`). "Mono." =
`Compiler.AST.Monomorphized`. The loop protocol is `/work/benchmarks/lss-compile-opt-loop.md`.

---

</details>

## 10. Corrections to §2 found while writing the specifications

Each spec was written by reading the code in full, and several of them contradict the shorter §2
text. The §2 table and placement lines above were edited to match; this section is the record of
what changed and why, so the loop is run against the corrected order. Nothing here changes the
ORDER of the 26 steps — it removes four false dependencies, splits eleven steps into measurable
sub-entries, and drops two sub-parts that cannot register on a timed stat.

(a) **Step 12 (`GlobalId`) is a prerequisite of step 13 ONLY.** §2 listed it as a prerequisite of
13, 16, 23 and 25. Spec J (step 23): kernels are `TOpt.VarKernel prefix home name` occurrences,
never `TOpt.Global`s, so an id minted from `env.toptNodes` never covers them; a dense kernel id would
have to be stamped on the AST occurrence in `AssignMVarIds`, a representation change out of scope.
Step 23 therefore stands alone after step 7. Spec L (step 25): post-mono `Mono.Global` (`Global
ModuleName.Canonical Name | Accessor Name`) carries no id and AbiCloning reads it out of
`registry.reverseMapping` and `MemberOrigin`; the spec keys the fingerprint and `specsByGlobal` on
`Mono.globalHash` instead. Spec J (step 16): the per-global facts memo only makes the `16a` mint
replay's `declaredArityOf`/`kernelAliasOf` probes cheaper; `16a` does not need it. Step 12 itself
has a SOFT dependency on step 11 (its edit list assumes the `enqueueSpecStamped`/`stampSelfSpineWith`
shape step 11 leaves) and is split `12a` (facts + ids + signature/annotation/arity/alias memos +
`gid` threading — carries the direct win) / `12b` (tallies, registry re-key, `nodeResolution`).

(b) **Step 2 has an optional trailing entry `2b`** (fuse `mRecord`'s two hash folds; hash values
unchanged), only after `2a` is kept. Step 2 introduces `HashMap.getBy` (probe type ≠ key type),
which step 17 must carry unchanged if it lands later; neither depends on the other.

(c) **Step 5 is two entries.** `5a` = the direct-state entry (`unifyS`, `Store.unifyStep : Variable
-> Variable -> S -> ( Bool, S )`) plus its Store/Translate/LssInfer callers — this is what step 10
needs. `5b` = the combinator layer + `UResult`; if it measures flat it is reverted without touching
`5a`. Precondition to check first: the inliner has not already flattened the entry (spec D §2's
MLIR grep).

(d) **Step 7b is skipped.** Under `7a` every counter `7b` (`ItemAux.counters`) would hold is bumped
only when the report is on, and the loop never times a report-on run, so `7b` cannot move a judged
stat. Only five census-key sites are ungated today (spec F §3 lists them); one (`sigStats` via
`drain`'s cap) is semantic and stays.

(e) **Step 10 is seven entries, and `10a` is NOT byte-identical.** `10a` admits `MonoIf` on the
closure result spine (`Backend.sretTailOk`, `Expr.generateIf`) — a codegen change, so it needs the
extra bootstrap turn (loop Phase 1.5) and the rail. `10b`–`10g` are pure front-end rewrites, BI:
`10b` `Step ()` → `S -> S` (~70 sites), `10c` failure plumbing (23 crash sites, 11 dead arms — the
one stage with a semantic decision), `10d` the 81 `Result`-returning functions (split `10d-i`
Engine/Store/LssInfer, `10d-ii` Translate), `10e` the 182 remaining `Step a` functions (three
splits), `10f` the ~20 hot nests + scope inlining + `translateList` + pure-read twins (where the
`$sret` coverage and the minor-GC drop mostly land), `10g` cleanup. Each is judged against the last
win; a stage flat on wall but down on minor GC is a rule-2 win.

(f) **Step 11: the "test the annotation before minting" part is not BI.** The lazy render already
removes the string for every non-`HeadGround` enqueue; deciding NOT to mint from the annotation
changes analysis order, so it is a separate optional `11c` behind the bootstrap turn + rail. `11a`
(one widen per enqueue, lazy render) and `11b` (the `widenSets` memo) are BI. If `11a`'s `consS`
proves GC-negative, `11a'` (pointer return without `consS`) is the fallback.

(g) **Step 13's class table is keyed by `eqKeySpec`, not `==`.** `specMapGet` is
`HashMap.get specHashOf eqKeySpec` (Monomorphized.elm:851–853) and `eqKeySpec` is `identicalOr True`
— the registry's own equality; the member class id must map through the same relation or two
`eqKeySpec`-equal types would get different members. Split `13a` (E1–E5 + E7 + E8 for the
non-lambda kinds; `byKey` keeps only `l|` strings behind a `KLamLegacy String` bridge arm) / `13b`
(E6 + the rest of E8: lambda mints, `specWidenedKeys` retirement).

(h) **Step 15's edit depends on where step 11 left the widen.** If step 11 passes one interned
widened key (or a thunk) in from `enqueueSpecStamped`, step 15 is `15a` only: force/use it in the
created/over-budget arm (BI). If step 11 left the local `Intern.widenSets` in `enqueueSpecKeyed`,
step 15 is `15b`: move it under `created || not underBudget`, which needs the rail + one bootstrap
turn. Read `enqueueSpecKeyed` after step 11 before choosing.

(i) **Step 16 splits `16a`/`16b`.** `16a` = D1 + D8 (the instantiation mass) and D2 (mint-preserving)
+ D4 + D10 + D12 (walk-shape edits), all BI, one file. `16b` (drop the callee mints) is S to write
but costs a bootstrap turn and the rail; trailing optional, or dropped once step 13 is in.
`LssInfer.unifyParamsBestEffort` is LIVE (not dead code as an earlier reading suggested) and is one
of the sites `16a` narrows.

(j) **Step 18 is built backend-first.** `18b` caches the interned `HPointer` per string literal in a
zero-initialised global slot (`__eco_str_lit_cached`) — BI, runtime + six backend files. `18a`
(Elm: dispatch on `String.length` first, then the name) changes the compiler's own source and is
gated by the fixed point B==C. `18b` pays for every string-literal `case` in the compiler, not just
the three named functions.

(k) **Step 21 converts less than §2 said.** `specWidenedKeys` becomes `Array (Maybe String)` (or
`Array Int` with `-1` = absent if step 13 is already in) — step 13 is not required. `muTied` stays a
`Dict` (written only on a real μ-tie; `muTied=0` on the self-compile) and NO `ItemAux` field is
converted (`demandQualified` is keyed by a non-dense id). The two id ranges the arrays index are
dense (spec K §4 proves it from the `members:` report line).

(l) **Step 22 (b) does not need step 13.** The second mint in `specializeLambda` is removed by
returning the id from the first mint rather than re-deriving it; step 13 only makes the remaining
single build cheaper. Three entries: `22a` (a+b), `22c`, `22d`.

(m) **Step 26: `lambdaCounter` stays a top-level `S` field** (written by `allocLambdaId` in
Translate on a path that co-updates nothing else); the groups are `sched`, `runMemo`, `letCtx` and
optional `drv`, each its own entry. The spec's precondition is a re-run of the co-update census on
the tree AS IT IS after steps 7, 8 and 10 (`scratchpad/coupdate.py` — copy it into `benchmarks/` when
the step is reached); if the uprobe leg shows fewer than ~10 M surviving `S` copies, record the
number and skip the step.

(n) **Step 24 (settle chain) uses step 22's `enrichAnnotationsTopOnlyChanged` if present**, and
otherwise keeps the `enriched == monoType` compare; no hard dependency either way. Entries `24a`
(round-count reduction with the `varsucc|verify*` rail keeping the idempotence proof honest) / `24b`
(post-drain walks).

(o) **Step 4 is built classify-first.** `4b` (the per-run classify memo, no signature change) then
`4a` (the per-item load memo + `loadTypeC` parameter), optional `4c` (zonk memo). Step 9 reuses step
4's `groundNoArrowWith`/`aliasMemo` predicate; if step 4 has not landed, step 9 lands spec C §4.9's
helpers alone.

(p) **Steps 3 and 19 (transient union-find store, `revMemoSetIfAbsent`)** — specified last; four things
changed. **(i)** The store is a new `Eco.CellStore` kernel module (C++ store table + undo log, a JS
implementation for the bootstrap stages, and a PURE twin in `compiler/src-xhr` for Stage 1 and the
elm-test-rs suite), rooted through the runtime's external-root scanner exactly as `Eco.MVar` is, with an
explicit `pushMark`/`rollback`/`commit` API — not the "version-stamped chunks" §2 guessed at. The
Elm-visible `UnionFind`/`IORef` interface does not change, so only 22 compiler sites move. **(ii)** Step 3
is a PREREQUISITE of step 19, which §2 had as a soft "re-check". **(iii)** That re-check is answered:
the union-find store does NOT subsume `revMemo`. Folding it into `Descriptor` reopens §4 N17, and a second
lane of the same store would put a `TypeIds`-typed value inside `System.TypeCheck.IO` — a layering
inversion. A separate cell store with a paired lifecycle (stashed, restored and reset at the same four
sites) gets the whole win. **(iv)** Entries: `3a` (package, pure twin, native pins — no compiler change,
so it is gated by the eco-kernel suite and `elm-tests`, not measured), `3b` (the measured, byte-identical
compiler change — explicitly NOT split further, because the rollback sites are not correct without the
trail), `19`, and `19′` (keep the `Array`, grow geometrically — about half the win, for a series that
slid step 3 to the end). Both steps are byte-identical by construction: the same cells are read and
written in the same order, and `push` returns the index `Array.length` returned before.

(q) **Spot-check of the specs against the base tree (2026-09-19).** Seven line citations from seven
specs (A, E, G, H, I, K, F) were re-checked and hold. One precondition number was wrong: step 8's
said 40 union-find read lines (Store 12); the tree has 46 (Store 15 code + 4 doc lines, Engine 1 + 1
doc, LssInfer 17, Translate 6, Monomorphize 2). The inventory itself was complete (`addSlotSource`
2035-2103 is a row); only the gate count was corrected. The remaining specs were not re-verified
line by line — every spec's §2 gives the `grep`s to re-run before editing, and that is the intended
check.
