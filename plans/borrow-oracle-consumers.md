# Borrow-Oracle Consumers (OC) — oracle-driven promotion + unique-kernel specialization

Status: IMPLEMENTATION-READY (v1, deep-dive pass; anchors verified 2026-08-06).
Parent design: `design_docs/globalopt/borrow-inference-design.md` (v2) §2, §10–§13;
evidence base: `design_docs/borrow-inf-census.md` §15–§18.
Series relationship: this plan is the graduation doc for the three non-RC
oracle consumers left behind by the tier series —

| OC track | graduates | recorded at |
|---|---|---|
| **OC1** call-crossing aggregate promotion | U-T1.4 (tier-1, "recorded NOT scheduled") + the remainder of phase-6 item 8 | `opt-tier1-aggregate-promotion.md:1241-1246`; `opt-tier4-parked.md` row 5 |
| **OC2** closure-environment promotion | T1.3.4 (tier-1, deferred) | `opt-tier1-aggregate-promotion.md:1157-1180`; tier-4 row 5 (same toll) |
| **OC3** uniqueness-informed kernel specialization | phase-1.5 §8 "uniqueness-informed kernel specialization" (never implemented) | `borrow-inference-phase1.5-analysis-oracle-track.md` §8 |

**None of these need RC ops.** Everything here consumes the shipped Strategy-B
oracle (B0–B3.5, analysis-complete) as facts. `opt-tier3-rc-runtime.md` stays
untouched; landing any OC unit updates the corresponding `opt-tier4-parked.md`
row (housekeeping section at the end).

Adding any new `.elm` source (`Borrow/Facts.elm`, tests) requires a
reconfigure — `cmake --preset build` — because `ELM_SOURCES` is a
non-CONFIGURE_DEPENDS glob (the `ninja-clang-lld-linux` preset name in
CLAUDE.md is stale; the configure preset is `build`).

---

## 0. Economics: the T1-R1 amendment (read before any unit)

T1-R1 (`opt-tier1-aggregate-promotion.md:61-67`, verbatim premise at `:53-59`):
tier-1 transforms must be oracle-free at compile time because the always-run
analysis costs **~15% of Stage-7a wall**, far above the tier's realistic 1–5%
win. That rule is *correct for default builds* and this plan does not repeal
it. It amends it:

> **OC-R1 (the amended rule):** oracle-coupled transforms are **opt-in per
> build** behind `borrow.oracleOpt` (env `ECO_BORROW_OPT=1`), default **off**.
> A default build never runs the analysis and its MLIR stays byte-identical
> to today (this is the standing byte-identity gate). The opt-in build pays a
> *measured* facts-derivation toll (OC0.4 — expected ≪ the 15% census figure,
> because it needs the sig fixpoint but not the per-def census/histogram
> legs) and must return more than that toll **on its own target workload**.
> Self-compile is the canary, not the target: the intended consumer is user
> programs, where compile-once/run-many amortizes the toll — exactly tier-4
> row 5's second revive arm.

Two standing lessons shape every unit below (the tier pattern, now ×6):

1. **Census before machinery, every time.** Each track opens with a sizing
   unit and a pre-registered numeric decision gate. No mechanism is built
   before its gate passes.
2. **Only remove work; never add fixed overhead to a hot path.** Any variant
   that can re-introduce allocation or per-iteration state (the T1.3.6
   cancellation trap) is benchmarked **3-arm isolated** (off / prior-ship /
   +flag), never only paired.

---

## 1. Verified code anchors (all re-checked 2026-08-06)

### The oracle (producer side)

| Anchor | Fact |
|---|---|
| `Compiler/GlobalOpt/Borrow.elm:123` | `run : Config.BorrowConfig -> Mono.MonoGraph -> ( Mono.MonoGraph, BorrowStats )` — graph returned **unchanged**; all per-resource facts are computed in `mergeDef` (`:674`, escape closure `:745-828`) and discarded. The exposing list (`:1-4`) is `( BorrowStats, emptyStats, run, renderStats, analyzeDefForTest )`. |
| `Borrow.elm:125-131` | Early-out guard: analysis skipped unless `report || validate || reify /= ROff`. **Must learn the new mode.** |
| `Borrow.elm:212` / `:224` / `:239` | `type alias SigTable = Array (Maybe BorrowSig)` indexed by SpecId; `solveSigs : Array (Maybe MonoNode) -> ( SigTable, Int, Int )`; `sigLookup` (private). Sigs contain **no ResVars** (`Sig.elm:15`) — the one artifact that survives per-def analysis. |
| `Borrow.elm:190` | `buildLambdaSigs : SigTable -> Dict Int (List LssFacts.LambdaRef) -> Dict Int BorrowSig` — LSS-member-keyed sigs for closures. |
| `Borrow.elm:748-757` / `:773-780` / `:797-798` | `escapesR` (UB predicate), `escDsu` (DSU + `gets` + `escEdges`), `escapesLB r = BitSet.member (Dsu.findRoot r escDsu) escRoots` — the tight per-resource non-escape oracle, currently a local `let`. |
| `Borrow/Sig.elm:34-44` | `SigTy = { shape : MonoType, modes : Array Mode }` (ResPos pre-order of `Rty.allRes`); `BorrowSig = { params : List SigTy, result : SigTy, resultLts : List ( ResPos, Set Int ) }` — `resultLts` couples result positions to 0-based param indices. |
| `Borrow/Solve.elm:33-41`, `:376-407` | `Solved` dense arrays by ResVar; readbacks `accessMode/storageOwnedOf/reifiedOwned/ltAOf/ltPOf/alphaOf`. `solve : Int -> Bool -> Constraints -> Solved` (arg 2 = allOwned isolation flag). |
| `Borrow/Constrain.elm:57-58` | `type alias Occ = { res : List ResVar }` — **no path/region**. Emitted only from `MonoVarLocal` (`:558`, via `addOcc :287-293`). |
| `Constrain.elm:110` | `Gen.freshSites : List ( ResVar, String, Int )` — (top resvar, class, weight); classes `lit:`/`call:` × `shapeClass` (`:351-382`). |
| `Constrain.elm:109` / `:334` / `:296` | `Gen.escSeeds : List ResVar` (`escSeedAll`), `addEscEdges`. Kernel/owned-arg consumption seeds at `:1033,1063,1113,1119,1707-1709`. |
| `Constrain.elm:89-111` | `Gen` currently **21 fields** — same 32-slot GC-scan cap as `BorrowStats` (**29 fields**, `Borrow.elm:47-77`; remedy precedent = group into a sub-record, `MonoSolver/Engine.elm:371-373`). |
| `Borrow/KernelSigs.elm:35-46` | `ParamMode = PBorrowed | POwned`; `KernelSig = { params : List ParamMode, resultAliases : List Int }`; `lookup : ( Name, Name ) -> Maybe KernelSig`; 33 audited rows; whitelist (unknown ⇒ owned). |
| `Borrow/LssFacts.elm:76` / `:197` | `buildInstances : Array (Maybe MonoNode) -> ( Dict Int (List LambdaRef), Set Int )`; `query : Facts -> MonoType -> CalleeFacts`. |
| `MonoGlobalOptimize.elm:156-164` | Phase 6 = `if borrowCfg.enabled then Borrow.run … else …`; stats out via `GlobalOptStats.borrow` (`:119-123`). |
| `Builder/Generate.elm:923-961` | `runGlobalOptPhase`: GlobalOpt (`:928`) → `CafDedupe.run` (`:935`) → `CafHoist.run` (`:944`) → `MonoBuildResult` (`:958-961`). **CafDedupe/CafHoist mutate the graph AFTER Phase 6** — SpecId/walk-order-keyed facts derived in Phase 6 are stale downstream. |
| `Builder/Generate.elm:1339-1390` | `writeMonoMlirStreaming` → `MLIR.streamMlirToWriter` (`Backend.elm:140`) / bytecode (`:261`) — where facts must arrive for emission-time consumers. |

### Config / hash

