# Lambda Set Specialization (LSS) in Eco — Detailed Design

*Status: DETAILED DESIGN v1 (2026-07-10). Supersedes the v0 outline (same
file, same date). v1.1 (2026-07-11, after the M1+M2 implementation gate):
added §9.3 (pass ordering — AbiCloning after Staging, the wrapper identity
rule, LSS_008) and §9.4 (staging retirement outlook).
Code references verified against the tree as of MonoSolver
runtime parity (plan rev 11, 2026-07-09): `Compiler/MonoSolver/*`,
`Compiler/Type/{Unify,Occurs,Type,Solve}.elm`, `System/TypeCheck/IO.elm`,
`Compiler/AST/{Monomorphized,TypedOptimized,TypeIds}.elm`,
`Compiler/Monomorphize/{AssignMVarIds,Prune}.elm`,
`Compiler/GlobalOpt/*`, `Compiler/Eco/Config.elm`, `Builder/Generate.elm`.*

*Basis: Brandon, Driscoll, Dai, Berkow, Milano — "Better Defunctionalization
through Lambda Set Specialization" (PLDI 2023),
`design_docs/auto-borrow-inference/lambda-set-specialization.pdf`.
Engine-choice justification: `lss-foundation-report.md`.*

---

## 0. Decision summary — what changed from the v0 outline

The single largest revision, made after checking what Eco's consumers
actually need:

> **v1 lambda-set members are identity-only (`Int` member ids), not typed
> lambdas.** The paper's set elements carry capture types, which is what
> forces μ-recursive sets, cycle-folding zonk, and μ-aware key substitution.
> Eco's v1 consumers (dispatch upgrades, specialization keys, borrow-inference
> seeding) need *which code objects can inhabit this arrow*, not their nested
> annotations. With id-only members, a lambda set is a **finite subset of a
> per-run member universe**: merge is pure set union (total, never fails),
> sets contain no store variables, μ cannot arise, and termination of
> set-keyed specialization is trivial (a finite join-semilattice). Typed
> members become a vNext extension behind the same data type.

Resolved decisions (details in the cited sections):

| Question (v0) | Decision (v1) | Where |
|---|---|---|
| OQ1 arrow embedding | New `FunL arg res setSlot` FlatType constructor, minted only by mono stores; `Fun1` retained for the typechecker and for lss-off mode | §4.1 |
| OQ2 internalization placement | By omission: signatures carry only annotation-arrow facts; body-internal sets ground per item | §7.1 |
| OQ3 member capture shapes | Id-only members (the big revision above); capture info recovered by consumers from materialized instances | §0, §9 |
| OQ4 PAPs / ctors / accessors as members | Interned member ids per (kind, global); PAP results keep the callee's member (sets track *value provenance*, not application depth) | §3.3 |
| OQ5 cross-build caching | Out of scope (unchanged) | §14 |
| OQ6 inliner interaction | `ClosureInfo.srcLambda` copied verbatim on inline (instances may share a source id — that is the semantics); test batch at M2 | §8.3, §11 |
| OQ7 μ-folding placement | Dissolved — no μ with id-only members | §0 |
| Syntactic-lambda identity | A new `Maybe SrcLambdaId` field **on the `TOpt.Function`/`TrackedFunction` constructors**, in-memory only (codec ignores it), stamped by `AssignMVarIds` | §3.2 |
| Where ⊤ lives in the store | An absorbing `top` flag on the set content (`LambdaSet1 True _`), not a separate content kind | §4.1 |

One correction of the v0 outline discovered during code verification:
GlobalOpt's `AbiCloning.abiCloningPass` is **a no-op stub** ("the
collection/cloning phases are not yet implemented") and **nothing in the
compiler produces `Mono.Known` closure kinds today** — the only pattern match
on `Mono.Known` is the consumer in `Generate/MLIR/Expr.elm:1090`. The typed
closure-calling tier (`ClosureKindId`, `captureAbi`, `_dispatch_mode=fast` in
`runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`) is real but has no
analysis feeding it. LSS is therefore not "upgrading an existing analysis" at
M3 — it is the **first producer** for that tier (§9).

---

## 1. Objective and scope

Unchanged from v0 (see `lss-foundation-report.md` §1–2 for the argument):
track, per arrow type, the set of function values that can inhabit it;
specialize higher-order definitions per concrete set; consume the facts as
(1) direct-call upgrades where sets are singletons, (2) small-set dispatch
lowering, (3) precision seed for auto-borrow inference. Everything below `⊤`
is an optimization; `⊤` is today's pipeline.

v1 explicitly does **not** deliver: typed set members, the tagged
capture-union value representation (M5, own design doc when reached),
specializing into C++ kernels, cross-build signature caching.

---

## 2. Pipeline position, switches, and config plumbing

LSS lives entirely inside the MonoSolver engine. The legacy engine never
computes sets (it only gains mechanical `LTop` stamps from the `MonoType`
change, §5.2). `EngineDiff` remains a subst-parity tool and always runs with
LSS off (§5.4).

### 2.1 Config surface

`Compiler/Eco/Config.elm` — extend `MonoConfig` (currently
`{ engine, diffDump }`, `Config.elm:61`):

```elm
type alias MonoConfig =
    { engine : MonoEngine
    , diffDump : Bool
    , lss : LssConfig
    }


{-| Lambda-set specialization knobs (§10). `enabled = False` must reproduce
today's pipeline byte-for-byte (every arrow annotation is `LTop`, no set
slots are minted in stores).
-}
type alias LssConfig =
    { enabled : Bool           -- master switch (M2+)
    , keyed : Bool             -- sets participate in SpecKeys (M4+)
    , maxSetSize : Int         -- |set| > K at zonk ⇒ widen to LTop
    , maxSpecsPerGlobal : Int  -- registry budget; exceeded ⇒ widen new keys
    , report : Bool            -- render an LSS census after mono
    }


defaultLss : LssConfig
defaultLss =
    { enabled = False
    , keyed = False
    , maxSetSize = 8
    , maxSpecsPerGlobal = 64
    , report = False
    }
```

JSON decoding follows the existing `monoDecoder` pattern (`Config.elm:154`,
optional fields over defaults); the config-hash discipline is the existing
one — emit a hash token **only for non-default values** so default builds
keep byte-identical cache hashes. Env overrides go beside `ECO_MONO_ENGINE`
in `Builder/Eco/Config.elm:78–118` (`applyEnvOverrides`):
`ECO_MONO_LSS=0|1|keyed`, `ECO_MONO_LSS_REPORT=1`.

### 2.2 Engine entry plumbing

`Builder/Generate.elm selectMonomorphizer` currently calls
`MonoSolver.monomorphize "main" globalTypeEnv typedGraph` — the engine never
sees `EcoConfig`. The entry signature changes:

```elm
-- Builder/Generate.elm (selectMonomorphizer)
Config.EngineSolver ->
    MonoSolver.monomorphize ecoConfig.mono "main" globalTypeEnv typedGraph
        |> Result.map emitLssReport      -- stderr side-channel, §8.6
```

`MonoSolver.Monomorphize.monomorphize` gains the `Config.MonoConfig`
parameter and threads `mono.lss` into `Engine.Env` (§8.1). The report (a
pre-rendered `Maybe String`) rides the result à la the existing
`monomorphizeWithJunk` variant, because `monomorphize` is pure
(`Result String Mono.MonoGraph`) and `compiler/src` cannot use
`Debug.toString` (eco-boot compiles it with `--optimize`).

---

## 3. Identity: the member universe

A **member id** is a dense per-run `Int` naming one function-valued code
object. The universe has two producers:

### 3.1 The id type

`Compiler/AST/TypeIds.elm`, following the existing phantom-`Id` pattern
(`MVarPh`/`MVarId`):

```elm
type LamPh
    = LamPh


{-| Per-run identity of a source-level function value: a syntactic lambda
(stamped in Phase-0, §3.2) or an interned non-lambda function value (§3.3).
Dense from 0; the two producers share one supply.
-}
type alias SrcLambdaId =
    Id LamPh
```

### 3.2 Syntactic lambdas: a tag on the `TOpt.Function` constructors

**Requirement.** The same syntactic lambda must map to the same member id in
every context that sees it: the owning def's signature inference (§7), every
specialization of the owning def, and every *re-translation* of a
sub-expression. The last one kills any walk-ordinal scheme: the engine
re-walks subtrees in fresh stores routinely (`Translate.retranslateAt`,
`Translate.elm:2739`, used by `buildFloatDefs`/`buildLocalDefs` for
number-multi and local-multi instances), so a counter threaded through the
walk would mint different ordinals per instance. The id must live **in the
tree**.

