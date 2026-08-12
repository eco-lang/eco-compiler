# Kernel-Opt 13: Mono-level CSE of pure calls (execute cse-pure-calls)

**Status: IMPLEMENTATION-READY v3 — 2026-08-10.** (v2 deepened from OUTLINE v1; v3 =
adversarial verification pass, every load-bearing anchor and API re-read in the tree.
v3 corrections worth knowing before you start: the `MonoGraph` effect/call caches are DEAD
at this pass's placement (0.1); `censusCfg` is already taken in the target `let` (3.4);
the three Config.elm append points are :47/:338/:361, **not** the `cafMemo` neighbourhood;
the provisional kernel list is now the intersection with kernel-opt-07's certified rows;
and Phase 2 asks the Debug policy for a **prohibition (D-2)**, not the merge licence v2
mistakenly requested.) Derives from `design_docs/kernel-boundary-reduction.md`
H3 (:2156-2164, re-read 2026-08-10); executes the pre-existing `plans/cse-pure-calls.md`
(NEW 2026-08-05, UNSIZED, census-gated), whose blocking precondition — a kernel purity
classification — is delivered by kernel-opt-07's `cseSafe` bit. Mechanics live in the
wrapped plan **by section reference**; everything needed to *build* the census and the
pass is lifted into this file.

## Goal

Execute `plans/cse-pure-calls.md`: a bounded-scope common-subexpression-elimination pass
over pure Mono-level calls, targeting the probe-then-insert idiom
(`if Set.member (f x) s then ... else Set.insert (f x) s` — `f x` built twice,
cse-pure-calls.md:49-58). Category B: a compiler pass, so it speeds every program eco
compiles, not just the compiler. Its win mechanism is *deleting executed work* — the only
mechanism (besides retention) this codebase has ever measured moving wall.

## Files touched

| file | change |
| --- | --- |
| `compiler/src/Compiler/GlobalOpt/CsePurity.elm` | **NEW (Phase 0)** — shared purity oracle: transitive Debug/effect-free spec BitSet + kernel `cseSafe` query (provisional list now, `KernelFacts.lookup` post-07) |
| `compiler/src/Compiler/GlobalOpt/CseCensus.elm` | **NEW (Phase 0)** — C1 census (`report : String -> CseCfg -> Mono.MonoGraph -> String`), distance buckets, kernel-opt-11 dead-call ride-along |
| `compiler/src/Compiler/GlobalOpt/MonoCse.elm` | **NEW (Phase 3 only — NOT built in Phase 0)** — C2 bounded-scope CSE (`run : { minCost : Int, maxPerDef : Int } -> Mono.MonoGraph -> ( Mono.MonoGraph, Stats )`), default-off |
| `compiler/src/Compiler/Eco/Config.elm` | `+ CseConfig` type (and its name in the `exposing` list, :2); `cse : CseConfig` appended at the END of `EcoConfig` (:34-48); `default` row appended after `sretTailFuncs = True` (:338, record closes :339); `cseDecoder` + one `D.apply` appended at the END of `decoder` (:346-361); `cse=1`/`cseMin=`/`cseMax=` hash tokens appended to `hash` (:540-744, after the `bopt=1` block at :732-743) |
| `compiler/src/Builder/Eco/Config.elm` | 4 env overrides (`ECO_CSE`, `ECO_CSE_REPORT`, `ECO_CSE_MIN_COST`, `ECO_CSE_MAX_PER_DEF`) appended to the `Task.andThen` chain after the `cfg29`/`ECO_BORROW_OPT` link (:260-264) |
| `compiler/src/Builder/Generate.elm` | 2 imports into the `Compiler.GlobalOpt.*` block (:70-77); `runGlobalOptPhase` gains a `Config.CseConfig` param (:922-923) and its call site (:845); `CseCensus.report` clause in the stderr chain (Phase 0); `MonoCse.run` wired between :928 and :934 (Phase 3) |
| `design_docs/invariants.csv` | `+ CSE_001` row (merge licence + exclusions), lands **with** C2, not before |
| `design_docs/debug-log-ordering-policy.md` | **referenced, not re-drafted** — authored by kernel-opt-11 Phase 1; C2 does not land before it exists |
| `benchmarks/kernel-opt.md` | C1 census tables (self-compile + aws) and, if the gate passes, the C2 wall A/B legs |
| `plans/kernel-opt-13-mono-cse.md` | the C1/D-C table recorded here regardless of outcome (§ "C1 result") |

New `.elm` files are picked up by the `file(GLOB_RECURSE ELM_SOURCES ...)` at
`compiler/CMakeLists.txt:126` — **`cmake --preset build` reconfigure is mandatory after
adding them** (glob is evaluated at configure time; eco-cmake-preset memory).

## Evidence

- **The plan exists and is UNSIZED** (cse-pure-calls.md:3): "Census (C1) before anything
  else." Nothing here is sized until C1 runs.
- **What blocked it**: carve-out 3 (cse-pure-calls.md:81-86) — "Not every `MonoVarKernel`
  is pure... CSE needs an explicit purity classification of kernel names, defaulting to
  *impure* for anything unlisted." That is kernel-opt-07's per-kernel `cseSafe` bit (H3 at
  kernel-boundary-reduction.md:2159 calls it `pureElm`; **`cseSafe` is the canonical name**
  — the cross-plan contract, kernel-opt-07 Phase 1).
- **There is no Elm-level CSE anywhere in the pipeline** (cse-pure-calls.md:24-31),
  re-verified 2026-08-10: `ls compiler/src/Compiler/GlobalOpt/` = AbiCloning, Borrow,
  CafCensus, CafDedupe, CafHoist, ListCombinators, MonoGlobalOptimize, MonoInlineSimplify,
  MonoReturnArity, Staging (+ `Borrow/`, `Staging/`). None eliminates redundant computation.
  LLVM's CSE runs downstream of every boxing/closure/layout decision and sees two identical
  *allocation sequences* it may not merge.
- **Favorable prior — K6** (cse-pure-calls.md:33-45): construction-time hash-consing is
  dynamic CSE over type construction; measured solver **−5.07% wall / −7.04% promotion /
  −13.2% RSS / majors 13→10** at **+0.02% MORE objects**. A static CSE pass is the
  compile-time generalization of that mechanism.
- **Anti-prior — K5**: eager retrofit interning, **+18.3% wall, REVERTED**
  (mono-comparable-key memory). Merge at the point of construction/first evaluation or
  not at all; never add a lookup structure to a hot path to find merges dynamically.
- **Static census caution ×4** (cse-pure-calls.md:149-154): four consecutive static
  censuses in this series collapsed at the admissibility gate. Expect that outcome; let
  C1's data overturn it.
- **The structural-equality machinery already exists and is proven**: `CafHoist.zeroRegions`
  (CafHoist.elm:1071-1072, exposed at :1-4) rewrites every `Region` to `A.zero` — Region is
  "the ONLY non-semantic payload in MonoExpr" — and `CafHoist.fingerprintOf`
  (CafHoist.elm:1172-1173) is the cheap bucket key. `CafDedupe.oneRound`
  (CafDedupe.elm:92-138) is the working example: bucket by `fingerprintOf`, then exact `==`
  on the zeroed tree inside the bucket ("collision-impossible", CafDedupe.elm:14-19). C1 and
  C2 reuse **both functions verbatim** — no new equality machinery.

## Approach

Five phases. Phase 0 decides everything; nothing after it is authorized by this plan
until the D-C gate is evaluated and recorded.

---

### Phase 0 — C1 census (`ECO_CSE_REPORT=1`), decides everything

Implements cse-pure-calls.md §4 "C1 — the census" (:124-141). **Two** new modules —
`CsePurity.elm` and `CseCensus.elm`; `MonoCse.elm` is Phase 3's deliverable and is NOT
written here (the gate may kill it, and the rollback story keeps the other two). **Zero**
behaviour change (`cse.enabled` stays False; the report is stderr-only and excluded from
the artifact hash).

Phase 0 also lands the *census half* of the Generate.elm wiring — registration points
**(1) partially** (only `import Compiler.GlobalOpt.CseCensus as CseCensus`), **(2)** and
**(4b)** of § 3.4. Points (3) and (4a) — the `MonoCse.run` binding and its stats line —
land in Phase 3. `CseCensus.report` runs on `goGraph` (Generate.elm:927-928) in Phase 0,
which is the same graph `MonoCse.run` will consume, so the C1 numbers and C2's input are
the same object.