| Anchor | Fact |
|---|---|
| `Compiler/Eco/Config.elm:67-78` / `:81-83` / `:317` | `BorrowConfig = { enabled, reify, report, validate }`; `BorrowReify = ROff | RRc`; defaults all-off. Decoder `:417-430`. |
| `Config.elm:532-724` | **`hash` contains no borrow token at all** — the whole borrow block is hash-inert today. Precedent for a new token: `aggp=1` at `:684-689` (emitted only when enabled, so historical caches stay valid). |
| `Builder/Eco/Config.elm:217-224`, `:429-483` | `ECO_BORROW` → `applyBorrowOverride`; `ECO_BORROW_REPORT` → `applyBorrowReportOverride` (report ⇒ enabled). |

### The tier-1 consumer machinery (what OC1/OC2 extend)

| Anchor | Fact |
|---|---|
| `Generate/MLIR/Expr.elm:7712-7894` | `walkPromo` — THE escape/use walker; verdict `Nothing`=disqualified. Its two allowance channels are **exactly oracle-shaped**: `tailSplitOk : Set Name` and `callSplitOk : Dict SpecId (Set Int)` (`:7712-7713`), today built from syntactic tables by `tailSplitAllowSet:7625` / `psplitAllowPositions:7664`. Sink list: bare read `:7721`; rebind `:7753,:7790`; non-projecting path `:7758` (`promoPathOk:8004`); case scrutinee `:7764-7781`; capture `:7882-7887`; call arg `:7829-7859` (unless `callSplitOk` grants); tail arg `:7861-7880` (unless `tailSplitOk`); nested def `:7818-7827`; alias fwd-ref `:7797-7809`. |
| `Expr.elm:7165-7188` / `:7198-7238` | `tupleBinderPromotable` / `promotableCtorCall` — T1.3.1/T1.3.2 entry points (flags `aggPromote`/`ctorInline`). |
| `Backend.elm:391-495` | `buildSretPromoted : EcoConfig -> Array (Maybe MonoNode) -> Dict Int Ctx.SretInfo`. Admission: flag; zero-capture `MonoDefine (MonoClosure …)` ≥1 param (`:403-404`); MTuple arity 2/3 result (`:405-410`); result-spine leaves construct (`sretTailOk:692-709`); ≥1 let-bound direct site (`collectSretSites:617-631`); `sretFresh` fixpoint widening `:506-551`. |
| `Backend.elm:740-904` | `buildPsplitPromoted` → `psplitFixpoint:761-771` (cap 4) → `psplitOnePass:774-904`. `planForParam:777-826`: MTuple 2/3 → `Ctx.SplitTuple`, single-ctor MCustom 2–6 fields → `Ctx.SplitCtor`. Admissibility = `Expr.paramSplitAdmissible` (`:796,:813`) with round N−1's table as allowance. **Zero-capture restriction at `:833-838`** (and sret mutual exclusion). Win pre-check `psplitScanExpr:926-1053` + `psplitSiteHit:1078`. |
| `Functions.elm:791-806`, `:817-959`, `:973-1090` | Worker/shim emission; `$sret` name `:892`, `$psplit` name `:1046`, shim projection loop `:1063-1090`. Worker split params bind via `ctx.splitAggParams` with `varMapping` **removed** (`:995,:1015-1016`) so bypass reads crash. |
| `Expr.elm:3173-3185`, `:3210-3242`, `:7503-7607` | Call-site migration: `tryPsplitCall` (freeness `psplitArgFree:3245`, emission `emitPsplitSlotArg:3372`), `trySretLetBinding`/`emitSretLetBinding`. |
| `Ops.td:113-165`, `:2862-3034` | 6 aggregate types; `eco.make.{tuple2,tuple3,record,custom,cons,closure_env}` (Pure), `eco.to_heap` (GCRootCarrier; **rejects closure_env**), `eco.from_heap`, `eco.make.closure` (`:3034`, the only allocating make). Lowerings `EcoToLLVMValueAgg.cpp:100-949` incl. `ClosureEnvMakeOpLowering:175`, `MakeClosureOpLowering:774`, `ProjectClosureFromEnvLowering:902`; registered `EcoToLLVM.cpp:448`. **No front-end producer exists for `make.record`/`make.cons`/`make.closure_env`** — free headroom. |
| Fixtures | `compiler/tests/TestLogic/Generate/AggPromoteTest.elm` (unit gate, 10 cases); `test/elm/src/AggPromoteTupleTest.elm` (corpus pin, 35 CHECK lines — every unit extends this file); codegen pins `test/codegen/value_*.mlir` incl. `value_closure_env.mlir`, `value_make_closure.mlir`. |

### The kernel side (OC3)

| Anchor | Fact |
|---|---|
| `elm-kernel-cpp/src/core/JsArrayExports.cpp:225-255` / `:268-308` | `unsafeSet` / `push` — **copy the whole node every call** (`alloc::allocArray` + element loop + slot write). Typed trampolines `copyForUnsafeSet:888`, `copyAndExtendForPush:711`. |
| `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp:1308-1400` + `runtime/src/allocator/RuntimeExports.cpp:4612` | **The hot path**: saturated `JsArray.unsafeSet/push/slice/appendN/singleton/empty/length/unsafeGet` are intrinsic-lowered (`Intrinsics.elm:324`, `:671-746`, ops `:911-947`) — `eco.array.set` → `eco_clone_array` + GEP + store; kind fixup `eco_array_set_fix_kind:4601`. Only `initialize/initializeFromList/map/indexedMap/foldl/foldr` reach `Elm_Kernel_JsArray_*` symbols. |
| `Generate/MLIR/Expr.elm:3867`, `:4222-4279`, `:764-825` | Kernel emission: intrinsic check first (`:4200`), else symbol path — `Ctx.kernelFuncSignatureFromType` → `registerKernelInstance` (`:4259`, `:920`) → symbol from `KernelAbi.kernelInstanceSymbol` (`KernelAbi.elm:182-407`). **The name is a plain string in `MonoVarKernel prefix home name tipe`; no whitelist rejects invented names** — a renamed kernel falls out of the intrinsic table onto the symbol path with a type-derived ABI. |
| Registration checklist for ONE new kernel fn | (1) C++ def `JsArrayExports.cpp` extern-C block (`:190+`); (2) decl `KernelExports.h:233-262`; (3) JIT map `RuntimeSymbols.cpp:733-777` (`KERNEL_SYM`, macro `:576-580`); (4)+(5) per-instance `_Int/_Float/_Char` suffixing only if wanted (`Generate/MLIR/KernelAbi.elm:333-390` + `Monomorphize/KernelAbi.elm:165-168` `suffixSelectingKernels`); (6) `Borrow/KernelSigs.elm` row (recommended); (7) intrinsic arm (only for op lowering); (8) Elm-visible wrapper — **not needed** for a Mono-level rewrite. |
| `runtime/src/allocator/Allocator.hpp:191/194/198` | `isInNursery/isInOldGen/isInHeap` — callable from kernels today (`ExportHelpers.hpp:11-13` includes the allocator headers; live example `JsArrayExports.cpp:227-240`). |
| `design_docs/invariants.csv:380` | **HEAP_005**: "There are no old to young pointers in the heap … the GC does not require a write barrier." The OC3 mutation rule (nursery-resident only) is chosen to leave this invariant **untouched**. Builder bit: `:574-576` HEAP_BUILDER_001-003, `Heap.hpp:145-171`, `HeapHelpers.hpp:1642-1712`. |
| Stats template | `ECO_DISPATCH_STATS`, `RuntimeExports.cpp:840-1004` (env-gated, allocation-free CAS table, atexit stderr dump) — clone verbatim for `ECO_ARRAY_STATS`. |
| Elm routing | elm/core `Array.elm:303-346` — `set`→`JsArray.unsafeSet` (tail `:309`, tree `setHelp:318-337`), `push`→`JsArray.push:346` + `insertTailInTree:401-440`. Dict/Set are pure-Elm RB trees (no kernel candidates). |

### The evidence (census, definitive 2026-07-31/08-02)