**Rejected alternative** — a field on `TOpt.Meta`: `Meta` has 101
construction sites across nine files (`grep "tvar = "`), and the field would
be dead weight on every non-lambda node. The `Function` constructors have ~46
construction/match sites total, concentrated where the change is meaningful.

**Change.** `Compiler/AST/TypedOptimized.elm:160–161`:

```elm
-- before
    | Function (List ( Name, Can.Type id )) (Expr id) (Meta id)
    | TrackedFunction (List ( A.Located Name, Can.Type id )) (Expr id) (Meta id)

-- after
    | Function (Maybe TypeIds.SrcLambdaId) (List ( Name, Can.Type id )) (Expr id) (Meta id)
    | TrackedFunction (Maybe TypeIds.SrcLambdaId) (List ( A.Located Name, Can.Type id )) (Expr id) (Meta id)
```

The field is **not persisted** — exactly the established `Meta.tvar`
precedent ("populated in-memory, dropped by the codec",
`TypedOptimized.elm:130–134`). The codec change is one-line-per-tag; encoder
untouched, decoder fills `Nothing`:

```elm
-- TypedOptimized.elm, exprDecoderS, tags 14/15
14 ->
    Bytes.Decode.map3 (Function Nothing)
        (BD.list (typedNameDecoderS st))
        (exprDecoderS st)
        (metaDecoderS st)
```

No `.ecot` version bump: the wire format is unchanged.

