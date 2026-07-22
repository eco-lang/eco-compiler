# Borrow Inference — Phase 4: LSS Handshake (B3.5, solver-only)

Status: IMPLEMENTATION-READY (v2, deep-dive pass). Parent design:
`design_docs/globalopt/borrow-inference-design.md` (v2) §10; milestone
B3.5. Series: `plans/borrow-inference-phase{0..6}-*.md`.

**Dependencies:** Phase 3 (sigs + fixpoint live: `Borrow/Sig.elm`,
`Borrow.elm` driver, `Borrow/Constrain.elm`, `Borrow/KernelSigs.elm`).
**Feeds:** Phase 5 precision; §22.6 engine-default evidence. **Gates:**
subst leg bit-identical to Phase 3; solver leg census with PoisonCause
split; cross-engine A/B archived.

**Scheduling freedom:** independent of Phase 5's U5.1 — if the Phase-2/3
census shows `poisonedByClosure` is a small share of would-be dups, this
phase can slide after Phase 5a.

**Goal:** where LSS knows a singleton lambda set, route the call boundary
through the member's real signature instead of poisoning — without ever
being unsound on blocked/unresolvable members, and inert on all-LTop
(subst) graphs.

Adding the new `.elm` sources (`Borrow/LssFacts.elm`) requires a
reconfigure — `cmake --preset build` — because `ELM_SOURCES` is a
non-CONFIGURE_DEPENDS glob (the `ninja-clang-lld-linux` name in CLAUDE.md
is stale; the configure preset is `build`).

## Verified facts this plan is built on

1. **Every MonoGraph FULL construction site (grep `MonoGraph {` +
   `Mono.MonoGraph` over `compiler/src`, cross-checked against the type
   def `Monomorphized.elm:813-825`).** The record is a *tagged wrapped
   record* (`type MonoGraph = MonoGraph { … }`). Four sites build a
   **complete** record (must gain a `lssMemberOrigins` field); the rest
   are `{ record | … }` updates (inherit the field for free) or
   destructures (read-only):
   - **Solver assemble** — `MonoSolver/Monomorphize.elm:985-996`
     (`assembleRawGraph`). Populate from `s.lssMemberTable` (U4.1).
   - **Subst assemble** — `Monomorphize/Monomorphize.elm:264-275`
     (`assembleRawGraphFrom`). No engine `S` here → `lssMemberOrigins =
     Dict.empty` (the inert path).
   - **Prune reassemble** — `Monomorphize/Prune.elm:235-248`
     (`pruneUnreachableSpecs`, shared by BOTH engines, runs at mono exit
     after assemble). Full record; destructures `(Mono.MonoGraph
     record)` at `:104`, so add `lssMemberOrigins = record.lssMemberOrigins`
     (preserve).
   - **Inline-simplify reassemble** — `MonoInlineSimplify.elm:894-905`
     (`optimizeNodes`), the pre-GlobalOpt pass. It destructures at `:797`
     WITHOUT capturing the field and rebuilds at `:894` — so the field is
     **dropped here unless threaded**. Add `lssMemberOrigins` to the `:797`
     destructure, to the `optimizeNodes` param list (`:860-868`), to its
     sole invocation at `:850` (`optimizeNodes nodesList ctx main registry
     ctorShapes ports flagsDecoder` → append the new arg), and to the
     `:894` record. This is the one site that could silently lose the
     export between mono exit and Phase 6 — pipeline is
     mono→inline-simplify→GlobalOpt (`Builder/Generate.elm:802,823`).
   - Update-pattern sites that inherit automatically (NO change):
     `MonoGlobalOptimize.elm:1031` (P1), `:1101`, `AbiCloning.elm:564`
     (P4) — all `{ record | nodes = … }`.
2. **No test/fixture builds a full MonoGraph.** Only
   `tests/TestLogic/Generate/CodeGen/CtorLayoutConsistency.elm:48`
   mentions it, as a destructure `(Mono.MonoGraph { ctorShapes })`. No
   test-builder arm to add.