- `nonEscapingOwnedLB = 610,685` = 14.5% of resources (UB 1.96M/46.7%; LB:UB 31%) — census §18.2.
- Per-class LB histogram (§18.2): `call:custom=18892/81086 (23.3%) · call:tup2=4301/11317 (38.0%) · lit:tup2=3078/9691 (31.8%) · call:clo=4035/8741 (46.2%) · lit:clo=1831/14351 (12.8%) · lit:cons=3936/12946 (30.4%)` …
- TRUE dynamic profile (§18.3, `ECO_INLINE_ALLOC=0` census leg): Custom **38.6%** / Closure **22.1%** / Tuple2 **19.2%** / Cons 10.4% / **Array 4.4% of objects at 179 B avg ≈ 20% of bytes (286M objects, ~51 GB of 250.7 GB)**.
- Weighted promotable ≈ **23.5%** of allocation (D-T1 table §18.4); pure intra-def `lit:` slice ~6%; **the remainder is call-boundary-entangled** — T1.3.1's as-built: "tuples passed to callees whose params the ORACLE proves borrowed/non-escaping — invisible to any per-def syntactic walk" (`opt-tier1-aggregate-promotion.md:330-334`; intra-def promotion saturated at ~43 sites, ≈0 dynamic effect).
- Closure routing: `poisonedByClosure = 99,530`, `closureRouted = 11,640` (§16).
- Static JsArray mutation-family sites (§16 worklist): `unsafeSet=137, initializeFromList=122, initialize=96, push=61, appendN, singleton` — small static counts; the dynamic clone traffic is unmeasured (OC3.0a exists to measure it).

---

## OC0 — Facts export + opt-mode plumbing (prerequisite for OC1/OC2; OC3 needs only OC0.1)

### OC0.1 — Config, env, hash token

**Files: `Compiler/Eco/Config.elm`, `Builder/Eco/Config.elm`.**

1. `BorrowConfig` gains a 5th field `oracleOpt : Bool` (default `False`,
   `Config.elm:67-78/:317`); decoder gains
   `|> D.apply (D.optionalField "oracleOpt" D.bool default.borrow.oracleOpt)`
   inside `borrowDecoder` (`:417-430`).
2. **Hash token — mandatory.** In `Config.hash` (`:532-724`), mirroring the
   `aggp` precedent at `:684-689`: append `"bopt=1"` iff
   `config.borrow.oracleOpt` (emit-only-when-on keeps historical caches
   valid). This is load-bearing: the borrow block is entirely hash-inert
   today, and `oracleOpt` changes emitted MLIR (OC1) and the Mono graph
   (OC3) — without the token, opt builds silently share `eco-stuff` caches
   with default builds.
3. `Builder/Eco/Config.elm`: new `applyBorrowOptOverride` for
   `ECO_BORROW_OPT` (template: `applyBorrowOverride:429-453`): `1/true/yes/on`
   ⇒ `{ b | enabled = True, oracleOpt = True }`; `0/off` ⇒
   `{ b | oracleOpt = False }`. Apply after `applyBorrowOverride` in the
   override chain (`:217-224` block).
4. `Borrow.elm:125-131` early-out guard: add `|| cfg.oracleOpt`.

**Gate:** flag-off `--text-mlir` byte-identity + full E2E; a unit asserting
`hash` differs oracleOpt-on vs off and is unchanged off-vs-historical.

### OC0.2 — `Borrow/Facts.elm`: the distilled consumer artifact

**Create `compiler/src/Compiler/GlobalOpt/Borrow/Facts.elm`** (reconfigure).
Facts are **SpecId/member-keyed only** — no ResVars, no walk-order keys — so
they survive graph rewrites by construction (same property that makes
`BorrowSig` durable, `Sig.elm:15`).

```elm
module Compiler.GlobalOpt.Borrow.Facts exposing
    ( OracleFacts, CalleeParamFacts, derive, borrowedParams, emptyFacts )

type alias CalleeParamFacts =
    { borrowedParams : Set Int
      -- 0-based param indices i where EVERY ResPos mode of params!!i is
      -- Borrowed AND no (pos, set) in resultLts has i ∈ set.  "The callee
      -- neither retains nor returns-any-alias-of this param."
    }

type alias OracleFacts =
    { bySpec : Dict Int CalleeParamFacts        -- SpecId-keyed (def sigs)
    , byLambda : Dict Int CalleeParamFacts      -- LSS member-id-keyed
    }

derive : Mono.MonoGraph -> OracleFacts
```

`derive` mirrors `Borrow.run`'s setup without the census: build
`LssFacts` instances (`LssFacts.buildInstances`, `Borrow.elm`'s existing
wiring), run `solveSigs` (`Borrow.elm:224`), `buildLambdaSigs`
(`Borrow.elm:190`), then distill each `BorrowSig` via the predicate above.
Implementation note: the mode scan is over `SigTy.modes` (ResPos pre-order,
`Sig.elm:34-37`); a param with ANY Owned interior position is excluded — v1
takes whole-param borrowedness only (per-position splitting of a partially
borrowed param is v2 precision, not admission).

Expose `derive` from `Borrow.elm`'s public surface (extend the exposing list
`Borrow.elm:1-4`) or make `Facts` self-contained by importing
`Borrow` internals — preferred: move `solveSigs`/`buildLambdaSigs` calls into
`Facts.derive` and have both `Borrow.run` and `Facts.derive` share them
(`solveSigs` is already a top-level function; widen the exposing list).

### OC0.3 — Threading to MLIR emission (post-CafHoist derivation)

The ordering hazard (anchors §1): CafDedupe/CafHoist mutate the graph AFTER
Phase 6, so **facts for emission are derived from the FINAL graph**, not
inside Phase 6:

**Files: `Builder/Generate.elm`, `Generate/MLIR/Backend.elm`,
`Generate/MLIR/Context.elm`.**

1. `runGlobalOptPhase` (`Builder/Generate.elm:923`): after `hoistedGraph` is
   final (`:958`), when `borrowCfg.oracleOpt`:
   `oracleFacts = Facts.derive hoistedGraph`, else `Facts.emptyFacts`.
   Add `oracleFacts` to `MonoBuildResult` (`:673-674`).
2. Thread into both stream entries `MLIR.streamMlirToWriter` /
   `streamMlirBytecode` (`Backend.elm:140/:261`) — new parameter, stored on
   the context: `Ctx.oracleFacts : Facts.OracleFacts` (new field beside
   `sretPromoted`/`psplitPromoted`, `Context.elm:224-225`).
3. `Backend.buildSretPromoted`/`buildPsplitPromoted` gain the facts as an
   argument (call sites `Backend.elm:159-160/:280-281`) — unused until OC1.1.

**Gate:** with `oracleOpt=False` nothing is derived (no wall change,
byte-identity); with `oracleOpt=True` and no consumer yet (OC1 not landed),
MLIR is STILL byte-identical — this is the plumbing-inertness gate, run once
before any consumer lands.

### OC0 as-built (2026-08-06)

**Landed:** OC0.1 + OC0.2 + OC0.3 + the census0 housekeeping, with three
deliberate deviations from the spec above:

1. **`Borrow.run`'s early-out guard is UNCHANGED** (spec step OC0.1.4).
   Extending it with `cfg.oracleOpt` would make Phase 6 run the full census
   whenever opt is on — pure waste, since the facts are derived at emission.
   The guard change belongs to OC3 (the first in-pass reification) and is
   deferred there. `ECO_BORROW_OPT=1` still sets `enabled=True` (per spec),
   which today only reaches the cheap early-out.
2. **Facts are derived inside `Backend` (`deriveOracleFacts`,
   `Backend.elm`), not threaded through `MonoBuildResult`.** Both stream
   entries call `Borrow.deriveFacts` on the very graph being emitted —
   post-CafHoist by construction, and immune to any future pass inserted
   between GlobalOpt and emission. `MonoBuildResult` is untouched; the
   derivation cost lands in FEStats `PhaseMlir` (note for OC0.4 reads).
   `generateMlirModule` (the no-config test entry) keeps empty facts.