**0.1 — `CsePurity.elm` (shared oracle for `CseCensus` and `MonoCse`; see Dependencies for
why kernel-opt-11 reads the same *facts* but not this module).**
Two questions: *is this kernel call CSE-safe*, and *is this call to a global spec
CSE-safe*. The second needs a transitive answer (a user function that internally
`Debug.log`s is not CSE-safe) — this is the part the outline left implicit.

```elm
module Compiler.GlobalOpt.CsePurity exposing
    ( Oracle, analyze, isSafeCall, safeSpecCount, costOf )

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.BitSet as BitSet
import Compiler.Data.Name exposing (Name)
import Dict exposing (Dict)


type alias Oracle =
    { safeSpecs : BitSet.BitSet }   -- specIds whose evaluation is observation-free


{-| Provisional kernel table — replaced by ONE line when kernel-opt-07 lands:

        KernelFacts.lookup ( home, name ) |> Maybe.map .cseSafe |> Maybe.withDefault False

Whitelist discipline (KernelSigs.elm:14-16): unlisted ⇒ NOT safe. The list is the
INTERSECTION of (a) the legacy borrow table (`Borrow/KernelSigs.elm`, `table` at
:52, rows :54-167) and (b) the rows kernel-opt-07 Phase 3 certifies `cseSafe`
(its A1 + A2 tables) — so the census can never over-report relative to the real
table it will be re-run against. Excluded for cause: `Debug.*` (observable),
`Crash.crash` (EffNoreturn, KernelSigs.elm:97-100), `Utils.equal`/`Utils.notEqual`
(stderr trace still live at elm-kernel-cpp/src/core/Utils.cpp:557-562 until
kernel-opt-07 R2 deletes it), every `callsBackIntoElm` row
(`JsArray.foldl/foldr/map`, `List.map2/sortBy/sortWith`, `String.all`), and every
kernel-opt-07 **class-B (`unaudited`)** row — `JsArray.length`, `JsArray.unsafeGet`,
`String.uncons`, `String.words`, `String.trim`, `String.toLower`, `String.toUpper`,
`Bytes.encode`, `Bytes.decode`, `Debug.toString` — whose C++ bodies have NOT been
read for effects and which therefore derive `cseSafe = False` under 07.
-}
provisionalCseSafe : Dict ( Name, Name ) ()
provisionalCseSafe =
    Dict.fromList
        [ ( ( "Utils", "compare" ), () )
        , ( ( "Utils", "lt" ), () ), ( ( "Utils", "le" ), () )
        , ( ( "Utils", "gt" ), () ), ( ( "Utils", "ge" ), () )
        , ( ( "String", "length" ), () )
        , ( ( "String", "startsWith" ), () ), ( ( "String", "endsWith" ), () )
        , ( ( "String", "contains" ), () ), ( ( "String", "slice" ), () )
        , ( ( "Bytes", "width" ), () ), ( ( "Bytes", "getStringWidth" ), () )
        ]


{-| LEAST fixpoint of "unsafe": a spec is unsafe if its body mentions an unsafe
kernel, calls a dynamic (non-`MonoVarGlobal`, non-`MonoVarKernel`) callee, or calls
an unsafe spec. Node slots that are `Nothing` (the Prune gap convention) and nodes
that are not `MonoDefine`/`MonoTailFunc` — `MonoCtor`, `MonoEnum`, `MonoExtern`,
`MonoManagerLeaf`, `MonoPortIncoming/Outgoing` (Mono.elm:1456-1464) — are unsafe by
construction. Least fixpoint ⇒ a recursive cycle with no Debug anywhere is SAFE,
which is correct: MERGING never needs totality (both occurrences diverge together);
only DROPPING does (kernel-opt-11, `droppable = cseSafe && totality == Total`).
-}
analyze : Mono.MonoGraph -> Oracle
analyze (Mono.MonoGraph g) =
    -- Round 0: one walk of every `Just` node body building, per specId,
    --   (a) directUnsafe : Bool   — mentions a non-safe kernel, a `Debug` home,
    --       or a callee that is neither MonoVarGlobal nor MonoVarKernel;
    --   (b) calleeIds : List Int  — the MonoVarGlobal SpecIds it calls/references.
    -- Then iterate `unsafe := unsafe ∪ { s | calleeIds s ∩ unsafe /= ∅ }` until a
    -- round adds nothing (cap 8 rounds, the fuel idiom of CafDedupe.fixpoint,
    -- CafDedupe.elm:72-89). safeSpecs = complement over BitSet.fromSize
    -- (Array.length g.nodes) built with BitSet.insert (BitSet.elm:35/63/92).
    ...


{-| Is this expression an admissible CSE candidate HEAD? -}
isSafeCall : Oracle -> Mono.MonoExpr -> Bool
isSafeCall oracle expr =
    case expr of
        Mono.MonoCall _ (Mono.MonoVarGlobal _ sid _) args _ _ ->
            BitSet.member sid oracle.safeSpecs && List.all (isSafeArg oracle) args

        Mono.MonoCall _ (Mono.MonoVarKernel _ _ home name _) args _ _ ->
            Dict.member ( home, name ) provisionalCseSafe && List.all (isSafeArg oracle) args

        _ ->
            False
```

`isSafeArg` = literal / local var / global var / unit / another `isSafeCall` (recursion
bounded by tree depth). **Anything else is not a candidate** — v1 candidates are
binder-free call trees (see 0.4 exclusions).