3. **MonoGraph is NEVER serialized.** `.ecot` / `typed-artifacts.dat`
   store the pre-mono `TypedOptimized.GlobalGraph`
   (`TypedOptimized.elm:1517`, `Details.elm:1068`); mono graph is
   per-compile in-memory. No encoder/decoder arm for `lssMemberOrigins`.
4. **The LSS reverse maps and what covers ctors/accessors** (the CRITICAL
   Phase-4 question). `LssMemberTable` (`Engine.elm:128-132`) has THREE
   sub-maps: `byKey : Dict String Int` (key→mid, injective — one fresh
   mid per interned key, `memberIdFor` `:597-615`), `globals : Dict Int
   TOpt.Global`, `kernels : Dict Int (String,String,String)`. Mint-site
   census (`LssInfer.walkExpr :648-678` + `Engine` `:623-661`):
   - `g|` globals (`VarGlobal`, `VarCycle`) → `standaloneMemberIdFor` →
     `insertMemberGlobal` → **`globals`**.
   - `c|` ctors (`VarEnum`, `VarBox`) → `standaloneMemberIdFor ("c|"…)` →
     **also `insertMemberGlobal`** → land in `globals` too, storing a bare
     `Global` **indistinguishable from `g|`** in the reverse map itself.
   - `k|` kernels (`VarKernel`, and kernel-ALIAS `VarGlobal` via
     `kernelAliasOf`, `:649-657`) → `kernelMemberIdFor` → **`kernels`**.
   - `a|` accessors (`Accessor`) → `standaloneMember` → `memberIdFor` only
     → **`byKey` ONLY, no reverse-map entry**.
   - `l|` lambdas (`injectLambdaMember`, `Engine.elm:229`) → `byKey` only
     (resolved via `ClosureInfo.lssMember` instance index, not origins).
   **Decision (resolves the outline's option-(a)-vs-(b) fork): populate
   all four `MemberOrigin` kinds by INVERTING `byKey` and dispatching on
   the 2-char key prefix** (`"g|" "c|" "k|" "a|" "l|"`), joining `globals`
   for `g|`/`c|` payloads and `kernels` for `k|`. The discriminating
   prefix that the `globals` reverse map loses is fully present in
   `byKey`, and the accessor field name is `String.dropLeft 2 key`. This
   needs **zero mint-site changes** and answers ctors/accessors with real
   origins (strictly better than the outline's "ship PUnresolved for
   ctor/accessor" fallback). Option (a) — extending mint sites — is
   therefore unnecessary.
5. **`registry.reverseMapping : Array (Maybe (Global, MonoType))`
   indexed by SpecId** (`Monomorphized.elm:781`), where `Global` is
   **Monomorphized's OWN `Global`** (`:759`, `Global IO.Canonical Name |
   Accessor Name`) — NOT `TOpt.Global`; Monomorphized does not import
   TypedOptimized. The forward `mapping` is `Dict.empty` post-mono
   (assemble sets it so — verified fact 1 sites, `mapping = Dict.empty`).
   A `Global` may specialize to MANY SpecIds → the `Global→SpecId` index
   is one-to-many, so it must be keyed and matched by TYPE. **Decision:**
   build `globalIndex : Dict String (List (MonoType, SpecId))` (key =
   `Mono.toComparableGlobal`, which is what `reverseMapping`'s `Global`s
   key by — the `LssMemberTable.globals` `TOpt.Global` payloads are
   converted to `Mono.Global` at the assemble site, U4.1 step 1) from one
   `Array.foldl`-with-SpecId-counter over `reverseMapping` at Phase-6
   start; at a query, pick the SpecId whose stored `MonoType`
   `Mono.eqLayout`-matches the callee type. No match / ambiguous →
   `PUnresolved`. **CAUTION:** `Mono.toComparableGlobal` (`"G…\0…"`)
   and `TOpt.toComparableGlobal` (`"….name"`) are DIFFERENT string
   formats — both index build and query MUST use `Mono.toComparableGlobal`
   or every `OriginGlobal`/`OriginCtor` silently resolves `PUnresolved`.
6. **CallInfo stamps survive to Phase 6.** `annotateCallStaging` (P5) is
   the last CallInfo writer; `MonoGlobalOptimize.elm:1192-1197` explicitly
   re-copies `closureKind/captureAbi/fastEvaluator/fastPapPrefix` from the
   existing CallInfo onto the re-derived one. Borrow runs as GlobalOpt
   Phase 6 (after `:150 annotateCallStaging` in `globalOptimizeWithStats`,
   `:125-152`), so `callInfo.fastEvaluator : Maybe LambdaId` and
   `callInfo.fastPapPrefix : Maybe Int` (`Monomorphized.elm:1538-1550`)
   are live and trustworthy at the query.
7. **The instance-index keying primitives.** `AbiCloning.instanceMember :
   ClosureInfo -> MonoType -> Maybe (Int, Bool)` (`:488-504`): prefer
   `closureInfo.lssMember` (Fix B), else raw `srcLambda`
   (`Id.toComparable`), else `singletonHeadMember tipe` with the Bool =
   `isAdopted`. `isWrapperHome : LambdaId -> Bool` (`:507-509`) tests the
   `AnonymousLambda home _` home against `Rewriter.wrapperHome`
   (`Staging/Rewriter.elm:50-52`, exposed). The block rule (`collectGo
   :288-291`): a member is BLOCKED iff `isAdopted || isWrapperHome
   closureInfo.lambdaId`; once blocked it stays blocked. Neither
   `instanceMember` nor `isWrapperHome` is exported (AbiCloning exposes
   only `AbiCloningStats, abiCloningPass, emptyStats`). **Decision:
   duplicate both (~18 LoC) into `LssFacts`**, importing only
   `Staging.Rewriter.wrapperHome` for the constant — exporting from
   AbiCloning would widen its API and force a GlobalOpt→AbiCloning import
   the borrow pass otherwise avoids, and the two indexes retain different
   payloads (AbiCloning keeps layout groups; borrow keeps bodies +
   `enclosingSpecId`), so there is nothing structural to share.
8. **`ClosureInfo`** (`:952-960`): `{ lambdaId, srcLambda : Maybe
   SrcLambdaId, lssMember : Maybe Int, captures : List (Name, MonoExpr,
   Bool), params : List (Name, MonoType), closureKind, captureAbi }`.
   `headAnno : MonoType -> LambdaSetAnno` (`:409`) and `singletonHeadMember
   : MonoType -> Maybe Int` (`:538`) are exposed.

### Design discrepancies

- **§10.4/§11.1 "same scan that builds the instance index" is not
  achievable in one pass.** A routed edge's target is the
  `enclosingSpecId` of the callee lambda's instance — knowable only from a
  COMPLETE instance index (a call references its callee by TYPE/`LSet` or
  by `fastEvaluator` LambdaId, never by enclosing SpecId). So U4.2 uses
  **two folds over `nodes`**: scan 1 builds `byMember`/`blocked`; scan 2
  (merged with Phase-3's plain-edge collection) resolves routed edges
  against the finished index. Cost is one extra O(nodes) fold —
  negligible. Same conclusion (routed edges land in the SCC graph),
  correct mechanics.
- **§10.3 "OriginGlobal → BorrowSig of the mapped SpecId" is one-to-many.**
  The reverse map is per-SpecId `(Global, MonoType)`; a Global has many
  SpecIds. Resolved by TYPE-matching the callee type (verified fact 5),
  not a bare `Global→SpecId` function. Recorded so no one implements the
  lossy version.
- **§10.3 PNoSig "never the optimistic initialization" needs the
  intra-SCC carve-out** spelled out in U4.2 step 4: lambda sigs ARE seeded
  optimistically *within* the enclosing SCC (co-scheduled by the routed
  edge); `PNoSig` fires only when `lambdaSigs` has NO entry at all — i.e.
  the enclosing SCC is strictly later in the reverse-topo walk, the exact
  edge-collection-gap signal the census counts.
- **§10.2's `MemberOrigin = OriginGlobal TOpt.Global` collides with
  `reverseMapping`'s `Global` type.** The `LssMemberTable.globals` payload
  is `TOpt.Global` (`Engine.elm:130`), but the `Global→SpecId` translation
  the design calls for (§10.2 "one-shot `Global → SpecId` index from
  `registry.reverseMapping`") reads `reverseMapping`, whose `Global` is
  **Monomorphized's own** `Global` (`:759`, extra `Accessor` case), keyed
  by a DIFFERENT `toComparableGlobal` format. This plan carries
  `Mono.Global` in `OriginGlobal`/`OriginCtor` (converting `TOpt.Global`
  at the assemble site) and keys `globalIndex` by `Mono.toComparableGlobal`
  throughout (U4.1/U4.2), so no `TOpt` import is added to `Monomorphized`
  and the two sides match. The design's `TOpt.Global` phrasing and its
  unqualified "`Global → SpecId` index" gloss over this impedance mismatch
  — returned as an open question for a §10.2 design-prose fix.
- **§10.4's `lambdaSigs : Dict LambdaId BorrowSig` is not a legal Elm
  `Dict`.** `LambdaId = AnonymousLambda IO.Canonical Int`
  (`Monomorphized.elm:747`) is a custom type with no `comparable`
  instance, so it cannot be a `Dict` key. This plan keys by a `String`
  `lambdaKey` (U4.2.a) — `ModuleName.toComparableCanonical home ++ "|" ++
  idx` — which is the only implementable form. Recorded as a §10.4
  design-prose fix (the intent, member→sig by lambda identity, is
  unchanged).

## U4.1 — `MonoGraph.lssMemberOrigins` export

**Edit `Compiler/AST/Monomorphized.elm`.** Add the origin type near the
`MonoGraph` def (`:813`) and the new record field (`:825`, taking the
record from 10 fields to 11 — well under the native 32-slot scan cap):

```elm
type MemberOrigin
    = OriginGlobal Global         -- g| members (Monomorphized's OWN Global)
    | OriginKernel Name Name      -- k| members (home, name); prefix dropped
    | OriginCtor Global           -- c| members (Monomorphized's OWN Global)
    | OriginAccessor Name         -- a| members (field)

-- MonoGraph gains, after `flagsDecoder`:
    , lssMemberOrigins : Dict Int MemberOrigin
```

Expose `MemberOrigin(..)` and the accessor in the module's exposing list
(mirror how `LambdaSetAnno(..)` is exposed at `:3`). **`OriginGlobal`/
`OriginCtor` carry Monomorphized's own `Global` (`:759`), NOT
`TOpt.Global`** — that type is already in scope (it backs
`SpecializationRegistry.reverseMapping`, so the `Global→SpecId` index
matches it directly, verified fact 5) and needs **no new import**.
Monomorphized does NOT import TypedOptimized; the `TOpt.Global` payloads
in `LssMemberTable.globals` are converted to `Mono.Global` in
`buildMemberOrigins` at the assemble site (below), which already imports
`TOpt`. (`Name`/`Dict` are also already in scope.)

**Edit the four full-construction sites (verified fact 1):**

1. `MonoSolver/Monomorphize.elm:985` — add
   `lssMemberOrigins = buildMemberOrigins s.lssMemberTable`. Define
   `buildMemberOrigins : Engine.LssMemberTable -> Dict Int MemberOrigin`
   locally (or in a tiny helper module `MonoSolver/MemberOrigins.elm` — a
   new source, reconfigure). Body: `CoreDict.foldl` over `table.byKey`
   producing `(mid, origin)` pairs, dispatching on `String.left 2 key`:
   - `"g|"` → `Maybe.map (toptToMono >> OriginGlobal) (CoreDict.get mid table.globals)`
   - `"c|"` → `Maybe.map (toptToMono >> OriginCtor) (CoreDict.get mid table.globals)`
     where `toptToMono (TOpt.Global h n) = Mono.Global h n` (`table.globals`
     holds `TOpt.Global`; the origin carries Monomorphized's own `Global`).
     This conversion lives here (assemble site imports `TOpt`), so
     `Monomorphized.elm` needs no `TOpt` import.
   - `"k|"` → `CoreDict.get mid table.kernels` →
     `Just (_,home,name)` → `OriginKernel home name`
   - `"a|"` → `Just (OriginAccessor (String.dropLeft 2 key))`
   - `"l|"` (and any other) → skip (lambda; resolved via instance index)
   Drop `Nothing`s (a `g|`/`c|`/`k|` with no reverse entry cannot occur —
   the mint always inserts — but code defensively). Result Dict keys are
   `mid`s; byKey is injective so no collisions.
2. `Monomorphize/Monomorphize.elm:264` — `lssMemberOrigins = Dict.empty`.
3. `Monomorphize/Prune.elm:235` — `lssMemberOrigins = record.lssMemberOrigins`.
4. `MonoInlineSimplify.elm:797/850/860/894` — thread it: add to the `:797`
   destructure, to `optimizeNodes`'s signature+params (`:860-869`), to the
   sole `optimizeNodes` call at `:850` (pass the new arg), and
   `lssMemberOrigins = lssMemberOrigins` at `:894`.

No serialization arms (verified fact 3). No test-builder arms (fact 2).

## U4.2 — `Borrow/LssFacts.elm` (~230 LoC) + driver/Constrain integration

**Create `compiler/src/Compiler/GlobalOpt/Borrow/LssFacts.elm`**
(reconfigure). Imports: `Compiler.AST.Monomorphized as Mono`,
`Compiler.GlobalOpt.Borrow.Sig` (Phase 3),
`Compiler.GlobalOpt.Borrow.KernelSigs` (Phase 3),
`Compiler.GlobalOpt.Staging.Rewriter (wrapperHome)`,
`Compiler.Elm.ModuleName as ModuleName` (`lambdaKey`'s
`toComparableCanonical`), `Compiler.Data.Id as Id` (the duplicated
`instanceMember`'s `Id.toComparable`), `Array`, `Dict`, `Set`. (No
`TOpt` import needed — origins carry `Mono.Global` and `globalIndex`
keys by `Mono.toComparableGlobal`, both via `Mono`.)

### U4.2.a — Types and the two indexes

```elm
type alias LambdaRef =
    { lambdaId : Mono.LambdaId
    , enclosingSpecId : Mono.SpecId
    , closureInfo : Mono.ClosureInfo
    , body : Mono.MonoExpr
    }

type alias LambdaInstances =
    { byMember : Dict Int (List LambdaRef)
    , blocked : Set Int
    }

type alias Facts =
    { instances : LambdaInstances
    , origins : Dict Int Mono.MemberOrigin
    , globalIndex : Dict String (List ( Mono.MonoType, Mono.SpecId ))
    , lambdaSigs : Dict String Sig.BorrowSig   -- key = lambdaKey (below)
    , sigs : Mono.SpecId -> Maybe Sig.BorrowSig  -- Phase-3 SigTable reader
    }
```

`lambdaKey : Mono.LambdaId -> String` — `LambdaId = AnonymousLambda
IO.Canonical Int` (`Monomorphized.elm:747`) has no comparable helper of
its own and `lambdaIdToString` lives in the codegen module
(`Generate/MLIR/Expr.elm:1148`, do not import into an analysis pass), so
define locally: `\(Mono.AnonymousLambda home idx) ->
ModuleName.toComparableCanonical home ++ "|" ++ String.fromInt idx`.

- **Instance index (scan 1).** `Array.foldl` over `nodes` with the SpecId
  index; per node run `collectGo`-style folds over the node's exprs
  (copy the traversal shape from `AbiCloning.collectGo :281-393`, but
  the accumulator carries `enclosingSpecId` = the current node's SpecId
  and appends `LambdaRef`s). At each `MonoClosure closureInfo body tipe`:
  key via the DUPLICATED `instanceMember closureInfo tipe` (fact 7); on
  `Just (m, isAdopted)`: if `isAdopted || isWrapperHome
  closureInfo.lambdaId` → `Set.insert m` into `blocked` (drop any refs);
  else, when `m ∉ blocked`, prepend `{ lambdaId, enclosingSpecId,
  closureInfo, body }` to `byMember[m]`. Mirror `collectGo`'s block-wins
  precedence exactly.
- **Global index.** `buildGlobalIndex : Mono.SpecializationRegistry ->
  Dict String (List (MonoType, SpecId))` = `Array.foldl`-with-SpecId-
  counter over `registry.reverseMapping` (index = SpecId; `Array.foldl`
  gives no index, so thread a `specId` counter as the assemble sites do),
  inserting `(Mono.toComparableGlobal g, (tipe, specId))` for each
  `Just (g, tipe)`. `g` here is `Mono.Global` (reverseMapping's type,
  verified fact 5) — key by `Mono.toComparableGlobal`, matching the
  `OriginGlobal`/`OriginCtor` query keys below.
- **Origins/lambdaSigs/sigs** come from the graph and Phase-3 driver
  state (below).

### U4.2.b — Query and decline ladder (design §10.3)

```elm
type CalleeFacts
    = Routed Sig.BorrowSig
    | Poison PoisonCause

type PoisonCause = PTop | PBlocked | PUnresolved | PNoSig | PMixedMeet

query : Facts -> Mono.CallInfo -> Mono.MonoType -> ( CalleeFacts, Census )
```

`Census` is a small record of the five PoisonCause counters plus
`lambdaSigNoSigReads` and `meetDegraded` (Phase 2's declared field name
for meet-degraded sites — U2's census table; NOT `mixedMeetSites`),
folded back by Constrain.
Resolution order:

1. **Stamp shortcut.** `case callInfo.fastEvaluator of Just lambdaId ->`
   look up `Dict.get (lambdaKey lambdaId) lambdaSigs`:
   - `Nothing` → `Poison PNoSig` (+`lambdaSigNoSigReads`).
   - `Just sig` and `callInfo.fastPapPrefix = Nothing` → `Routed sig`.
   - `Just sig` and `fastPapPrefix = Just k` → `Routed (papSuffix k sig)`
     where **`papSuffix`** drops the k captured-prefix positions:
     `params = List.drop k sig.params`, `result = sig.result`, and
     `resultLts` REMAPPED — for each `(pos, s)` keep only param indices
     that are supplied at this site and renumber them:
     `(pos, Set.map (\i -> i - k) (Set.filter (\i -> i >= k) s))`.
     Indices `< k` referenced the PAP-captured prefix (already forced
     owned through the capture channel, §8.4) and couple to no caller arg
     here, so they drop out. (This is the concrete form of §10.3's
     "zip the supplied args against the sig's param suffix after k".)
2. **Set resolution.** `case Mono.headAnno calleeType of`:
   - `Mono.LTop -> Poison PTop`.
   - `Mono.LSet [m]` → `resolveMember facts calleeType m` (below).
   - `Mono.LSet ms` (|ms|>1) → resolve each; if any `Poison c` →
     propagate the first cause; else `meet` the routed sigs (step 3).
3. **`meet` (call-site-only, BORROW_006 — never written back).**
   - Params: **any-owned wins** — pointwise over `sig.params`, a position
     is `Owned` if any member's is `Owned`, else `Borrowed`.
   - Result: **any-borrowed wins** — Borrowed if any member's result is;
     `resultLts` = pointwise UNION of the members' `LParams` sets.
   - Any site reached through `meet` bumps `PMixedMeet`/`meetDegraded`
     (census detail only; still `Routed`).

**`resolveMember facts calleeType m`:**

- **Lambda member** (`Dict.member m facts.instances.byMember` or `m ∈
  blocked`): `m ∈ blocked` → `Poison PBlocked`. Else meet the refs'
  lambda sigs: for each `ref`, `Dict.get (lambdaKey ref.lambdaId)
  lambdaSigs` — any `Nothing` → `Poison PNoSig`. `validate`
  (dev-only assert) checks the refs' sigs are `Sig.sigEq`-equal
  (LSS_009/017 make verbatim instances interchangeable; a mismatch is a
  soundness probe, not fatal — meet still applies).
- **Standalone member** (`Dict.get m facts.origins`):
  - `Just (OriginKernel home name)` → `kernelToSig (KernelSigs.lookup
    (home,name)) calleeType` (adapter below) → `Routed`.
  - `Just (OriginCtor g)` → `Routed (constructSig calleeType)`
    (all params `Owned`, result owned-fresh, `resultLts = []`).
  - `Just (OriginGlobal g)` → look up `globalIndex[Mono.toComparableGlobal g]`
    (`g : Mono.Global`; same key function buildGlobalIndex used),
    find the entry whose MonoType `Mono.eqLayout`-matches `calleeType`;
    `Just specId` → `facts.sigs specId` (`Nothing` → `Poison PNoSig`),
    else no/ambiguous match → `Poison PUnresolved`.
  - `Just (OriginAccessor _)` → `Routed (accessorSig calleeType)`
    (`params = [Borrowed]`, result Borrowed with `resultLts =
    [(resultPos0, Set.singleton 0)]` — result couples to param 0).
  - `Nothing` → `Poison PUnresolved`.

Adapters, all producing call-site-only `Sig.BorrowSig` from the peeled
`calleeType` (`Sig.SigTy.shape` = the peeled MonoType; modes per rule):

```elm
kernelToSig  : KernelSigs.KernelSig -> Mono.MonoType -> Sig.BorrowSig
constructSig : Mono.MonoType -> Sig.BorrowSig
accessorSig  : Mono.MonoType -> Sig.BorrowSig
```

`kernelToSig`: param modes map `PBorrowed→Borrowed`, `POwned→Owned`;
result Borrowed; `resultAliases = Just i` → `resultLts =
[(resultPos0, Set.singleton i)]`, else `[]`. Reuse `Sig.allOwnedSig`/
`optimisticSig` as scaffolds where the mode pattern matches.

### U4.2.c — Driver + Constrain integration

- **`Borrow.elm` (Phase-3 driver upgrade).** At `Borrow.run` start, after
  edge collection, build `Facts` once: `instances` (scan 1),
  `globalIndex` (from `registry`), `origins` (destructure
  `MonoGraph.lssMemberOrigins`). Thread `Facts` into the per-def `Ctx`
  (add a field). **`lambdaSigs`** is mutable fixpoint state living beside
  the Phase-3 `SigTable`: seed member-lambda entries optimistically at
  each SCC's init (alongside member def sigs, U3.1.d step 1) and write
  back the read-back lambda sigs each iteration; on SCC convergence the
  entries are final. A `lambdaSigs` read for a lambda whose enclosing SCC
  is strictly later in the reverse-topo walk finds `Nothing` → `PNoSig`
  (the gap signal). Within the enclosing SCC the optimistic seed is
  present, so co-scheduled routed callers never spuriously `PNoSig`
  (see Design discrepancies).
- **Routed edges (scan 2, ordering fix).** Merge with Phase-3's
  plain-edge fold (U3.1.b `collectEdges`): at each `MonoCall … callInfo`,
  run a lightweight `routedTarget : Facts -> CallInfo -> MonoType ->
  Maybe SpecId` — resolve exactly as `query`'s stamp/singleton arms would
  but return only the callee's `enclosingSpecId` (for a lambda member,
  `ref.enclosingSpecId`; multi-member sites contribute an edge PER
  resolvable member). Add edge `callerSpecId → target` to the adjacency
  the SCC builder consumes (U3.1.c). This co-schedules routed callers
  with the defs that solve their callees' lambda sigs.
- **Constrain integration (`Borrow/Constrain.elm`).** In the §8.3
  generic/closure branch of the `MonoCall` arm (the "everything else"
  bucket Phase 3 left all-owned poison), call `query facts callInfo
  (Mono.typeOf callee)` FIRST:
  - `Routed sig` → apply the exact Phase-3 direct-call machinery
    (U3.1.e): zip `args` against `sig.params`, per ResPos Owned→owned
    flows / Borrowed→liveness-only seeds, result `freshRTy` +
    `resultLts` coupling flows. For a `fastPapPrefix = Just k` sig the
    args already zip 1:1 against the k-dropped `sig.params`.
  - `Poison cause` → unchanged Phase-2 all-owned behavior; bump
    `cause`'s census bucket.

## U4.3 — Cross-engine A/B gate

- **Subst leg (hard inert gate).** Full corpus + self-compile under the
  DEFAULT engine — bit-identical MLIR to Phase 3. Under subst,
  `lssMemberOrigins = Dict.empty` and `LambdaInstances.byMember` is empty
  (subst emits all-`LTop` arrows — `headAnno` never `LSet`), so every
  `query` returns `Poison PTop`/`PUnresolved` and the boundary is exactly
  Phase 3's. This is a gate, not an assumption:
  `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`
  (run ONCE; grep the file) + the byte-identity flag-on-vs-off check with
  the harness env-blindness workaround (touch all test `.elm` before the
  flag-on leg). Front-end: `cmake --build build --target elm-tests`
  (serial with E2E — typed-artifacts cache race).
- **Solver leg.** All-keyed solver self-compile, minted via the **NATIVE
  binary** (cmake Stage-5 node is 4 GB-pinned and OOMs — house lesson).
  Invoke the solver engine per the house switch (`ECO_MONO_LSS` /
  eco-config `mono.engine`; all-keyed is the shipped default per MEMORY).
  Publish the PoisonCause census split
  (`PTop/PBlocked/PUnresolved/PNoSig/PMixedMeet`), `lambdaSigNoSigReads`
  (≈0 steady-state), and the coverage delta vs Phase 3
  (`poisonedByClosure` recovered share; design predicts a strict superset
  of Run M's 13.2% fast-routed *events*).
- Archive both censuses in this plan's as-built section as the §22.6
  engine-default evidence.

## Gates summary

Subst bit-identity vs Phase 3 (hard inert gate) · solver E2E green ·
PoisonCause census published · `lambdaSigNoSigReads ≈ 0` steady-state ·
`sccFixpointBailouts = 0` (Phase-3 counter, re-checked with routed edges
added) · wall budget ≤3% on both engines (record majors per the
major-GC-lottery lesson).

## References

Design §3.3 (engine reality), §10 (this phase implements it), §11.1
(routed edges), §20 BORROW_006, §22.6. Code anchors:
`MonoSolver/Monomorphize.elm:985` (solver assemble) ·
`Monomorphize/Monomorphize.elm:264` (subst assemble) ·
`Monomorphize/Prune.elm:235` · `MonoInlineSimplify.elm:797,894` ·
`Engine.elm:128-132,597-661` (LssMemberTable + mints) ·
`LssInfer.elm:648-678,915-931` (mint sites) ·
`AbiCloning.elm:235-247,281-393,488-509` (index template, keying) ·
`Staging/Rewriter.elm:50` (wrapperHome) ·
`Monomorphized.elm:409,538,781,813-825,952-960,1538-1550` (headAnno,
singletonHeadMember, reverseMapping, MonoGraph/ClosureInfo/CallInfo) ·
`MonoGlobalOptimize.elm:125-152,1192-1197` (phase order, stamp
preservation).