3. **`buildSretPromoted`/`buildPsplitPromoted` signatures unchanged** —
   facts live on `Ctx.oracleFacts` (`Context.elm`, record now 25/32
   fields); OC1.1 adds the Backend-side parameter when it actually
   consumes it.

Files: `Compiler/Eco/Config.elm` (BorrowConfig.oracleOpt, decoder, `bopt=1`
hash token, borrowCensus0 field deleted), `Builder/Eco/Config.elm`
(`applyBorrowOptOverride` for `ECO_BORROW_OPT`, census0 override deleted),
`Compiler/GlobalOpt/Borrow/Facts.elm` (NEW leaf: `OracleFacts` /
`CalleeParamFacts` / readers), `Compiler/GlobalOpt/Borrow.elm`
(`deriveFacts` + `distillSig`, exposed), `Generate/MLIR/Context.elm`
(`oracleFacts` field + `withOracleFacts`), `Generate/MLIR/Backend.elm`
(`deriveOracleFacts` + both ctx sites), `Builder/Generate.elm` (census0
fold + `Census0`/`borrowCensus0Line` + param deleted),
`tests/TestLogic/GlobalOpt/BorrowOracleOptConfigTest.elm` (NEW: 3 hash
units — off≡default continuity, on differs + `bopt=1`, rest-of-block
inert). Reconfigured (`cmake --preset build`) for the two new `.elm`
sources.

**Gates (all run 2026-08-06, ALL GREEN):**

- Hash units 3/3 (filtered elm-test-rs run); `elm-tests` 13,066 pass with
  the 12 failures = the known pre-existing POST_010 set (none
  borrow-related).
- **Full E2E: 1620/1620 PASSED**, exit 0.
- **Plumbing-inertness byte-identity: PASS ×2** — cold-cache Stage-7a
  self-compile (`--text-mlir`, subst workload, methodology invocation),
  `ECO_BORROW_OPT=1` vs off, `cmp`-identical both interleaved pairs
  (122,544,256 B). This also exercised `deriveFacts` end-to-end on the
  real ~31K-def graph without incident.
- **OC0.4 toll (PRELIMINARY, n=2 interleaved, subst workload, majors 9 on
  every leg):** off 215.6s/218.0s, on 237.2s/239.1s ⇒ sigs-only
  derivation ≈ **+21.3s = +9.8% wall** — below the census-mode ~15% but
  right at the OC0.4b threshold. OC0.4b (scoped derivation — constrain
  only defs reachable from candidate-class sites) is therefore **live as
  an option** for OC1, not dismissed; the D-OC1 win gate must clear this
  ~10% figure on self-compile, or the opt posture stays user-workload-only
  per OC-R1. Solver-workload toll unmeasured (subst graph has no LSS
  routing; solver adds lambda-sig work — measure when an OC1 solver leg
  exists). Full ×3 methodology legs owed at OC1.2's verdict.

### OC0.4 — Toll measurement (sizes OC-R1's denominator)

Method per `benchmarks/borrow-inf-opt.md:33-100` (cold Stage-7a, workload
engine pinned subst, interleaved ×3, majors recorded, ninja env-blindness:
`rm -f $BK/bin/eco-compiler{,.mlir}` between env flavors). Three legs:
baseline / `ECO_BORROW_REPORT=1` (the known ~15% figure, re-confirm) /
`ECO_BORROW_OPT=1` with OC0.3 plumbing only. Record the sigs-only
(`Facts.derive`) toll as **the** number every D-gate below compares wins
against. Instrument via the existing `FEStats.Handle` timing channel
(`Builder/Generate.elm:739`) if a per-phase split is wanted.

Expected: `derive` runs `solveSigs` (per-def constrain+solve inside the SCC
fixpoint) but skips the census/histogram/escape-closure legs of `mergeDef` —
meaningfully below 15%, but MEASURE, do not assume. If the toll comes out
≥10%, add a scoping step (only constrain defs reachable from candidate-class
sites) BEFORE proceeding — recorded here as OC0.4b, unscheduled.

---

## OC1 — Call-crossing aggregate promotion (U-T1.4)

**The claim to test:** the ~31.8%-of-`lit:tup2` (and the dominant `call:`
classes) blocked at call boundaries can be unlocked by feeding
oracle-proven-borrowed callee positions into the EXISTING psplit machinery —
entering through the walker's `callSplitOk` channel with **zero walker
restructuring** (anchors §1: `Expr.elm:7712-7713`).

### OC1.0 — The reason census (census-first; uses OC0 plumbing in report mode)

The tier pattern demands we know WHY call-entangled sites are not already
captured before building anything. The syntactic psplit fixpoint ALREADY
chains zero-capture workers whose param walks pass — so the oracle's delta is
confined to specific reject reasons. Bucket them.

**Files: `Generate/MLIR/Backend.elm` (census fold), `Expr.elm` (reason
plumbing), stderr report behind `ECO_BORROW_OPT_REPORT=1` (report-only:
no hash token, no graph effect — mirrors `ECO_BORROW_REPORT` posture).**

For every def: run `tupleBinderPromotable`/`promotableCtorCall` candidates
that FAIL today, and for each failing candidate whose first disqualifying
sink is a call/tail arg (`walkPromo` sinks 6/7), classify the callee position
against `Ctx.oracleFacts`:

| bucket | meaning | pre-specced consumer |
|---|---|---|
| `oc1:already` | position already psplit/sret-granted | none (sanity: should be 0 among rejects) |
| `oc1:borrowed-splittable` | `i ∈ borrowedParams(callee)` ∧ callee shape splittable (`planForParam` shapes) ∧ callee is zero-capture ∧ callee's own walk fails ONLY on sinks 6/7 at positions that are themselves oracle-borrowed (the transitive chain case) | OC1.1-A (fixpoint widening) |
| `oc1:borrowed-captured` | `i ∈ borrowedParams` via `byLambda`/`bySpec` but callee has captures (the zero-capture restriction at `Backend.elm:833-838` binds) | OC1.1-B (capture-lifting) |
| `oc1:borrowed-kernel` | arg position is a `PBorrowed` KERNEL param (callee needs `!eco.value` — would force `to_heap` re-materialization) | recorded, NOT v1 (materialization trap) |
| `oc1:borrowed-opaque` | oracle says borrowed but callee walk fails on shape/scrutinee mechanics (`promoPathOk`/`deciderScrutineeOk` rejects) | recorded, NOT v1 |
| `oc1:owned` | callee genuinely retains (sig says Owned / resultLts couples) | none — correctly blocked |