**Why `analyze` rebuilds the call graph instead of reading the one in `MonoGraph`.**
`MonoGraph` carries three precomputed caches that look like exactly what this fixpoint
needs — `callEdges : Array (Maybe (List Int))` ("reuse in downstream passes instead of
re-traversing MonoExpr trees"), `specHasEffects : BitSet` ("SpecIds whose node body
references `Debug.*` kernels") and `specValueUsed` (Monomorphized.elm:1400-1402).
**All three are DEAD at this point in the pipeline:** `MonoInlineSimplify.optimize`
rebuilds the graph with `callEdges = Array.empty`, `specHasEffects = BitSet.empty`,
`specValueUsed = BitSet.empty` (**MonoInlineSimplify.elm:901-903**), and it runs before
GlobalOpt (`runInlineSimplifyPhase` at Generate.elm:807, `MonoInlineSimplify.optimize`
at :829, handing off to `runGlobalOptPhase` at :845). Reading them here would silently
classify every spec as Debug-free — an unsound-optimistic oracle. Do not
"optimize" `analyze` by consulting them, and do not repopulate them — restoring those
caches is a separate change with its own gates.

**0.2 — candidate keying (reuse, do not reinvent).** Per occurrence:

```elm
canonKey : Mono.MonoExpr -> ( String, Mono.MonoExpr )
canonKey e =
    ( CafHoist.fingerprintOf e (Mono.typeOf e)      -- CafHoist.elm:1172
    , CafHoist.zeroRegions (zeroCallInfo e)          -- CafHoist.elm:1071
    )
```

`zeroRegions` does **not** touch `CallInfo` (its `MonoCall` arm is
`Mono.MonoCall A.zero (zeroRegions func) (List.map zeroRegions args) ty callInfo`,
CafHoist.elm:1101-1102), so `CallInfo` participates in `==`. That is conservative and
correct — every `CallInfo` field is derived from the callee, the arg/result types and the
staging solution, and none of them is positional (`callModel`, `stageArities`,
`isSingleStageSaturated`, `initialRemaining`, `remainingStageArities`, `closureKind`,
`captureAbi`, `fastEvaluator`, `fastPapPrefix`, `callKind`, `evaluatorReturnType`;
Monomorphized.elm:2129-2141), so two structurally identical calls in one body should get
identical `CallInfo` from `annotateCallStaging`. "Should" is not "does", so the census
computes **both** groupings — with `CallInfo` intact and with it rewritten to
`Mono.defaultCallInfo` (exposed, Monomorphized.elm:27) by a local `zeroCallInfo` walk —
and reports the difference as `callInfoBlocked=`. Equality inside a fingerprint bucket is
plain `==` on the zeroed tree, exactly as `CafDedupe.classify` does
(CafDedupe.elm:144-160).

**0.3 — distance buckets (the load-bearing definition; C-R1's corollary,
cse-pure-calls.md:116-120).** Each occurrence carries its root→node path as a list of
steps; the pair's bucket is read off the two path suffixes below their lowest common
ancestor.

```elm
type Step
    = SStrict Int   -- call func/arg, list/tuple/record item: unconditional, no binder crossed
    | SSeq Int      -- MonoLet bound(0)/body(1), MonoDestruct body: unconditional, binder crossed
    | SGuard Int    -- MonoIf condition i  (i == 0 ⇒ unconditional)
    | SBranch Int   -- MonoIf then-branch i / final; MonoCase branch i; Decider Inline leaf
    | SClosure      -- entered a MonoClosure body: DIFFERENT evaluation frequency
```

Constructor mapping, against the real AST (Monomorphized.elm:1505-1523):
`MonoIf (List ( cond, branch )) final ty` has NO scrutinee expression — index `i` into the
pair list gives `SGuard i` for the condition and `SBranch i` for its branch, and `final`
is `SBranch (List.length branches)`. `MonoCase scrutName jumpName (Decider MonoChoice)
(List ( Int, MonoExpr )) ty` (:1517) likewise has no scrutinee expression: sub-expressions
live either in a decider `Leaf (Inline e)` (`MonoChoice`, :1705-1707), always reached under
some `DT.Test`, or in the `( Int, MonoExpr )` jump-target list — **both are `SBranch`**.
`MonoLet def body` uses `SSeq 0` for the def's bound expression and `SSeq 1` for the body;
`MonoTailDef` bindings are treated exactly like `MonoDef` for pathing. `MonoDestruct`'s
body is `SSeq 1` (its `MonoDestructor` holds no expression). `MonoTailCall` args are
`SStrict i`.

Classification is a **total, ordered** decision list — first matching row wins, and the
last row is the catch-all, so every pair lands in exactly one bucket. Write `U` for the set
of *unconditional* steps `{SStrict _, SSeq _, SGuard 0}`.

| # | bucket | rule (first match wins) | near? | C2 v1 |
| --- | --- | --- | --- | --- |
| 1 | `b4_crossdef` | the two occurrences are in different `MonoNode` bodies (no LCA) | far | out of scope (CAF territory, cse-pure-calls.md:210-212) |
| 2 | `b3_frame` | either suffix contains `SClosure` | far | excluded, **permanently** — different evaluation frequency |
| 3 | `b0_block` | both suffixes are all `SStrict` | near | **merge** |
| 4 | `b1_seq` | both suffixes ⊆ {`SStrict`,`SSeq`} | near | **merge** |
| 5 | `b1c_probe` | **at least one** suffix ⊆ `U` (that occurrence dominates the LCA's continuation) | near | **merge** — this is probe-then-insert |
| 6 | `b2_branch` | catch-all: **neither** suffix ⊆ `U` — both are guarded by an `SBranch` or an `SGuard i>0` | **far** (needs speculation) | excluded → C4 |

The **near pool** is `b0_block + b1_seq + b1c_probe`. Rows 3 and 4 are strict subcases of
row 5 (both suffixes ⊆ `U`), split out only so the census can see how much of the pool is
the trivially-safe straight-line kind; collapsing them would not change admissibility.
Row 5 is admissible without speculation precisely because the dominating occurrence is
evaluated on every path that reaches the other one — `SGuard 0` (the FIRST condition of a
`MonoIf` chain) is the only guard position counted as unconditional (conservative:
`SGuard i>0` is reached only if guards `<i` all failed). Row 6 is the residual and is the
only pair shape that would require evaluating something on a path that did not evaluate it.

**0.4 — v1 candidate exclusions (each one counted, so the gate sees what was thrown away).**
- `fnResultExcluded` — result type is an arrow. Test: `Mono.isFunctionType (Mono.typeOf e)`
  (both exposed; Monomorphized.elm:1992 and :1718). **Non-negotiable**: CGEN_069
  (invariants.csv:360) records that a hoisted *function-typed* value "invalidates the
  enclosing call's staged CallInfo — typed-apply arity assert — pinned by the Combinator
  corpus tests". Same hazard, same exclusion.
- `binderExcluded` — the candidate subtree contains `MonoLet`/`MonoDestruct`/`MonoCase`/
  `MonoClosure`. Keeps v1 free of every binder-capture and duplicate-SSA-name question.
- `shadowBlocked` — some free local of the candidate is *rebound* between the LCA and an
  occurrence. Test: `Set.intersect (freeLocals shape) namesBoundBelowLCA /= Set.empty`.
- `belowMinCost` — local cost `< minCost` (default 5). **`MonoInlineSimplify.computeCost`
  is NOT exposed** (module exposing list is `(Metrics, optimize, buildBodyLookup,
  countClosures, residualTaxonomy, functionResultCensus)`, MonoInlineSimplify.elm:1), so
  `CsePurity` carries a local `costOf : MonoExpr -> Int` transcribed from `computeCost`
  (:1218-1246) for the constructors v1 admits — leaves 1, `MonoList` `3 + Σitems`,
  `MonoCall` `5 + costOf func + Σ costOf args` (:1245-1246) — and the *same* function is
  used by the census and by C2 so the histogram and the `minCost` cut agree. The census
  reports the cost histogram so `minCost` is chosen from data, not guessed.
- `debugExcluded` — candidate mentions a `Debug` kernel (`home == "Debug"`, the same test
  CafHoist uses at CafHoist.elm:392-393). Redundant with `CsePurity` but counted
  separately so the two models can be cross-checked.

**0.5 — kernel-opt-11 ride-along (free, per that plan's Phase 0).** The same walk counts,
for every `MonoLet (MonoDef n bound) body _`: `deadPureLets` where
`countLocalUses n body == 0 && isSafeCall oracle bound`, split out as
`deadDroppableKernelLets` when the callee is a `MonoVarKernel` (post-07: `droppable`, i.e.
`cseSafe && totality == Total`). `countLocalUses : Name -> MonoExpr -> Int` is a 20-line
local helper in `CsePurity`: MonoInlineSimplify's `usesInDefs` is a `let`-bound helper
*inside* `dropDeadDefs` (:4747-4749) and `countUsages` is top-level at :5193 but **not
exposed** (module exposing list, MonoInlineSimplify.elm:1) — neither is reachable. The
liveness expression being mirrored is `usesInDefs name rest + countUsages name finalBody`
at :4770-4771, feeding the dead-let gate at :4780-4781.

**0.6 — output format** (stderr, modelled line-for-line on `CafCensus.report`,
CafCensus.elm:426-427, rendered via `writeLnErr` in Generate.elm:962-963). Shares are
integers in basis points to avoid float formatting. **The numbers below are ILLUSTRATIVE
placeholders showing the line shape — they are not a prediction and must never be quoted
as data; the measured lines go in "C1 result".**

```
cse-census: specs=12043 callOccs=181233 candidateOccs=44120 groups=3117 redundantOccs=5204
cse-census dist: b0_block=812 b1_seq=1944 b1c_probe=677 b2_branch=1391 b3_frame=290 b4_crossdef=90
cse-census near: nearRedundant=3433 nearShareBp=189 nearCost=41211 costShareBp=204 loopNear=1201 nearTop20Bp=6120
cse-census blocked: shadowBlocked=88 callInfoBlocked=12 fnResultExcluded=430 binderExcluded=1902 belowMinCost=6610 debugExcluded=17
cse-census cost: c1_4=... c5_9=... c10_49=... c50plus=...
cse-census probe: setMember=... dictGet=... other=...
cse-census top heads: Data.Map.get=214 String.length=180 ...
cse-census top specs: Compiler.Type.Solve.solve=63 ...
cse-dce: deadPureLets=41 deadDroppableKernelLets=12
cse-dce top: String.length=6 Utils.compare=3 ...
```

**Rendering heads as names is not free, and must not be done by parsing the fingerprint.**
`fingerprintOf`'s `headTag` yields `"g" ++ String.fromInt sid` for a `MonoVarGlobal` and
`"k" ++ home ++ "." ++ name` for a `MonoVarKernel` (CafHoist.elm:1207-1216) — a bucket key,
not a stable wire format. Carry the head identity on the `Occ` record instead
(`head : Head` with `HGlobal Int | HKernel Name Name`), captured while walking. Kernels
print as `home ++ "." ++ name`; globals resolve through `g.registry.reverseMapping :
Array (Maybe ( Global, MonoType ))` (Monomorphized.elm:1361). **Copy `CafCensus`'s
`specName` helper verbatim (CafCensus.elm:546-555)**: `Just ( Mono.Global (IO.Canonical _
moduleName) n, _ ) -> moduleName ++ "." ++ Name.toElmString n`; `Just ( Mono.Accessor f, _ )
-> "accessor." ++ Name.toElmString f`; `Nothing -> "spec" ++ String.fromInt sid`. That pins
the two extra imports `CseCensus` needs — `Compiler.Data.Name as Name` (`toElmString` at
Data/Name.elm:92) and `System.TypeCheck.IO as IO` (for the `IO.Canonical` pattern).

`loopNear` = near-redundant occurrences inside a `MonoTailFunc` body (Mono.elm:1458) —
the cheap static proxy for dynamic heat, and the answer to "static censuses over-promise".
`probe:` classifies a near group by its head symbol: `setMember` = the group's head is a
`Data.Set.member`/`Data.Map.member` spec, `dictGet` = `Data.Map.get`/`Data.Set.*` lookup,
`other` = everything else. These are matched on the rendered `specName` string, so the
bucket is a reporting convenience, not a semantic classification.

**0.7 — flag plumbing** (mirrors `list.report`, whose "output-only, excluded from `hash`"
docstring is Config.elm:57-59, and `mono.validate`, whose inline `--` comment is
Config.elm:117). See "Flag & rollback" for the exact rows and registration points.

**0.8 — run it.**

```bash
cmake --preset build                       # ELM_SOURCES glob has new files
cmake --build build --target eco-compiler 2>&1 | tee /tmp/cse_build.txt

BK=build/compiler/build-kernel
# (a) self-compile corpus, SHIPPING config (solver+LSS — the graph C2 will really see)
rm -rf "$BK/eco-stuff"
( cd "$BK" && ECO_CSE_REPORT=1 ./bin/eco-compiler make --optimize \
    --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/cse-census.mlir /work/compiler/src/Terminal/Main.elm ) 2> /tmp/cse_self.txt
grep -E '^cse-(census|dce)' /tmp/cse_self.txt

# (b) same, under the benchmark's workload engine so the numbers line up with the A/B legs
rm -rf "$BK/eco-stuff"
( cd "$BK" && ECO_MONO_ENGINE=subst ECO_CSE_REPORT=1 ./bin/eco-compiler make --optimize \
    --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/cse-census-subst.mlir /work/compiler/src/Terminal/Main.elm ) 2> /tmp/cse_self_subst.txt

# (c) the mandatory user workload (cse-pure-calls.md:126-129) + the exponential canary
( cd /work/projects/elm-aws-codegen && ECO_CSE_REPORT=1 /usr/bin/time -v \
    /work/build/compiler/build-kernel/bin/eco-compiler make src/elm/Top.elm \
    --local-package eco/kernel=/work/eco-kernel-cpp --output=/tmp/aws-cse.mlir ) 2> /tmp/cse_aws.txt
grep -E '^cse-(census|dce)|Elapsed \(wall' /tmp/cse_aws.txt
```

**Phase 0 acceptance:** both new modules compile; `elm-tests` green; the census runs on both
corpora and its lines are pasted into `benchmarks/kernel-opt.md` **and** into the
"C1 result" section of this file; the emitted `.mlir` with `ECO_CSE_REPORT=1` is
`cmp`-identical to the same build without it (census is inert); `Config.hash` is unchanged
by `ECO_CSE_REPORT=1` (grep the eco-stuff cache key, or assert by rebuilding with the flag
and observing a cache hit).

---

### Phase 1 — D-C gate (cse-pure-calls.md:143-147)

**Proceed to Phase 3 iff, on the self-compile corpus, BOTH:
(i) `nearShareBp >= 200` (nearRedundant ≥ 2% of `callOccs`), AND
(ii) `nearTop20Bp >= 5000`** — the top-20 heads cover ≥ 50% of the near pool, so a
bounded-scope pass captures most of it. Both numbers are printed on the `cse-census near:`
line (0.6); `nearTop20Bp = 10000 * (Σ of the 20 largest per-head nearRedundant counts) /
nearRedundant`. No judgement call: read the two integers.

**What the 2% is measured against, stated exactly:** `callOccs` = every `MonoCall` node in
every `MonoDefine`/`MonoTailFunc` body of the final graph. It is a **static** denominator;
this census cannot count *evaluated* calls (no Mono-level profile exists, and building one
is a bigger project than the pass). The wrapped plan's "≥2% of evaluated calls"
(cse-pure-calls.md:146) is therefore realized as: **static near-share ≥ 2%**, with
`loopNear` (near redundancy inside tail-recursive bodies) reported as the dynamic-heat
proxy and used as the tie-breaker if the share lands in 150-200 bp. Say so in the recorded
table; do not launder a static number as a dynamic one.

- **Gate passes** → Phase 2 (policy note) then Phase 3 (C2), scope = the near buckets only.
- **Gate fails** → **STOP**. Record the negative result in this file and in
  `benchmarks/kernel-opt.md`, keep the census modules (they are inert, off by default, and
  kernel-opt-11 Phase 0 consumes `cse-dce:`), close the plan. The ×4 base rate says this is
  the likely branch; taking it cleanly is a success, not a failure.
- **Split verdict** (self-compile passes, aws fails, or vice versa) → proceed **only** if
  self-compile passes, and record the aws number as the generalization caveat; the pass is
  measured on self-compile and shipped default-off regardless.

---

### Phase 2 — Debug/⊥ policy note (blocking, written once)

`design_docs/debug-log-ordering-policy.md` — **drafted by kernel-opt-11 Phase 1, referenced
here, not re-drafted** (cross-plan contract; the debt is recorded as owed-and-never-written
at cse-pure-calls.md:71-80, originally from `plans/opt-tier2-cons-fusion.md` U-T2.4′). C2
does not land before the file exists. Read kernel-opt-11 Phase 1 for the committed draft
body; this plan contributes exactly two requirements, both of which the draft **already
satisfies** — verify them rather than renegotiate them:

1. **Merge prohibition (11's D-2), not a merge licence.** kernel-opt-11's draft states
   "Two occurrences of an expression that transitively logs are never CSE-merged: the
   number of emitted lines is observable output," and 11's D-5 forbids assuming `--optimize`
   strips `Debug` on the MLIR path (`checkForDebugUses` runs only under the JS `prod` entry,
   Builder/Generate.elm:195-198/259-266). **This plan does not ask for the opposite
   latitude** — an earlier draft of this file did, and that was a contract violation.
   `CsePurity` enforces D-2 by construction (any Debug-reaching spec is unsafe, and
   `home == "Debug"` is directly unsafe), so no merge can change log cardinality. The
   `debugExcluded` counter exists to *measure the size of the region D-2 fences off*, not
   to argue for opening it. Reopening it would require first making the native path run
   `checkForDebugUses` — 11's D-5, a separate change with its own gates.
2. **⊥ selection (11's D-4).** Merging two occurrences that both crash picks one as *the*
   ⊥, which can change the crash *message*; the E2E suite asserts on crash text in places
   (cse-pure-calls.md:77-80). D-4 grants exactly that latitude under `--optimize`. v1 does
   not need it (a crashing callee is `Throws`, hence not `droppable`, and its spec is unsafe
   unless kernel-opt-07 certifies otherwise), so D-4 is recorded for C4, not for C2.

Phase 2 acceptance: `design_docs/debug-log-ordering-policy.md` exists and its D-2/D-4/D-5
clauses read as above; `design_docs/invariants.csv` carries kernel-opt-11's
`OPT_DEBUG_ORDER_001` row pointing at it; and this plan's own `CSE_001` row (Phase 3.5)
cites `OPT_DEBUG_ORDER_001` in its `source` column. If 11 has not reached its Phase 1 when
this plan's gate passes, **13 writes the file** to 11's draft text verbatim and 11 then
references it — the file is written once, by whichever plan arrives first, and never
diverges.

---

### Phase 3 — C2, bounded-scope CSE (cse-pure-calls.md:156-167)

**3.1 — Where it runs. PINNED, and this deviates from the wrapped plan; the deviation is
deliberate.** cse-pure-calls.md:158-162 says "before phase 5 (call-staging annotation)"
inside `globalOptimizeWithStats` (MonoGlobalOptimize.elm:128-168; phase 4 `AbiCloning` at
:148-149, phase 5 `annotateCallStaging` at :153-154). **C2 instead runs as a top-level pass
in `Builder/Generate.elm:runGlobalOptPhase`, immediately after
`MonoGlobalOptimize.globalOptimizeWithStats` (:927-928) and before `CafDedupe.run`
(:934-939)** — i.e. in the same post-annotation GlobalOpt tail that `CafDedupe` (:934-939)
and `CafHoist` (:943-952) already occupy, and on exactly the graph (`goGraph`) the C1
census measured. (C2 sits *before* CafDedupe, not in CafHoist's slot: CSE must not have to
reason about specs CafDedupe is about to merge away.) Two reasons:

- **The exponential.** `annotateCallStaging` is O(2^let-in-bound-depth)
  (`plans/annotate-call-staging-metadata.md`; the elm-aws-codegen "hang"; eco
  annotate-call-staging memory). C2's whole job is adding `MonoLet` bindings. Running
  *after* the annotator means the pass cannot feed it a single new let.
- **Verbatim moves are already licensed here.** CGEN_069 (invariants.csv:360) states the
  CafHoist precedent in the invariant itself: "Moves are VERBATIM (CallInfo per-node — jumps
  case-local)", and CafHoist runs post-annotation at Generate.elm:943-952. C2 *moves* a call
  node into a let and replaces its duplicates with `MonoVarLocal` of the same type; every
  surviving `MonoCall` keeps the `CallInfo` it was annotated with, and no call changes its
  callee value or arity. Function-typed results — the one case CGEN_069 says breaks this —
  are excluded (0.4).

**Fallback branch, criterion stated:** if E2E or MLIR verification fails with staging /
typed-apply arity errors attributable to a moved call, move C2 inside
`globalOptimizeWithStats` between :149 and :153 (threading `Config.CseConfig` through the
signature at :128, plus its two call sites at :112 and Generate.elm:928) and re-measure the
aws canary wall *first* — the exponential is then live again and is the gating risk.

**3.2 — Module skeleton** (`Stats`/`emptyStats`/`run`/`renderStats` shape copied from
`CafDedupe`, CafDedupe.elm:1-69):

```elm
module Compiler.GlobalOpt.MonoCse exposing (Stats, emptyStats, run, renderStats)

type alias Stats =
    { specsTouched : Int, groups : Int, merged : Int, letsInserted : Int
    , shadowBlocked : Int, budgetExhausted : Int }


run : { minCost : Int, maxPerDef : Int } -> Mono.MonoGraph -> ( Mono.MonoGraph, Stats )
run cfg ((Mono.MonoGraph g) as graph) =
    let
        oracle = CsePurity.analyze graph

        -- g.nodes : Array (Maybe MonoNode) — `Nothing` slots are the Prune gap
        -- convention (CafDedupe.elm:22-24) and MUST be passed through unchanged;
        -- array length and index↔specId identity are invariants of the graph.
        ( nodes1, stats ) =
            Array.foldl (rewriteNode cfg oracle) ( Array.empty, emptyStats ) g.nodes
    in
    ( Mono.MonoGraph { g | nodes = nodes1 }, stats )
```

Only `g.nodes` is rewritten, and only *within* node bodies. The record-update syntax
carries the other ten `MonoGraph` fields (Monomorphized.elm:1393-1406) forward untouched:
`main`, `registry` (whose `nextId` lives at Monomorphized.elm:1359 — it is a *registry*
field, not a graph field), `ctorShapes`, `nextLambdaIndex`, `callEdges`, `specHasEffects`,
`specValueUsed`, `ports`, `flagsDecoder`, `lssMemberOrigins`. No spec is minted and none is
removed — unlike CafDedupe/CafHoist — so CafHoist's append-only drift assertion
(`nextId == |nodes| == |reverseMapping|`, CGEN_069) is trivially satisfied, and the three
already-empty caches stay empty (they were zeroed at MonoInlineSimplify.elm:901-903;
C2 must not repopulate them).

**3.3 — Per-body algorithm (two phases, mirroring CafHoist's collect/replace, CafHoist.elm
header :20-30).**

- *Collect.* One walk producing `Dict String (List Occ)` (fingerprint bucket → occurrences),
  each `Occ = { shape, ty, head, path, cost, free }` (`head` per 0.6; `free : Set Name` =
  the shape's free locals). Within a bucket, partition by `==` on `shape`
  (CafDedupe.classify idiom, CafDedupe.elm:148-160). Keep groups with ≥2
  occurrences whose pairwise bucket (0.3) is near, that clear every 0.4 exclusion, and
  whose cost ≥ `cfg.minCost`. Cap at `cfg.maxPerDef` groups per body (bump
  `budgetExhausted` and stop collecting — determinism: groups are taken in
  traversal-encounter order, like CafHoist's minting order).
- *Choose insertion point.* **The LCA of the group's occurrence paths, and nothing above
  it.** Do *not* walk further up to widen sharing: every free local of the shape is by
  construction in scope at the occurrences, and moving above its binder makes the moved
  expression ill-scoped. Two validations at the LCA, both drops on failure:
  1. `shadowBlocked` — for each occurrence, no `Step` on its suffix below the LCA may cross
     a binder that rebinds a name in `occ.free` (the binders are `SSeq 0`/`SSeq 1` of a
     `MonoLet`/`MonoDestruct` and the `SBranch` into a `MonoCase` arm). Concretely:
     `not (Set.isEmpty (Set.intersect occ.free (namesBoundOnSuffix occ)))` ⇒ drop.
  2. `b2_branch` residue — require ≥1 occurrence whose suffix from the LCA is entirely
     unconditional (⊆ `U` = `SStrict`/`SSeq`/`SGuard 0`). This is bucket rule 5 restated at
     the group level, and it is exactly what makes wrapping the LCA in a `MonoLet`
     semantics-preserving: the moved expression now evaluates strictly before the LCA's own
     evaluation, which is unobservable only because that occurrence would have been
     evaluated on this path anyway. (Order relative to *other* strict work does change —
     unobservable in v1 because `CsePurity` admits only Debug-free, non-`Throws` candidates;
     see Phase 2 / `OPT_DEBUG_ORDER_001` D-4 before ever relaxing that.)
- *Replace.* Top-down rebuild: at the insertion node, emit
  `Mono.MonoLet (Mono.MonoDef fresh firstOcc) rebuilt (Mono.typeOf rebuilt)`; inside
  `rebuilt`, every occurrence (including the first) becomes
  `Mono.MonoVarLocal fresh occTy`. Fresh names: `"mono_cse_" ++ String.fromInt n` with a
  per-run counter, mirroring `freshVar` at MonoInlineSimplify.elm:2279-2283.

**Why `freshenLetBoundNames` is NOT needed here** (correcting the v1 outline): that guard
exists because the inliner *copies* bodies, producing duplicate let names on one SSA id
(eco-inliner-dup-let-names memory). C2 never copies — it **moves** the first occurrence and
**deletes** the duplicates, which strictly reduces binder multiplicity. It is also not
callable: `freshenLetBoundNames` is private to MonoInlineSimplify (exposing list,
MonoInlineSimplify.elm:1). The v1 exclusion `binderExcluded` (0.4) removes the question
entirely for v1 candidates.

**3.4 — Wiring** (all four registration points, verified against how `CafDedupe` is wired;
(1)-partial, (2) and (4b) already landed in Phase 0):

1. `compiler/src/Builder/Generate.elm:70-77` — the `Compiler.GlobalOpt.*` import block
   (CafDedupe at :72, CafHoist :73). Phase 0 adds
   `import Compiler.GlobalOpt.CseCensus as CseCensus`; Phase 3 adds
   `import Compiler.GlobalOpt.MonoCse as MonoCse`. `CsePurity` is **not** imported here —
   only `CseCensus`/`MonoCse` consume it.
2. `Generate.elm:922-923` — `runGlobalOptPhase` signature and params gain a
   `Config.CseConfig` argument **named `cseCfg`**, placed after `cafMemo` (i.e.
   `… -> Config.CafMemoConfig -> Config.CseConfig -> FEStats.Handle -> …`), and the sole
   call site at `:845` gains `ecoConfig.cse` in the same position.
3. `Generate.elm` between `:928` and `:934` — the pass, in the `CafDedupe` conditional style:
   ```elm
   ( cseGraph, cseStats ) =
       if cseCfg.enabled then
           MonoCse.run { minCost = cseCfg.minCost, maxPerDef = cseCfg.maxPerDef } goGraph
       else
           ( goGraph, MonoCse.emptyStats )
   ```
   and `CafDedupe.run` / the `else` branch at `:934-939` consume `cseGraph` instead of
   `goGraph`.
4. `Generate.elm:962-1010` — two `writeLnErr` clauses in the existing `Task.andThen` chain
   (`writeLnErr` is bound at :962-963):
   (4a) `MonoCse.renderStats cseStats` when `cseCfg.enabled` — one line prefixed
   `mono-cse:`, built exactly like `CafDedupe.renderStats` (CafDedupe.elm:53-62, which
   emits `"caf-dedupe: rounds=… groups=… removed=… refsRewritten=…"`), i.e.
   `mono-cse: specsTouched=… groups=… merged=… letsInserted=… shadowBlocked=…
   budgetExhausted=…`; and
   (4b) `CseCensus.report "cse-census" cseCensusCfg cseGraph` when `cseCfg.report`.
   **Name the config binding `cseCensusCfg`, NOT `censusCfg`** — `censusCfg` is already
   bound in this same `let` at :954-955 (`{ minNodes = cafMemo.hoist.minNodes }`, CafCensus's
   config) and reusing the name is a shadowing collision. `type alias CseCfg = { minCost :
   Int, topN : Int }` (`topN` = 20, the width of the `top heads` / `top specs` lines);
   `cseCensusCfg = { minCost = cseCfg.minCost, topN = 20 }`. In Phase 0 the report runs on
   `goGraph`; from Phase 3 it runs on the **post-CSE** graph when the pass is on (residue is
   the collapse gate, exactly the pre/post pattern CafCensus uses at :977 and :994).

**3.5 — Invariant row.** Add `CSE_001` to `design_docs/invariants.csv` in the CGEN_069 style
(one semicolon-delimited row: id;phase;category;status;description;source) stating: merge
licence = `CsePurity`-safe call trees only; near buckets only; function-typed and
binder-containing candidates excluded; moves are verbatim so `CallInfo` travels with the
node; whitelist discipline (unlisted kernel ⇒ unsafe); Debug-reaching specs are unsafe per
`OPT_DEBUG_ORDER_001` D-2; determinism (encounter order); sources
`Compiler.GlobalOpt.MonoCse|Compiler.GlobalOpt.CsePurity|CGEN_069|OPT_DEBUG_ORDER_001`.
The `description` column must contain **no `;`** — that is the file's field separator
(header `id;phase;category;status;description;source`, invariants.csv:1); use ` - ` for
clause breaks, as CGEN_069 does at :360.

**Phase 3 acceptance:** flag-off byte-identity (`cmp` the `.mlir` against a pre-change
build — the pass must be *unreachable* when off); flag-on E2E green; flag-on emitted `.mlir`
for a fixed input byte-identical to flag-off (see Gates — CSE is semantically transparent,
so this identity is a **soundness** gate, not an expectation of no change to the
*compiler's own* MLIR); the `mono-cse:` stats line shows `merged > 0`; aws canary wall within 3% of
its flag-off time.

---

### Phase 4 — C4 widening (cse-pure-calls.md:175-179), one candidate at a time

Only on C2's measured result, each with its own A/B, in this order (decreasing confidence):
`b2_branch` groups with a common prefix — this needs a **speculation** argument (the merged
value is evaluated on a path that would not have evaluated it, so a ⊥-capable or
non-terminating candidate becomes observable) and therefore rides `OPT_DEBUG_ORDER_001`
D-4, *not* D-2; note D-3 forbids hoisting a **logging** expression out of a conditional
outright, so the Debug exclusion stays absolute even at C4. Then: record-accessor chains;
partial redundancy. **Loop-invariant code motion
stays out of scope** (cse-pure-calls.md:206-209) — same live-range risk, larger, separate.
Do not batch.

---

## C1 result

Measured 2026-08-12, self-compile corpus, `ECO_MONO_ENGINE=subst ECO_CSE_REPORT=1`.

**Two runs are recorded because the first was wrong.** The first census gave
`nearRedundant=1619 nearShareBp=109`; that was inflated by a path-encoding
defect — every `Leaf (Inline _)` in a decider `Chain`/`FanOut` tree was given
the same path step, so two distinct occurrences shared a path key, their common
prefix swallowed both suffixes, and the pair classified as `b0_block`
(trivially near) when it was nothing of the kind. The transform had the same
defect and, before it was fixed, produced `unbound variable mono_cse_N` — a
`MonoLet` that did not dominate its uses. **Do not quote the first numbers.**

### Corrected census (decider leaves distinctly pathed)

```
cse-census: specs=30905 safeSpecs=17531 callOccs=147860 candidateOccs=69995 groups=1413 redundantOccs=1909
cse-census dist: b0_block=2 b1_seq=26 b1c_probe=54 b2_branch=1672 b3_frame=155 b4_crossdef=0
cse-census near: nearRedundant=82 nearShareBp=5 nearCost=645 loopNear=5 nearTop20Bp=9756
cse-census blocked: shadowBlocked=0 callInfoBlocked=0 fnResultExcluded=8467 binderExcluded=8717 belowMinCost=0 debugExcluded=0
cse-dce: deadLets=21341 deadPureLets=10358 deadDroppableKernelLets=423
```

**The census and the transform now agree exactly: `nearRedundant = 82` and
`MonoCse` reports `merged = 82`.** That agreement is the strongest available
evidence that both are correct, and it is the reason the first pair of numbers
can be confidently discarded rather than merely doubted.

### D-C gate: FAILS, by a factor of 40

| criterion | required | measured | verdict |
|---|---|---|---|
| `nearShareBp` | ≥ 200 (2% of `callOccs`) | **5** (0.05%) | **FAIL** |
| `nearTop20Bp` | ≥ 5000 | 9756 | pass |

The plan's verdict is STOP at Phase 1. **C2 was built and benchmarked anyway on
explicit instruction** — the loop's standing rule is that a plan-internal census
bar is never a veto, only a wall regression is.

### What the distribution actually says

**`b2_branch = 1672` of 1,909 redundant occurrences (87.6%) is the dominant
bucket** — pairs where NEITHER occurrence dominates the other, so both are
guarded and merging one would evaluate it on a path that does not today. That
is the C4 speculation territory the plan deliberately excludes from v1, and it
is where essentially all of the redundancy lives.

**The probe-then-insert idiom this plan targets is close to absent from this
codebase:** `b1c_probe = 54`. Together with `b0_block = 2` and `b1_seq = 26`
that is the entire admissible pool — 82 occurrences against 147,860 static call
sites. The motivating example (`if Set.member (f x) s then … else Set.insert
(f x) s`) is real Elm, but the compiler's own source does not write it.

`loopNear = 5` — the dynamic-heat proxy is essentially zero, so even those 82
merges are almost all in code that runs once.

### Counters that are structurally zero and are NOT findings

`shadowBlocked = 0` and `callInfoBlocked = 0` are **not measured** by the
census: the shadow test is an LCA-level check only the pass performs (the pass
reports it separately and also found 0 after the fix), and the dual
`CallInfo`-zeroed grouping the plan asked for was never implemented.
`b4_crossdef = 0` is structural — the census groups only within one body.
`belowMinCost = 0` and `c1_4 = 0` are real but uninformative: a `MonoCall` costs
`5 + func + args`, so the cheapest candidate is 6 and the default floor of 5
excludes nothing. Anyone tuning `minCost` must start above 6.

## Flag & rollback

| knob | default | kind | where |
| --- | --- | --- | --- |
| `cse.enabled` / `ECO_CSE=1\|0` | **False** | artifact-affecting → hash token `cse=1` | Config.elm `CseConfig` + `default` + `hash`; Builder/Eco/Config.elm override |
| `cse.report` / `ECO_CSE_REPORT=1` | False | **output-only, excluded from `hash`** | same, no hash token (pattern: `list.report`, Config.elm:57-59; `mono.validate`, Config.elm:117) |
| `cse.minCost` / `ECO_CSE_MIN_COST` | 5 | tuning; token `cseMin=` only when non-default **and** `enabled` | same |
| `cse.maxPerDef` / `ECO_CSE_MAX_PER_DEF` | 64 | tuning; token `cseMax=` only when non-default **and** `enabled` | same |

Registration checklist for the config record (all five points, verified against `cafMemo`
and the tier-1 booleans on 2026-08-10). **The three Config.elm positions are all "append at
the END", and they must stay in lockstep:**

1. `EcoConfig` field `cse : CseConfig` — appended after `sretTailFuncs`, i.e. a new
   `, cse : CseConfig` line between **Config.elm:47 and the closing `}` at :48** (record
   opens at :34). Also add `CseConfig` to the module `exposing` list (Config.elm:2, the
   `EcoConfig, InlineConfig, …, CafHoistConfig` line).
2. `default` row — a new `, cse = { enabled = False, report = False, minCost = 5,
   maxPerDef = 64 }` appended after **`, sretTailFuncs = True` (Config.elm:338)**, before
   the record's closing `}` at :339. (Note: `Config.elm:321` is the `cafMemo` row and is
   the WRONG slot for an end-appended field — the decoder is positional, see 3.)
3. `cseDecoder` + one `|> D.apply (D.optionalField "cse" cseDecoder default.cse)` appended
   **after the `sretTailFuncs` apply at Config.elm:361** (chain runs :346-361), because
   `D.pure EcoConfig |> D.apply …` is **positional**: record-field order and apply order
   must match or the config silently mis-decodes every field after the insertion point.
   `cseDecoder` follows `listDecoder` (Config.elm:367-370): decode only the JSON-settable
   knobs (`enabled`, `minCost`, `maxPerDef`) through an explicit lambda and hard-wire
   `report = default.cse.report`, so `ECO_CSE_REPORT` stays env-only.
4. Hash tokens in `hash` (`hash` spans **Config.elm:540-744**) — append a new `++ (if …)`
   block after the `bopt=1` block at **:732-743**, inside the final `)` at :744. Emit
   `cse=1` only when `cfg.cse.enabled`, and `cseMin=`/`cseMax=` only when enabled AND
   non-default, so default configs hash exactly as today and share every existing cache.
   `cse.report` contributes **no** token.
5. Four `applyCseXxxOverride` functions + four `Task.andThen` links appended after the
   `cfg29` / `ECO_BORROW_OPT` link (**Builder/Eco/Config.elm:260-264**, the current tail of
   the chain), copying `applyCafDedupeOverride`'s `["1","true","yes"] /
   ["0","false","no"]` parsing (Builder/Eco/Config.elm:811-826) for the two booleans and
   `String.toInt`-with-fallback for the two Ints.

**Rollback story.** (a) Runtime: `ECO_CSE=0` restores today's pipeline exactly — the pass is
not run, and the default-off hash token means flag-off builds share pre-feature caches.
(b) Census-only: `ECO_CSE_REPORT=1` with `enabled=False` is stderr-only and artifact-inert.
(c) Full revert: delete the new modules (three after Phase 3; two if the D-C gate closed the
plan at Phase 1 and `MonoCse.elm` never existed) and revert the config/Generate hunks; nothing
else in the tree depends on them (kernel-opt-11 Phase 0 consumes the `cse-dce:` lines, so
if 11 has shipped, keep `CseCensus.elm` + `CsePurity.elm` and revert only `MonoCse.elm`).

## Traps & risks

- **CSE extends live ranges by construction** (cse-pure-calls.md:93-104): a naive
  whole-definition CSE can be wall-negative while every allocation counter improves — the
  chunked-lists trap read from the other direction. C-R1 (near-only buckets) is the
  mitigation; watch promotion/majors, not object counts.
- **`annotateCallStaging` exponential** (cse-pure-calls.md:193-197): the reason C2 is placed
  *after* the annotator (3.1). If the fallback placement is ever taken, the aws canary
  becomes the gating measurement, not a formality.
- **Function-typed candidates**: excluded by CGEN_069's recorded failure mode (typed-apply
  arity assert, Combinator corpus). Do not relax without re-reading invariants.csv:360.
- **Shadowing / capture**: two structurally equal shapes can reference *different* locals if
  a binder rebinds the name between them. The `shadowBlocked` test (0.4/3.3) is the guard;
  it is also a census counter so the cost of the conservatism is visible.
- **`CallInfo` in the equality key** silently blocks merges; `callInfoBlocked=` measures it
  before anyone "fixes" equality by weakening it.
- **The graph's own effect/call caches are DEAD here and read as "clean".**
  `MonoInlineSimplify.optimize` zeroes `callEdges`, `specHasEffects` and `specValueUsed`
  (MonoInlineSimplify.elm:901-903) before GlobalOpt runs, so `g.specHasEffects` — literally
  "SpecIds whose node body references `Debug.*` kernels" — answers `False` for **every**
  spec at C2's placement. Consulting it would produce an unsound-optimistic oracle that
  passes every test until someone ships a `Debug.log` in a hot spec. `CsePurity.analyze`
  rebuilds both facts from the node bodies; see 0.1.
- **`g.nodes` is `Array (Maybe MonoNode)`.** `Nothing` slots are Prune gaps and index ↔
  specId identity is a graph invariant — a fold that drops or reorders them silently
  renumbers every spec. Pass gaps through unchanged (CafDedupe.elm:22-24, and its own
  `Array.foldl` over `maybeNode` at :98-119 is the pattern to copy).
- **`censusCfg` is already taken.** Generate.elm:954-955 binds `censusCfg` in the very
  `let` C2 is being added to; the CSE census config must be `cseCensusCfg` (3.4 point 4).
- **Census over-promise**: distance-unbounded counting measures the wrong thing
  (cse-pure-calls.md:116-120). The ×4 collapse pattern says assume the gate fails; the
  distance buckets and `loopNear` exist so the number that decides is the honest one.
- **Stale-census temptation**: the Aug-10 cmp3/compare peephole work already deleted the
  comparison-heavy call rows; do not size C1 expectations from the pre-peephole dynamic
  census.
- **Whitelist discipline**: an unlisted kernel is **unsafe**, per consumer, forever
  (cross-plan contract; KernelSigs.elm:14-16). The provisional list in `CsePurity` is a
  bring-up scaffold with an explicit expiry: it is deleted the day kernel-opt-07 lands.
- **E2E/unit cache race**: run E2E and `elm-tests` **serially** (eco-e2e-unit-cache-race
  memory) — concurrent suites corrupt `~/.eco` typed-artifacts.dat.

## Dependencies

- **kernel-opt-07 (HARD)** — `kernel-opt-07-kernel-facts-table.md`: supplies `cseSafe`
  (+`totality` for the DCE ride-along). C1 may run against `CsePurity.provisionalCseSafe`
  but **must be re-run** against `KernelFacts.lookup` before the D-C gate is treated as
  final; C2 does not land on the provisional list.
- **kernel-opt-11 (SOFT)** — `kernel-opt-11-mono-dce-cost-model.md`: authors
  `design_docs/debug-log-ordering-policy.md` (Phase 2 here waits on it), consumes this
  plan's `cse-dce:` counters as its Phase 0, and will consume `CsePurity` when it rewires
  `isPureExpr` (MonoInlineSimplify.elm:5102-5133).
- **kernel-opt-12 (INFORMATIONAL, no code coupling)** — its per-call `eco.cse_safe` attr on
  `eco.call` is a *backend* channel with merge-only semantics; this plan neither emits nor
  consumes it, and nothing here licenses motion after `EcoGCPrepare`. The decl-side attr
  `eco.gc_leaf` (kernel-opt-08/09) is likewise unrelated to Mono-level CSE.
- External: none beyond the standard toolchain. `CafHoist.zeroRegions` / `fingerprintOf`
  are genuinely **reused** (both exposed, CafHoist.elm:1-4). K6's hash-cons sites and
  `MonoInlineSimplify.computeCost` are **read only, and copied not called** — `computeCost`
  is unexported (MonoInlineSimplify.elm:1), so `CsePurity.costOf` is a transcription; if
  kernel-opt-11 Phase 3 changes `computeCost`'s kernel-callee arm, `costOf` does **not**
  follow it automatically and the `minCost` histogram must be re-read. No file owned by
  another plan is modified by this one.

- **Note on 11's shared consumer.** kernel-opt-11 Phase 2 rewires `isPureExpr` via its own
  `isPureExprGen` inside `MonoInlineSimplify`, gated by `inline.kernelFactsDce`; it does
  **not** import `CsePurity`. The two purity models must therefore stay reconcilable by
  construction: both answer from `KernelFacts` post-07 and both take the same
  whitelist-default (unlisted ⇒ unsafe). `CsePurity`'s extra machinery — the transitive
  spec fixpoint — is strictly stronger and exists only because CSE looks at *global* calls,
  which 11's dead-let gate never does.

## Expected impact

**Census-gated at every step; effort L.** Honest expectation: a K6-shaped retention +
deleted-work win **iff** C1 finds a real near-distance merge pool (K6's own motivating
census found 99.2% duplicate construction — but on one data type, not general expressions).
The calibrated base rate says the gate fails (×4 static-census collapses); if it does, the
plan stops at Phase 1 having spent only the census, and still buys: the C1/D-C table on
record, kernel-opt-11's dead-call census for free, a reusable `CsePurity` oracle, and first
consumer pressure on kernel-opt-07's `cseSafe` bit. This is NOT a metadata-only change, so
the "wall-FLAT like statepoint removals" prior does not apply — if merges happen at bounded
distance, executed work is actually deleted. Equally, the K5 anti-prior binds: no dynamic
lookup structure is added anywhere, ever.

## Gates

All of cse-pure-calls.md §5 (:181-204), plus the kernel-opt-series standards. Run tests
**once**, teed, then grep — never re-run to re-read (CLAUDE.md).

- **Emitted-output byte-identity is the primary gate** (cse-pure-calls.md:183-188): for a
  fixed input program, the `.mlir` eco emits must be **byte-identical flag-on vs flag-off**
  — CSE is semantically transparent, so losing this identity is a soundness bug. The
  compiler's OWN MLIR does change (that is the point), so the self-host gate is a
  **stage-comparison**: `cmake --build build --target bootstrap` (compiler/CMakeLists.txt:1026)
  reaching **both** fixed points — Stage 4b JS and Stage 8c native — i.e. bootstrap to a NEW
  fixed point, byte-identical *at* the fixed point.
  ```bash
  BK=build/compiler/build-kernel
  # ONE binary (built with the feature compiled in), TWO workload legs.
  for LEG in off on; do
    [ "$LEG" = on ] && V=1 || V=0
    rm -rf "$BK/eco-stuff"
    ( cd "$BK" && ECO_CSE=$V ./bin/eco-compiler make --optimize \
        --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp \
        --output="bin/cse-$LEG.mlir" /work/compiler/src/Terminal/Main.elm ) \
      2> "/tmp/cse_$LEG.txt"
  done
  cmp "$BK/bin/cse-off.mlir" "$BK/bin/cse-on.mlir"      # MUST be identical
  cmake --build build --target bootstrap 2>&1 | tee /tmp/bootstrap.txt
  grep -Ei "fixed point|identical|differ|FAILED" /tmp/bootstrap.txt
  ```
  (`ECO_CSE=1` is in `Config.hash` as `cse=1`, so the two legs are cache-disjoint by
  construction; the `rm -rf eco-stuff` is belt-and-braces per tier2 methodology.)
- **Full E2E**, never `check` after a codegen-affecting change:
  ```bash
  cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
  grep -E "TESTS (PASSED|FAILED)|[0-9]+/[0-9]+|Falsifiable" /tmp/test_output.txt | tail -20
  ```
  Run flag-off first (must match the pre-change pass count exactly), then flag-on.
- **Front-end suite**: `cmake --build build --target elm-tests 2>&1 | tee /tmp/elm_tests.txt`
  (12 known pre-existing typechecker-gate failures, cse-pure-calls.md:192); run **serially**
  with E2E.
- **Heap-validate suite green.** `ECO_HEAP_VALIDATE` is a **compile-time** CMake option
  (CMakeLists.txt:84-88 → `add_compile_definitions`, consumed as `#if ECO_HEAP_VALIDATE`
  in e.g. runtime/src/allocator/ThreadLocalHeap.hpp:188), **not** an env var — it needs its
  own tree, per the series convention (kernel-opt-05 Gate 4):
  ```bash
  cmake --preset build -B /work/build-val -DECO_HEAP_VALIDATE=ON
  cmake --build /work/build-val --target full 2>&1 | tee /tmp/validate_output.txt
  grep -E "FAIL|Failed|error:|[0-9]+/[0-9]+" /tmp/validate_output.txt | tail -20
  ```
  Baseline is 1632/1632. Run the flag-on leg with `ECO_CSE=1` after `touch
  /work/test/elm/src/*.elm` (the harness's staleness check is mtime-based even though the
  flag is hash-keyed — eco-LSS-design memory).
- **`elm-aws-codegen` canary, mandatory, every run** (the `annotateCallStaging` exponential):
  the Phase 0.8 (c) command with `/usr/bin/time -v`; gate = completes, wall within 3% of
  flag-off.
- **Wall A/B with major-GC counts recorded** — cold-cache Stage 7a per
  `benchmarks/tier2-opt.md` "Methodology" (heading :35, protocol :35-96): binary built with the track flags,
  workload `ECO_MONO_ENGINE=subst`, `rm -rf $BK/eco-stuff` before every leg, warmup leg
  first, record wall + max RSS + objects/bytes allocated + minor/major GC + promoted +
  `out.mlir` size. **Never report a wall without its majors** (trigger lottery).
  **Retention counters are the ones C-R1 says can go the wrong way** — `Objects promoted`
  and `Major GC cycles` decide, not object counts (cse-pure-calls.md:200-204).
- Item-specific: the C1 distance-bucketed census table recorded in "C1 result" **regardless
  of D-C outcome**; crash-text E2E assertions re-checked after any merge of ⊥-capable calls
  (C4 only, by construction, in v1).

---

## Outcome — 2026-08-12: C1 GATE FAILED; C2 BUILT AND SHIPPED DEFAULT-OFF (Run P)

All five phases executed. The D-C gate failed by 40×; C2 was built and
benchmarked anyway on explicit instruction, since the loop's standing rule is
that a plan-internal census bar is never a veto — only a wall regression is.

**Landed:** `CsePurity.elm`, `CseCensus.elm`, `MonoCse.elm`, the `CseConfig`
knobs (`ECO_CSE` / `ECO_CSE_REPORT` / `ECO_CSE_MIN_COST` / `ECO_CSE_MAX_PER_DEF`),
the Generate.elm wiring, and invariant `CSE_001`. Phase 2 needed no work:
`design_docs/debug-log-ordering-policy.md` was authored by kernel-opt-11, and
its D-2 is exactly the prohibition this plan requires — `CsePurity` enforces it
by construction.

**Measured (Run P, frozen corpus):**

| | value |
|---|---|
| merges | **81** (82 on the live tree) |
| emitted `-out.mlir` | −1,052 B |
| `Objects allocated` | **+3,611,190 (+1.66%)** — the pass's own analysis cost |
| wall | −1.71% ⇒ FLAT |
| gates | E2E **1646/1646** in both flag states |

### Why it stays DEFAULT-OFF, unlike every other item in this series

This is the first item where flag-on has a *measured cost*: the pass walks all
30,905 specs and builds path keys for 69,995 candidates to find 81 merges, and
that shows up as +1.66% allocation in the compiler. Elsewhere in this loop a
FLAT wall meant "costs nothing, keep it on"; here FLAT means "the noise band is
wider than both the cost and the benefit". Shipping it on would trade a
measurable allocation increase for 81 static occurrences against a gate it
missed by 40×. It is landed, correct, tested, and one env var from being live if
the corpus ever changes.

### Two real defects found, both by measurement rather than review

1. **Decider path collision.** Every `Leaf (Inline _)` in a `Chain`/`FanOut`
   shared one path step, so distinct occurrences collided on one key. In the
   census this inflated `nearRedundant` 1619 vs 82 — a 20× overcount that would
   have PASSED the first criterion and sent the plan down a false branch. In the
   transform it produced a `MonoLet` that did not dominate its uses. Fixed by
   giving each decider position a distinct key; `CSE_001` now records the
   requirement.
2. **Tail-def parameters were not binders.** The scope test tracked `MonoLet`
   and `MonoDestruct` names only, so a candidate mentioning a `MonoTailDef`
   parameter was hoisted above its binder — caught by
   `test/elm/src/MultiLocalTailRecTest.elm` failing with
   `lookupVar: unbound variable i`. The plan's own reasoning contains the seed
   of this error: it says "every free local of the shape is by construction in
   scope at the occurrences", which is true and beside the point, because the
   binding goes at the LCA, not at the occurrence.

A third hazard was fixed pre-emptively rather than by failure: a group's let
binds the original first-occurrence subtree verbatim, so nested groups would
dangle. `dropOverlapping` rejects any group whose occurrence subtrees overlap a
kept group's.

### What the census actually says about this codebase

`b2_branch = 1672` of 1,909 redundant occurrences (87.6%) — pairs where neither
occurrence dominates. Essentially all the Elm-level redundancy in this compiler
is behind conditionals on both sides, which is C4 speculation territory and
explicitly out of v1 scope. The probe-then-insert idiom the plan is named for
(`b1c_probe`) accounts for **54 occurrences in 147,860 call sites**. The idiom
is real Elm; the compiler's own source does not write it.

`loopNear = 5`: even those 82 merges are almost entirely in code that runs once,
so the dynamic-heat proxy the plan introduced to keep static censuses honest
reports approximately nothing.

**Gates NOT run** (removed from the loop by instruction): heap-validate tree,
`--target bootstrap`. `elm-tests` was not re-run for this item — no
`compiler/tests` suite was added or touched.