Producers (`Compiler/LocalOpt/Typed/{NormalizeLambdaBoundaries,Port,Module,
Expression}.elm`, `Compiler/TypedCanonical/Build.elm`, plus the legacy
engine's reconstructions in `Compiler/Monomorphize/Specialize.elm`) construct
with `Nothing` — a mechanical sweep guided by the compiler's exhaustiveness
errors.

**Assignment** happens in Phase-0, in `AssignMVarIds.rewriteExpr`'s existing
`Function`/`TrackedFunction` arms (`AssignMVarIds.elm:546–570`), which
already rebuild every node while re-typing the tree `Name → MVarId`:

```elm
-- AssignMVarIds.elm, rewriteExpr
TOpt.Function _ args body meta ->
    let
        ( lamId, ctx1 ) =
            freshLamId ctx    -- Ctx gains a nextLam supply + a label row

        ( newMeta, ctx2 ) =
            rewriteMeta ctx1 meta

        ( newArgs, ctx3 ) =
            rewriteTypedArgs ctx2 args

        ( newBody, ctx4 ) =
            rewriteExpr ctx3 body
    in
    ( TOpt.Function (Just lamId) newArgs newBody newMeta, ctx4 )
```

`GlobalMVarState` (`AssignMVarIds.elm:29`, currently `superVars` + `nextId`)
gains:

```elm
    , nextLam : TypeIds.SrcLambdaId          -- seeds the engine's interning supply (§3.3)
    , lamLabels : CoreDict.Dict Int String   -- member id -> "home.defName#k" (reports only)
```

`freshLamId` labels each id with the enclosing global (available in
`rewriteNodes`' per-node context) so the M2 census (§8.6) is human-readable.
Because `AssignMVarIds` runs on the **merged whole-program graph** and its
walk is deterministic, ids are per-run stable — the same stability class as
`MVarId`s themselves, which is exactly what the engine requires and no more.

### 3.3 Non-lambda function values: interned members

`List.map Just xs`, `List.map String.fromInt xs`, a global function passed
as an argument — these put non-lambda function values into arrow positions
constantly; widening them to ⊤ would gut precision. They are globals with
stable names, so they intern on demand in the engine (no tree tag needed):

```elm
-- Compiler/MonoSolver/Engine.elm
{-| Member id for a non-lambda function value, interned by kind+identity.
Keys: "g|home|name" (global function ref), "c|home|name" (ctor used as fn),
"k|home|name" (kernel ref), "a|field" (accessor value). Ids come from the
same supply as Phase-0 lambda ids (S.nextMemberId is seeded from
GlobalMVarState.nextLam).
-}
memberIdFor : String -> Step Int
memberIdFor key s =
    case CoreDict.get key s.lssMembers of
        Just mid ->
            Ok ( mid, s )

        Nothing ->
            let
                mid =
                    s.nextMemberId
            in
            Ok ( mid
               , { s
                   | lssMembers = CoreDict.insert key mid s.lssMembers
                   , nextMemberId = mid + 1
                 }
               )
```

Policy decisions bundled here:

- **A top-level function referenced as a value** contributes its own member
  (`"g|…"`). Its *body's* lambda flows are behind its signature (§7), not
  inlined into the member — provenance, not transparency.
- **PAP results keep the underlying callee's member.** `f = add 1` flows
  `add`'s member; arity/stage information is already in the type
  (GOPT_016 nested `MFunction`). Dispatch consumers see "this closure's code
  is `add`'s evaluator chain", which is what `eco_pap_extend` semantics need.
- **Local tail defs escaping as values** (rare; they exist to be
  tail-called) widen to ⊤ in v1.

---

## 4. Store representation

### 4.1 Two new `FlatType` constructors

`System/TypeCheck/IO.elm:639–645`:

```elm
type FlatType
    = App1 Canonical String (List Variable)
    | Fun1 Variable Variable
    | FunL Variable Variable Variable
      -- ^ arg, result, lambda-set slot. Minted ONLY by MonoSolver stores
      --   with lss.enabled; the typechecking phase never constructs it.
    | EmptyRecord1
    | Record1 (CoreDict.Dict String Variable) Variable
    | Unit1
    | Tuple1 Variable Variable (List Variable)
    | LambdaSet1 Bool (CoreDict.Dict Int ())
      -- ^ top-flag, member ids. The ONLY legal content of a FunL set slot
      --   besides FlexVar. Contains no Variables: sets are ground data.
```

Content discipline (add to the module doc, becomes invariant LSS_007):
a `FunL` set slot's content is `FlexVar` (no information yet) or
`Structure (LambdaSet1 …)`; `LambdaSet1` never appears anywhere else.
`⊤` is `LambdaSet1 True _` — an absorbing element under union.

`Fun1` is **retained**, with defined meaning "arrow with no set slot": the
typechecker's stores, and mono stores with `lss.enabled = False`, mint only
`Fun1`. This keeps the lss-off fast path allocation-identical to today
(no dead Point per arrow) and makes M1 byte-identical by construction.

### 4.2 `Unify` changes

Three new arms in `unifyStructure`'s structure×structure matrix
(`Unify.elm:718–774`), directly after the existing `Fun1` arm:

```elm
( IO.FunL arg1 res1 set1, IO.FunL arg2 res2 set2 ) ->
    subUnify arg1 arg2
        |> andThen (\_ -> subUnify res1 res2)
        |> andThen (\_ -> subUnify set1 set2)
        |> andThen (\_ -> merge ctx otherContent)

-- Mixed arrows: unify the type structure, keep the slotted side.
-- Legal only transiently (a demand encoded before lss gating, §6.3);
-- semantically Fun1 ≡ FunL with an unconstrained slot.
( IO.Fun1 arg1 res1, IO.FunL arg2 res2 _ ) ->
    subUnify arg1 arg2
        |> andThen (\_ -> subUnify res1 res2)
        |> andThen (\_ -> merge ctx otherContent)

( IO.FunL arg1 res1 _, IO.Fun1 arg2 res2 ) ->
    subUnify arg1 arg2
        |> andThen (\_ -> subUnify res1 res2)
        |> andThen (\_ -> merge ctx content)

( IO.LambdaSet1 top1 members1, IO.LambdaSet1 top2 members2 ) ->
    -- Join-semilattice union. TOTAL: set unification never mismatches.
    merge ctx (IO.Structure (IO.LambdaSet1 (top1 || top2) (CoreDict.union members1 members2)))
```

This is the whole unifier extension. Note what is *absent* relative to
`unifyRecord` (`Unify.elm:785–847`): no shared-field sub-unification (members
carry no variables), no extension-variable plumbing (growth happens by
merging, not through an ext row), no mismatch path. The foundation report's
row analogy holds for the merge *shape* only; id-only members collapse it to
`Dict.union`.

`unifyFlexSuperStructure` (`Unify.elm:565`) needs **no change** — its
existing `_ -> mismatch` catch-all correctly rejects `number/comparable ~
FunL/LambdaSet1`. `unifyFlex`/`unifyRigid`/alias arms dispatch on `Content`,
not `FlatType`, and are untouched.

### 4.3 Other exhaustive `FlatType` matches

Verified by grep; every site and its new arm:

| Site | Arm |
|---|---|
| `Occurs.elm:71–86` (one match) | `FunL a b s` → recurse `[a, b, s]` like `Fun1`+1; `LambdaSet1 _ _` → no children, `False` |
| `Type.elm:534 termToCanType` | `FunL a b _` → `Can.TLambda` of a/b (erasure — canonical types never see sets); `LambdaSet1 _ _` → `crash "LambdaSet1 outside an arrow slot"` |
| `Type.elm:712` (error-type term walk) | same shape as above (render `FunL` as the arrow) |
| `Solve.elm:1181 traverseFlatType` | `FunL` → `IO.pure IO.FunL |> apply (f a) |> apply (f b) |> apply (f s)`; `LambdaSet1 top ms` → `IO.pure (LambdaSet1 top ms)` |
| `Solve.elm:699/1148` (rank adjust / occurs sweeps) | structural recursion arms, same pattern as `Fun1` plus the slot |
| `SolverRoots.elm:157` | no change — it matches `Just (IO.Fun1 …)` with a fallthrough, and typecheck-phase stores never contain `FunL` |
| `MonoSolver/Store.elm` zonk (§6.1) | real arms — the interesting consumer |

All typechecker-side arms are *structural pass-throughs*, not crashes, except
`termToCanType`'s `LambdaSet1` (which is unreachable from any store that
contains well-formed content, per LSS_007). Cost of this shared-file touch:
seven files, all arms forced by the compiler's exhaustiveness check — the
kind of change that cannot silently rot.

### 4.4 `Store.loadType`: minting slots, capturing arrow order

`Store.loadTypeC` (`Store.elm:92–176`) is the single function that converts
`Can.Type MVarId` into store structure — for demands, schemes, kernel types,
and signature inference alike. Its `TLambda` arm changes; `LoadCtx`
(`Store.elm:58`) gains the lss flag and an arrow-slot accumulator:

```elm
type alias LoadCtx =
    { store : IO.State
    , memo : Dict.Dict Int IO.Variable
    , revMemo : Array (Maybe TypeIds.MVarId)
    , lssOn : Bool
    , arrowSlots : List IO.Variable   -- set slots in minting order (reversed)
    }


-- loadTypeC, TLambda arm
Can.TLambda from to ->
    let
        ( pFrom, c1 ) =
            loadTypeC superStatic from c0

        ( pTo, c2 ) =
            loadTypeC superStatic to c1
    in
    if c2.lssOn then
        let
            ( pSet, c3 ) =
                freshVarC (IO.FlexVar Nothing) c2
        in
        structC (IO.FunL pFrom pTo pSet)
            { c3 | arrowSlots = pSet :: c3.arrowSlots }

    else
        structC (IO.Fun1 pFrom pTo) c2
```

Two derived API points:

- `loadTypeIsolatedWithArrows : Can.Type MVarId -> Step ( IO.Variable, Array IO.Variable )`
  — the existing isolated-memo instantiation (`Store.elm:82`) additionally
  returning the minted slots in order (`List.reverse c.arrowSlots` →
  `Array`). This is how signature facts pair with a fresh instantiation
  (§7.1, §8.4) — **arrow ordinal ≡ position in this array**, defined once, by
  this one function (invariant LSS_006). No parallel skeleton type, no
  re-walk.
- `classifyDirect` (`Store.elm:834`) — the storeless fast classification —
  stamps `LTop` on arrows it builds structurally. That is sound-but-imprecise,
  which is why the call fast paths gate on signature triviality (§8.4).

### 4.5 Cost

With `lss.enabled`: one extra Point per arrow occurrence at load, one
`Dict Int ()` per constrained set. With it off: zero delta (the `Fun1` path
is unchanged, and no set slot is ever allocated). The M2 gate includes the
self-compile wall-time comparison flag-on vs flag-off (§11).

---

## 5. `MonoType`, keys, and gates

### 5.1 The annotation

`Compiler/AST/Monomorphized.elm:202–214` — `MFunction` gains an annotation,
in first position (so ignoring sites read `MFunction _ args ret`):

```elm
type MonoType
    = MInt
    | MFloat
    | MBool
    | MChar
    | MString
    | MUnit
    | MList MonoType
    | MTuple (List MonoType)
    | MRecord (Dict Name MonoType)
    | MCustom IO.Canonical Name (List MonoType)
    | MFunction LambdaSetAnno (List MonoType) MonoType
    | MVar MVarId Constraint


{-| The lambda-set fact on an arrow. `LTop` = statically unknown or
deliberately widened — exactly today's world; the whole existing pipeline
(boxed closures, papCreate/papExtend, CallGenericApply) is the correct
lowering of LTop. `LSet` is a non-empty, ascending-sorted list of member ids
(§3); an unconstrained residual zonks to LTop, never to an empty set (§6.1),
so `LSet []` is unrepresentable by construction.
-}
type LambdaSetAnno
    = LTop
    | LSet (List Int)
```

Note the file already contains a `-- ====== LAMBDA SETS ======` banner
(`Monomorphized.elm:248`) — a fossil of the pass's Roc-inspired birth,
currently housing `resolveNumberType`. `LambdaSetAnno` moves in under it;
the banner becomes true again.

### 5.2 Blast radius and mechanical rules

`MFunction` appears at **159 sites in 24 files** (grep, verified). The M1
sweep is mechanical under two rules:

- **Constructing:** `MFunction args ret` → `MFunction LTop args ret` —
  everywhere except MonoSolver zonk (§6.1), which is the only producer of
  real sets.
- **Matching:** `MFunction args ret` → `MFunction _ args ret` — except type
  *rebuilders*, which must thread the annotation through instead of dropping
  it: `Zonk.lambdaChain` (`Zonk.elm:154`), `resolveNumberType`
  (`Monomorphized.elm:265`), `Traverse.mapNodeTypes` callees, GlobalOpt's
  staging canonicalizers (`MonoGlobalOptimize.canonicalizeClosureStaging`,
  `Staging/Rewriter.elm` — 5 sites) and `peelStages`/`decomposeFunctionType`
  (`MonoGlobalOptimize.elm:1858`), and the MLIR type mapping
  (`Generate/MLIR/Types.elm`), which ignores the annotation for layout (an
  arrow is a closure value regardless of its set — REP_* untouched).

Heaviest files: `Monomorphized.elm` (26), legacy `TypeSubst.elm` (24) +
`Specialize.elm` (22) — the legacy engine compiles with `LTop` stamps and
never reads the field.

**Equality audit (M4 task):** Elm's structural `==` on `MonoType` becomes
set-sensitive. Key sites *want* that; layout comparisons do not. Provide

```elm
widenSets : MonoType -> MonoType      -- every anno := LTop (recursive)
eqLayout : MonoType -> MonoType -> Bool
eqLayout a b = widenSets a == widenSets b
```

and sweep `==`-on-MonoType sites (GlobalOpt staging equality, Diff, tests)
during M4, defaulting each to `eqLayout` unless it is a key computation.

### 5.3 The comparable key

`toComparableMonoTypeHelper`'s `MFunction` arm (`Monomorphized.elm:993–1000`)
— `LTop` must keep today's exact `"A("` fragment so that all-⊤ graphs key
byte-identically:

```elm
MFunction anno args ret ->
    let
        annoKey =
            case anno of
                LTop ->
                    "A("

                LSet members ->
                    "A[" ++ String.join "," (List.map String.fromInt members) ++ "]("

        newWork =
            List.foldl (\t w -> WorkType t :: w)
                (WorkMarker "->" :: WorkType ret :: WorkMarker ")" :: rest)
                args
    in
    toComparableMonoTypeHelper newWork (annoKey :: acc)
```

Canonicality: `LSet` lists are sorted ascending at construction (zonk sorts,
§6.1), so equal sets always produce equal keys. Member ids are per-run
stable (§3.2), so keys are deterministic within a run — the same stability
contract the registry already has via `MVarId`-erased keys (MONO_003
comment, `Monomorphized.elm:941`).

### 5.4 Diff/byte gates

- **M1 gate:** all annos are `LTop` ⇒ `toComparableMonoType` output is
  byte-identical to today ⇒ the `EngineDiff` corpus MATCH set must be
  unchanged.
- **M2+:** `EngineDiff` (`MonoDiff.run`, `Diff.elm`) compares solver against
  the subst engine, which cannot produce sets; `selectMonomorphizer` forces
  `lss.enabled = False` for `EngineDiff` runs. The serializer
  (`Diff.serRegEntry` uses `toComparableMonoType`) needs no change under
  that rule.

---

## 6. Zonk, classify, encode

### 6.1 Store readback (`Store.zonkFlatC`, `Store.elm:651`)

```elm
IO.Fun1 a b ->
    -- lss-off arrows, and typechecker-shaped structure: no set information.
    … Ok ( Mono.MFunction Mono.LTop [ ma ] mb, c2 )

IO.FunL a b setVar ->
    case zonkToMonoC superTable revMemo a c0 of
        Err e -> Err e
        Ok ( ma, c1 ) ->
            case zonkToMonoC superTable revMemo b c1 of
                Err e -> Err e
                Ok ( mb, c2 ) ->
                    let
                        ( anno, c3 ) =
                            zonkSetSlot maxSetSize setVar c2
                    in
                    Ok ( Mono.MFunction anno [ ma ] mb, c3 )


{-| Read a set slot back to an annotation. Policy:
  - unresolved slot (FlexVar)      -> LTop   (unknown, NOT empty — an
                                              empty claim would license
                                              consumers to treat the arrow
                                              as dead)
  - LambdaSet1 True _              -> LTop   (widened / kernel-facing)
  - LambdaSet1 False members       -> LSet (sorted ids), unless
                                      |members| > maxSetSize -> LTop
                                      (counted in lssStats.widenedBySize)
-}
zonkSetSlot : Int -> IO.Variable -> ZonkCtx -> ( Mono.LambdaSetAnno, ZonkCtx )
```

This is the **only** producer of `LSet`. It runs at item quiescence (zonk is
already the commit point — MONO_028 discipline), so a set is read only after
every unification the item will ever do — the same reason numbers stopped
mis-defaulting.

### 6.2 Pure classification paths

`Zonk.canTypeToMono`/`lambdaChain` (`Zonk.elm:154–166`) and
`Store.classifyDirect`'s structural `TLambda` arm (`Store.elm:861`) stamp
`LTop`. These paths are used for entry seeding, closed-scheme caches, and
memo-miss classification; §8.4's `sigTrivial` gate ensures they are never
used where a real set could exist.

### 6.3 Encoding demands (`Store.monoTypeToVarC`, `Store.elm:369`)

The `MFunction` arm currently folds args right-to-left into nested `Fun1`s.
Under lss it folds into `FunL`s whose slots are bound to the annotation's
content — every arrow minted from one `MFunction` layer shares that layer's
annotation (mono's one-arg-per-arrow invariant means the layer almost always
mints exactly one arrow):

```elm
Mono.MFunction anno args result ->
    let
        ( pResult, st1 ) =
            monoTypeToVarC result st

        setContent =
            case anno of
                Mono.LTop ->
                    IO.LambdaSet1 True CoreDict.empty

                Mono.LSet members ->
                    IO.LambdaSet1 False (CoreDict.fromList (List.map (\m -> ( m, () )) members))
    in
    List.foldl
        (\argType ( accPoint, stA ) ->
            let
                ( pa, stA1 ) = monoTypeToVarC argType stA
                ( pSet, stA2 ) = freshVarS (IO.Structure setContent) stA1
            in
            structS (IO.FunL pa accPoint pSet) stA2
        )
        ( pResult, st1 )
        (List.reverse args)
```

Note the deliberate asymmetry with §6.1: a **demand's** `LTop` encodes as
`top = True` (poison — "some caller was widened, this arrow must stay
dynamic"), while an **unconstrained slot** reads back as `LTop` without ever
having poisoned anything. "No information" and "widened" are distinct in the
store and collapse only at readback.

---

## 7. The inference layer: `Compiler/MonoSolver/LssInfer.elm` (new)

### 7.1 Signature model

A def's LSS signature summarizes what its *body* contributes to the arrows
of its *annotation type* — the facts a caller must apply without walking the
body (the paper's `Q ⇒ τ` for AT-Def-Ref). With id-only members this is
small and flat:

```elm
module Compiler.MonoSolver.LssInfer exposing
    ( LssSignature, ArrowFact, signatureFor, sigTrivial )


{-| Per-definition lambda-set signature.

`arrows` is indexed by ARROW ORDINAL: position in the arrow-slot array that
`Store.loadTypeIsolatedWithArrows` yields when loading this def's annotation
type (LSS_006). A caller instantiates the same annotation through the same
function, so ordinal pairing is exact by construction.
-}
type alias LssSignature =
    { arrows : Array ArrowFact
    , trivial : Bool   -- every fact is {rep=self, members=[], top=False}
    }


{-| One annotation arrow's facts:
  - rep      : smallest ordinal whose set slot the body unified with this
               one (equivalence classes over annotation arrows — the
               "same α at two positions" linkage, e.g. the classic
               `twice : (a -α-> a) -> a -α-> a` sharing)
  - members  : ids the body itself injects (the make-mult constraint
               ℓ ⊑ α, id-only)
  - top      : the body forces ⊤ (e.g. the arrow reaches a kernel)
-}
type alias ArrowFact =
    { rep : Int
    , members : List Int
    , top : Bool
    }
```

Internalization is **by omission**: set variables not reachable from the
annotation's arrows simply do not appear in the signature. Their effects on
annotation arrows were already applied by unification during inference, and
their own groundings recompute per specialization item when the body is
walked there (mono re-walks bodies per item anyway).

### 7.2 SCC-granular, demand-lazy inference

```elm
signatureFor : TOpt.Global -> Step LssSignature
```

Semantics:

1. **Memo hit** (`S.lssSignatures`, keyed by `TOpt.toComparableGlobal`) →
   return.
2. **Resolve the inference unit**: the def's SCC. `TOpt.Cycle` nodes
   materialize SCCs explicitly (members reach the cycle node via `_M$` links
   — same resolution `specializeNode`'s `Cycle` arm uses,
   `MonoSolver/Monomorphize.elm:311`); a non-cycle def is a singleton unit.
3. **Pre-resolve callee signatures**: fold over the unit's bodies collecting
   referenced globals (a cheap syntactic pass); for each not in the unit and
   not memoized, recurse `signatureFor`. Doing this *before* step 4 keeps
   scratch stores strictly nested-free.
4. **Infer the unit in one scratch store** (`withScratchStore`, below):
   - Load every member's annotation type via
     `loadTypeIsolatedWithArrows`… **no** — via the *shared* scratch memo
     (`Store.loadType`), capturing each member's arrow-slot array. Within
     the unit, self- and sibling references load the same annotation
     MVarIds through the same memo, so recursive calls share the def's own
     set slots — the paper's Σ/TIU-Self-Ref rule, which is what forbids
     polymorphic recursion in set parameters and guarantees termination.
   - Walk each member body (§7.3).
5. **Zonk the signatures**: per member, per annotation arrow slot: read
   members/top from the root content; compute `rep` by `UF.equivalent`
   against lower-ordinal slots (arrows-per-signature is small; the O(n²) is
   on n ≈ arity). Memoize all unit members at once.

In-progress protection: a `lssInProgress : Set String` guard in `S`; a
`signatureFor` re-entry on a member of an in-flight unit is an `EngineBug`
crash (step 3 makes it impossible; the crash keeps it that way).

```elm
{-| Run a Step against a fresh scratch store, restoring the item's
store/memo/revMemo afterward. The pattern is retranslateAt's stash/restore
(Translate.elm:2739) promoted to a combinator.
-}
withScratchStore : Step a -> Step a
```

### 7.3 The inference walk — what it must and must not do

The walk is a **types-only fold** over `TOpt.Expr` (~250 lines), not a
shadow of `Translate.translate`. It can be this small because within one
def, the typechecker already connected everything: sub-expression types
share solver-rooted `MVarId`s, and the scratch memo (`MVarId → Point`) makes
every occurrence of a variable load to the same Point. The walk only adds
what the type checker never knew — set facts:

| Node | Action |
|---|---|
| `Function (Just lam) params body meta` | `loadType meta.tipe` → head `FunL` slot → unify `LambdaSet1 False {lam}` in; recurse body |
| `Call region func args meta` with `VarGlobal g` | `instantiateLss g` (§8.4 — shared with translate) → unify param slots against `loadType (typeOf arg)` per arg (the existing `unifyParamsWithArgs` shape, `Translate.elm:2175`, reused best-effort) and result against `loadType meta.tipe` |
| `Call` with `VarKernel`/`VarDebug` | load the kernel scheme fresh, unify args, then `poisonArrowSets` on the kernel's own type (§7.5) |
| `VarGlobal g` standalone, function-typed | `memberIdFor ("g|" ++ …)` → unify singleton into the head slot of `loadType meta.tipe`; same for ctor (`VarEnum`/`VarBox`/ctor refs → `"c|…"`) and accessor values (`"a|field"`) |
| `Let def body` | record `letEnv name ↦ loaded RHS type Point`; at each use of `name`: `joinArrowSets rhsPoint usePoint` (§7.4) |
| everything else | structural recursion only — **no** type connection; shared MVarIds already carry the flow, and re-implementing translate's demand-concretization corners here would be wrong-layer work |

The walk performs no enqueues, allocates no `SpecId`s, emits no exprs, and
touches no multi-instance stacks — it cannot perturb specialization state.

### 7.4 Let boundaries (the §6.4 corner, v1 policy)

Use sites of let-generalized bindings carry their own instantiation
`MVarId`s, disconnected from the RHS's (the artifact-fidelity finding; this
is why the engine has `localMulti` machinery). Unifying whole types across
that boundary is wrong (uses at different types would mismatch). v1 joins
**set slots only**:

```elm
{-| Walk two loaded type structures in parallel, unifying ONLY the set slots
of arrows at matching positions. On structural divergence (one side is a
variable or the shapes differ — a generalized position), poison BOTH sides'
remaining arrow slots to ⊤ and stop descending that branch.
-}
joinArrowSets : IO.Variable -> IO.Variable -> Step ()
```

Consequences, stated honestly: all uses of a let-bound function share one
set (union over uses — sound, loses per-use set separation inside a def),
and generalized positions go ⊤. Defs remain the precision unit, matching the
paper's own granularity choice. The upgrade path (per-use set instantiation
mirroring `localMulti`) is a vNext item and is *why* `joinArrowSets` is a
separate function rather than inlined.

### 7.5 The kernel/port/effect boundary

```elm
{-| Poison every arrow set slot reachable in a loaded type: kernels apply
closures through the generic runtime path, so any arrow crossing the kernel
ABI is dynamic (LSS_004). Bounded depth; type structure in a store is finite.
-}
poisonArrowSets : IO.Variable -> Step ()
poisonArrowSets v =
    -- UF.get v; on Structure: FunL a b s -> unify s with (LambdaSet1 True ∅),
    -- recurse a, b; other structures -> recurse children; vars -> stop.
```

Hooks (all in `Translate.elm`, at the points that already derive the foreign
type): `deriveKernelAbiTypeWith` (`:2101`) after its instantiate — poisons
kernel schemes on both call and ref paths; `specializePort` (`:667`) on the
payload/encoder arrows; `VarDebug` via the kernel path. `List.map`, `foldl`,
`foldr`, `filter` are plain Elm in elm/core 1.0.5 (verified) and are *not*
poisoned; `List.map2–5`, `sortBy`, `sortWith`, Task/Process internals are.

### 7.6 Cost and memoization

One scratch-store body walk per global (per SCC), on first demand, memoized
for the run — versus today's per-*specialization* full translate walks, this
is a ≤1× addend on distinct-global count, not on spec count. `trivial`
signatures (the overwhelmingly common case: first-order code) additionally
keep the fast paths (§8.4). M2's gate measures self-compile wall time
flag-on/off; the structure-sharing warnings of the paper's §6.1–6.2 don't
bite id-only sets (no nested terms exist to share).

---

## 8. Engine integration

### 8.1 `Engine.S` / `Engine.Env` additions

```elm
-- Engine.S (global fields; all survive resetItem — resetItem untouched)
    , lssSignatures : CoreDict.Dict String LssInfer.LssSignature
    , lssInProgress : Set.Set String
    , lssMembers : CoreDict.Dict String Int      -- §3.3 interning
    , nextMemberId : Int                          -- seeded from GlobalMVarState.nextLam
    , specCountByGlobal : CoreDict.Dict String Int  -- §8.5 budget
    , lssStats : LssStats                         -- §8.6 report counters

-- Engine.Env (immutable)
    , lss : Config.LssConfig
    , lamLabels : CoreDict.Dict Int String        -- §3.2, report rendering
```

`initState` (`MonoSolver/Monomorphize.elm:103`) wires them from the new
`Config.MonoConfig` parameter and `GlobalMVarState`.

### 8.2 `specializeLambda` (`Translate.elm:1090`)

The one place a set gains a syntactic-lambda member. The `Function` arms of
`translate` (`Translate.elm:571–575`) pass the node's tag through:

```elm
TOpt.Function srcLam params body meta ->
    specializeLambda srcLam params body meta.tipe s0
```

and the head of `specializeLambda` swaps storeless classification for a
store round-trip when lss is on:

```elm
specializeLambda srcLam params body canType =
    -- lss on: LOAD the lambda's type (arrows slotted, through the item
    -- memo so demand concretization is visible), inject the lambda's own
    -- member into the head arrow's slot, and zonk — the closure's MonoType
    -- then carries `LSet [self, …demand-joined members]` on its head arrow.
    -- lss off: `classify canType` exactly as today.
    Store.loadType canType
        |> Engine.andThen
            (\funcVar ->
                injectHeadMember srcLam funcVar   -- no-op when srcLam == Nothing or lss off
                    |> Engine.andThen (\_ -> Store.zonkToMono funcVar)
            )
        |> Engine.andThen (\monoType0 -> … {- unchanged param peel / body walk -})
```

`injectHeadMember` reads `UF.get funcVar` expecting
`Structure (FunL _ _ slot)` and unifies `LambdaSet1 False {member}` into
`slot` (an `EngineBug` if a lambda's loaded type is not an arrow).

### 8.3 `ClosureInfo` (`Monomorphized.elm:618`)

```elm
type alias ClosureInfo =
    { lambdaId : LambdaId
    , srcLambda : Maybe TypeIds.SrcLambdaId   -- NEW: source identity (§3)
    , captures : List ( Name, MonoExpr, Bool )
    , params : List ( Name, MonoType )
    , closureKind : MaybeClosureKind
    , captureAbi : Maybe CaptureABI
    }
```

The closure's *target set* is deliberately **not** duplicated here — it is
the annotation on the closure's own `MonoType` (third field of
`MonoClosure`), already carried. Consumers read
`Mono.typeOf closure |> headAnno`. Inliner rule (OQ6): `srcLambda` copies
verbatim on inline/clone — several instances sharing a source id is the
intended semantics ("same code object"), unlike `LambdaId`, which the
inliner must keep unique (MONO_019 unchanged).

### 8.4 Call paths: applying signatures

`instantiateLss` supersedes bare `instantiate` (`Translate.elm:2165`) on the
global-call paths:

```elm
instantiateLss : TOpt.Global -> Can.Type TypeIds.MVarId -> Step IO.Variable
instantiateLss global funcCanType =
    LssInfer.signatureFor global
        |> Engine.andThen
            (\sig ->
                Store.loadTypeIsolatedWithArrows funcCanType
                    |> Engine.andThen
                        (\( funcVar, slots ) ->
                            applySignature sig slots
                                |> Engine.map (\_ -> funcVar)
                        )
            )


applySignature : LssSignature -> Array IO.Variable -> Step ()
-- per ordinal i, fact = arrows[i]:
--   fact.rep /= i          -> unifyStep slots[i] slots[fact.rep]
--   fact.top               -> unify slots[i] with LambdaSet1 True ∅
--   fact.members /= []     -> unify slots[i] with LambdaSet1 False members
```

Consistency requirement (LSS_006): the signature's ordinals and this load
enumerate arrows of the **same annotation type** — both sides source it from
`lookupAnnotation` (`Translate.elm:3974`), falling back to `funcMeta.tipe`
exactly as `translateCall` does today (`Translate.elm:1199–1213`).

In `translateGlobalCallSlow` (`Translate.elm:1688`) the only change is
`instantiate funcCanType` → `instantiateLss global funcCanType`; the
existing sequence (unify params via `unifyParamsCollect`, unify expected
result, translate args, zonk `funcVar`, `enqueueSpec` at the zonked type)
needs *no* modification — sets ride the same Points. This is the payoff of
the store architecture: the demand-flow engine is already bidirectional.

**Fast paths.** `translateGlobalCall`'s M2a/M2b guards (`Translate.elm:1408`)
gain one conjunct:

```elm
if List.isEmpty s.numberMulti && List.isEmpty s.localMulti && lssFast global s then
```

where `lssFast` = lss off **or** the callee's signature is `trivial` *and*
no argument type mentions an arrow (an arrow-free ground call cannot
transport sets, so cached classification stays exact). `sigTrivial` forces
the signature computation on first use — the memo makes that a one-time
cost. The `cachedSchemeMono`/`callMemo` caches themselves stay valid because
their keys are only used under this guard.

Indirect calls (`translateIndirectCall`, `:1316`) need **no** set-specific
code: the callee expression's zonked type carries its annotation, which is
precisely the dispatch fact consumers want on that `MonoCall`.

**M3 correction — the transport gap.** The two claims above ("sets ride
the same Points", "the callee expression's zonked type carries its
annotation") turned out to hold only for closure-literal heads and
direct-call callee types; measured on real graphs, **no `MonoCall` callee
type carried a set** at GlobalOpt time. The reason is LSS_006 itself:
`Store.loadType` mints fresh arrow structure per load — only leaf MVarIds
are memo-shared — so two loads of the same canonical type (and *any* two
loads of a GROUND type) have disconnected set slots. Three fixes, landed
with M3, restore the transport chain end-to-end
(literal-arg member → callee demand → spec binder types → param-use call
sites):

1. `Translate.injectArgLambdaMember` (inside `argUnifyVar`): a lambda
   LITERAL argument injects its member into the arg var that is unified
   with the callee's param slot. (`classifyLambdaHead`'s own injection
   lands in the lambda's *own* load — disconnected from the call.)
2. `Translate.demandUnifyRoot` + `Engine.S.lssRootAnn`: function-root defs
   stash the demand-seeded annotation var; the def-root
   `classifyLambdaHead` consumes it (matched by canonical type,
   consume-once) instead of fresh-loading, so `specializeLambda`'s peeled
   binder/param types zonk the transported sets, and `VarLocal` uses (the
   varEnv-bound type) carry them to indirect call sites.
3. `specializeCycleFuncDef`'s TailDef arm gains an lss-on branch that
   zonks node/param types from the seeded var (self-recursive HOFs are
   cycle tail-defs; the storeless `classify` cannot see store content).
   The lss-off chain is kept verbatim (byte identity).

Known v1 precision gap: local-multi arguments (let-bound lambdas passed to
HOFs) do not transport members — their stash vars are fresh instantiations
and `enrichFromEnv` deliberately skips local-multi targets. The annotation
stays `LTop`: no upgrade, no unsoundness. Candidate follow-up ("M3.5")
once census data shows it matters.

### 8.5 Keys and the budget (`Engine.enqueueSpec`, `Engine.elm:307`)

```elm
enqueueSpec : Mono.Global -> Mono.MonoType -> Step Mono.SpecId
enqueueSpec global monoType s =
    let
        lss =
            s.env.lss

        gkey =
            Mono.toComparableGlobal global

        keyType =
            if lss.enabled && lss.keyed && underBudget lss gkey s then
                monoType

            else
                Mono.widenSets monoType

        ( specId, reg1 ) =
            Registry.getOrCreateSpecId global keyType s.registry
    in
    …unchanged scheduling; on NEW spec: bump specCountByGlobal[gkey],
     and if the widen branch fired with lss.keyed, count it in
     lssStats.widenedByBudget…
```

Semantics per milestone: M2/M3 (`keyed = False`) — keys are today's keys,
node types still carry annotations (graph facts without fan-out). M4
(`keyed = True`) — sets split specializations up to the per-global budget;
past it, *new* demands widen their sets (types never widen — MONO_020/021/024
forbid it; this is the sets-widen-first asymmetry from the foundation
report). `Registry.updateRegistryType` continues to overwrite the reverse
mapping with the actual node type (MONO_017), annotations included.

### 8.6 Assembly, Prune, report

- **Prune:** no set-specific closing pass exists or is needed — `LSet`/`LTop`
  are ground data by construction (§6.1); the fused number-close
  (`Prune.elm:108–135`) only needs the mechanical `MFunction` arm in
  `resolveNumberType`'s rebuild.
- **Report** (`lss.report`): rendered after prune from `lssStats` +
  a graph walk — per-global spec counts (top N), set-size histogram,
  widening events by cause (size/budget/kernel), member census with
  `lamLabels`. Returned as the `Maybe String` of §2.2; `Builder/Generate.elm`
  prints it to stderr. This is the M2 gate artifact and the budget-tuning
  instrument (the `backendstats` discipline).

---

## 9. Consumers

### 9.1 Ground truth (verified)

- `_fast_evaluator` clones (`$cap`) are emitted per closure today
  (`Generate/MLIR/Expr.elm:1082`, `:4524`).
- The dispatch tiers `fast | closure | unknown` are fully implemented in
  `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:1108–1256`.
  *Correction from the M3 audit (plan step 3.1)*: the `_dispatch_mode`
  attribute has **no producer** and its consumers are bypassed; the live
  trigger is `PapExtendOpLowering` — a SATURATED typed papExtend
  (`remaining_arity` present) carrying `_fast_evaluator` + `_capture_abi`
  takes `emitFastClosureCall`; that helper was dead code until M3.
- `Mono.ClosureKindId`/`Known`/`captureAbi` have **no producer**;
  `AbiCloning.abiCloningPass` is a stub; call sites default to
  `CallGenericApply` (`Mono.defaultCallInfo`) unless
  `MonoGlobalOptimize.computeCallInfo` proves a direct call.

### 9.2 M3 — the singleton upgrade pass (sketch; own plan doc at M3)

A new GlobalOpt pass (natural home: completing `AbiCloning.elm`, whose
module doc already describes this job):

1. Index the pruned graph: `srcLambda → [reachable MonoClosure instances]`
   (one walk collecting `ClosureInfo.srcLambda`).
2. For each `MonoCall` whose callee's type head-annotation is `LSet [m]`:
   if `m` has exactly one reachable instance and its capture ABI is
   determinable, stamp `callInfo.closureKind = Known …`,
   `captureAbi = Just …`; `computeCallInfo`
   (`MonoGlobalOptimize.elm:1910`) and the MLIR call emission then take the
   fast tier (`_dispatch_mode="fast"` with `_fast_evaluator`/`_capture_abi`),
   which the C++ lowering already handles.
3. Ambiguity (multiple instances, differing ABIs) → leave `CallGenericApply`;
   this *is* the ABI-cloning trigger condition (ABI_CLONE_001) if cloning is
   ever implemented — LSS supplies the analysis it was waiting for.

**Precondition**: the wrapper identity rule (§9.3, LSS_008) must land
before this pass is enabled — without it, staging wrappers falsify step
2's uniqueness test and the stamp is a silent miscompile.

### 9.3 Pass ordering — AbiCloning runs after Staging

`globalOptimize` (`MonoGlobalOptimize.elm:108–132`) runs Phase 2
`Staging.analyzeAndSolveStaging` (+ Phase 3 validation), Phase 4
`AbiCloning`, Phase 5 `annotateCallStaging`. That order is load-bearing,
not incidental: the two passes act on orthogonal axes of the closure ABI —
Staging on *arity segmentation* (how a curried value's parameters split
into stages), AbiCloning on *code identity* (which evaluator + capture
layout inhabits the arrow) — and the second **depends on the first for
correctness** in three ways.

**(a) The fast tier consumes staging facts as correctness inputs.** An
M3-upgraded call is still "typed mode": saturation is decided *statically*
(`EcoToLLVMClosures.cpp:2039`,
`isSaturated = (numNewArgs == remainingArity)`), and CGEN_052 makes a wrong
`remaining_arity` a **silent miscompile** — the runtime sanity check in
`eco_pap_extend` only catches over-saturation, so an under-saturating chain
quietly builds a PAP where the evaluator should have been entered.
`initialRemaining`/`remainingStageArities` are derived by `computeCallInfo`
(`MonoGlobalOptimize.elm:1994–2017`) from the callee's
**post-canonicalization** type. A join point (`case`/`if` producing
functions) has one static type, but runtime values from different branches
can have different natural segmentations; the Staging solver's union-find
over producers and join/param slots (`SlotIfResult`/`SlotCaseResult`/
`SlotParam`, `Staging/GraphBuilder.elm`) is what makes that single type
*truthful of every value that can flow*, wrapping minority producers and
demoting producer-less classes (`dynamicSlots`) to `CallGenericApply`
(GOPT_001/GOPT_003, GOPT_010–016). The M3 stamp only *adds* evaluator and
capture knowledge on top of that segmentation truth; it never replaces it.

**(b) AbiCloning's stamps denote value identity; Staging rewrites values.**
`closureKind = Known kindId` + `captureAbi` at a call site is a claim about
*the runtime object that arrives there* — its evaluator symbol and capture
layout. Staging's `wrapClosureToCanonical` (`Staging/Rewriter.elm:500`)
**replaces** a producer's value with nested wrapper closures whenever its
natural segmentation differs from the class canonical. A pass whose output
facts name value identity must run after the last pass that rewrites
values. Inverting the order — AbiCloning first — turns a guarded
interaction into unguarded stamp falsification:

```elm
let f = \x y -> ...            -- member m, natural staging [2]
in ( f 1 2                     -- singleton site: would stamp Known(m)
   , case c of                 -- join with g, canonical staging [1,1]
       A -> f
       B -> g )
```

`f` is created once. Staging must wrap it *at the producer* for the join's
benefit (or the join's other consumers miscompile under CGEN_052); every
consumer — including the already-stamped direct site — then receives the
wrapper: different evaluator, different capture ABI. The stamp is now wrong
and nothing detects it, because Staging has no map from a rewritten
producer to the downstream `CallInfo`s that mention it — building that map
is exactly the reachable-instance analysis AbiCloning itself performs, so
"AbiCloning first" degenerates into running AbiCloning *again* after
Staging. The remaining escalation — pinning stamped producers as
unwrappable — dies on classes containing two pinned producers with
different natural segmentations: a contradiction that forces un-stamping
and a fixpoint iteration between the two passes. Staging-first costs one
line (below) and is guarded automatically.

**(c) Phase 5 threading.** `annotateCallStaging` recomputes and threads
`CallInfo` from the staging solution and must *preserve* M3 stamps. With
AbiCloning at Phase 4, stamps are produced immediately before the one pass
that threads them, on a graph no later phase rewrites.

**The wrapper identity hole and its fix.** As implemented at M2, wrapping
breaks LSS's identity link: `buildNestedWrapper` constructs each wrapper
stage with `srcLambda = Nothing` (`Staging/Rewriter.elm:574`), while
`wrapClosureToCanonical` deliberately preserves the *type* annotation
(`Mono.headAnno originalType`, `:515`) — and
`Mono.buildSegmentedFunctionType` (`Monomorphized.elm:1390`) replicates
that same annotation onto **every** stage arrow it builds. A call site can
therefore see head annotation `LSet [m]` while the flowing value is a
wrapper. M3's index (`srcLambda → reachable instances`) would find exactly
one instance of `m` — the original, nested *inside* the wrapper — and stamp
`Known(m)` with m's capture ABI at a site whose runtime value is the
wrapper: wrong capture loads, wrong evaluator, silent miscompile.

Fix (an M3 precondition, one line plus tests): propagate the wrappee's
identity onto every wrapper stage —

```elm
-- Staging/Rewriter.elm, buildNestedWrapper (thread originalInfo down):
closureInfo =
    { lambdaId = lambdaId
    , srcLambda = originalInfo.srcLambda   -- was: Nothing
    , ...
```

Sound on both axes:

- **LSS_002 holds by construction**: every wrapper stage's type is a suffix
  of `buildSegmentedFunctionType anno …`, whose head annotation at each
  stage is the same `anno` — `LTop` or a set containing m. Inner stages are
  m's PAPs, and v1's "PAPs keep the callee's member" rule (§3.3/OQ4) makes
  annotating them with m the intended semantics, not a fudge.
- **M3 becomes sound by construction**: m now has ≥ 2 reachable instances
  (original + wrapper stages) with differing capture ABIs, so step 3's
  ambiguity rule declines the upgrade at every stage depth — with no
  wrapper-specific logic inside AbiCloning.

Framing matters here: this is *not* a wrapper workaround bolted onto M3.
Instance uniqueness is already M3's core soundness condition — step 3
exists because instances multiply for several reasons (the inliner
duplicates closures too, though its rebuilds carry `srcLambda = Nothing`
under `LTop` heads and are safe by absence, per OQ6). Staging wrappers are
simply one more producer of instance multiplicity; the fix makes them tell
the truth to a guard that already exists. Recorded as **LSS_008** (§12).

*Implementation addendum (M3):* staging wrappers are not the only
impersonators. `wrapTopLevelCallables`' **alias/general wrappers**
(`makeAliasClosureGO`/`makeGeneralClosureGO`) eta-expand a callable at its
full stage arity, so their type can carry a singleton `LSet [m]` (the set
flows through `f = g` aliases) while the runtime value is the synthesized
wrapper — and full arity means the shape guards alone do NOT catch them.
They wrap arbitrary expressions, not a `MonoClosure`, so there is no
`srcLambda` to propagate — and `SrcLambdaId` is an opaque supply-only
`Id`, so one cannot be fabricated. The fix lives at the consumer instead:
`AbiCloning.instanceMember` counts any `srcLambda`-less closure whose head
annotation is a singleton `LSet [m]` as an instance of `m` (identity
adoption), which restores multiplicity and makes the guard decline. The
inliner's partial-application rebuilds remain safe by construction: they
carry `LTop` heads AND strictly reduced first-stage arity, so both the
annotation gate and the arity guard reject them independently.

The cost is precision, not correctness: the upgrade is declined exactly
where wrapping occurred — where the flowing value genuinely is not m in
m's natural shape. Recovering those sites is a staging-side refinement,
not an ordering change — see §9.4.

### 9.4 Retiring Staging (outlook)

Not part of v1; recorded so the intent survives. Staging exists to make
static segmentation truthful for the *generic* closure world. As LSS
coverage grows, that world shrinks, and staging's one expensive artifact —
wrapper closures (an allocation plus an indirect call per canonicalized
stage) — pays off at progressively fewer call sites. The retirement path
is **staged shrinkage driven by census evidence**, never one-shot
deletion:

1. **Post-M3, census-gated — bias the canonical choice.** Make
   `chooseCanonicalSegmentation` prefer the natural segmentation of
   producers whose consumers are singleton-upgradable, so the wrapping
   burden falls on cold/generic producers instead and hot members keep
   their natural shape for fast dispatch. A stronger variant — skipping
   wrapping entirely when *no* typed-segmentation consumer of the join
   remains — additionally requires relaxing GOPT_003 (branch types agree
   *including staging*) for such joins and is a separate design. Build
   either only if the census shows wrapper insertion and singleton sets
   actually collide on hot paths: compare `dispatchUpgraded` against a new
   `wrappersInserted` counter. (`NormalizeLambdaBoundaries` already
   flattens most staging heterogeneity pre-mono, so the overlap may be
   small — measure first.)
2. **Post-M5.** Small-set dispatch (§9.5) calls each member with its *own*
   natural segmentation and capture ABI inside the tag match, so joins
   whose members all fit one small set no longer need canonical wrapping
   for those consumers at all. Staging's wrapping obligation then
   contracts to the `LTop` residue — kernel/port boundaries,
   budget-widened arrows, erased types.
3. **What is never deleted while the typed call protocol exists**:
   GOPT_001 type↔parameter normalization, truthful segmentation for
   `LTop`-headed joins feeding `CallDirectKnownSegmentation` sites, and
   the `dynamicSlots` demotion to `CallGenericApply`. These are cheap
   type-level rewrites with no runtime cost; they are the ABI discipline
   of the ⊤ world, and LSS's tiers are escape hatches out of it, not
   replacements for it.

**Retirement criterion** (measurable, from the census): on the perf corpus
and the eco self-compile, (i) the share of non-direct calls dispatched
through LSS tiers and (ii) `wrappersInserted` on hot paths. When wrappers
on hot paths approach zero, steps 1–2 have de facto retired staging's
*runtime* cost; solver/rewriter machinery that then serves only dead
wrapping can be dismantled behind the usual gates (full E2E + perf suite,
flag-off byte gate).

### 9.5 M5 — small-set dispatch (deferred design)

`LSet [m1..mk]`, k ≤ K: lower the closure value to a k-variant tagged
capture union and the call to a match over known targets (paper §5.2). New
value representation + REP_*/HEAP_* invariants — explicitly out of v1's
scope; the annotations M2–M4 produce are its complete input.

### 9.6 M6 — borrow inference

Reads `LSet` annotations + `srcLambda` to resolve higher-order callees when
computing borrow summaries; no mono changes beyond M4.

---

## 10. Control semantics (consolidated)

| Knob | Enforced at | Effect | Counted in |
|---|---|---|---|
| `enabled = False` | `LoadCtx.lssOn`, `specializeLambda`, guards | No slots minted anywhere; every anno `LTop`; byte-identical pipeline | — |
| kernel/port boundary | `poisonArrowSets` hooks (§7.5) | Foreign-facing arrows ⊤ | `widenedByKernel` |
| `maxSetSize` | `zonkSetSlot` (§6.1) | Oversize sets read back as `LTop` | `widenedBySize` |
| `maxSpecsPerGlobal` | `enqueueSpec` (§8.5) | Past budget, new keys set-widened (types untouched) | `widenedByBudget` |
| `keyed = False` | `enqueueSpec` | Facts recorded, zero fan-out | — |
| `report` | end of mono | Census to stderr | — |

Invariant behind all of them (LSS_005): widening changes annotations,
specialization counts, and downstream dispatch choices — never runtime
semantics. Every knob's fallback is the fully-implemented `LTop` pipeline.

---

## 11. Milestones (file-level, each independently gated)

- **M0 — prerequisites.** MonoSolver default engine + bake
  (`Config.elm:112` default flip; separate decision). Kernel-honesty work
  (solver-reuse-evaluation §6.3) scoped — required before M2's poison hooks
  can be *trusted*, not before M1.
- **M1 — plumbing, all-⊤ (byte-identical).**
  `MonoType`/`LambdaSetAnno` + 159-site sweep (§5.1–5.3); `FlatType`
  constructors + all arms (§4.1–4.3); `LssConfig` + entry plumbing (§2);
  `TypeIds.SrcLambdaId`. Gate: full E2E green both engines; `EngineDiff`
  corpus MATCH set unchanged; self-compile wall time unchanged (no slots
  minted).
- **M2 — identity + inference + report (flag-on, keys unchanged).**
  `TOpt.Function` tag + codec + producer sweep + `AssignMVarIds` stamp
  (§3.2); `Store` load/zonk/encode (§4.4, §6); `LssInfer` (§7);
  `specializeLambda`/`ClosureInfo`/`instantiateLss`/fast-path gating (§8);
  stats+report. Gates: E2E green with `ECO_MONO_LSS=1`; LSS_002 checker in
  `TestLogic` (every reachable `MonoClosure`'s `srcLambda` ∈ its head
  annotation's set unless `LTop`); census plausibility on the E2E corpus +
  eco self-compile; wall-time delta measured.
- **M3 — singleton consumer** (§9.2) + wrapper identity propagation
  (§9.3, LSS_008 — lands first) + call-site attr emission. Gate:
  E2E + perf suite; dispatch-upgrade and wrapper-insertion counts in the
  report.
- **M4 — `keyed = True` + budgets + `==` audit** (§5.2, §8.5). Gate:
  spec-count/binary-size deltas within budget on the corpus **and**
  elm-aws-codegen (the known pathological input); no `eqLayout` regressions.
- **M5 / M6** — separate design docs (§9.5–9.6).

---

## 12. Invariants delta (lands with M2 unless noted)

- **LSS_001** — In a pruned graph, every `MFunction` annotation is `LTop` or
  a non-empty ascending-sorted `LSet`; `LSet []` is unrepresentable.
- **LSS_002** — For every reachable `MonoClosure` with
  `srcLambda = Just m`, the head annotation of its `MonoType` is `LTop` or
  contains `m`. (Tested — the lowering-totality property.)
- **LSS_003** — Member ids are per-run stable: assigned only by Phase-0
  (`AssignMVarIds`) and engine interning; no other producer.
- **LSS_004** — Arrow positions crossing the kernel/port ABI carry `LTop`.
- **LSS_005** — Widening monotonicity: for any program, compiling with any
  stricter widening policy changes only annotations, specialization counts,
  and dispatch tiers — never observable behavior.
- **LSS_006** — Arrow ordinals are defined by `Store.loadTypeC`'s minting
  order over a def's annotation type; `LssSignature.arrows` and
  `applySignature` both index by it.
- **LSS_007** — Store content discipline: `FunL` set slots contain `FlexVar`
  or `Structure (LambdaSet1 …)`; `LambdaSet1` appears nowhere else; the
  typechecking phase's stores contain neither constructor.
- **LSS_008 (lands with M3)** — Any GlobalOpt rewrite that wraps or
  replaces a reachable `MonoClosure` must propagate the original's
  `srcLambda` onto every closure it creates whose type head-annotation can
  name that member (staging wrappers: all stages). Instance
  *multiplicity*, not absence, is the signal M3's uniqueness guard
  consumes; a wrapper hiding its provenance under `srcLambda = Nothing`
  while the annotation still names m re-establishes false uniqueness and
  licenses a wrong `Known` stamp (§9.3).
- Amend: MONO_005/MONO_017 wording (registry keys may be set-widened while
  reverse-mapping types carry annotations, §8.5); MONO_019 (LambdaId
  uniqueness) explicitly does **not** apply to `srcLambda`.

---

## 13. File-by-file change inventory

| File | Change | Size |
|---|---|---|
| `System/TypeCheck/IO.elm` | +2 `FlatType` ctors, module-doc discipline | S |
| `Compiler/Type/Unify.elm` | +4 `unifyStructure` arms (§4.2) | S |
| `Compiler/Type/Occurs.elm`, `Type.elm`, `Solve.elm` | exhaustive-match arms (§4.3) | S |
| `Compiler/AST/TypeIds.elm` | `SrcLambdaId` | S |
| `Compiler/AST/TypedOptimized.elm` | `Function`/`TrackedFunction` field; decoder `(Function Nothing)` | S |
| `Compiler/LocalOpt/Typed/*`, `TypedCanonical/Build.elm` | construct with `Nothing` (~25 sites) | S, mechanical |
| `Compiler/Monomorphize/AssignMVarIds.elm` | `freshLamId` + stamps + `GlobalMVarState` fields | S |
| `Compiler/AST/Monomorphized.elm` | `MFunction` anno, `LambdaSetAnno`, `widenSets`/`eqLayout`, comparable arm, `ClosureInfo.srcLambda` | M |
| all 24 `MFunction` files | mechanical `LTop`/`_` sweep; rebuilders thread anno (§5.2) | M, mechanical |
| `Compiler/MonoSolver/Store.elm` | `LoadCtx` fields, `TLambda` arm, `loadTypeIsolatedWithArrows`, zonk arms, `zonkSetSlot`, encode arm | M |
| `Compiler/MonoSolver/Engine.elm` | S/Env fields, `memberIdFor`, budgeted `enqueueSpec`, stats | M |
| `Compiler/MonoSolver/LssInfer.elm` | **new** — §7 (~450 lines incl. walk) | L |
| `Compiler/MonoSolver/Translate.elm` | `specializeLambda`, `instantiateLss`, fast-path guard, poison hooks | M |
| `Compiler/MonoSolver/Monomorphize.elm` | config param, initState wiring, report plumbing | S |
| `Compiler/Eco/Config.elm`, `Builder/Eco/Config.elm`, `Builder/Generate.elm` | `LssConfig`, env overrides, entry plumbing | S |
| `Compiler/MonoSolver/Diff.elm` | force-lss-off rule note (§5.4) | S |
| `Compiler/GlobalOpt/AbiCloning.elm` | M3 — the singleton pass (§9.2) | M (M3) |
| `Compiler/GlobalOpt/Staging/Rewriter.elm` | M3 — propagate `srcLambda` onto wrapper stages (§9.3, LSS_008) | S (M3) |
| `design_docs/invariants.csv` | §12 | S |

---

## 14. Remaining open questions

- **vNext typed members** — reintroduce capture shapes in `LSet` elements
  (restores paper-exact precision, resurrects μ machinery); gate on M5
  actually needing it.
- **Per-use let-boundary sets** — upgrade §7.4's shared-set join to per-use
  instantiation aligned with `localMulti`; gate on census evidence that
  let-bound HOFs are a real precision hole.
- **Cross-build signature caching** (was OQ5) — unchanged: only after the
  in-memory design is stable, and never as a name-keyed side channel.
- **`_dispatch_mode` call-site emission audit** — M3 must confirm exactly
  where the Elm side sets call dispatch attributes today (the consumer tier
  is C++-verified; the producer path is partial), before wiring `Known`.

---

## 15. References

Paper: `design_docs/auto-borrow-inference/lambda-set-specialization.pdf`
(esp. §4.1 inclusion constraints, §4.2 inference, §5.1 specialization, §6
implementation considerations). Foundation: `lss-foundation-report.md`.
History/doctrine: `design-recovery.md` (§6 number saga, §10 elevated
design), `solver-reuse-evaluation.md` (§6.3 kernel honesty, §8 synergy).
Engine status: `plans/monosolver-drop-in-monomorphizer.md` (rev 11).
Closure machinery ground truth: `Generate/MLIR/Expr.elm:1079–1114`,
`runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:1108–1256`,
invariants REP_CLOSURE_001/002, CGEN_CLOSURE_003–008, ABI_CLONE_001,
CLONE_RELATION_001, GOPT_001/013–016.