Also count, per bucket, the **weighted** share (reuse the class-weighting
discipline: multiply bucket site counts by §18.3 dynamic class shares) and a
DEV-JS leg (run the compiler's Elm source under node — the
`eco-fast-compiler-dev-loop` — as T1.3.9's census did) if the C++ loop is too
slow to iterate.

> **D-OC1 (pre-registered):** proceed to OC1.1 iff
> (`oc1:borrowed-splittable` + `oc1:borrowed-captured`) weighted share
> ≥ **3%** of allocation volume, taking the LARGEST bucket first. If both
> buckets land < 3%, record NO-GO in this file + `opt-tier4-parked.md`
> row 5 (with the census table), and stop — the oracle's call-crossing story
> is then empirically dead on this workload, and only a user-workload rerun
> revives it.

### OC1.0 as-built (2026-08-07) — **D-OC1 FAILED: 0.03% vs ≥3% ⇒ OC1.1 NO-GO**

**Built:** `Expr.oc1CensusNode` (candidate discovery mirroring the
`generateLet` hooks + `oc1Walk`, the collector mirror of `walkPromo` with
the same alias/scope/nested-frame discipline; the real `walkPromo` verdict
stays the drift-free ground truth) and `Backend.oc1CensusReport` (block
classification against `Facts.borrowedParamsOf` + callee nodes +
`KernelSigs`, bucket priority owned > closurecall > kernel > tail >
captured > opaque > splittable, §18.3-weighted rendering). Report-only
behind `borrow.oracleOptReport` / `ECO_BORROW_OPT_REPORT=1` (6th
BorrowConfig field, NOT hashed), invoked from both MLIR write paths in
`Builder/Generate.elm`. Census approximations (documented): `fwdRefd` /
`splitAggParams` empty at census altitude; TailRec synthetic `MonoUnit`
let bodies skipped; non-global callees NOT resolved through CallInfo/LSS
stamps (classified `closurecall`).

**Gates:** elm-tests 13,066 + known-12 POST_010; census-leg out.mlir
`cmp`-identical to off (report-inertness PASS); `inconsistent = 0/0/0` on
both graphs (the walker-mirror drift detector). Census cost +23.8s
(+11.2%) over the subst baseline. Full legs in `benchmarks/tier2-opt.md`
Run K.

**The census (Stage-7a self-compile, 2026-08-07):**

```
subst : candidates tup2=440 tup3=10 custom=1125
        intra 86/1/78  hard 171/4/337  inconsistent 0/0/0
        splittable 0/0/1  captured 0/0/0  kernel 0/0/1  opaque 3/0/166
        owned 28/5/406  tail 0/0/4  closurecall 152/0/132
        weighted%: splittable=0.03 captured=0 kernel=0.03 opaque=5.83
                   owned=15.3 tail=0.14 closurecall=11.16
solver: candidates tup2=440 tup3=10 custom=1266
        intra 85/1/84  hard 172/4/372  inconsistent 0/0/0
        splittable 0/0/1  captured 0/0/0  kernel 0/0/1  opaque 3/0/167
        owned 28/5/552  tail 0/0/4  closurecall 152/0/85
        weighted%: splittable=0.03 captured=0 kernel=0.03 opaque=5.22
                   owned=18.2 tail=0.12 closurecall=9.22
```

**Verdict (per the pre-registered rule): NO-GO.** The borrowed-splittable
pool is ONE candidate and borrowed-captured is EMPTY — D-OC1 = 0.03%
weighted on both graphs, two orders of magnitude under the gate. OC1.1 and
OC1.2 are NOT built. The tier pattern's seventh instance, caught for the
cost of a census. Reading the buckets honestly:

- `owned` dominates (15.3–18.2% weighted): the callees genuinely retain
  their arguments — the §15.2 genuine-owners lesson recurring at the
  aggregate-argument boundary. The oracle is not leaving borrows on the
  table here; the sites are correctly blocked.
- `closurecall` (9.2–11.2% weighted, incl. 152 of 440 tup2 candidates) is
  the ONLY possibly-recoverable mass: blocks whose callee is statically
  unknown to the census (non-`MonoVarGlobal` callee). **OC1.0b — since
  RUN (2026-08-07, as-built below): resolution found NOTHING (100%
  `unres-dyn`); the bucket is definitively dead.**
- `opaque` (~5–6%): borrowed-at-position but the callee's own param use is
  not projection-only — the materialization-trap class, correctly parked.

**Consequence for the series:** OC1's verdict is recorded, which
discharges OC2's ordering constraint (OC2.0 may run on its own evidence
whenever scheduled); OC3 was always independent. `opt-tier4-parked.md`
row 5 updated with this outcome.

### OC1.0b as-built (2026-08-07) — **lam-splittable = 0%: the closurecall bucket is definitively dead**

**Built:** `Oc1ClosureCall` now carries the resolution material
(`headAnno` singleton member of the callee type — the shipped B3.5
set-resolution route, raw arg index; `CallInfo.fastEvaluator` stamp as
fallback with `fastPapPrefix`-shifted indices), computed in the collector
(`Expr.oc1Walk`); `Backend.oc1BlockKind` resolves against a
LambdaId→member index inverted from `LssFacts.buildInstances` and
classifies through `Facts.borrowedParamsOfLambda` + the representative
instance's params/body via `paramSplitAdmissible`. New buckets:
`lam-splittable` / `lam-opaque` / `lam-owned`, with the unresolved residue
SPLIT BY CAUSE — `unres-dyn` (no anno, no stamp) / `unres-blocked` /
`unres-noinst` — so a zero result is self-certifying, not silent. D-line:
`D-OC1.0b lam-splittable` (gate ≥3%, consumer = OC2).

**Gates:** elm-tests 13,066 + known-12; solver census leg out.mlir
`cmp`-identical to solver off; `inconsistent=0/0/0`; solver census cost
+34.1s (+10.1%). Run L in `benchmarks/tier2-opt.md`.

**The verdict: 0%, certified.** On the solver graph every single former
`closurecall` block classified `unres-dyn` (152/0/86;
`unres-blocked = 0`, `unres-noinst = 0`): at no blocking site does the
callee carry a singleton lambda-set annotation or a `fastEvaluator`
stamp. The mechanism worked and found nothing to resolve — by emission
time AbiCloning has already devirtualized every singleton-set call to
direct dispatch, so the closure-call residue blocking promotion
candidates is TRUE dynamic dispatch, exactly T1.3.4's ordering-decision
reason 1, now measured on this population. Subst control behaved as
predicted (all-LTop ⇒ `unres-dyn` 152/0/133, lam-* zero).

**Multi-set extension (2026-08-07, same day):** resolution widened from
singletons to FULL member lists (`Oc1ClosureCall` carries the whole
`LSet ms`); multi-member sets classify via the BORROW_006-style meet
(`oc1SetKind`: any-owned wins, any-opaque next, `lamset-splittable` only
on UNANIMITY — a set-wide uniform split ABI needs every member
conforming; `unres-set` diagnoses member-unresolvable sets). Result:
**`lamset-*` = 0 and `unres-set` = 0 — no multi-member set exists at any
blocking site; the entire residue is `LTop`.** Consistent with the
pipeline's shape: all-keyed specialization dissolves per-path
multiplicity into singleton-keyed specializations (already devirtualized
by AbiCloning), so only INTRINSIC multi-sets could appear here — and
none do at these positions (or were `maxSetSize`-widened to LTop).
`D-OC1.0b-set lamset-splittable = 0%`.

**Consequence:** the last open OC1 bucket closes — the OC1 kill is now
complete on every bucket and certified on all three resolution routes
(singleton anno, fastEvaluator stamp, multi-set meet): `owned` =
correctly blocked, `unres-dyn` = pure-LTop dynamic dispatch, `opaque` =
mechanics, splittable pool = 1. The only remaining revive condition for
tier-4 row 5 is a USER workload whose OC1.0 census clears the gate. For
OC2, the negative is informative twice over: the closure-mediated
call-argument population contains zero devirtualizable residue AND zero
closed multi-sets, so OC2's case rests entirely on its own
`oc2:direct-only` candidate census, and the "set-wide uniform ABI"
consumer sketch has no population here.

### OC1.1 — Mechanism (two pre-specced variants; build only the gated winner) — **NOT BUILT (D-OC1 NO-GO above)**

Both variants share: flag = `borrow.oracleOpt` (hash `bopt=1`, OC0.1);
admission tables built in `Backend.elm` where `oracleFacts` already arrives
(OC0.3); call-site migration and the walker allowance ride the EXISTING
channels (`tryPsplitCall`, `psplitAllowPositions` → `callSplitOk`).

**OC1.1-A — oracle-widened psplit fixpoint (the `oc1:borrowed-splittable`
bucket).** Edit `Backend.psplitOnePass` (`:774-904`):

- `planForParam` admission for position `(sid, i)` additionally passes when:
  shape splittable (unchanged shapes: `SplitTuple` MTuple 2/3, `SplitCtor`
  single-ctor 2–6 fields) ∧ `i ∈ borrowedParams(sid)` ∧
  `Expr.paramSplitAdmissible` run with a WIDENED allowance set: sinks 6/7 at
  positions `(sid2, j)` are permitted iff `j ∈ borrowedParams(sid2)` AND
  `(sid2, j)` is in the current round's candidate table (the same
  prev-table discipline `psplitOnePass` already uses — this makes
  oracle-borrowed chains converge exactly like syntactic chains, cap 4
  rounds unchanged).
