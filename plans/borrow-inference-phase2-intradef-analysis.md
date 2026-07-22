# Borrow Inference — Phase 2: Intra-def Analysis + Census (B2)

Status: IMPLEMENTATION-READY (v2, deep-dive pass). Parent design:
`design_docs/globalopt/borrow-inference-design.md` (v2) §6–§9, §13;
milestone B2. Series: `plans/borrow-inference-phase{0..6}-*.md`.

**Dependencies:** Phase 1 (`Borrow/Lifetime.elm`, `Borrow/Dsu.elm` — both
IMPLEMENTATION-READY). **Feeds:** Phase 3 (adds the SCC fixpoint + real
`Env.sigs`; this phase's driver is per-def, all-boundaries-owned).
**Gates:** full E2E green flag-on with emitted-MLIR byte-identity;
census lands; wall delta ≤3%; elm-aws-codegen canary.

**Goal:** the per-def analysis (RTy → constraints → staged solving) wired
as GlobalOpt Phase 6 in census-only mode (`reify = ROff`), every call
boundary all-owned (`Env.sigs` = const `Nothing`, kernels via all-owned
default). The standalone deliverable is the uniqueness/sharing oracle +
the `ECO_BORROW_REPORT` census.

All new modules go under `compiler/src/Compiler/GlobalOpt/Borrow/`.
Adding a compiler `.elm` source requires one reconfigure —
`cmake --preset build` — because `ELM_SOURCES` is a non-CONFIGURE_DEPENDS
glob (`compiler/CMakeLists.txt:126-129`); the `ninja-clang-lld-linux`
preset name in CLAUDE.md is stale. Test files need no reconfigure
(`compiler/tests` is symlinked wholesale, `CMakeLists.txt:119`).

## Verified facts this plan is built on

1. **`MonoType` constructors (`Monomorphized.elm:203-215`), exhaustive:**
   `MInt | MFloat | MBool | MChar | MString | MUnit | MList MonoType |
   MTuple (List MonoType) | MRecord (Dict Name MonoType) | MCustom
   IO.Canonical Name (List MonoType) | MFunction LambdaSetAnno (List
   MonoType) MonoType | MVar MVarId Constraint`. Notes for `Rty.freshRTy`
   (U2.1): `MString`/`MList`/`MBool`/`MUnit` are **dedicated
   constructors** (not customs); tuples are one `MTuple (List MonoType)`
   (no `Tuple2/Tuple3` ctors — arity is the list length); `MRecord` is a
   `Dict Name MonoType`, so **field order is already canonical ascending**
   (`Dict.toList` gives sorted `(Name, MonoType)` — the "sorted field
   order" `RRecord` needs comes free, no re-sort). `Constraint = CEcoValue
   | CNumber` (`:243-245`); `MVar _ CNumber` at Phase 6 is a compiler bug
   (`:194-196`) — treat as `RScalar`-poison defensively but do not expect
   it. `MVar _ CEcoValue` → `ROpaque` (poisoned, §7.3).
2. **`MonoExpr` — 18 constructors with arities (`Monomorphized.elm:913-
   931`):** `MonoLiteral Literal MonoType` · `MonoVarLocal Name MonoType`
   · `MonoVarGlobal Region SpecId MonoType` · `MonoVarKernel Region Name
   Name Name MonoType` (prefix, home, name, type) · `MonoList Region
   (List MonoExpr) MonoType` · `MonoClosure ClosureInfo MonoExpr MonoType`
   · `MonoCall Region MonoExpr (List MonoExpr) MonoType CallInfo` ·
   `MonoTailCall Name (List (Name, MonoExpr)) MonoType` · `MonoIf (List
   (MonoExpr, MonoExpr)) MonoExpr MonoType` · `MonoLet MonoDef MonoExpr
   MonoType` · `MonoDestruct MonoDestructor MonoExpr MonoType` ·
   `MonoCase Name Name (Decider MonoChoice) (List (Int, MonoExpr))
   MonoType` · `MonoRecordCreate (List (Name, MonoExpr)) MonoType` ·
   `MonoRecordAccess MonoExpr Name MonoType` · `MonoRecordUpdate MonoExpr
   (List (Name, MonoExpr)) MonoType` · `MonoTupleCreate Region (List
   MonoExpr) MonoType` · `MonoUnit` · `MonoAccessorValue Region Name
   MonoType`. The walker is **total, no wildcard** (§U2.2 table).
3. **`Mono.typeOf : MonoExpr -> MonoType`** exists and is total
   (`Monomorphized.elm:1126-…`, all 18 arms), exported (`:12`). Every
   `MonoExpr` carries its `MonoType`, so `freshRTy` is always callable on
   a sub-result. `Mono.nodeType : MonoNode -> MonoType` (`:883-908`) is
   the node analogue.
4. **`MonoNode` kinds (`Monomorphized.elm:864-873`):** `MonoDefine
   MonoExpr MonoType` · `MonoTailFunc (List (Name, MonoType)) MonoExpr
   MonoType` · `MonoCtor CtorShape MonoType` · `MonoEnum Int MonoType` ·
   `MonoExtern MonoType` · `MonoManagerLeaf String MonoType` ·
   `MonoPortIncoming MonoExpr MonoType` · `MonoPortOutgoing MonoExpr
   MonoType`. Per-def entry points = `MonoDefine`/`MonoTailFunc`;
   construct rule = `MonoCtor`/`MonoEnum`; whole-signature `RPort` poison
   = `MonoExtern`/`MonoManagerLeaf`/`MonoPortIncoming`/`MonoPortOutgoing`.
5. **`MonoDef = MonoDef Name MonoExpr | MonoTailDef Name (List (Name,
   MonoType)) MonoExpr` (`:965-967`); `MonoDestructor Name MonoPath
   MonoType` (`:973`); `MonoPath = MonoIndex Int ContainerKind MonoType
   MonoPath | MonoField Name MonoType MonoPath | MonoUnbox MonoType
   MonoPath | MonoRoot Name MonoType` (`:1002-1006`).** `Decider a = Leaf
   a | Chain (List (MonoDtPath, DT.Test)) (Decider a) (Decider a) | FanOut
   MonoDtPath (List (DT.Test, Decider a)) (Decider a)` (`:1105-1108`);
   `MonoChoice = Inline MonoExpr | Jump Int` (`:1113-1115`). The walker
   reaches arm expressions through the decider exactly as
   `MonoTraverse.foldDeciderAccFirst`/`foldChoiceAccFirst` do
   (`MonoTraverse.elm:202-207`): fold the decider collecting each `Leaf
   (Inline e)`, then fold the `jumps : List (Int, MonoExpr)` table; `Jump
   n` leaves carry no expr (they redirect to `jumps` entry `n`).
6. **`CallInfo`/`CallKind` (`:1493-1550`):** `CallKind =
   CallDirectKnownSegmentation | CallDirectFlat | CallGenericApply |
   CallSegmentationUnknown`; `callInfo.isSingleStageSaturated : Bool` and
   `callInfo.callKind` are the §8.3 dispatch keys. Phase 2 needs only the
   coarse split (direct-var vs kernel-var vs everything-else) since all
   boundaries are owned this phase; the fine dispatch is Phase 3.
7. **32-slot GC-scan record cap is a HEAP invariant, not advisory.**
   Compiled Record heap objects have a 32-slot GC scan limit; a record
   with a 33rd field fails the backend verifier at MLIR parse
   (`field_count exceeds Record's 32-slot GC scan limit`) — documented on
   the MonoSolver `S` record (`Compiler/MonoSolver/Engine.elm:124-126,
   338-342`). Because the Borrow modules are themselves self-compiled by
   eco, every live analysis record (`Gen`, `Constraints`, `SolveState`,
   `BorrowStats`) must stay ≤32 fields. Grouping plan in U2.2/U2.3.
8. **No compiler test hand-builds `MonoExpr` values directly.** A
   grep for constructor-on-RHS (`= MonoLet`, `MonoDef "…"`, …) over
   `compiler/tests/` finds zero. The established fixture pattern is
   source-first: `Compiler.AST.SourceBuilder` (`define, callExpr, ifExpr,
   listExpr, binopsExpr, intExpr, varExpr, tLambda, tType, caseExpr,
   letExpr, destruct, …`, exposed `SourceBuilder.elm:1-40`) →
   `TestLogic.TestPipeline.runToMono` / `runToGlobalOpt`
   (`TestPipeline.elm:332`, yields `.monoGraph` / `.optimizedMonoGraph :
   Mono.MonoGraph`) → traverse the resulting graph. Pure record data
   (`Constraints`, DSU ops) *is* hand-built directly, per the `DsuTest`
   precedent (Phase 1). Fixture strategy in U2.3 splits accordingly.
9. **Config wiring anchors:** pure data + decoder + hash live in
   `Compiler/Eco/Config.elm` (`EcoConfig` `:32-37`, `default` `:202-232`,
   `decoder` `:239-245`, `hash` `:361-456`); env overrides live in
   `Builder/Eco/Config.elm` (`applyEnvOverrides` `:103-171`, per-var
   helpers `:368-…`). `report`-style flags are excluded from `hash` by
   the simplest mechanism possible: **they are never referenced inside
   `hash`** (see `lss.report`/`mono.validate`/`inline.report` — none
   appears in `hash`), and every optional token is emitted only for a
   non-default value (`hash:404-455`), so a default block contributes
   nothing and caches never invalidate.
10. **Phase-6 wiring anchors:** `MonoGlobalOptimize.globalOptimizeWith
    Stats` (`:125-152`) runs P1–P5 and returns after `annotateCallStaging`
    at `:150`; `GlobalOptStats` record at `:117-120`. It is called once,
    from `Builder/Generate.elm:906` inside `runGlobalOptPhase` (`:900-
    963`), which currently takes a `Bool` lssReport (`:901`) sourced from
    `ecoConfig.mono.lss.report` at the call site `:823`. Census stderr
    lines use `System.IO.writeLn System.IO.stderr` (`Generate.elm:918`,
    `:746`); **stdout is owned by MLIR text mode** (`:744-746`), so the
    borrow census MUST go to stderr.

### Design discrepancies

- **D1 — `MonoCase` Name order is swapped in the design prose.** §8.2
  writes `MonoCase root _ decider jumps`, implying the scrutinee root is
  the FIRST `Name`. The constructor is `MonoCase label scrutinee decider
  jumps t` (canonical binding names at `MonoTraverse.elm:386`,
  `Generate/MLIR/Expr.elm:391`, `TailRec.elm:338`): first `Name` = case
  **label** (join-point label), second `Name` = **scrutinee** root var.
  The walker seeds the resource of the SECOND `Name`. Flagged; returned
  as an open question for a design-prose fix.
- **D2 — `BorrowConfig` placement (decision).** §6 says "following the
  `lss`/`inline` blocks" but does not fix top-level vs nested-under-mono.
  Decision: **top-level `borrow` field on `EcoConfig`**, parallel to
  `inline`/`bytesFusion`, NOT under `mono`. Rationale: borrow is a
  GlobalOpt-Phase-6 concern read in `runGlobalOptPhase`, engine-agnostic
  (runs under `EngineSubst` too), and `mono.*` is monomorphizer-scoped.
  Mirrors how `inline` (also a GlobalOpt consumer) sits top-level.
- **D3 — `MList` "spine collapse" (§7.2) is a no-op at the RTy layer.**
  §7.2's table says `MList` gets "spine collapse per §7.3", but §7.3
  defines collapse only for `RCustom`. `RList ResVar RTy` already models
  the list as ONE spine resource + a single element `RTy` shared across
  all cons cells — i.e. the collapse is baked into the type, not a
  separate constraint step. No per-cons resources are minted. Recorded so
  U2.1 does not invent a spine-merge pass.
- **D4 — §8.2's path example notation is index-first and is superseded by
  the `Step` (nodeId, index) order.** The §8.2 dispatch table (:759-762)
  writes paths as `Seq 0 2`/`Seq 1 2` (destruct rhs/body of a 2-child
  node) and `Arm i n`, i.e. **index first, arity/node second**. That
  conflicts with the `Step` type fixed in Phase 1 U1.1 and design §7.4
  (:666-668), whose first `Int` is the **skeleton node id** and second is
  the **child/arm index** (`Seq n i`, `Arm n i`). This plan adopts the
  type-consistent node-first form throughout (U2.2: `Seq n 0` rhs, `Seq n
  1` body, `Arm n i` arms). Flagged; returned as an open question for a
  §8.2 design-prose fix (mirrors how D1 is handled).

## Census counters — single source of truth (design §13, verbatim)

This plan **declares** the counter set that Phases 3/4/5/6 consume. The
`BorrowStats` record (U2.4) is the one place they live; keep it ≤32
fields (fact 7 — currently 20, room to grow). Each §13 line verbatim →
its canonical field name; counters that only become nonzero in a later
phase are declared here at `0` so downstream plans have stable names.

| §13 counter (verbatim) | field | first live |
|---|---|---|
| resources minted | `resources` | B2 |
| %borrowed | `borrowedResources` (÷ `resources`) | B2 |
| would-be dups | `wouldDup` | B2 |
| would-be drops | `wouldDrop` | B2 |
| would-be frees | `wouldFree` | B2 |
| `poisonedByClosure` (PoisonCause split from B3.5) | `poisonedByClosure` | B2 |
| `poisonedByErased` | `poisonedByErased` | B2 |
| `poisonedByKernel` | `poisonedByKernel` | B2 (kernels all-owned) |
| `poisonedParams` | `poisonedParams` | B3 (declared 0) |
| `poisoningCallSites` | `poisoningCallSites` | B3 (declared 0) |
| `capturesForcedOwned` (§8.4) | `capturesForcedOwned` | B2 |
| `nonVarOperandHeapResults` (split owned-fresh vs borrowed-producer) | `nonVarOperandHeapOwnedFresh`, `nonVarOperandHeapBorrowedProducer` | B2 |
| `updateCopiedHeapFields` | `updateCopiedHeapFields` | B2 |
| `lambdaSigNoSigReads` (`Poison PNoSig`) | `lambdaSigNoSigReads` | B3.5 (declared 0) |
| RC-1 sizing: borrow lifetimes crossing owned mutator-argument flows | `rc1CrossingFlows` | B3 (declared 0) |
| max borrow-induced lifetime extension per def | `maxBorrowExtension` | B2 |
| `immortal` literal count | `immortalLiterals` | B2 |
| meet-degraded sites (`PMixedMeet`) | `meetDegraded` | B3.5 (declared 0) |

## U2.1 — `Borrow/Rty.elm` (~150 LoC)

New file; reconfigure after creating. Header:

```elm
module Compiler.GlobalOpt.Borrow.Rty exposing
    ( ResVar, RTy(..)
    , freshRTy, zipRTy, topRes, allRes, rcManaged )

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Dict
```

Types (design §7.3, verbatim; `ResVar = Int`, dense from 0 per def):

```elm
type alias ResVar = Int
type RTy
    = RScalar
    | RString ResVar
    | ROpaque ResVar                       -- MVar _ CEcoValue
    | RList ResVar RTy
    | RTuple ResVar (List RTy)
    | RRecord ResVar (List ( Name, RTy ))  -- ascending field order
    | RCustom ResVar (List RTy)            -- type-arg positions only
    | RClosure ResVar                      -- env resource
```

The ResVar supply threaded through `freshRTy` is a **plain `Int`
counter**, NOT the full `Gen` record. `Gen` embeds `Constraints`
(U2.2) and therefore lives in `Constrain.elm`; `Constrain` in turn must
import `Rty` (for `RTy`/`freshRTy`/`zipRTy`/`topRes`/`allRes`). Giving
`Rty.freshRTy` a `Gen` parameter would make `Rty` depend on
`Constrain.Constraints`, forming a forbidden `Rty` → `Constrain` → `Rty`
import cycle. Keeping the counter a bare `Int` (`Rty` imports only
`Array`/`Mono`/`Name`/`Dict`) breaks the cycle; the U2.2 walker lifts it
in and out of `Gen.next`. `Gen`/`emptyGen`/`fresh` are defined in
`Constrain.elm` (U2.2), not here.

`freshRTy : Mono.MonoType -> Int -> ( RTy, Int )` — bare `Int` counter
in/out; one ResVar per heap row, per fact 1's §7.2 table:

- `MInt|MFloat|MBool|MChar|MUnit` → `RScalar` (no ResVar — BORROW_001);
- `MString` → `RString r`;
- `MVar _ CEcoValue` → `ROpaque r`; `MVar _ CNumber` → `RScalar`
  (defensive, fact 1 — a bug if it ever reaches here);
- `MList t` → `RList r (freshRTy t)` (D3: single spine resvar);
- `MTuple ts` → `RTuple r (map freshRTy ts)`;
- `MRecord d` → `RRecord r (Dict.toList d |> map (\(n,t) -> (n, freshRTy
  t)))` (already ascending, fact 1);
- `MCustom _ _ args` → `RCustom r (map freshRTy args)` (type-arg
  positions only; per-ctor interior is the vertical-get collapse emitted
  in U2.2, §7.3, not minted here);
- `MFunction _ _ _` → `RClosure r` (param/result spaces are handled at
  boundaries, never inside a value's RTy).

Helpers:
- `topRes : RTy -> Maybe ResVar` — `RScalar → Nothing`; every other row →
  `Just` its head ResVar.
- `allRes : RTy -> List ResVar` — pre-order (head then children
  left-to-right); the mint order `freshRTy` used, so it is the canonical
  `ResPos` ordering Phase 3's `SigTy` relies on.
- `zipRTy : RTy -> RTy -> List ( ResVar, ResVar )` — structurally pair
  two aligned ground RTys pre-order (always aligned: ground+equal by
  construction, §7.3). Mismatched shapes are unreachable; return `[]`
  (total, conservative — a dropped flow only shortens a lifetime).
- `rcManaged : Mono.MonoType -> Bool` — B0-report v1 set: `MString` →
  True; everything else False until B4 (the bytes/string flat-buffer
  family; §16.1). Used only for census bucketing (`wouldFree`/RC sizing)
  this phase; no reify consumer yet.

`RCustom` interior collapse and `ROpaque` poisoning are **constraint-side
behaviors** (emitted in U2.2/solved in U2.3), documented here for the RTy
reader but not encoded in the type.

## U2.2 — `Borrow/Constrain.elm` (~350 LoC)

New file; reconfigure. Emits the `Constraints` accumulator (design §7.5,
verbatim) — 7 fields, under the cap:

```elm
type alias Constraints =
    { flows : List ( ResVar, ResVar )        -- bind → use (lateral; I-Use)
    , gets : List Get                        -- container reads (I-Get)
    , storageEq : List ( ResVar, ResVar )    -- nested/heap-storage equalities (§3.3)
    , scopes : Dict ResVar Path              -- binding resource → scope path (I-Let)
    , seeds : List ( ResVar, Path )          -- ltA/ltP ≥ p (reads, borrowed args)
    , forcedOwned : List ( ResVar, Reason )
    , occs : List Occ }                      -- reification records
type alias Get = { container : ResVar, out : List ( ResVar, ResVar ), path : Path }
type alias Occ = { occId : Int, binder : Name, path : Path, res : List ResVar }
type Reason = RConstruct | RKernel | RClosureBoundary | RErased | RPort | RTailArg
```

`Path`/`Step` are imported from `Borrow.Lifetime` (Phase 1: `Step = Seq
Int Int | Arm Int Int`, `type alias Path = List Step`).

`Gen` (the full per-def analysis state: ResVar supply + constraint
accumulator + skeleton-node counter) is defined **here**, not in `Rty`
(U2.1 — cycle avoidance):

```elm
type alias Gen =
    { next : ResVar, cs : Constraints, nodeCounter : Int }   -- 3 fields, under the cap
emptyGen : Gen
fresh : Gen -> ( ResVar, Gen )   -- ( g.next, { g | next = g.next + 1 } )
```

`Rty.freshRTy` takes a bare `Int`; the walker lifts it through `Gen.next`
(`\t g -> let ( rty, n ) = Rty.freshRTy t g.next in ( rty, { g | next = n } )`).

Walker (Design-B direct recursion, no DSL — §8.1; depth = AST depth,
which is stack-safe at node scale, per Phase 1's stack-safety note):

```elm
type alias Env =
    { vars : Dict Name RTy
    , sigs : Mono.SpecId -> Maybe ()   -- Phase 2 placeholder (const Nothing); Phase 3 swaps () → Sig.BorrowSig
    , kernels : ()                     -- Phase 2 placeholder (kernels all-owned unconditionally); Phase 3 swaps () → the KernelSigs table
    , lssFacts : () }                  -- placeholder pre-B3.5
constrainExpr : Env -> Path -> Mono.MonoExpr -> Gen -> ( RTy, Gen )
```

**Decision — Phase 2 uses `()` placeholder codomains for `sigs`/`kernels`,
NOT the real cross-module types** (mirrors the existing `lssFacts : ()`
placeholder). `Borrow/Sig.elm` (`BorrowSig`) and `Borrow/KernelSigs.elm`
(`KernelSig`/`lookup`) are Phase-3 **create** deliverables (Phase-3 plan
U3.1.a/U3.2, design §6:561-562); Phase 2 must not reference them or it
cannot compile against a source tree that lacks those modules. Because
Phase 2 keeps every boundary all-owned, the walker never needs a real sig
lookup: `sigs` always yields `Nothing` and the kernel branch is all-owned
unconditionally (see §8.3 dispatch), so a placeholder `()` codomain is
sufficient. Phase 3 swaps the `()` codomains for `Maybe Sig.BorrowSig` and
the `KernelSigs` table at the same site.

**Skeleton path numbering (fixed here so Phase 5 ltP placement is
deterministic).** The walker threads a monotone skeleton-node counter (a
field on `Gen`; mint a fresh node id at every branching constructor).
Sequential children of a node of that-many children get `Seq nodeId i`;
disjoint arms get `Arm nodeId i`. Concrete assignments: `MonoLet` /
`MonoDestruct` = `Seq n 0` (rhs/root) then `Seq n 1` (body), arity 2;
`MonoIf`/`MonoCase` arms = `Arm n i`, conds evaluated at `Seq`; call
args = `Seq n i` in argument order; `MonoList`/tuple/record elements =
`Seq n i`. `topRes`/`allRes` give the resources a `seeds`/`scopes` path
attaches to.

**Full dispatch table (all 18 `MonoExpr` ctors — total, no wildcard;
matches fact 2 arities):**

| Constructor | Action |
|---|---|
| `MonoLiteral (LStr _) t` | fresh `RString r`; bump `immortalLiterals`; mark immortal (census only — reify skips). |
| `MonoLiteral _ _` | `RScalar`. |
| `MonoUnit` | `RScalar`. |
| `MonoVarLocal x _` | `Dict.get x env.vars`; mint a use RTy via `freshRTy`; `flows` bind→use pairwise (`zipRTy`); `storageEq` on every *nested* pair (heap-storage, §3.3); record an `Occ`. |
| `MonoVarGlobal _ specId t` | value reference: call rule (§8.3) with 0 args (Phase 2: `env.sigs specId = Nothing` ⇒ result `freshRTy t` all-owned). Function-typed reference with no args ⇒ fresh `RClosure`. |
| `MonoVarKernel _ _ _ _ t` | kernel *value* (not a call): fresh `RClosure`, `forcedOwned RClosureBoundary` (boundary-poisoned). |
| `MonoList _ es t` / `MonoTupleCreate _ es t` / `MonoRecordCreate fes t` | constrain each element/field; result `freshRTy t`, container top `forcedOwned RConstruct`; each element-use resource `storageEq` with the matching container slot resource (**heap-store position** — Stage-C store obligation forces Owned; a Borrowed binder stored here becomes a coercion dup). `MonoRecordCreate` iterates `fes : List (Name, MonoExpr)`; align slots by field name. |
| `MonoRecordAccess e f t` | constrain `e`; `gets { container = top e, out = [(slot-of-f, fresh r)], path }`; `seeds (top e, path)` (a read). |
| `MonoRecordUpdate base fes t` | constrain `base` as a read (`gets` at this path) + each field; result `freshRTy t` `forcedOwned RConstruct`; copied-over (unmentioned) fields = vertical `Get.out` base→result pairs; bump `updateCopiedHeapFields` per heap-typed copied field (no occurrence to attach a dup to — sizes the B6 field-selector prereq). |
| `MonoRecordAccess`/update slot indices | resolved by field name against the base's `RRecord` field list (ascending, fact 1). |
| `MonoDestruct (MonoDestructor x dpath _) body t` | root var (from `dpath`'s `MonoRoot Name`) resource `seeds` at `Seq n 0`; `gets` with one `out` pair per projected heap position along `dpath` (`MonoIndex`/`MonoField`/`MonoUnbox`); bind `x`'s RTy in `env.vars`; body at `Seq n 1`; `scopes (res x) = Seq n 1`. |
| `MonoCase label scrutinee decider jumps t` | **D1**: seed the resource of the SECOND name (`scrutinee`); decider tests read tags/fields ⇒ `seeds` the scrutinee's resource chain at the case path. Reach arm bodies via `foldDecider` (fact 5): each `Leaf (Inline e)` and each `jumps` entry is an arm at `Arm n i`; zip every arm result into one fresh case-result RTy (`flows` both directions ⇒ effective `storageEq` + access join — branch unification). `Jump` leaves carry no expr. |
| `MonoIf pairs elseE t` | each `(cond, then)` in `pairs`: cond at `Seq`, branch at `Arm n i`; `elseE` at `Arm n last`; zip branch results into one fresh RTy as for case. |
| `MonoLet (MonoDef x rhs) body t` | rhs at `Seq n 0`; bind `x`; `scopes (res x) = Seq n 1`; body at `Seq n 1`. |
| `MonoLet (MonoTailDef x params rhs) body t` | local tail function: analyze `rhs` as a nested def (own skeleton, params bound from `params`); signature all-owned v1; bind `x` `RClosure`; body. |
| `MonoCall f args t callInfo` | §8.3 dispatch (below). |
| `MonoTailCall _ args t` | constrain each `(name, e)` arg; every arg occurrence `seeds` **escape** (§8.5: a path ordered after the whole body — `RTailArg`) so reification never places a drop after the tail call (BORROW_005); no mode forcing. |
| `MonoClosure info body t` | §8.4: each captured heap resource in `info.captures` `forcedOwned RClosureBoundary`, nested `storageEq` with env interior; bump `capturesForcedOwned`; body analyzed as a nested function (params from `info.params`, all-owned v1). |
| `MonoAccessorValue _ _ t` | function value → fresh `RClosure`, `forcedOwned RClosureBoundary`. |

**§8.3 call dispatch (Phase 2 = coarse; every branch lands all-owned).**
Inside `MonoCall`, dispatch on the callee shape (fact 6):
- callee `MonoVarGlobal _ specId _`: `env.sigs specId` (= `Nothing` this
  phase) ⇒ every arg `flows` owned into a fresh param instance, result
  `freshRTy t` owned. Phase 3 replaces `Nothing` with the sig table.
- callee `MonoVarKernel _ _ home name _`: Phase 2 does **not** consult a
  kernel table (`env.kernels` is a `()` placeholder); every kernel call is
  all-owned unconditionally ⇒ args owned; bump `poisonedByKernel` for
  heap-typed args; result owned-fresh. Phase 3 replaces this with
  `KernelSigs.lookup (home, name)`.
- everything else (closure/generic/PAP, under/over-application): every
  arg `forcedOwned RClosureBoundary`, result fresh all-owned; bump
  `poisonedByClosure`.
Also bump `nonVarOperandHeapOwnedFresh` / `nonVarOperandHeapBorrowedProducer`
for each heap-typed **non-variable** operand (DS4 sizing), split by
whether its producer is an owned-fresh construct or a borrowed-producer
read.

**`MonoNode` entry (`constrainNode : Env -> Mono.MonoNode -> Gen -> Gen`,
fact 4):** `MonoDefine e _` / `MonoTailFunc params e _` → seed params
into `env.vars`, `constrainExpr` the body at root `[]`; `MonoCtor`/
`MonoEnum` → construct rule (result owned-fresh); `MonoExtern`/
`MonoManagerLeaf`/`MonoPortIncoming`/`MonoPortOutgoing` → whole signature
`RPort`-poisoned (no walk; count nothing — these never demand analysis).

**Record-cap grouping (fact 7):** keep `Constraints` at 7 fields and
`Gen` at 3 (`next`, `cs`, `nodeCounter`). Do NOT inline census counters
into `Gen`/`Constraints` — census accumulates in the separate
`BorrowStats` record threaded by the U2.4 driver, folded from `occs`
after solving.

## U2.3 — `Borrow/Solve.elm` (~300 LoC)

New file; reconfigure. Stages A–D per §9, two-index-space model (§7.1;
DSU is storage-only, access/lt are raw-ResVar Arrays). All worklists are
**data**, driven by tail-recursive loops over a list-as-stack
accumulator — Elm compiles self-tail-calls to loops, so the fixpoint
dimension never uses the JS call stack (`plans/state-monad-stack-
safety.md`); only the finite-depth structural helpers recurse.

```elm
type Mode = Borrowed | Owned                 -- lattice & < •
type alias SolveState =
    { dsu : Dsu.Dsu                          -- Phase 1 module
    , storageOwned : Array Bool              -- indexed by DSU root
    , access : Array Mode                    -- raw ResVar
    , ltA : Array Lifetime.Lifetime          -- raw ResVar
    , ltP : Array Lifetime.Lifetime }        -- raw ResVar
type alias Solved = { state : SolveState, cs : Constrain.Constraints }
solve : Int -> Bool -> Constrain.Constraints -> Solved   -- nRes, allOwnedFlag, constraints
```

- **Stage A — storage classes.** `Dsu.union` over every `storageEq` pair
  AND every `flows` pair (bidirectional ≥ ⇒ equality along flow, §3.3);
  set `storageOwned[root] = True` for every `forcedOwned` member's class.
- **Stage B — approximate lifetimes (`ltA`).** Seed from `cs.seeds`
  (`Lifetime.join (ltA r) (Lifetime.fromPath p)`); worklist of ResVars:
  pop `u`; for each `(b, u) ∈ flows`, `new = join (ltA b) (ltA u)`; if
  `not (Lifetime.eq new (ltA b))` set and push `b`. Terminates (finite
  lattice, monotone).
- **Stage C — access modes.** `forcedOwned` resources start `Owned`
  (else `Borrowed`; if `allOwnedFlag`, seed **every** access `Owned` —
  the Perceus baseline / soundness-isolation switch, §19.2). Per
  directed `(b,u) ∈ flows`: `access b := access b ⊔ access u` (rule 2,
  ownedness flows down); and if `not (Lifetime.endsBefore (ltA u)
  (scope b))` then `access u := access u ⊔ access b` (rule 1, escape
  from an owned binding must be owned). Each `Get` imposes `access
  interior = access projected` (get-constr). **Store obligation:** every
  resource at a heap-store position (`storageEq` member of an
  owned-storing class) has `access` forced `Owned`. Iterate to fixpoint.
- **Stage D — precise lifetimes (`ltP`).** Same seeds; propagate along
  **lateral-flow** (flow edges whose use side solved `Borrowed`) and
  **vertical-flow** (`Get.out` pairs where interior `Owned`, projected
  `Borrowed`). `ltP` governs move legality / drop placement (Phase 5).

Readback API (§9.5 primary rule):

```elm
reifiedMode : ResVar -> Solved -> Mode   -- top-level → access; nested → storage class
ltAOf : ResVar -> Solved -> Lifetime.Lifetime   -- for BORROW_005 test (Phase 3)
coercionPoints : Solved -> List ResVar   -- producer Borrowed, consumer-side Owned (census dups)
```

Because `reifiedMode` distinguishes top-level (its `access`) from nested
(its DSU class `storageOwned`), the caller passes a top-level flag; the
census computes `wouldDup` from `coercionPoints`, `wouldDrop`/`wouldFree`
from owned resources whose `ltP` ends inside the body (`wouldFree` gated
by `rcManaged`).

**Tests (`compiler/tests/Compiler/GlobalOpt/Borrow/SolveTest.elm`,
`module … exposing (suite)`).** Per fact 8, Solve tests hand-build
`Constraints` records directly (pure data, `DsuTest` precedent) — this is
the honest, precise fixture path; the Constrain walker is exercised
source-first (below). Fixtures, each a small `Constraints` literal with
known expected modes/lifetimes:
1. **read-only helper**: a binding used only in a `seeds` read, no owned
   consumer ⇒ `reifiedMode = Borrowed`.
2. **escaping store**: a binding whose resource is `storageEq` into an
   owned-storing (`forcedOwned RConstruct`) class ⇒ `Owned`.
3. **asymmetric case arms**: one arm stores (owned), one only reads;
   branch-unified binder ⇒ `Owned` (any-owned-wins on the join).
4. **projection chain (vertical flow)**: a `Get` whose output is consumed
   owned ⇒ container interior forced `Owned`; appears in
   `coercionPoints`.
5. **tail loop (escape seeding)**: a resource seeded `RTailArg` at a
   past-body path ⇒ `ltA` never `endsBefore` the tail-call path (the
   fact Phase 3's BORROW_005 test asserts end-to-end).
6. **all-owned flag ⇒ every heap occurrence non-final dups** (Perceus
   shape): same `Constraints` as (1) but `allOwnedFlag = True` ⇒ every
   `reifiedMode = Owned` and `coercionPoints` covers every borrowed-source
   store. Pins §19.2's isolation switch.

## U2.4 — Phase-6 wiring + config + census plumbing

**(a) `Borrow.elm` driver v0** (new file; reconfigure). Per-def
orchestration only — no SCC, no edges (Phase 3 adds those, discarding
`callEdges` which the inline pass empties). API:

```elm
module Compiler.GlobalOpt.Borrow exposing ( BorrowStats, emptyStats, run )
run : Config.BorrowConfig -> Mono.MonoGraph -> ( Mono.MonoGraph, BorrowStats )
```

`run` folds over `nodes : Array (Maybe MonoNode)` (via `Array.foldl`);
per live node: `Constrain.constrainNode` (Env with `sigs = \_ -> Nothing`,
`kernels = ()` [Phase 2 placeholder — kernels all-owned unconditionally;
Phase 3 swaps `()` for the real `KernelSigs` table]) → `Solve.solve nRes
False cs` → fold the `Solved` facts into `BorrowStats`. **The B2 census
passes `allOwnedFlag = False`:** boundaries are owned via `sigs = Nothing`,
not via the per-access §19.2 Perceus switch, which must stay `False` so
the census can actually measure `%borrowed`. The `allOwnedFlag = True`
path is reserved for the U2.3 test-6 isolation pin — there is no
`BorrowConfig` knob for it (it is a fixed `False` here, a fixed `True` in
that one test). With `reify = ROff` the graph is
returned **unchanged** (`( graph, stats )`, identity in the first slot) —
this is what the U2.5 graph-identity gate checks. `BorrowStats` holds the
counters from the census table above (≤32 fields; add
`emptyStats`/`mergeStats`). `Config.BorrowReify = ROff | RRc` (RRc unused
until B4).

**(b) `Compiler/Eco/Config.elm`.** Add the block (D2: top-level):

```elm
type alias BorrowConfig =
    { enabled : Bool, reify : BorrowReify, report : Bool, validate : Bool }
type BorrowReify = ROff | RRc
```

- `EcoConfig` (`:32-37`) gains `, borrow : BorrowConfig`.
- `default` (`:202-232`) gains `, borrow = { enabled = False, reify =
  ROff, report = False, validate = False }` — `enabled = False` ⇒
  byte-identical by construction (pass not called).
- `decoder` (`:239-245`) gains `|> D.apply (D.optionalField "borrow"
  borrowDecoder default.borrow)` + a `borrowDecoder` mirroring
  `lssDecoder` (`:298-307`): decode `enabled`/`reify` (string
  `"off"|"rc"` → `ROff|RRc`, default `ROff`), and accept `report`/
  `validate` from JSON for convenience.
- `hash` (`:361-456`): append `borrow` tokens ONLY for non-default
  artifact-affecting values — emit `"brc=1"` iff `cfg.borrow.reify ==
  RRc` (the only field that changes emitted artifacts). `enabled=True,
  reify=ROff` is graph-identical ⇒ no token. `report`/`validate` are
  **never referenced in `hash`** (fact 9), exactly like `lss.report`.

**(c) `Builder/Eco/Config.elm`** env overrides (`applyEnvOverrides`
`:103-171`): add two links mirroring `applyLssReportOverride` (`:370-
389`): `ECO_BORROW=off|rc|1` (`1` ⇒ `enabled=True, reify=ROff`;
`rc` ⇒ `enabled=True, reify=RRc`; `off`/absent ⇒ unchanged) and
`ECO_BORROW_REPORT=1|true|yes` ⇒ `borrow.report=True`. Document both in
the module header list (`:78-100`).

**(d) `MonoGlobalOptimize.elm`.** Thread the borrow config and run Phase
6 after `annotateCallStaging` (`:150`):
- `GlobalOptStats` (`:117-120`) gains `, borrow : Borrow.BorrowStats`.
- `globalOptimizeWithStats` signature → `Config.BorrowConfig ->
  Mono.MonoGraph -> ( Mono.MonoGraph, GlobalOptStats )`. Replace the
  return tuple at `:150-152` with: run `annotateCallStaging …` → `graph5`;
  `( graph6, borrowStats ) = Borrow.run borrowCfg graph5`; return
  `( graph6, { wrappersInserted = …, abiCloning = abiStats, borrow =
  borrowStats } )`. With `reify = ROff`, `graph6 == graph5` (identity).
- Keep `globalOptimize : Mono.MonoGraph -> Mono.MonoGraph` unchanged for
  `TestPipeline`/other callers by defining it `= Tuple.first <<
  globalOptimizeWithStats Config.default.borrow` (borrow disabled).
  `import Compiler.Eco.Config as Config` (leaf data module, no cycle).

**(e) `Builder/Generate.elm`.** At `:823` change `runGlobalOptPhase
ecoConfig.mono.lss.report stats` → `runGlobalOptPhase ecoConfig stats`.
`runGlobalOptPhase` (`:900-963`) signature → `Config.EcoConfig ->
FEStats.Handle -> Mono.MonoGraph -> Task …`; pass `ecoConfig.borrow` to
`globalOptimizeWithStats` (`:906`); keep the existing lss line gated on
`ecoConfig.mono.lss.report`; add, gated on `ecoConfig.borrow.report`, a
**stderr** (`System.IO.writeLn System.IO.stderr`, fact 10 — never stdout)
`key=value` census line rendering `goStats.borrow` in the house pattern
(`grep -a`-safe), e.g. `borrow: resources=… borrowed=… wouldDup=…
wouldDrop=… wouldFree=… poisonedByClosure=… poisonedByErased=…
poisonedByKernel=… capturesForcedOwned=… immortal=… maxExt=…`.

## U2.5 — B2 gate run

- **Graph identity (the load-bearing new gate).** With `enabled=True,
  reify=ROff` the pass returns the graph unchanged, so emitted MLIR is
  byte-identical flag-on vs flag-off. Mechanics: `--text-mlir` is
  byte-canonical (the property the `mlir-equivalence` runner relies on,
  `plans/stage2-stage7-mlir-diff-runner.md`); the gate compiles the E2E
  corpus twice and diffs the `.mlir`. Concretely:
  1. **Env-blindness trap (LSS lesson, §19.4):** `borrow.enabled`/`report`
     do not change `Config.hash` (analysis-only), so the E2E harness
     cache is blind to them and would reuse stale flag-off artifacts.
     **`touch` every test `.elm` before the flag-on leg.**
  2. Flag-off leg: `cmake --build build --target full 2>&1 | tee
     /tmp/borrow_off.txt` (run ONCE; grep the file).
  3. Flag-on leg: `find test -name '*.elm' -exec touch {} +` then
     `ECO_BORROW=1 ECO_BORROW_REPORT=1 cmake --build build --target full
     2>&1 | tee /tmp/borrow_on.txt`.
  4. Both must show all tests passing (byte-identical MLIR ⇒ identical
     downstream). Since MLIR is unchanged, full-corpus equality is
     implied; optionally diff a sampled set of `--text-mlir` dumps to
     confirm identity directly.
- **Full E2E green flag-on:** the `--target full` run above. Run E2E and
  `elm-tests` **serially, never concurrently** (typed-artifacts cache
  race, §19.4). `elm-tests` for the new pure suites:
  `cmake --preset build` (refresh `ELM_SOURCES` after the new src files)
  then `cmake --build build --target elm-tests 2>&1 | tee
  /tmp/test_output.txt`; grep `TESTS (PASSED|FAILED)|Falsifiable`.
- **Wall budget ≤3%:** interleaved self-compile timing flag-on vs off
  (record **majors** alongside walls — the major-GC trigger lottery
  lesson; a wall without its major count is uninterpretable).
- **elm-aws-codegen canary:** the deep inliner let-chains are the
  pathological walker input (the `annotateCallStaging` exponential
  incident's shape). Gate = canary completes within wall budget; the
  per-def walk stays linear (no fixpoint blowup — there is no SCC loop in
  Phase 2). Invoke it as the prior borrow/LSS work did (the
  elm-aws-codegen corpus entry under `test/`).
- **First real census** recorded in this plan's as-built section
  (grep `/tmp/borrow_on.txt` for `borrow:` lines).
- **Invariant row:** add **BORROW_001** to `design_docs/invariants.csv`
  (§20: resources minted only at §7.2 heap positions; scalars/Bool/Unit
  never carry RC ops) — the one row that becomes meaningful at B2.

## Gates summary

E2E 100% flag-on · emitted-MLIR byte-identity flag-on/off · elm-tests
green (Rty/Constrain/Solve suites) · wall ≤3% (majors recorded) · canary
passes · census published · BORROW_001 row landed.

## References

Design §6 (module map/config, :548-582), §7 (data model, :584-720), §8
(constraint gen, :722-831), §9 (+§9.5 solving/reified modes, :833-908),
§13 (census, :1230-1257), §19.2 (A/B discipline, :1560-1569), §19.4
(traps, :1595-1602), §20 (BORROW_001, :1609), §21 (budgets, :1641-1657).
Code anchors: `Monomorphized.elm:203-215, 864-931, 965-1006, 1105-1126,
1493-1550` · `MonoTraverse.elm:180-234` (walker/decider template) ·
`MonoGlobalOptimize.elm:117-152` · `Builder/Generate.elm:733-963` ·
`Compiler/Eco/Config.elm:32-456` · `Builder/Eco/Config.elm:103-389` ·
`MonoSolver/Engine.elm:124-342` (32-slot cap) · `TestPipeline.elm:332` ·
`SourceBuilder.elm:1-40`. Phase 1 modules: `Borrow/Lifetime.elm`,
`Borrow/Dsu.elm`. Stack-safety: `plans/state-monad-stack-safety.md`.
Byte-gate: `plans/stage2-stage7-mlir-diff-runner.md`.