- **v1 strictness:** NO `to_heap` re-materialization inside workers. Any
  whole-use not covered by the widened allowance keeps the reject. (The
  materialization variant is `oc1:borrowed-kernel`'s consumer — deliberately
  out of v1; it re-adds allocation on a path we do not control, the exact
  shape of the borrow perf-tune lesson "only remove allocation".)
- Win pre-check (`psplitScanExpr`) unchanged — a widened admission with no
  justifying site still drops out. Mutual exclusion with sret unchanged.
- The worker/shim emitters (`Functions.elm:973-1090`) and
  `emitPsplitSlotArg` need **no change** — they are table-driven.

**OC1.1-B — capture-lifting (the `oc1:borrowed-captured` bucket).** Only if
D-OC1 selects it. Investigation step FIRST (time-boxed): determine whether
the zero-capture restriction at `Backend.elm:833-838` is load-bearing (the
worker cloning path `generatePsplitWorkerAndShim` assumes the
`MonoClosure` has no capture params in its signature flattening
`:1009-1010`) or conservatism. If load-bearing: the worker keeps its capture
params verbatim and splits only regular params — spec the signature as
`(captures..., split scalars...)`, shim unchanged shape. Fixtures MUST
include a capture-carrying helper called through LSS fast-dispatch. If the
investigation finds the capture ABI genuinely entangles (REP_CLOSURE_*
territory), STOP and record — do not fight the backend here; that is OC2's
risk budget, not OC1's.

**Fixtures (both variants):** extend `AggPromoteTupleTest.elm` (named cases,
CHECK-pinned): `oborrowchain` (A: two-hop borrowed chain where the middle
def's own walk fails today), `oborrowneg` (callee stores the param — sig
Owned — must NOT promote), `oborrowalias` (callee returns a field of the
param — resultLts couples — must NOT promote), plus for B: `oborrowcap`
(capture-carrying borrowed callee). Unit cases in `AggPromoteTest.elm`
asserting the admission table directly (follow the existing 10-case idiom).

### OC1.2 — Verdict (Run N in `benchmarks/borrow-inf-opt.md`)

3-arm isolated: off / prior-ship / `+ECO_BORROW_OPT` (which now includes the
toll AND the win). Cold Stage-7a ×3 interleaved + majors; per-tag allocation
census leg with `ECO_INLINE_ALLOC=0`; A/B `cmp` of subst-mode
`borrowopt-out.mlir` for workload identity. **Decision rule:** default-off
regardless of outcome (OC-R1); the verdict decides whether the flag is
*documented as recommended* for user-program release builds. Also record the
realized-vs-census reconciliation (sites admitted vs `oc1:*` buckets) — the
placement-bug detector for the admission logic.

Full gate battery per landing: E2E full (teed once, grep the file), unit +
corpus fixtures, flag-off byte-identity, bootstrap fixed point,
`ECO_HEAP_VALIDATE` corpus leg, serial vs `elm-tests`.

---

## OC2 — Closure-environment promotion (T1.3.4) — strictly after OC1

Ordering rationale (from T1.3.4's own record, quoted at
`opt-tier1-aggregate-promotion.md:1165-1180`): riskiest backend surface
($cap/$clo, REP_CLOSURE_*), 89% of the old program's rejection mass, and its
honest path needs the borrow-facts export — which OC0/OC1 will have built and
battle-tested. Do not start OC2 until OC1.2's verdict is recorded.

### OC2.0 — Census: how much of `lit:clo` is intra-def-consumable?

The LB histogram says `lit:clo = 1831/14351 (12.8%)` non-escaping and
`call:clo = 4035/8741 (46.2%)`; dynamic closure share is 22.1% — but the
admissible subset is closures whose EVERY use is a saturated direct call
with a known single target. Extend the OC1.0 census fold: for each
`MonoClosure` let-binding, classify uses via the walker (a `walkPromo`
variant tracking the closure binder):

- `oc2:direct-only` — every use is a saturated direct call (CallInfo
  `fastEvaluator` stamp present / LSS singleton member) in the same def.
- `oc2:call-crossing` — additionally passed to a callee whose sig proves the
  function param borrowed (`borrowedParams`) — the OC1-composed class.
- `oc2:papExtend` / `oc2:escape` — disqualified (papExtend traffic was 89%
  of historical rejections — expect this bucket to dominate; that
  expectation failing is exactly what the census is for).

> **D-OC2 (pre-registered):** proceed iff `oc2:direct-only` weighted share
> ≥ **2%** of allocation. `oc2:call-crossing` is recorded for a v2 and does
> NOT count toward the gate (it stacks OC1 risk on OC2 risk).

### OC2.0 as-built (2026-08-07) — **D-OC2 FAILED: 0.13% vs ≥2% ⇒ OC2.1 NO-GO**

**Built:** `Backend.oc2CensusReport` — self-contained consumption walk over
every let-bound `MonoClosure` binder (callee-position saturated calls vs
arity-mismatched PAP uses vs arg-position passes classified against
`Borrow.deriveFacts` spec sigs + `KernelSigs` vs everything-else escape;
all 18 `MonoExpr` arms; aliases counted escape — conservative for the
gate; TailRec `MonoUnit` bodies skipped). Denominator = ALL closure
creation sites (inline-arg lambdas are sites, never candidates). Behind
`borrow.oracleOptReport` / `ECO_BORROW_OPT_REPORT=1` (report-only, NOT
hashed), hooked into both MLIR write paths. NO Expr.elm changes.

**Gates:** elm-tests 13,066 + known-12 POST_010; solver census-leg
out.mlir `cmp`-identical to off; census cost +36.2s (+10.8%). Run K
(2026-08-07 series) in `benchmarks/tier2-opt.md`.

**The census (Stage-7a self-compile):**

```
solver: sites=14518 letBound=7417
        direct-only=84  cross=884  pap=5  escape=6444  dead=0
        weighted: direct-only=0.13  cross=1.35
subst : sites=13681 letBound=6921
        direct-only=79  cross=823  pap=5  escape=6014  dead=0
        weighted: direct-only=0.13  cross=1.33
```

**Verdict (per the pre-registered rule): NO-GO — OC2.1/OC2.2 NOT built.**
The tier pattern's eighth instance. Reading it honestly:

- The site total cross-checks the escape census (`lit:clo` = 14,351 §18.2)
  — the universe is right. Half of all closure sites are inline-arg
  lambdas, structurally outside the intra-def class.
- **87% of let-bound candidates escape**: the old escape program's
  89%-closure-rejection figure reproduced at candidate level, now with
  per-use cause. Bound closures exist to be passed — the intra-def
  direct-call-only class is 84 sites (0.58% of sites, 0.13% weighted),
  ~15× under the gate. Even perfect recovery of every candidate class
  (upper bound 22.1% × 7417/14518 ≈ 11.3%) would ride mostly on `escape`
  sites the mechanism cannot touch.
- `cross` = 884 / 1.35% weighted is the only nontrivial signal: closures
  passed exclusively to oracle-proven-borrowed positions (the OC1-composed
  v2 class). Under the gate even if it were eligible, and its consumer is
  the same closure-ABI surface — recorded, not scheduled.
- `pap` = 5: papExtend traffic among LET-BOUND closures is negligible —
  the historical 89% papExtend-rejection mass lives in the inline-arg and
  escape populations, not here.

**Consequence:** T1.3.4 stays parked with its record now census-backed at
the candidate level; the OC series' closure-env track terminates. The OC
series overall: OC1 dead (all routes), OC2 dead (this census), OC3
remains the sole live track (clone census first).

### OC2.1 — Mechanism (intra-def only, v1) — **NOT BUILT (D-OC2 NO-GO above)**

For an admitted closure binding: emit the environment via
`eco.make.closure_env` (`Ops.td:2942`; lowering `ClosureEnvMakeOpLowering`
already in-tree; front-end producer is NEW — first consumer of the warm
Phase-4 plumbing). Each use site is a direct call to the known target
(`fastEvaluator` LambdaId): emit the target's `$cap`-style direct call with
env slots projected via `ProjectClosureFromEnvLowering` (`:902`) or passed
as scalars (decided by a short spike against the existing $cap-inlining
machinery — memory: `$cap-inlining v3` shipped; reuse its calling
convention rather than inventing one).

Constraints (all hard):
- `eco.to_heap` REJECTS `closure_env` by design — there is no materialization
  escape hatch; admission must therefore be exact (any non-direct use ⇒
  reject at admission, enforced again by a crash arm at emission, the
  `splitAggParams`-removal idiom).
- Read REP_CLOSURE_* + CGEN_064 + REP_AGG_001 amendments BEFORE touching
  emission (invariants discipline; CLAUDE.md).
- New invariant row(s) minted for "value-form env never reaches a papExtend/
  generic-apply boundary" per `design_docs/invariants.csv` discipline.

**Fixtures:** `AggPromoteTupleTest.elm` cases `oclolocal` (make+call only),
`ocloescape` (closure returned — reject), `oclopap` (partial application —
reject); codegen pin extending `value_closure_env.mlir`/
`value_make_closure.mlir`; unit cases in `AggPromoteTest.elm`.

### OC2.2 — Verdict (Run O)

Same battery as OC1.2. Extra watch: closure-dispatch event counters (the LSS
`ECO_CLOSURE_STATS` census, `RuntimeExports.cpp:~790-838`) — env promotion
must not regress dispatch (the U2b lesson: fewer events ≠ faster).

---

## OC3 — Uniqueness-informed kernel specialization (JsArray first)

Independent of OC1/OC2 (needs OC0.1 only — the flag/hash plumbing, not the
facts export: the rewrite runs INSIDE Phase 6 where `Solved` is live).
Runs its cheap census (OC3.0a) in parallel with OC1.0.

### OC3.0a — Runtime clone census (cheapest signal first; NO compiler work)

Every hot `Array.set/push` copy funnels through `eco_clone_array`
(`RuntimeExports.cpp:4612`) or the typed trampolines/kernel symbols
(`JsArrayExports.cpp:711-946, 225-308`). Add `ECO_ARRAY_STATS` (clone the
`ECO_DISPATCH_STATS` template `:840-1004`): count calls + bytes copied at
`eco_clone_array`, `copyForUnsafeSet`, `copyAndExtendForPush`,
`Elm_Kernel_JsArray_unsafeSet`, `_push`. Run the standard workloads
(self-compile; elm-aws-codegen canary; any user workload available).

> **D-OC3a (pre-registered):** proceed iff clone traffic ≥ **1% of total
> allocation bytes** (denominator: the `ECO_INLINE_ALLOC=0` census figure,
> 250.7 GB on self-compile) on at least one target workload. Array is 4.4%
> of objects / ~20% of bytes allocated — if little of that is clone churn,
> the track dies here for the cost of one stats block.

### OC3.0b — Static licensing census (inside `mergeDef`; report-mode only)

The uniqueness license, defined precisely (v1, deliberately
under-approximating):

A kernel call argument `arr` at a candidate site is **statically unique** iff
1. the arg expression is a bare `MonoVarLocal x`;
2. `x`'s binding is a **fresh-in-def** producer — its top resvar appears in
   `Gen.freshSites` (i.e. a construct or callee-fresh call result, NOT a
   param, NOT a field/projection read — `unsafeGet` results alias the parent
   via `resultAliases` and correctly fail this);
3. that top resvar appears in **exactly one** `Occ` (this call's read) —
   count over `Constraints.occs`;
4. `alphaOf r solved = ∅` and `r ∉ resultResSet`;
5. the resvar's ESC-class contains **no escape seed other than the candidate
   call's own consumption seed**. Mechanically: extend `Gen.escSeeds :
   List ResVar` → `List ( ResVar, EscSrc )` with
   `type EscSrc = EscKernelArg Int {- siteId -} | EscOther` (kernel-arg
   seeds stamped with a per-def `siteId` minted at the call; all other
   producers pass `EscOther`); the license check recomputes `escRoots` with
   the candidate site's own seeds masked. (`Gen` is at 21 fields — the
   `siteId` counter fits; keep ≤32.)

Chains compose: `a1 = set i v a0; a2 = set j w a1` — each intermediate is
fresh, single-occurrence, unaliased ⇒ the whole chain licenses. The
persistent-structure cases (`Array.set` tree path mutating a shared subtree)
correctly FAIL condition 2/5 — the subtree arrives via `unsafeGet`.

Census output: per-kernel licensed-site counts + (via DEV-JS or a licensed
`siteId` list) which sites. New counters ride the existing Dict-histogram
pattern (`escClassHisto` precedent) — **do not** add >1 scalar field to
`BorrowStats` (29/32).

> **D-OC3b:** proceed to mechanism iff licensed sites cover ≥ **25%** of the
> dynamic clone traffic measured in OC3.0a (correlate via the per-symbol
> stats split). Otherwise record NO-GO with both tables.

### OC3.1 — The reify rewrite (compiler side)

**The site-mapping problem and its resolution.** `Occ` carries no
path/region (anchors §1) — so the rewrite uses **deterministic re-walk
correlation**, made safe by construction:

- **Files: `Borrow/Constrain.elm` (siteId minting, OC3.0b), new
  `Borrow/ReifyUnique.elm` (reconfigure), `Borrow.elm` (wiring).**
- In `mergeDef`'s scope (where `solved`, `da`, and the license set are
  live), when `cfg.oracleOpt`: run `ReifyUnique.rewriteDef`, a traversal
  that re-mints `siteId`s with the SAME discipline as `constrainExpr`
  (factor the kernel-call-site enumeration into ONE shared helper used by
  both walks — the enforcement is structural, not by convention) and
  rewrites licensed sites:
  `MonoCall (MonoVarKernel p "JsArray" "unsafeSet" t) [i, v, arr]` →
  same call with name `"unsafeSetUnique"` (and `push` → `pushUnique`).
  The MonoType is unchanged (same ABI shape).
- **Parity assert:** the rewrite walk's final `siteId` counter MUST equal
  the constrain walk's; on mismatch `Debug.todo "OC3: site-walk drift"` —
  loud, immediate, and covered by a unit that runs both walks over every
  fixture def.
- `Borrow.run`'s signature stays `( MonoGraph, BorrowStats )` — in opt mode
  the returned graph is now the REWRITTEN graph (this is the first
  graph-affecting borrow mode; the flag-off byte-identity gate is unchanged,
  and flag-on identity is deliberately given up — hash token `bopt` exists
  for exactly this).
- Downstream survival: CafDedupe/CafHoist do not touch `MonoVarKernel`
  names; the renamed call flows to emission, falls out of the intrinsic
  table (`Intrinsics.elm:671-746` has no `unsafeSetUnique` arm — desirable:
  it must NOT take the `eco_clone_array` lowering), and lands on the
  type-derived symbol path (`Expr.elm:4222-4279`) as
  `Elm_Kernel_JsArray_unsafeSetUnique`. No per-instance suffix rows in v1
  (boxed-root only — skip registration sites 4/5/7/8).

**KernelSigs row (site 6):** `unsafeSetUnique`/`pushUnique` =
`params = [POwned, POwned, POwned]` / `[POwned, POwned]`,
`resultAliases = []` — the array param is CONSUMED (destroyed); sound and
conservative for any later analysis run over rewritten graphs.

### OC3.2 — The runtime variants (C++ side)

**Files: `elm-kernel-cpp/src/core/JsArrayExports.cpp`,
`elm-kernel-cpp/src/KernelExports.h`,
`runtime/src/codegen/RuntimeSymbols.cpp`.** (Registration checklist items
1–3 + 6; NOT 4/5/7/8 in v1.)

```cpp
// beside Elm_Kernel_JsArray_unsafeSet (JsArrayExports.cpp:225)
HPtr Elm_Kernel_JsArray_unsafeSetUnique(HPtr index, HPtr value, HPtr array) {
    // License: compiler proved `array` statically unique & dead after this
    // call.  Mutation is STILL residency-gated: in-place only while the
    // array is nursery-resident, so no old-gen slot is ever written and
    // HEAP_005 (no old→young pointers, invariants.csv:380) holds untouched.
    if (Allocator::instance().isInNursery(array.raw()))
        { /* bounds-checked slot store + kind fixup; NO allocation */ }
    else
        return Elm_Kernel_JsArray_unsafeSet(index, value, array); // copy path
}
```

- The in-place path allocates nothing ⇒ no safepoint ⇒ no relocation hazard
  mid-operation. Writing young←young / young←old edges is always legal; the
  promoted case (array survived a minor GC — possible even for unique
  values) falls back to the copy path, preserving HEAP_005 with zero
  barrier cost. **No invariants.csv amendment is required**; add an
  `ECO_HEAP_VALIDATE`-gated assert that the in-place branch only ever fires
  on nursery-resident objects.
- Builder bit: NOT used (the array is already user-reachable; HEAP_BUILDER_003
  forbids the bit here — the residency check replaces it).
- `ECO_ARRAY_STATS` gains `unique_hit` / `unique_promoted_fallback` counters
  in the same entry struct — the nursery-residency hit rate is the number
  that decides whether v2 (per-instance `_Int/_Float` variants, or an
  `eco.array.set_in_place` intrinsic for the hot path) is worth it.
- `push`'s in-place variant needs capacity it does not have (arrays are
  exact-sized, `allocArray(len+1)` at `:293`) — **v1 ships `unsafeSetUnique`
  only**; `pushUnique` is recorded as v2 behind a capacity/slack redesign
  (a heap-layout change — separate plan if OC3.3 justifies it). OC3.0b's
  census MUST therefore report `unsafeSet`-licensed sites separately;
  D-OC3b applies to the set-only slice.

### OC3.3 — Verdict (Run P)

Full battery: E2E + string/slice suite + **`ECO_HEAP_VALIDATE` corpus AND
GC-pressure legs** (mutation is the first mutator-time heap write outside
builders — the validator suite is the gate that catches an escaped license);
bootstrap fixed point flag-on AND flag-off; 3-arm isolated wall + the
`ECO_ARRAY_STATS` before/after clone-bytes delta; census-vs-realized
reconciliation (licensed sites vs `unique_hit` counts). Watch: `unique_hit`
rate < ~50% ⇒ the promoted-fallback path dominates and the win evaporates —
record honestly against D-OC3a's prediction.

---

## Ordering & expected yield

```
OC0.1 ──┬── OC3.0a (runtime clone census — cheapest, start immediately)
        │        └─ D-OC3a ─ OC3.0b ─ D-OC3b ─ OC3.1 ─ OC3.2 ─ OC3.3
        └── OC0.2 ─ OC0.3 ─ OC0.4
                     └─ OC1.0 ─ D-OC1 ─ OC1.1(A|B) ─ OC1.2
                                              └─ (after verdict) OC2.0 ─ D-OC2 ─ OC2.1 ─ OC2.2
```

Honest yield brackets (all census-gated, none promised): OC1 rides the
call-entangled remainder of the ≈23.5% weighted promotable mass (§18.4) —
the intra-def ~6% is already saturated at ≈0 dynamic effect, so OC1.0's
bucket split IS the yield estimate, not the 23.5%. OC2 is bounded above by
the 5.6%-weighted closure class × the `oc2:direct-only` fraction. OC3 is
bounded above by the OC3.0a clone-bytes figure × the licensed × nursery-hit
fractions. The tier pattern says expect the gates to kill some of these —
that is what they are for; a NO-GO with its table is a deliverable of this
plan, recorded here and in `opt-tier4-parked.md`.

## Gates summary

Every landing: full E2E once (`cmake --build build --target full 2>&1 | tee
/tmp/test_output.txt`, grep the file, NEVER re-run); `elm-tests` serial
(typed-artifacts cache race); flag-off `--text-mlir` byte-identity; corpus
`.elm` touched before every flag-on leg (env-blind harness); bootstrap fixed
point for graph-affecting units (OC1.1, OC2.1, OC3.1); `ECO_HEAP_VALIDATE`
for OC3; benchmarks as Runs N/O/P in `benchmarks/borrow-inf-opt.md` under
its methodology block (cold Stage-7a, workload engine pinned subst,
interleaved ×3, majors recorded, `ECO_INLINE_ALLOC=0` census legs, ninja
env-blindness `rm -f $BK/bin/eco-compiler{,.mlir}`); solver-leg binaries
minted via the NATIVE binary (Stage-5 node is 4 GB-pinned).

## Risks / standing constraints

- **32-slot GC-scan cap**: `BorrowStats` 29/32, `Gen` 21/32 — new counters
  ride Dict-histogram fields or a grouped sub-record (Engine.elm precedent).
- **`MonoGraph.callEdges` is empty at Phase 6** — never read it; reuse the
  borrow driver's re-collected edges.
- **CafDedupe/CafHoist run after Phase 6** — emission-time facts derive from
  the post-hoist graph ONLY (OC0.3); the OC3 rewrite is safe because kernel
  names survive both passes.
- **Hash discipline**: `bopt=1` token (OC0.1) before ANY graph/MLIR effect
  lands; report-only modes stay tokenless.
- REP_AGG_001 / CGEN_064 / CGEN_066/067 re-read before touching Backend or
  Functions emission; REP_CLOSURE_* before OC2.1; invariants.csv discipline
  for any new rule (OC2 mints; OC3 explicitly needs no amendment).
- The T1.3.6 cancellation trap: every new flag benchmarked 3-arm isolated.
- The materialization trap: NO `to_heap` inside workers in v1 (OC1.1-A
  strictness); the `oc1:borrowed-kernel` bucket stays parked until dynamic
  heat evidence exists.

## Housekeeping owed on landing

- `opt-tier4-parked.md` row 5 (oracle-coupled reification): point its
  "revive iff" at this plan; record each D-gate outcome there.
- `opt-tier1-aggregate-promotion.md` U-T1.4 / T1.3.4: add "graduated to
  `plans/borrow-oracle-consumers.md`" pointers.
- `borrow-inference-phase6-v2-backlog.md` item 8: note the call-crossing
  remainder now lives here (the intra-def half shipped in tier 1).
- While in `Builder/Eco/Config.elm`: the long-owed `ECO_BORROW_CENSUS0`
  deletion (`Compiler/Eco/Config.elm:111` `borrowCensus0`,
  `applyBorrowCensus0Override:628-648`, the `Builder/Generate.elm:1071-1073`
  fold) — superseded by `ECO_BORROW_REPORT=1`; delete in OC0.1's commit.

## References

Oracle: `Borrow.elm` (driver/census/escape closure), `Borrow/{Solve,Sig,
Constrain,Rty,Lifetime,KernelSigs,LssFacts,Dsu,Mode}.elm` — anchors §1.
Tier-1 machinery: `opt-tier1-aggregate-promotion.md` (T1-R1 `:61-67`,
U-T1.4 `:1241-1246`, T1.3.4 `:1157-1180`, step yields `:1181-1188`);
`Backend.elm:391-904`, `Functions.elm:791-1090`, `Expr.elm:3173-3485,
5343-5425, 7146-8202`, `Ops.elm`, `Ops.td:113-165/2862-3034`,
`EcoToLLVMValueAgg.cpp`, `EcoToLLVM.cpp:448`. Kernel side:
`JsArrayExports.cpp`, `KernelExports.h:233-262`, `RuntimeSymbols.cpp:576-777`,
`EcoToLLVMHeap.cpp:1308-1400`, `RuntimeExports.cpp:4601-4640/840-1004`,
`Allocator.hpp:191-201`, `invariants.csv:380/574-576`. Evidence:
`design_docs/borrow-inf-census.md` §15.1 (predicate), §15.2 (kernel audit),
§16 (definitive census), §18 (escape closure, weighting, dynamic
correction, D-T1). Method: `benchmarks/borrow-inf-opt.md:10-102`.
