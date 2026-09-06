module Compiler.GlobalOpt.AbiCloning exposing (AbiCloningStats, abiCloningPass, emptyStats, instanceFingerprint, peelStages)

{-| ABI Cloning Pass — LSS singleton dispatch upgrade (design §9.2/§9.3,
M3.5 interchangeability rule, LSS_009).

Runs at GlobalOpt Phase 4, AFTER Staging (Phases 2-3) — the order is a
correctness dependency, not convention (design §9.3): the stamps placed
here denote value identity, and Staging's Rewriter is the last pass that
replaces values (wrapper closures). Staging wrappers propagate the
wrappee's `srcLambda` (LSS_008), so they mark their member BLOCKED below
and decline the upgrade wherever wrapping occurred.

The pass:

1.  Indexes the graph: member -> { blocked, instances bucketed by
    param+return layout }, with layout keys precomputed per instance.
2.  For each `MonoCall` whose callee-type head annotation is a singleton
    lambda set `LSet [m]`: if `m` is unblocked and the site's layout
    bucket is unanimous in capture layout, stamps
    `callInfo.closureKind`/`captureAbi`/`fastEvaluator` with a
    REPRESENTATIVE instance (LSS_009 — verbatim copies of one member at
    one layout are interchangeable: monomorphization is type-directed and
    all external influence enters a lambda body via its captures/params,
    so same source + same layouts means alpha-equivalent compiled bodies
    with one `computeClosureCaptures` slot order).
3.  Anything else (no instance, blocked member, layout mismatch, ABI
    disagreement) leaves the call untouched —
    `CallGenericApply`/`CallSegmentationUnknown` remain dynamically safe
    (CGEN_060). The declined classes are ABI_CLONE_001 / M5 sizing data.

SCALE DISCIPLINE (self-compile profiling, 2026-07-12): this pass runs over
graphs with 10^5 nodes and members with THOUSANDS of verbatim instances
(cross-spec copies of hot core lambdas). Three rules keep it linear:
integer guards run before any key-string is built; instances are bucketed
by layout key at index time so a site does one Dict.get instead of
filtering the member's whole instance list; and a node's expression tree
is only REBUILT (traverseExpr allocates a fresh tree) when a cheap
foldExpr pre-scan finds at least one candidate call site — the vast
majority of nodes have none and pass through untouched.

The blocked rule is load-bearing: `_fast_evaluator` dispatch calls the
stamped instance's fast clone directly with typed capture loads and NO
runtime identity check (EcoToLLVMClosures.cpp `emitFastClosureCall`).
Staging wrappers and `wrapTopLevelCallables` eta-wrappers share a member's
identity but not its code or capture layout — stamping across them is a
silent miscompile.


# API

@docs AbiCloningStats, abiCloningPass, emptyStats

-}

import Array
import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Id as Id
import Compiler.Reporting.Annotation exposing (Region)
import Compiler.GlobalOpt.Staging.Rewriter as Rewriter
import Dict exposing (Dict)



-- ============================================================================
-- ====== STATS ======
-- ============================================================================


{-| Census counters (reported behind `lss.report` / ECO_MONO_LSS_REPORT).

  - dispatchUpgraded: call sites stamped for fast dispatch
  - declinedBlocked: singleton member with a blocker instance (staging
    wrapper stage or adopted synthetic eta-wrapper)
  - declinedNoInstance: singleton member with no MonoClosure instance
    (interned globals/ctors/kernels, tail-def'd lambdas)
  - declinedShape: no candidate matches the site's callee layout / arg
    count / guard set (a PAP value would be the only inhabitant, or Char
    captures). H6.0b splits it into sub-reasons (the sub-counters sum to
    declinedShape):
      - declinedShapeArity: argCount == 0 or first-stage arity mismatch —
        the flowing value is (or would be) a PAP of the instance
      - declinedShapeBucketMiss: no layout bucket for the site fingerprint
      - declinedShapeLayout: bucket found but no group passes the
        paramCount + eqLayout confirm
      - declinedShapeChar: matching group has Char captures (i16 capture
        load unexercised)
      - declinedShapeNonArrow: callee type is not an arrow
  - declinedAbiMismatch: layout-compatible candidates disagree on capture
    layout (same source lambda capturing differently-typed environment
    per enclosing specialization)
  - declinedBodyMismatch: LSS_024 fingerprint fence — the group passed the
    layout and capture-unanimity gates but its instances' verbatim-body
    fingerprints disagree: behaviorally divergent same-layout clones (the
    E11 hijack class). Never stamped; generic dispatch stays correct.

-}
type alias AbiCloningStats =
    { dispatchUpgraded : Int
    , stampedPapPrefix : Int
    , stampedStaged : Int

    -- ^ E2.7 (LSS_014): over-applying sites whose first stage matched an
    -- instance exactly — batch-1 fast dispatch + generic remainder.

    -- ^ E2 (LSS_011): sites stamped via the PAP-suffix match — the callee
    -- value is an m-PAP holding k applied args; captureAbi carries the
    -- merged captures++prefix and CallInfo.fastPapPrefix = Just k.
    , declinedBlocked : Int
    , declinedNoInstance : Int
    , declinedShape : Int
    , declinedShapeArity : Int

    -- E2 sub-split of declinedShapeArity (the three sum to it):
    --   Zero  — argCount == 0 (bare reference in callee position);
    --   Under — site applies fewer args than its own callee type's first
    --           stage (the call CREATES a PAP — no dispatch to convert);
    --   Over  — site applies more (flat multi-stage call; dispatch exists
    --           but needs staging-aware stamping — v2).
    , declinedShapeArityZero : Int
    , declinedShapeArityUnder : Int
    , declinedShapeArityOver : Int
    , declinedShapeBucketMiss : Int
    , declinedShapeLayout : Int
    , declinedShapeChar : Int
    , declinedShapeNonArrow : Int
    , declinedAbiMismatch : Int
    , declinedBodyMismatch : Int -- LSS_024 F fence: fingerprint-divergent same-layout groups declined (each one is a fenced E11-class hazard — investigate when non-zero)
    -- E9.5 + lss-lpartial counters bundled in ONE field: the flat stats
    -- record sits at the 32-slot GC-scan cap (the Engine.S lesson) — a
    -- nested record is a single slot.
    -- fn/ctor: noInstance singleton sites rewritten to direct calls
    -- (flag lss.postSettleDevirt; 0 flag-off). noSpec: candidate passed
    -- every guard but no registry spec eqLayout-matched (expect ~0).
    -- partialDeclined (lss-lpartial AR-P2): LPartial-headed sites the
    -- stamp DECLINED — the observable devirt guard.
    , devirtPost : { fn : Int, ctor : Int, noSpec : Int, partialDeclined : Int }
    , multiInstanceGroups : Int -- layout groups holding ≥2 distinct lambdaIds. A MONITORING DELTA, not a zero-gate (amended LSS_017 reading): MonoInlineSimplify mints fresh lambdaIds for verbatim inline copies, and under LSS_024 annotation-only clones legitimately join one group — the representative premise is discharged by fingerprint unanimity, not by this count.

    -- Census (2026-07-21, plans/lss-dispatch-value-extraction.md open
    -- questions). Stats-only — never touches the graph; the maps are
    -- bounded by consulted-site populations.
    , declineByMember : Dict Int Int -- consulted-singleton DECLINES per member id (dominated by the Over class) — the residue-attribution join key
    , memberReps : Dict Int (List Mono.LambdaId) -- group-representative lambdaIds for members recorded in declineByMember/multiSetMembers (symbol join)
    , multiSetSiteHist : Dict Int Int -- E3 de-risk: |set| -> consulted call sites carrying a MULTI-member set
    , multiSetMembers : Dict Int Int -- E3 de-risk: member id -> occurrences across multi-set sites
    , topSiteShapes : Dict String Int -- E8 split: LTop-annotated call sites by callee-expression shape (escape proxy: recordAccess/callResult vs local/global)
    , varSiteShapes : Dict String Int -- Phase 1a/3 (plans/lss-unknown-elimination.md §2.5, plans/lss-set-variable.md): the same census for LVar-annotated sites — the "still a variable" half of what used to be one undifferentiated ⊤ population. Same shape keys as topSiteShapes; same TRAP (stampCall consults EVERY call, so these are SITE counts, not dispatch weight).
    , stampedWrapperInstances : Int -- E7 trigger: stamped sites whose representative is a staging wrapper (collision signal)
    , instQual : { hist : Dict String Int, divergentGroups : Int, byHost : Dict String Int, flatStamped : Int, shape : Dict String Int } -- P0 census (plans/lss-instance-qualified-members.md §2). `hist`: "<n>" -> layout groups holding n instances, plus "div<n>" for the fingerprint-DIVERGENT ones. `divergentGroups`: groups with multi && not fpUnanimous — the target class (a divergent group shares one member id across behaviourally different bodies, which is the local-multi instance-blindness this plan closes; inliner copies are verbatim and land in the unanimous bucket). `byHost`: "<host global>|<reason>" at every consulted site — the join key against the runtime dispatch census. One nested record because the flat stats record is near the 32-slot GC-scan cap.
    , blockedMembers : List ( Int, Maybe Mono.LambdaId ) -- LSS_026 §11 census: every blocked member with its BLOCKER instance (the adopting synthetic closure; Nothing = μ-tie / no attribution). Print-only, never consulted by stamping. The instrument that named `Compiler_Type_Type_lambda_41139` as the 146-site blocker — member IDS shift with the corpus, the SYMBOL is the stable join key, which is why the blocker travels with the id. (It did NOT explain the de-stamp — see §11.5 — but it is what made that refutable.) Cost: one Dict fold over the index per COMPILE, alongside the existing `countMultiInstanceGroups` fold; nothing per site.
    }


{-| All-zero stats (also returned when the pass short-circuits).
-}
emptyStats : AbiCloningStats
emptyStats =
    { dispatchUpgraded = 0
    , stampedPapPrefix = 0
    , stampedStaged = 0
    , declinedBlocked = 0
    , declinedNoInstance = 0
    , declinedShape = 0
    , declinedShapeArity = 0
    , declinedShapeArityZero = 0
    , declinedShapeArityUnder = 0
    , declinedShapeArityOver = 0
    , declinedShapeBucketMiss = 0
    , declinedShapeLayout = 0
    , declinedShapeChar = 0
    , declinedShapeNonArrow = 0
    , declinedAbiMismatch = 0
    , declinedBodyMismatch = 0
    , devirtPost = { fn = 0, ctor = 0, noSpec = 0, partialDeclined = 0 }
    , multiInstanceGroups = 0
    , declineByMember = Dict.empty
    , memberReps = Dict.empty
    , multiSetSiteHist = Dict.empty
    , multiSetMembers = Dict.empty
    , topSiteShapes = Dict.empty
    , varSiteShapes = Dict.empty
    , stampedWrapperInstances = 0
    , instQual = { hist = Dict.empty, divergentGroups = 0, byHost = Dict.empty, flatStamped = 0, shape = Dict.empty }
    , blockedMembers = []
    }



-- ============================================================================
-- ====== INSTANCE INDEX ======
-- ============================================================================


{-| Everything the pass knows about one member's reachable instances.

`blocked = True` when ANY instance shares the member's identity but not
its code: staging-wrapper stages (LSS_008 propagation, synthetic
`Rewriter.wrapperHome`) and adopted synthetic closures (`srcLambda =
Nothing` under a singleton annotation — `wrapTopLevelCallables`
eta-wrappers). A blocked member declines all its sites; its buckets are
dropped (their contents are irrelevant).

`buckets` maps a DEPTH-CAPPED layout fingerprint of (params ++ return) to
the layout GROUPS behind it. A group holds all instances with `eqLayout`-
equal param+return layout; its resolution (representative + capture
unanimity + Char guard) is computed INCREMENTALLY at index time, so a
call site pays integer guards, one bounded fingerprint, one Dict.get and
one full `eqLayout` confirm per group — never a per-site key string over
self-compile-sized types and never a per-site scan of thousand-instance
member lists (the 2026-07-12 profiling findings).

-}
type alias MemberInfo =
    { blocked : Bool
    , blockedBy : Maybe Mono.LambdaId -- census attribution: the ADOPTING/blocking instance's lambdaId (its home names the wrapped def for GlobalOpt wrappers). Nothing for μ-tie blocks (no instance did it) and for unblocked members. Print-only — never consulted by stamping.
    , buckets : Dict String (List LayoutGroup)
    }


{-| All instances sharing one param+return layout. `rep` is the FIRST in
deterministic node-walk order (the stamped representative). `unanimous`
tracks capture-layout agreement across the group; `charFree` tracks the
absence of Char captures (both checked against `rep` as members join).
`paramCount` is denormalized for the integer guard.

`fpUnanimous`/`repFp` are the LSS_024 fingerprint fence: representative
stamps additionally require every joined instance's verbatim-body
fingerprint (`fpOf` — regions omitted, own lambdaIds positionally numbered,
annotations/member ids/SpecIds/CallInfo VERBATIM) to equal `rep`'s.
Fingerprints are computed LAZILY — only when a second DISTINCT lambdaId
joins a group whose stamp is still live (`unanimous && fpUnanimous`), with
`rep`'s memoized in `repFp` — so single-instance groups (the vast majority)
never serialize anything. This replaces LSS_017's id-inequality discharge of
LSS_009's interchangeable-representative premise with a checkable one:
fingerprint-equal, layout-unanimous clones are interchangeable (textual
identity — strictly weaker than the id-inequality premise it replaces).
-}
type alias LayoutGroup =
    { rep : Instance
    , paramCount : Int
    , unanimous : Bool
    , charFree : Bool
    , multi : Bool -- ≥2 DISTINCT lambdaIds joined this group (monitoring — see multiInstanceGroups; the flag-on stamp license is unanimous && fpUnanimous, never this flag)
    , fpUnanimous : Bool -- LSS_024: every instance's fingerprint equals rep's (trivially True single-instance; sticky False; maintained only when the fence is ON — flag-off it stays True and the pass is byte-identical to the pre-LSS_024 tree, INCLUDING the four measured non-verbatim multi-group stamps the fence would decline, see the flag-gating note on abiCloningPass)
    , repFp : Maybe String -- rep's fingerprint, memoized at the first multi join that needs it
    , count : Int -- P0 census only (plans/lss-instance-qualified-members.md §2.1): instances joined into this group. Never consulted by stamping.
    }


type alias Instance =
    { lambdaId : Mono.LambdaId
    , captureTypes : List Mono.MonoType
    , paramTypes : List Mono.MonoType
    , returnType : Mono.MonoType
    , info : Mono.ClosureInfo -- LSS_024 F fence: closure header reference for the lazy fingerprint
    , body : Mono.MonoExpr -- LSS_024 F fence: body reference for the lazy fingerprint

    -- LSS_031: `Just specId` when this instance is a NODE-TOP-LEVEL closure —
    -- one that `Functions.generateNode` emits under
    -- `specIdToFuncName registry specId`, NEVER under its own `lambdaId`.
    -- A stamp naming the lambdaId would then reference a symbol that does not
    -- exist, which is exactly the dangling `_fast_evaluator` LSS_031 records.
    -- `Nothing` for a nested closure: those are queued through
    -- `Expr.pendingLambdas` and DO get a function named by their lambdaId.
    , topLevelSpec : Maybe Mono.SpecId
    }


{-| Fingerprint depth: enough to separate real-world layout families
(collisions only cost an extra eqLayout confirm, never soundness).
-}
fingerprintDepth : Int
fingerprintDepth =
    4


siteFingerprint : List Mono.MonoType -> Mono.MonoType -> String
siteFingerprint params ret =
    String.join "," (List.map (Mono.shallowLayoutKey fingerprintDepth) params)
        ++ "->"
        ++ Mono.shallowLayoutKey fingerprintDepth ret


collectInstances : Bool -> Mono.MonoGraph -> Dict Int MemberInfo
collectInstances fpFence (Mono.MonoGraph record) =
    Tuple.second
        (Array.foldl
            (\maybeNode ( specId, acc ) ->
                case maybeNode of
                    Just node ->
                        -- LSS_031: the node is walked with its SpecId in
                        -- hand, so a top-level closure can record that it is
                        -- emitted under the spec's name. Everything nested
                        -- inside is walked with `Nothing` — those are ordinary
                        -- lambdas named by their lambdaId.
                        ( specId + 1, collectNode fpFence specId node acc )

                    Nothing ->
                        ( specId + 1, acc )
            )
            ( 0, Dict.empty )
            record.nodes
        )


{-| LSS_031: walk a node, recording which of its closures (if any) is emitted
under the SPEC's name rather than under its own lambdaId.

Exactly the three node kinds that route through `Functions.generateDefine` —
`MonoDefine` and the two port kinds — hand their whole expression to
`generateClosureFunc funcName`, so a `MonoClosure` sitting there IS the spec's
function. `MonoTailFunc` must NOT be included: its params are already split
out and its expr is the BODY, so a closure there is an ordinary nested lambda
that `Lambdas.elm` names — attributing the spec to it would swap one wrong
symbol for another.
-}
collectNode : Bool -> Mono.SpecId -> Mono.MonoNode -> Dict Int MemberInfo -> Dict Int MemberInfo
collectNode fpFence specId node acc =
    case node of
        Mono.MonoDefine ((Mono.MonoClosure _ _ _) as expr) _ ->
            collectClosure fpFence (Just specId) expr acc

        Mono.MonoPortIncoming ((Mono.MonoClosure _ _ _) as expr) _ ->
            collectClosure fpFence (Just specId) expr acc

        Mono.MonoPortOutgoing ((Mono.MonoClosure _ _ _) as expr) _ ->
            collectClosure fpFence (Just specId) expr acc

        _ ->
            List.foldl (collectGo fpFence) acc (nodeExprs node)


nodeExprs : Mono.MonoNode -> List Mono.MonoExpr
nodeExprs node =
    case node of
        Mono.MonoDefine expr _ ->
            [ expr ]

        Mono.MonoTailFunc _ expr _ ->
            [ expr ]

        Mono.MonoPortIncoming expr _ ->
            [ expr ]

        Mono.MonoPortOutgoing expr _ ->
            [ expr ]

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []


{-| First-order accumulating walk for the instance index (same de-HOF
rationale as the stamping walk below).
-}
collectGo : Bool -> Mono.MonoExpr -> Dict Int MemberInfo -> Dict Int MemberInfo
collectGo fpFence expr acc =
    case expr of
        Mono.MonoClosure _ _ _ ->
            collectClosure fpFence Nothing expr acc

        _ ->
            collectOther fpFence expr acc


{-| LSS_031: index one closure, recording whether it is a node's TOP-LEVEL
closure (`Just specId`, emitted under the spec name) or a nested one
(`Nothing`, emitted under its lambdaId).
-}
collectClosure : Bool -> Maybe Mono.SpecId -> Mono.MonoExpr -> Dict Int MemberInfo -> Dict Int MemberInfo
collectClosure fpFence topLevelSpec expr acc =
    case expr of
        Mono.MonoClosure closureInfo body tipe ->
            let
                -- LSS_031: `generateNode` emits the spec un-suffixed, so the
                -- spec name is only usable when the emitter would pick the
                -- BARE branch. A top-level definition is closed over globals
                -- only, so this is expected to hold universally; if it ever
                -- does not, fall back rather than invent a `$cap` symbol.
                emittedSpec =
                    if List.isEmpty closureInfo.captures then
                        topLevelSpec

                    else
                        Nothing

                acc1 =
                    case instanceMember closureInfo tipe of
                        Just ( m, isAdopted ) ->
                            if isAdopted || isWrapperHome closureInfo.lambdaId then
                                -- Blocked members never stamp; drop any buckets.
                                Dict.insert m { blocked = True, blockedBy = Just closureInfo.lambdaId, buckets = Dict.empty } acc

                            else
                                Dict.update m
                                    (\present ->
                                        case present of
                                            Just mi ->
                                                if mi.blocked then
                                                    present

                                                else
                                                    Just { mi | buckets = insertInstance fpFence emittedSpec closureInfo body mi.buckets }

                                            Nothing ->
                                                Just { blocked = False, blockedBy = Nothing, buckets = insertInstance fpFence emittedSpec closureInfo body Dict.empty }
                                    )
                                    acc

                        Nothing ->
                            acc

                acc2 =
                    List.foldl (\( _, e, _ ) a -> collectGo fpFence e a) acc1 closureInfo.captures
            in
            collectGo fpFence body acc2

        _ ->
            -- `collectClosure` is only ever called on a closure; this arm
            -- keeps the match total.
            acc


{-| Every non-closure expression form. Split out of `collectGo` by LSS_031 so
the closure arm can take a `Maybe SpecId`.
-}
collectOther : Bool -> Mono.MonoExpr -> Dict Int MemberInfo -> Dict Int MemberInfo
collectOther fpFence expr acc =
    case expr of
        Mono.MonoCall _ func args _ _ ->
            List.foldl (collectGo fpFence) (collectGo fpFence func acc) args

        Mono.MonoTailCall _ args _ ->
            List.foldl (\( _, e ) a -> collectGo fpFence e a) acc args

        Mono.MonoIf branches final _ ->
            collectGo fpFence final (List.foldl (\( c, t ) a -> collectGo fpFence t (collectGo fpFence c a)) acc branches)

        Mono.MonoLet def body _ ->
            collectGo fpFence body (collectGoDef fpFence def acc)

        Mono.MonoDestruct _ inner _ ->
            collectGo fpFence inner acc

        Mono.MonoCase _ _ decider jumps _ ->
            List.foldl (\( _, e ) a -> collectGo fpFence e a) (collectGoDecider fpFence decider acc) jumps

        Mono.MonoList _ items _ ->
            List.foldl (collectGo fpFence) acc items

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> collectGo fpFence e a) acc fields

        Mono.MonoRecordAccess inner _ _ ->
            collectGo fpFence inner acc

        Mono.MonoRecordUpdate record updates _ ->
            List.foldl (\( _, e ) a -> collectGo fpFence e a) (collectGo fpFence record acc) updates

        Mono.MonoTupleCreate _ elements _ ->
            List.foldl (collectGo fpFence) acc elements

        Mono.MonoLiteral _ _ ->
            acc

        Mono.MonoVarLocal _ _ ->
            acc

        Mono.MonoVarGlobal _ _ _ ->
            acc

        Mono.MonoVarKernel _ _ _ _ _ ->
            acc

        Mono.MonoUnit ->
            acc

        Mono.MonoAccessorValue _ _ _ ->
            acc

        Mono.MonoClosure _ _ _ ->
            collectClosure fpFence Nothing expr acc


collectGoDef : Bool -> Mono.MonoDef -> Dict Int MemberInfo -> Dict Int MemberInfo
collectGoDef fpFence def acc =
    case def of
        Mono.MonoDef _ e ->
            collectGo fpFence e acc

        Mono.MonoTailDef _ _ e ->
            collectGo fpFence e acc


collectGoDecider : Bool -> Mono.Decider Mono.MonoChoice -> Dict Int MemberInfo -> Dict Int MemberInfo
collectGoDecider fpFence decider acc =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            collectGo fpFence e acc

        Mono.Leaf (Mono.Jump _) ->
            acc

        Mono.Chain _ success failure ->
            collectGoDecider fpFence failure (collectGoDecider fpFence success acc)

        Mono.FanOut _ edges fallback ->
            collectGoDecider fpFence fallback (List.foldl (\( _, d ) a -> collectGoDecider fpFence d a) acc edges)


insertInstance : Bool -> Maybe Mono.SpecId -> Mono.ClosureInfo -> Mono.MonoExpr -> Dict String (List LayoutGroup) -> Dict String (List LayoutGroup)
insertInstance fpFence emittedSpec closureInfo body buckets =
    let
        paramTypes =
            List.map Tuple.second closureInfo.params

        returnType =
            Mono.typeOf body

        inst =
            { lambdaId = closureInfo.lambdaId
            , captureTypes = List.map (\( _, e, _ ) -> Mono.typeOf e) closureInfo.captures
            , paramTypes = paramTypes
            , returnType = returnType
            , info = closureInfo
            , body = body
            , topLevelSpec = emittedSpec
            }
    in
    Dict.update (siteFingerprint paramTypes returnType)
        (\present -> Just (joinGroup fpFence inst (Maybe.withDefault [] present)))
        buckets


{-| Add an instance to its layout group within a fingerprint bucket (or
start a new group). Group facts update incrementally against `rep`:
capture unanimity and Char-freedom, both with the allocation-free
`eqLayout`. Order of groups and the identity of `rep` follow the
deterministic node walk.
-}
joinGroup : Bool -> Instance -> List LayoutGroup -> List LayoutGroup
joinGroup fpFence inst groups =
    case groups of
        [] ->
            [ { rep = inst
              , paramCount = List.length inst.paramTypes
              , unanimous = True
              , charFree = not (List.any ((==) Mono.MChar) inst.captureTypes)
              , multi = False
              , fpUnanimous = True
              , repFp = Nothing
              , count = 1
              }
            ]

        g :: rest ->
            if sameSignatureLayout g.rep inst then
                if inst.lambdaId == g.rep.lambdaId then
                    { g | unanimous = g.unanimous && sameCaptureLayout g.rep inst, count = g.count + 1 } :: rest

                else
                    -- LSS_024 F fence: a DISTINCT lambdaId joined. Maintain
                    -- fingerprint unanimity LAZILY, and only when the fence
                    -- is ON: both flags are sticky-False and only consulted
                    -- together (a stamp needs unanimous && fpUnanimous), so
                    -- once either is False the serialization is skipped
                    -- entirely; fence off, fpUnanimous stays True and the
                    -- pass behaves exactly as before LSS_024.
                    let
                        uni1 =
                            g.unanimous && sameCaptureLayout g.rep inst

                        ( fpU1, repFp1 ) =
                            if not (fpFence && uni1 && g.fpUnanimous) then
                                ( g.fpUnanimous, g.repFp )

                            else
                                let
                                    rf =
                                        case g.repFp of
                                            Just f ->
                                                f

                                            Nothing ->
                                                fpOf g.rep
                                in
                                ( fpOf inst == rf, Just rf )
                    in
                    { g
                        | unanimous = uni1
                        , multi = True
                        , fpUnanimous = fpU1
                        , repFp = repFp1
                        , count = g.count + 1
                    }
                        :: rest

            else
                g :: joinGroup fpFence inst rest


sameSignatureLayout : Instance -> Instance -> Bool
sameSignatureLayout a b =
    eqLayoutLists a.paramTypes b.paramTypes && Mono.eqLayout a.returnType b.returnType


sameCaptureLayout : Instance -> Instance -> Bool
sameCaptureLayout a b =
    eqLayoutLists a.captureTypes b.captureTypes


eqLayoutLists : List Mono.MonoType -> List Mono.MonoType -> Bool
eqLayoutLists xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: restX, y :: restY ) ->
            Mono.eqLayout x y && eqLayoutLists restX restY

        _ ->
            False


{-| Which member this closure instance counts against, and whether the
identity was ADOPTED rather than stamped.

  - `srcLambda = Just m`: the stamped identity (mono-created instances,
    inliner copies, local-multi retranslations — all verbatim copies —
    plus staging wrapper stages via LSS_008 propagation, separated into
    blockers by their synthetic `lambdaId` home).
  - `srcLambda = Nothing` but the type's head annotation is a singleton
    `LSet [m]`: identity adoption (LSS_008) — GlobalOpt-synthesized
    closures (alias/general wrappers from wrapTopLevelCallables) carry no
    provenance stamp, yet their TYPE claims exactly one member, so the
    value can impersonate it at singleton call sites. They block the
    member. (`SrcLambdaId` is an opaque supply-only Id, so adoption
    happens here in the index rather than by stamping the ClosureInfo.)
  - `srcLambda = Nothing` with LTop / multi-member annotation: not
    indexed. Such a value can only flow to sites whose sets are at least
    as wide, and v1 never stamps non-singleton sites.

-}
instanceMember : Mono.ClosureInfo -> Mono.MonoType -> Maybe ( Int, Bool )
instanceMember closureInfo tipe =
    -- Fix B (LSS_017): prefer the minted-under member id — spec-qualified for
    -- keyed-routed globals — so the index lives in the SAME id space as the
    -- set annotations the call sites carry. The raw srcLambda fallback only
    -- serves graphs minted without the stamp (lss off — pass inert anyway).
    case closureInfo.lssMember of
        Just m ->
            Just ( m, False )

        Nothing ->
            case closureInfo.srcLambda of
                Just m ->
                    Just ( Id.toComparable m, False )

                Nothing ->
                    Maybe.map (\m -> ( m, True )) (Mono.singletonHeadMember tipe)


isWrapperHome : Mono.LambdaId -> Bool
isWrapperHome (Mono.AnonymousLambda home _) =
    home == Rewriter.wrapperHome


-- ============================================================================
-- ====== PUBLIC API ======
-- ============================================================================


type alias StampCtx =
    { kindIds : Dict Int Int -- member id -> ClosureKindId int
    , nextKind : Int
    , stats : AbiCloningStats

    -- E9.5 post-settle devirt (plans/lss-post-settle-fn-global-devirt.md
    -- §3). `origins` resolves a noInstance singleton's member id to its
    -- standalone target; `specsByGlobal` is the registry inversion the
    -- eqLayout spec match reads (family gkey -> (SpecId int, spec type)
    -- pairs). Both are Dict.empty when the flag is off, so the flag-off
    -- pass carries only two never-consulted empty-dict fields.
    , postSettle : Bool
    , origins : Dict Int Mono.MemberOrigin
    , specsByGlobal : Dict String (List ( Int, Mono.MonoType ))

    -- Fix A (plan §15.1): peel an over-applying site's curried callee type to
    -- its own arg count before matching. Flag-gated because it changes WHICH
    -- sites get stamped, hence CallInfo, hence emitted MLIR.
    , flatPeel : Bool

    -- P0 census: the global whose spec the walk is currently inside, so a
    -- decline can be attributed to the HOST function (`elm/core:Dict.foldl`)
    -- rather than to an anonymous member id. Set per node from the registry's
    -- SpecId-indexed `reverseMapping`; "?" when the node has no entry.
    , hostGlobal : String
    }


{-| Run the ABI cloning pass on a MonoGraph.

With LSS off (or no singleton sets), the instance index is empty and the
graph is returned untouched — the pass is inert by construction, so the
flag-off pipeline stays byte-identical.

`fpFence` (LSS_024, = `lss.layoutQualMembers`): when True, representative
stamps additionally require verbatim-body fingerprint unanimity across the
layout group (`bodyMismatch` decline otherwise). The fence is FLAG-GATED
rather than unconditional by a MEASURED decision (2026-08-21, the plan's
§4.5 gate): the default tree holds exactly FOUR multi groups whose
instances are NOT verbatim — local-multi twins in `Dict.map` specs whose
fingerprints differ only by a sibling qualified-member id (`A[34133]` vs
`A[34134]`) or by annotation PRECISION on a capture type (`A[18467]` vs
`A(` LTop) — and today's LSS_017 id-inequality doctrine stamps them.
Fencing them flag-off would change default artifacts (−4 staged stamps),
so flag-off keeps HEAD's exact behavior (byte-identity gate PASSES) and
the fence applies exactly where LSS_024's id sharing makes it load-bearing.
Those four stamps are a recorded flip-time delta: at any default flip of
`lss.layoutQualMembers` they become `bodyMismatch` declines, with the
soundness rationale on their side (textual-identity doctrine; the id
congruence that could re-admit the sibling-id pair is the plan's parked
v2, never to be improvised in).

-}
abiCloningPass : Bool -> Bool -> Bool -> Mono.MonoGraph -> ( Mono.MonoGraph, AbiCloningStats )
abiCloningPass fpFence postSettle flatPeel ((Mono.MonoGraph record) as graph) =
    let
        -- LSS_018: μ-tied members are force-blocked — their instances span
        -- DIFFERENT demands of one recursive family (behaviorally divergent;
        -- the §11.6 hijack class), so they must never rep-stamp. Blocking at
        -- the index (not stripping `lssMember` at the instance) is the only
        -- sound shape per LSS_008: sites decline into generic dispatch and
        -- count under `declinedBlocked`.
        index =
            Dict.foldl
                (\m () acc -> Dict.insert m { blocked = True, blockedBy = Nothing, buckets = Dict.empty } acc)
                (collectInstances fpFence graph)
                record.lssBlockedMembers
    in
    if Dict.isEmpty index && not postSettle then
        -- Inert-by-construction fast exit (LSS off / no singleton members).
        -- E9.5: flag-on proceeds even with an empty closure index — the
        -- post-settle rewrite consults the ORIGINS/registry, not instances
        -- (a graph can hold devirtable g|/c| singletons and no closures).
        ( graph, emptyStats )

    else
        let
            -- Fix B probe: count multi-instance groups up front (index-time
            -- fact, independent of stamping outcomes).
            groupCensus =
                instQualGroupCensus index

            stats0 =
                { emptyStats

                    | multiInstanceGroups = countMultiInstanceGroups index
                    , instQual = { hist = groupCensus.hist, divergentGroups = groupCensus.divergentGroups, byHost = Dict.empty, flatStamped = 0, shape = Dict.empty }
                    , blockedMembers =
                        Dict.foldr
                            (\m mi acc ->
                                if mi.blocked then
                                    ( m, mi.blockedBy ) :: acc

                                else
                                    acc
                            )
                            []
                            index
                }

            -- E9.5: the registry inversion for the post-settle spec match —
            -- one pass over reverseMapping, flag-on only. SpecId ints come
            -- from the array index (reverseMapping is SpecId-indexed), so
            -- ascending fold order means each family list is DESCENDING by
            -- SpecId; the consumer takes the MINIMUM match, order-free.
            specsByGlobal =
                if postSettle then
                    Tuple.second
                        (Array.foldl
                            (\maybeEntry ( i, acc ) ->
                                case maybeEntry of
                                    Just ( global, specType ) ->
                                        ( i + 1
                                        , Dict.update (Mono.toComparableGlobal global)
                                            (\v -> Just (( i, specType ) :: Maybe.withDefault [] v))
                                            acc
                                        )

                                    Nothing ->
                                        ( i + 1, acc )
                            )
                            ( 0, Dict.empty )
                            record.registry.reverseMapping
                        )

                else
                    Dict.empty

            -- P0 census: the walk is SpecId-indexed (nodes and
            -- reverseMapping share the index), so the host global is one
            -- array read per node — cheap enough to be unconditional, like
            -- every other census map in this record.
            ( ( nodes1, _ ), finalCtx ) =
                Array.foldl
                    (\maybeNode ( ( accNodes, specId ), accCtx ) ->
                        case maybeNode of
                            Just node ->
                                let
                                    ( newNode, ctx1 ) =
                                        stampNode index { accCtx | hostGlobal = hostGlobalAt record.registry.reverseMapping specId } node
                                in
                                ( ( Array.push (Just newNode) accNodes, specId + 1 ), ctx1 )

                            Nothing ->
                                ( ( Array.push Nothing accNodes, specId + 1 ), accCtx )
                    )
                    ( ( Array.empty, 0 )
                    , { kindIds = Dict.empty
                      , nextKind = 0
                      , stats = stats0
                      , postSettle = postSettle
                      , origins =
                            if postSettle then
                                record.lssMemberOrigins

                            else
                                Dict.empty
                      , specsByGlobal = specsByGlobal
                      , flatPeel = flatPeel
                      , hostGlobal = "?"
                      }
                    )
                    record.nodes
        in
        ( Mono.MonoGraph { record | nodes = nodes1 }, finalCtx.stats )


{-| P0 census: the global a SpecId belongs to, for decline attribution.
-}
hostGlobalAt : Array.Array (Maybe ( Mono.Global, Mono.MonoType )) -> Int -> String
hostGlobalAt reverseMapping specId =
    case Array.get specId reverseMapping of
        Just (Just ( global, _ )) ->
            Mono.toComparableGlobal global

        _ ->
            "?"


{-| P0 census (plans/lss-instance-qualified-members.md §2.1): the layout-group
instance histogram, plus the count of FINGERPRINT-DIVERGENT groups.

A divergent group (`multi && not fpUnanimous`) is one member id indexing two
behaviourally different bodies. Because the member id already carries the
source lambda and the enclosing spec (LSS_017/LSS_024), divergence implies the
bodies came from ONE source lambda re-translated per local-multi instance —
inliner copies are verbatim and stay unanimous. That is the population this
plan's instance qualification splits, and its size is the go/no-go number.

Keys: `"<n>"` for a group of n instances, `"div<n>"` for a divergent one.
-}
instQualGroupCensus : Dict Int MemberInfo -> { hist : Dict String Int, divergentGroups : Int }
instQualGroupCensus index =
    Dict.foldl
        (\_ mi acc ->
            Dict.foldl
                (\_ groups acc2 ->
                    List.foldl
                        (\g a ->
                            let
                                divergent =
                                    g.multi && not g.fpUnanimous
                            in
                            { hist =
                                bumpDictStr
                                    (if divergent then
                                        "div" ++ String.fromInt g.count

                                     else
                                        String.fromInt g.count
                                    )
                                    a.hist
                            , divergentGroups =
                                if divergent then
                                    a.divergentGroups + 1

                                else
                                    a.divergentGroups
                            }
                        )
                        acc2
                        groups
                )
                acc
                mi.buckets
        )
        { hist = Dict.empty, divergentGroups = 0 }
        index


countMultiInstanceGroups : Dict Int MemberInfo -> Int
countMultiInstanceGroups index =
    Dict.foldl
        (\_ mi acc ->
            Dict.foldl
                (\_ groups acc2 ->
                    List.foldl
                        (\g a ->
                            if g.multi then
                                a + 1

                            else
                                a
                        )
                        acc2
                        groups
                )
                acc
                mi.buckets
        )
        0
        index


stampNode : Dict Int MemberInfo -> StampCtx -> Mono.MonoNode -> ( Mono.MonoNode, StampCtx )
stampNode index ctx node =
    case node of
        Mono.MonoDefine expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    stampExprTree index ctx expr
            in
            ( Mono.MonoDefine newExpr tipe, ctx1 )

        Mono.MonoTailFunc params expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    stampExprTree index ctx expr
            in
            ( Mono.MonoTailFunc params newExpr tipe, ctx1 )

        Mono.MonoPortIncoming expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    stampExprTree index ctx expr
            in
            ( Mono.MonoPortIncoming newExpr tipe, ctx1 )

        Mono.MonoPortOutgoing expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    stampExprTree index ctx expr
            in
            ( Mono.MonoPortOutgoing newExpr tipe, ctx1 )

        other ->
            ( other, ctx )


{-| Stamp one node body. The walk is FIRST-ORDER on purpose (2026-07-12
self-compile profiling): the generic `MonoTraverse` combinators route every
recursive step through the runtime's generic closure apply
(`invokeSaturatedTyped`), which multiplies into minutes at 10^6-expression
scale — the same lesson the solver engine's D11/A5 de-HOF rewrites
recorded. `scanExpr` is an early-exit candidate probe (a `foldExpr` cannot
stop early); nodes without a candidate site pass through UNTOUCHED (no
rebuild, no allocation). Only candidate-bearing nodes are rebuilt by the
direct `goExpr` recursion.
-}
stampExprTree : Dict Int MemberInfo -> StampCtx -> Mono.MonoExpr -> ( Mono.MonoExpr, StampCtx )
stampExprTree index ctx expr =
    if scanExpr index expr then
        goExpr index ctx expr

    else
        ( expr, ctx )


{-| Early-exit candidate probe: does this tree contain a call whose callee
head annotation is a singleton set? Allocation-free.
-}
scanExpr : Dict Int MemberInfo -> Mono.MonoExpr -> Bool
scanExpr index expr =
    case expr of
        Mono.MonoCall _ func args _ _ ->
            isSingletonHead func || scanExpr index func || List.any (scanExpr index) args

        Mono.MonoClosure info body _ ->
            List.any (\( _, e, _ ) -> scanExpr index e) info.captures || scanExpr index body

        Mono.MonoTailCall _ args _ ->
            List.any (\( _, e ) -> scanExpr index e) args

        Mono.MonoIf branches final _ ->
            List.any (\( c, t ) -> scanExpr index c || scanExpr index t) branches || scanExpr index final

        Mono.MonoLet def body _ ->
            scanDef index def || scanExpr index body

        Mono.MonoDestruct _ inner _ ->
            scanExpr index inner

        Mono.MonoCase _ _ decider jumps _ ->
            scanDecider index decider || List.any (\( _, e ) -> scanExpr index e) jumps

        Mono.MonoList _ items _ ->
            List.any (scanExpr index) items

        Mono.MonoRecordCreate fields _ ->
            List.any (\( _, e ) -> scanExpr index e) fields

        Mono.MonoRecordAccess inner _ _ ->
            scanExpr index inner

        Mono.MonoRecordUpdate record updates _ ->
            scanExpr index record || List.any (\( _, e ) -> scanExpr index e) updates

        Mono.MonoTupleCreate _ elements _ ->
            List.any (scanExpr index) elements

        Mono.MonoLiteral _ _ ->
            False

        Mono.MonoVarLocal _ _ ->
            False

        Mono.MonoVarGlobal _ _ _ ->
            False

        Mono.MonoVarKernel _ _ _ _ _ ->
            False

        Mono.MonoUnit ->
            False

        Mono.MonoAccessorValue _ _ _ ->
            False


isSingletonHead : Mono.MonoExpr -> Bool
isSingletonHead func =
    case Mono.headAnno (Mono.typeOf func) of
        Mono.LSet [ _ ] ->
            True

        _ ->
            False


scanDef : Dict Int MemberInfo -> Mono.MonoDef -> Bool
scanDef index def =
    case def of
        Mono.MonoDef _ e ->
            scanExpr index e

        Mono.MonoTailDef _ _ e ->
            scanExpr index e


scanDecider : Dict Int MemberInfo -> Mono.Decider Mono.MonoChoice -> Bool
scanDecider index decider =
    case decider of
        Mono.Leaf choice ->
            scanChoice index choice

        Mono.Chain _ success failure ->
            scanDecider index success || scanDecider index failure

        Mono.FanOut _ edges fallback ->
            List.any (\( _, d ) -> scanDecider index d) edges || scanDecider index fallback


scanChoice : Dict Int MemberInfo -> Mono.MonoChoice -> Bool
scanChoice index choice =
    case choice of
        Mono.Inline e ->
            scanExpr index e

        Mono.Jump _ ->
            False


{-| Direct bottom-up stamping recursion (children first, then the node
itself). Mirrors `MonoTraverse.traverseExprChildren`'s constructor
coverage exactly; every recursive call is saturated and first-order.
-}
goExpr : Dict Int MemberInfo -> StampCtx -> Mono.MonoExpr -> ( Mono.MonoExpr, StampCtx )
goExpr index ctx expr =
    case expr of
        Mono.MonoCall region func args resultType callInfo ->
            let
                ( newFunc, ctx1 ) =
                    goExpr index ctx func

                ( newArgs, ctx2 ) =
                    goList index ctx1 args
            in
            stampCall index ctx2 region newFunc newArgs resultType callInfo

        Mono.MonoClosure info body closureType ->
            let
                ( newCaptures, ctx1 ) =
                    goCaptures index ctx info.captures

                ( newBody, ctx2 ) =
                    goExpr index ctx1 body
            in
            ( Mono.MonoClosure { info | captures = newCaptures } newBody closureType, ctx2 )

        Mono.MonoTailCall name args resultType ->
            let
                ( newArgs, ctx1 ) =
                    goNamedList index ctx args
            in
            ( Mono.MonoTailCall name newArgs resultType, ctx1 )

        Mono.MonoIf branches final resultType ->
            let
                ( newBranches, ctx1 ) =
                    goBranches index ctx branches

                ( newFinal, ctx2 ) =
                    goExpr index ctx1 final
            in
            ( Mono.MonoIf newBranches newFinal resultType, ctx2 )

        Mono.MonoLet def body resultType ->
            let
                ( newDef, ctx1 ) =
                    goDef index ctx def

                ( newBody, ctx2 ) =
                    goExpr index ctx1 body
            in
            ( Mono.MonoLet newDef newBody resultType, ctx2 )

        Mono.MonoDestruct path inner resultType ->
            let
                ( newInner, ctx1 ) =
                    goExpr index ctx inner
            in
            ( Mono.MonoDestruct path newInner resultType, ctx1 )

        Mono.MonoCase label scrutinee decider jumps resultType ->
            let
                ( newDecider, ctx1 ) =
                    goDecider index ctx decider

                ( newJumps, ctx2 ) =
                    goJumps index ctx1 jumps
            in
            ( Mono.MonoCase label scrutinee newDecider newJumps resultType, ctx2 )

        Mono.MonoList region items resultType ->
            let
                ( newItems, ctx1 ) =
                    goList index ctx items
            in
            ( Mono.MonoList region newItems resultType, ctx1 )

        Mono.MonoRecordCreate fields resultType ->
            let
                ( newFields, ctx1 ) =
                    goNamedList index ctx fields
            in
            ( Mono.MonoRecordCreate newFields resultType, ctx1 )

        Mono.MonoRecordAccess inner field resultType ->
            let
                ( newInner, ctx1 ) =
                    goExpr index ctx inner
            in
            ( Mono.MonoRecordAccess newInner field resultType, ctx1 )

        Mono.MonoRecordUpdate record updates resultType ->
            let
                ( newRecord, ctx1 ) =
                    goExpr index ctx record

                ( newUpdates, ctx2 ) =
                    goNamedList index ctx1 updates
            in
            ( Mono.MonoRecordUpdate newRecord newUpdates resultType, ctx2 )

        Mono.MonoTupleCreate region elements resultType ->
            let
                ( newElements, ctx1 ) =
                    goList index ctx elements
            in
            ( Mono.MonoTupleCreate region newElements resultType, ctx1 )

        Mono.MonoLiteral _ _ ->
            ( expr, ctx )

        Mono.MonoVarLocal _ _ ->
            ( expr, ctx )

        Mono.MonoVarGlobal _ _ _ ->
            ( expr, ctx )

        Mono.MonoVarKernel _ _ _ _ _ ->
            ( expr, ctx )

        Mono.MonoUnit ->
            ( expr, ctx )

        Mono.MonoAccessorValue _ _ _ ->
            ( expr, ctx )


goList : Dict Int MemberInfo -> StampCtx -> List Mono.MonoExpr -> ( List Mono.MonoExpr, StampCtx )
goList index ctx items =
    case items of
        [] ->
            ( [], ctx )

        e :: rest ->
            let
                ( e1, ctx1 ) =
                    goExpr index ctx e

                ( rest1, ctx2 ) =
                    goList index ctx1 rest
            in
            ( e1 :: rest1, ctx2 )


goNamedList : Dict Int MemberInfo -> StampCtx -> List ( a, Mono.MonoExpr ) -> ( List ( a, Mono.MonoExpr ), StampCtx )
goNamedList index ctx items =
    case items of
        [] ->
            ( [], ctx )

        ( n, e ) :: rest ->
            let
                ( e1, ctx1 ) =
                    goExpr index ctx e

                ( rest1, ctx2 ) =
                    goNamedList index ctx1 rest
            in
            ( ( n, e1 ) :: rest1, ctx2 )


goCaptures : Dict Int MemberInfo -> StampCtx -> List ( a, Mono.MonoExpr, b ) -> ( List ( a, Mono.MonoExpr, b ), StampCtx )
goCaptures index ctx items =
    case items of
        [] ->
            ( [], ctx )

        ( n, e, t ) :: rest ->
            let
                ( e1, ctx1 ) =
                    goExpr index ctx e

                ( rest1, ctx2 ) =
                    goCaptures index ctx1 rest
            in
            ( ( n, e1, t ) :: rest1, ctx2 )


goBranches : Dict Int MemberInfo -> StampCtx -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> ( List ( Mono.MonoExpr, Mono.MonoExpr ), StampCtx )
goBranches index ctx branches =
    case branches of
        [] ->
            ( [], ctx )

        ( c, t ) :: rest ->
            let
                ( c1, ctx1 ) =
                    goExpr index ctx c

                ( t1, ctx2 ) =
                    goExpr index ctx1 t

                ( rest1, ctx3 ) =
                    goBranches index ctx2 rest
            in
            ( ( c1, t1 ) :: rest1, ctx3 )


goJumps : Dict Int MemberInfo -> StampCtx -> List ( Int, Mono.MonoExpr ) -> ( List ( Int, Mono.MonoExpr ), StampCtx )
goJumps =
    goNamedList


goDef : Dict Int MemberInfo -> StampCtx -> Mono.MonoDef -> ( Mono.MonoDef, StampCtx )
goDef index ctx def =
    case def of
        Mono.MonoDef name e ->
            let
                ( e1, ctx1 ) =
                    goExpr index ctx e
            in
            ( Mono.MonoDef name e1, ctx1 )

        Mono.MonoTailDef name params e ->
            let
                ( e1, ctx1 ) =
                    goExpr index ctx e
            in
            ( Mono.MonoTailDef name params e1, ctx1 )


goDecider : Dict Int MemberInfo -> StampCtx -> Mono.Decider Mono.MonoChoice -> ( Mono.Decider Mono.MonoChoice, StampCtx )
goDecider index ctx decider =
    case decider of
        Mono.Leaf choice ->
            let
                ( c1, ctx1 ) =
                    goChoice index ctx choice
            in
            ( Mono.Leaf c1, ctx1 )

        Mono.Chain testChain success failure ->
            let
                ( s1, ctx1 ) =
                    goDecider index ctx success

                ( f1, ctx2 ) =
                    goDecider index ctx1 failure
            in
            ( Mono.Chain testChain s1 f1, ctx2 )

        Mono.FanOut path edges fallback ->
            let
                ( edges1, ctx1 ) =
                    goEdges index ctx edges

                ( fb1, ctx2 ) =
                    goDecider index ctx1 fallback
            in
            ( Mono.FanOut path edges1 fb1, ctx2 )


goEdges : Dict Int MemberInfo -> StampCtx -> List ( a, Mono.Decider Mono.MonoChoice ) -> ( List ( a, Mono.Decider Mono.MonoChoice ), StampCtx )
goEdges index ctx edges =
    case edges of
        [] ->
            ( [], ctx )

        ( t, d ) :: rest ->
            let
                ( d1, ctx1 ) =
                    goDecider index ctx d

                ( rest1, ctx2 ) =
                    goEdges index ctx1 rest
            in
            ( ( t, d1 ) :: rest1, ctx2 )


goChoice : Dict Int MemberInfo -> StampCtx -> Mono.MonoChoice -> ( Mono.MonoChoice, StampCtx )
goChoice index ctx choice =
    case choice of
        Mono.Inline e ->
            let
                ( e1, ctx1 ) =
                    goExpr index ctx e
            in
            ( Mono.Inline e1, ctx1 )

        Mono.Jump _ ->
            ( choice, ctx )


{-| The per-call stamping decision (children already rebuilt).
-}
stampCall : Dict Int MemberInfo -> StampCtx -> Region -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Mono.CallInfo -> ( Mono.MonoExpr, StampCtx )
stampCall index ctx region func args resultType callInfo =
    case Mono.headAnno (Mono.typeOf func) of
        Mono.LSet [ m ] ->
            case Dict.get m index of
                Just memberInfo ->
                    case resolveRepresentative ctx.flatPeel (Mono.typeOf func) (List.length args) memberInfo of
                        Stamp inst ->
                            let
                                ( kindId, ctx1 ) =
                                    kindIdFor m ctx

                                stamped =
                                    { callInfo
                                        | closureKind = Just (Mono.Known (Mono.ClosureKindId kindId))
                                        , captureAbi =
                                            Just
                                                { captureTypes = inst.captureTypes
                                                , paramTypes = inst.paramTypes
                                                , returnType = inst.returnType
                                                }
                                        , fastEvaluator = Just inst.lambdaId
                                        , fastEvaluatorSpec = inst.topLevelSpec
                                    }

                                stats1 =
                                    ctx1.stats

                                -- census (E7 trigger): a stamped wrapper rep.
                                wrapperInc =
                                    if isWrapperHome inst.lambdaId then
                                        1

                                    else
                                        0
                            in
                            ( Mono.MonoCall region func args resultType stamped
                            , bumpHost "stamped"
                                { ctx1
                                    | stats =
                                        { stats1
                                            | dispatchUpgraded = stats1.dispatchUpgraded + 1
                                            , stampedWrapperInstances = stats1.stampedWrapperInstances + wrapperInc
                                        }
                                }
                            )

                        StampFlat inst ->
                            -- Fix A: identical stamp to the exact arm. The
                            -- site applies argCount args and the instance
                            -- takes argCount params, so `Expr.fastDispatchStamp`
                            -- (which compares |args| against
                            -- |captureAbi.paramTypes| and NEVER looks at the
                            -- callee's curried type) matches and emits
                            -- `singleton_fast`. `generateStagedFastDispatchCall`
                            -- is not reached — this is not a staged call.
                            let
                                ( kindIdF, ctxF ) =
                                    kindIdFor m ctx

                                statsF =
                                    ctxF.stats

                                iqF =
                                    statsF.instQual
                            in
                            ( Mono.MonoCall region
                                func
                                args
                                resultType
                                { callInfo
                                    | closureKind = Just (Mono.Known (Mono.ClosureKindId kindIdF))
                                    , captureAbi =
                                        Just
                                            { captureTypes = inst.captureTypes
                                            , paramTypes = inst.paramTypes
                                            , returnType = inst.returnType
                                            }
                                    , fastEvaluator = Just inst.lambdaId
                                    , fastEvaluatorSpec = inst.topLevelSpec
                                }
                            , bumpHost "stampedFlat"
                                { ctxF
                                    | stats =
                                        { statsF
                                            | dispatchUpgraded = statsF.dispatchUpgraded + 1
                                            , instQual = { iqF | flatStamped = iqF.flatStamped + 1 }
                                        }
                                }
                            )

                        StampPap inst k ->
                            -- E2 (LSS_011): the flowing value is inst's PAP
                            -- holding k applied args. Its filled value slots
                            -- are [captures…, k args…] in slot order, so the
                            -- merged captureAbi makes the unchanged fast
                            -- lowering load exactly the filled prefix and
                            -- call the SAME clone with the full argument row.
                            -- fastPapPrefix = Just k is part of the stamp and
                            -- MUST survive to emission (annotateCallStaging
                            -- preserves it with the other stamp fields) — the
                            -- bare-vs-$cap symbol choice subtracts it from
                            -- |captureTypes|.
                            let
                                ( kindId, ctx1 ) =
                                    kindIdFor m ctx

                                stamped =
                                    { callInfo
                                        | closureKind = Just (Mono.Known (Mono.ClosureKindId kindId))
                                        , captureAbi =
                                            Just
                                                { captureTypes = inst.captureTypes ++ List.take k inst.paramTypes
                                                , paramTypes = List.drop k inst.paramTypes
                                                , returnType = inst.returnType
                                                }
                                        , fastEvaluator = Just inst.lambdaId
                                        , fastEvaluatorSpec = inst.topLevelSpec
                                        , fastPapPrefix = Just k
                                    }

                                stats1 =
                                    ctx1.stats
                            in
                            ( Mono.MonoCall region func args resultType stamped
                            , { ctx1 | stats = { stats1 | stampedPapPrefix = stats1.stampedPapPrefix + 1 } }
                            )

                        StampStaged inst ->
                            -- E2.7 (LSS_014): over-applying site whose FIRST
                            -- stage matches the instance exactly. Stamp the
                            -- SAME fields as the exact arm (the instance row
                            -- verbatim; fastPapPrefix stays Nothing) —
                            -- emission detects stagedness as
                            -- |args| > |captureAbi.paramTypes| and splits:
                            -- fast batch 1, then a generic
                            -- segmentation-unknown application of the
                            -- remainder to the intermediate.
                            let
                                ( kindId, ctx1 ) =
                                    kindIdFor m ctx

                                stamped =
                                    { callInfo
                                        | closureKind = Just (Mono.Known (Mono.ClosureKindId kindId))
                                        , captureAbi =
                                            Just
                                                { captureTypes = inst.captureTypes
                                                , paramTypes = inst.paramTypes
                                                , returnType = inst.returnType
                                                }
                                        , fastEvaluator = Just inst.lambdaId
                                        , fastEvaluatorSpec = inst.topLevelSpec
                                    }

                                stats1 =
                                    ctx1.stats
                            in
                            ( Mono.MonoCall region func args resultType stamped
                            , { ctx1 | stats = { stats1 | stampedStaged = stats1.stampedStaged + 1 } }
                            )

                        Decline reason bump ->
                            -- census: attribute the decline to the member and
                            -- capture its group reps (the runtime-join key),
                            -- and (P0) to the HOST global with its reason.
                            let
                                ctxB =
                                    bumpShape (Mono.typeOf func) (List.length args) reason (bumpHost reason (bump ctx))

                                statsB =
                                    ctxB.stats
                            in
                            ( Mono.MonoCall region func args resultType callInfo
                            , { ctxB
                                | stats =
                                    { statsB
                                        | declineByMember = bumpDict m statsB.declineByMember
                                        , memberReps = Dict.insert m (memberRepsOf memberInfo) statsB.memberReps
                                    }
                              }
                            )

                Nothing ->
                    -- E9.5 (plans/lss-post-settle-fn-global-devirt.md §3):
                    -- the member has NO closure instance. For standalone
                    -- g|/c| members that is definitional (function globals
                    -- and ctors have no MonoClosure), and the singleton +
                    -- plain-var callee + EXACT-arity guards prove the
                    -- runtime value is the BARE global/ctor — zero captures
                    -- — so a direct call to any eqLayout-matching spec of
                    -- the target is observably equivalent (LSS_005; the E11
                    -- hijack class needs a capture record and cannot arise
                    -- capture-free). Commit-after-settle: annotations are
                    -- final here, so this catches exactly the sites
                    -- translate-time E9/E9.1 committed too early to see.
                    case postSettleTarget m func (List.length args) ctx of
                        PsStamp specId isCtor ->
                            let
                                stats1 =
                                    ctx.stats

                                stats2 =
                                    if isCtor then
                                        (let
                                            dp1 =
                                                stats1.devirtPost
                                         in
                                         { stats1 | devirtPost = { dp1 | ctor = dp1.ctor + 1 } }
                                        )

                                    else
                                        (let
                                            dp1 =
                                                stats1.devirtPost
                                         in
                                         { stats1 | devirtPost = { dp1 | fn = dp1.fn + 1 } }
                                        )
                            in
                            ( Mono.MonoCall region
                                (Mono.MonoVarGlobal region specId (Mono.typeOf func))
                                args
                                resultType
                                callInfo
                            , { ctx | stats = stats2 }
                            )

                        PsNoSpec ->
                            -- Candidate passed every guard but no registry
                            -- spec eqLayout-matched (census expectation ~0).
                            let
                                statsN =
                                    ctx.stats
                            in
                            ( Mono.MonoCall region func args resultType callInfo
                            , bumpHost "noInstanceNoSpec"
                                (bumpNoInstance
                                    (let
                                        dpN =
                                            statsN.devirtPost
                                     in
                                     { ctx | stats = { statsN | devirtPost = { dpN | noSpec = dpN.noSpec + 1 } } }
                                    )
                                )
                            )

                        PsNotCandidate ->
                            -- P0 census: noInstance is the single biggest
                            -- decline class (45.5 % on the self-compile), so it
                            -- gets host attribution too.
                            ( Mono.MonoCall region func args resultType callInfo, bumpHost "noInstance" (bumpNoInstance ctx) )

        Mono.LSet ms ->
            -- census (E3 de-risk): a consulted site carrying a MULTI-member
            -- set — |set| histogram + per-member occurrences (+ reps for the
            -- runtime join, when the member has instances in the index).
            let
                stats0 =
                    ctx.stats

                statsMembers =
                    List.foldl
                        (\mid acc ->
                            { acc
                                | multiSetMembers = bumpDict mid acc.multiSetMembers
                                , memberReps =
                                    case Dict.get mid index of
                                        Just mi ->
                                            Dict.insert mid (memberRepsOf mi) acc.memberReps

                                        Nothing ->
                                            acc.memberReps
                            }
                        )
                        { stats0 | multiSetSiteHist = bumpDict (List.length ms) stats0.multiSetSiteHist }
                        ms
            in
            ( Mono.MonoCall region func args resultType callInfo
            , bumpHost ("multi" ++ String.fromInt (List.length ms)) { ctx | stats = statsMembers }
            )

        Mono.LTop _ ->
            -- census (E8 split): an unknowable-callee site — classify the
            -- callee expression shape (escape proxy).
            let
                stats0 =
                    ctx.stats
            in
            ( Mono.MonoCall region func args resultType callInfo
            , { ctx | stats = { stats0 | topSiteShapes = bumpDictStr (calleeShape func) stats0.topSiteShapes } }
            )

        Mono.LPartial _ ->
            -- AR-P2 (lss-lpartial §3), THE devirt guard: a LOWER bound is
            -- never a singleton — stamping it would direct-call one member
            -- while an unrecorded inhabitant may exist (the arrowSolverRoots
            -- false-singleton class). NON-STAMP, censused so the guard is
            -- observable.
            let
                stats0p =
                    ctx.stats
            in
            ( Mono.MonoCall region func args resultType callInfo
            , (let
                dp0 =
                    stats0p.devirtPost
               in
               { ctx | stats = { stats0p | devirtPost = { dp0 | partialDeclined = dp0.partialDeclined + 1 } } }
              )
            )

        Mono.LVar _ ->
            -- Same NON-STAMP as LTop — a variable names no members, so there is
            -- nothing to devirtualize — but censused separately so the ⊤-site
            -- population stays split into "widened" and "still a variable"
            -- (plans/lss-unknown-elimination.md §2.5).
            --
            -- TRAP, previously recorded: `stampCall` consults EVERY call, so
            -- both of these are SITE censuses, not dispatch weight.
            let
                stats0 =
                    ctx.stats
            in
            ( Mono.MonoCall region func args resultType callInfo
            , { ctx | stats = { stats0 | varSiteShapes = bumpDictStr (calleeShape func) stats0.varSiteShapes } }
            )


{-| Plan §17.4 step 0: for an OVER-APPLYING decline, record
`"<firstStageArity>-><argCount>|<peelOutcome>"`.

This is what sizes Fix A. `exact` means the peel lands on the arg count and the
flattened match is at least POSSIBLE (the bucket may still miss); `miss` means
the type runs out of arrow or a stage overshoots, and no amount of peeling can
help that site. Recorded on declines only, which flag-off is all of them.
-}
bumpShape : Mono.MonoType -> Int -> String -> StampCtx -> StampCtx
bumpShape calleeType argCount reason ctx =
    case calleeType of
        Mono.MFunction _ _ fargs _ ->
            if argCount <= List.length fargs then
                ctx

            else
                let
                    key =
                        String.fromInt (List.length fargs)
                            ++ "->"
                            ++ String.fromInt argCount
                            ++ "|"
                            ++ (case peelStages argCount calleeType of
                                    Just _ ->
                                        "exact"

                                    Nothing ->
                                        "miss"
                               )
                            ++ "|"
                            ++ reason

                    st =
                        ctx.stats

                    iq =
                        st.instQual
                in
                { ctx | stats = { st | instQual = { iq | shape = bumpDictStr key iq.shape } } }

        _ ->
            ctx


{-| P0 census: attribute one consulted site to its HOST global and outcome —
`"elm/core:Dict.foldl|bodyMismatch"`. The host is what joins to the runtime
dispatch census; a member id does not survive a recompile, a global does.
-}
bumpHost : String -> StampCtx -> StampCtx
bumpHost outcome ctx =
    let
        st =
            ctx.stats

        iq =
            st.instQual
    in
    { ctx | stats = { st | instQual = { iq | byHost = bumpDictStr (ctx.hostGlobal ++ "|" ++ outcome) iq.byHost } } }


{-| Census helpers (2026-07-21). Stats-only.
-}
bumpDict : Int -> Dict Int Int -> Dict Int Int
bumpDict k d =
    Dict.update k (\v -> Just (Maybe.withDefault 0 v + 1)) d


bumpDictStr : String -> Dict String Int -> Dict String Int
bumpDictStr k d =
    Dict.update k (\v -> Just (Maybe.withDefault 0 v + 1)) d


{-| All group-representative lambdaIds of a member — the symbol-join key
for the runtime dispatch census (rendered `Module_lambda_N` downstream).
-}
memberRepsOf : MemberInfo -> List Mono.LambdaId
memberRepsOf mi =
    Dict.foldl
        (\_ groups acc -> List.foldl (\g a -> g.rep.lambdaId :: a) acc groups)
        []
        mi.buckets


{-| Census (E8 split): the callee-expression SHAPE of an LTop site. An
approximation of escape provenance: `recordAccess`/`callResult` callees
were loaded from data / computed (the escape classes only E8-family work
can reach); `local` absorbs params AND destructured projections (so the
data-loaded share is an UNDER-count); `closureLiteral`/`global` are
analysis-reachable in principle.
-}
calleeShape : Mono.MonoExpr -> String
calleeShape f =
    case f of
        Mono.MonoVarLocal _ _ ->
            "local"

        Mono.MonoRecordAccess _ _ _ ->
            "recordAccess"

        Mono.MonoCall _ _ _ _ _ ->
            "callResult"

        Mono.MonoVarGlobal _ _ _ ->
            "global"

        Mono.MonoVarKernel _ _ _ _ _ ->
            "kernel"

        Mono.MonoClosure _ _ _ ->
            "closureLiteral"

        Mono.MonoCase _ _ _ _ _ ->
            "case"

        Mono.MonoIf _ _ _ ->
            "if"

        Mono.MonoLet _ _ _ ->
            "let"

        _ ->
            "other"


type Resolution
    = Stamp Instance
    | StampPap Instance Int
    | StampStaged Instance
      -- Fix A: an OVER-APPLYING site whose peeled (flattened) view matches an
      -- instance exactly, so the call SATURATES that instance and is stamped
      -- like the exact path — `Stamp`'s fields verbatim, no staging. Separate
      -- constructor only so the census can count it.
    | StampFlat Instance
      -- The String is the decline REASON, labelled at each construction site.
      -- Currently consumed only by the (removed, re-addable) one-shot per-site
      -- decline log — see /work/lss-decline-log-analysis.md for the recipe —
      -- and kept because any future decline investigation needs it on day one.
    | Decline String (StampCtx -> StampCtx)


{-| LSS_009 (+ LSS_011 PAP arm): pick an interchangeable representative for
the site, or decline with the census reason. Guard order is a scale
invariant: integer guards first, then one BOUNDED fingerprint, one
Dict.get, and one full `eqLayout` confirm per group in the bucket
(usually one).

  - blocked member → decline (the flowing value could be a wrapper — its
    code and capture layout differ);
  - non-empty args and callee-type first-stage arity == arg count (the
    site must exactly saturate its OWN callee type — an under-applying
    site creates a PAP rather than dispatching, an over-applying site is
    a flat multi-stage call: both v1-declined, sub-counted);
  - exact path: the site's layout group must exist, be capture-unanimous,
    and be free of Char captures (`emitFastClosureCall`'s i16 capture
    load is still unexercised C++); its `rep` is the stamped
    representative — the flowing value is a RAW instance;
  - PAP path (E2, LSS_011): when no group matches the site's FULL param
    layout, the flowing value may be an m-PAP holding k applied args —
    its peeled type has k fewer params than the instance. Scan all of the
    member's groups for one whose k-dropped param suffix (k ≥ 1) matches
    the site; the PAP's filled value slots are then [captures…, k args…]
    in slot order (Heap: n_values = captures + k, max_values = captures +
    params), so stamping captureAbi = captures ++ take k params lets the
    unchanged fast lowering load exactly the filled prefix. The k prefix
    types face the same Char gate as captures (they are loaded by the
    same code).

-}
resolveRepresentative : Bool -> Mono.MonoType -> Int -> MemberInfo -> Resolution
resolveRepresentative flatPeel calleeType argCount memberInfo =
    if memberInfo.blocked then
        Decline "blocked" bumpBlocked

    else
        case calleeType of
            Mono.MFunction _ _ fargs fret ->
                if argCount == 0 then
                    Decline "arityZero" bumpShapeArityZero

                else if argCount < List.length fargs then
                    Decline "arityUnder" bumpShapeArityUnder

                else if argCount > List.length fargs then
                    -- Fix A (plan §14/§15.1): the site applies its args FLAT
                    -- while the callee TYPE is curried — `Store.classifyGo`
                    -- builds ONE parameter per `MFunction` stage for EVERY
                    -- arrow, so this branch fires for every HOF whose callback
                    -- takes 2+ arguments (the whole fold family: 33.2 % of the
                    -- compiler's generic dispatch, measured). The type is
                    -- representation-AGNOSTIC — an arrow is inhabited by a
                    -- flat n-param closure, a curried chain and PAPs alike —
                    -- so it cannot license a stamp. The INSTANCE is the
                    -- representation authority: peel the type to the site's
                    -- own arg count and match against THAT.
                    case flattenedResolution flatPeel argCount calleeType memberInfo of
                        Just resolution ->
                            resolution

                        Nothing ->
                            -- E2.7 (LSS_014, v2 staged stamping): the site
                            -- applies MORE args than its callee type's first
                            -- stage — a flat multi-stage call. If an instance
                            -- matches the site's FIRST stage exactly (params +
                            -- return, layout-wise), the runtime callee IS that
                            -- instance (LSS_009) and applying
                            -- |inst.paramTypes| args saturates the instance's
                            -- own stage — stamp batch 1; emission applies the
                            -- remainder generically to the intermediate.
                            -- Misses keep the Over census bucket. No PAP
                            -- fallback here (an over-applied PAP is v3).
                            --
                            -- Reached only when the peel found no exact
                            -- landing, so today's decline attribution is
                            -- preserved unchanged (review B3).
                            resolveStagedFirstStage fargs fret memberInfo

                else
                    case Dict.get (siteFingerprint fargs fret) memberInfo.buckets of
                        Nothing ->
                            resolvePapSuffix fargs fret argCount memberInfo bumpShapeBucketMiss

                        Just groups ->
                            resolveInGroups fargs fret argCount groups memberInfo

            _ ->
                Decline "nonArrow" bumpShapeNonArrow


resolveInGroups : List Mono.MonoType -> Mono.MonoType -> Int -> List LayoutGroup -> MemberInfo -> Resolution
resolveInGroups fargs fret argCount groups memberInfo =
    case groups of
        [] ->
            resolvePapSuffix fargs fret argCount memberInfo bumpShapeLayout

        g :: rest ->
            if g.paramCount == argCount && eqLayoutLists g.rep.paramTypes fargs && Mono.eqLayout g.rep.returnType fret then
                if not g.charFree then
                    Decline "char" bumpShapeChar

                else if not g.unanimous then
                    Decline "abiMismatch" bumpAbiMismatch

                else if g.fpUnanimous then
                    Stamp g.rep

                else
                    -- LSS_024 F fence: same-layout clones with divergent
                    -- verbatim bodies (the E11 class) — never stamp.
                    Decline "bodyMismatch" bumpBodyMismatch

            else
                resolveInGroups fargs fret argCount rest memberInfo


{-| E2.7 (LSS_014): first-stage match for an OVER-applying site. The exact
path's group test minus the argCount equality — the group's params/return
must equal the SITE's first stage. Same charFree gate (batch-1 args load
through the same code as captures) and unanimity gate as the exact path.
-}
resolveStagedFirstStage : List Mono.MonoType -> Mono.MonoType -> MemberInfo -> Resolution
resolveStagedFirstStage fargs fret memberInfo =
    case Dict.get (siteFingerprint fargs fret) memberInfo.buckets of
        Nothing ->
            Decline "arityOver" bumpShapeArityOver

        Just groups ->
            stagedScan fargs fret groups


stagedScan : List Mono.MonoType -> Mono.MonoType -> List LayoutGroup -> Resolution
stagedScan fargs fret groups =
    case groups of
        [] ->
            Decline "arityOver" bumpShapeArityOver

        g :: rest ->
            if g.paramCount == List.length fargs && eqLayoutLists g.rep.paramTypes fargs && Mono.eqLayout g.rep.returnType fret then
                if not g.charFree then
                    Decline "char" bumpShapeChar

                else if not g.unanimous then
                    Decline "abiMismatch" bumpAbiMismatch

                else if g.fpUnanimous then
                    StampStaged g.rep

                else
                    Decline "bodyMismatch" bumpBodyMismatch

            else
                stagedScan fargs fret rest


{-| Fix A (plan §17.1): accumulate the callee type's stages until the parameter
count reaches `want`, returning the flattened parameter list and that stage's
return type.

`Nothing` when the type runs out of arrow before reaching `want`, or when a
stage OVERSHOOTS it — peel-until-EQUAL, never peel-n-times. Overshoot is not
theoretical: `zonkFlat` and `MonoInlineSimplify.flattenArrowOnce` both emit
multi-parameter `MFunction`s, so a stage may carry more than one parameter.

The intermediate stages' lambda-set annotations are dropped. They never
materialise at runtime — a flat call never dispatches through them — which is
the same trade `flattenArrowOnce` documents as "annotation soundness over
precision", except that here nothing reads them at all.

Pure and total; exposed for the unit pins.
-}
peelStages : Int -> Mono.MonoType -> Maybe ( List Mono.MonoType, Mono.MonoType )
peelStages want ty =
    peelGo want 0 [] ty


peelGo : Int -> Int -> List (List Mono.MonoType) -> Mono.MonoType -> Maybe ( List Mono.MonoType, Mono.MonoType )
peelGo want have acc ty =
    case ty of
        Mono.MFunction _ _ params ret ->
            let
                have1 =
                    have + List.length params

                acc1 =
                    params :: acc
            in
            if have1 == want then
                Just ( List.concat (List.reverse acc1), ret )

            else if have1 > want then
                Nothing

            else
                peelGo want have1 acc1 ret

        _ ->
            Nothing


{-| Fix A: the flattened-view match for an over-applying site.

`Just` only when the peel lands EXACTLY on `argCount` AND a layout group
carries that full parameter list; the gates are then the exact path's, in the
exact path's order.

A DEDICATED scan rather than `resolveInGroups`, because that function falls
through to `resolvePapSuffix` and a PAP suffix must never satisfy a flattened
match (plan review B2/B11): the whole licence here is that the flowing value is
an n-parameter closure which the n-argument call SATURATES, so `remaining_arity
== argCount` (CGEN_052) holds by the instance's own shape. A k-dropped suffix
match would stamp a saturating call on a value that is not saturated.
-}
flattenedResolution : Bool -> Int -> Mono.MonoType -> MemberInfo -> Maybe Resolution
flattenedResolution flatPeel argCount calleeType memberInfo =
    if not flatPeel then
        Nothing

    else
        case peelStages argCount calleeType of
            Nothing ->
                Nothing

            Just ( flatArgs, flatRet ) ->
                case Dict.get (siteFingerprint flatArgs flatRet) memberInfo.buckets of
                    Nothing ->
                        Nothing

                    Just groups ->
                        flattenedScan argCount flatArgs flatRet groups


flattenedScan : Int -> List Mono.MonoType -> Mono.MonoType -> List LayoutGroup -> Maybe Resolution
flattenedScan argCount flatArgs flatRet groups =
    case groups of
        [] ->
            Nothing

        g :: rest ->
            if g.paramCount == argCount && eqLayoutLists g.rep.paramTypes flatArgs && Mono.eqLayout g.rep.returnType flatRet then
                Just
                    (if not g.charFree then
                        Decline "char" bumpShapeChar

                     else if not g.unanimous then
                        Decline "abiMismatch" bumpAbiMismatch

                     else if g.fpUnanimous then
                        StampFlat g.rep

                     else
                        -- Plan §15.0, THE STACKED GUARD: Fix A gets the site
                        -- past the arity check and it lands HERE unless
                        -- `lss.stamp.enabled` (instance qualification) is also
                        -- on. At `Dict_foldl_$_32636` — 100 M dispatches, the
                        -- largest single site in the compiler — that is
                        -- exactly what happens. Measure A in BOTH arms.
                        Decline "bodyMismatch" bumpBodyMismatch
                    )

            else
                flattenedScan argCount flatArgs flatRet rest


{-| E2 (LSS_011): the PAP-suffix match. The site saturates its own callee
type (argCount == |fargs|), but no group carries that FULL param layout —
so if any group's k-dropped suffix matches, the flowing value is that
group's instance partially applied with k args. Scans every group of the
member (members have very few groups; the exact path's bucket already
missed). `noMatch` is the decline the exact path would have charged.
-}
resolvePapSuffix : List Mono.MonoType -> Mono.MonoType -> Int -> MemberInfo -> (StampCtx -> StampCtx) -> Resolution
resolvePapSuffix fargs fret argCount memberInfo noMatch =
    papScan fargs fret argCount (List.concat (Dict.values memberInfo.buckets)) noMatch


papScan : List Mono.MonoType -> Mono.MonoType -> Int -> List LayoutGroup -> (StampCtx -> StampCtx) -> Resolution
papScan fargs fret argCount groups noMatch =
    case groups of
        [] ->
            Decline "bucketOrLayoutMiss" noMatch

        g :: rest ->
            let
                k =
                    g.paramCount - argCount
            in
            if k >= 1 && eqLayoutLists (List.drop k g.rep.paramTypes) fargs && Mono.eqLayout g.rep.returnType fret then
                if not g.charFree || List.any ((==) Mono.MChar) (List.take k g.rep.paramTypes) then
                    -- the k prefix slots are loaded by the same capture-load
                    -- code as real captures — same i16 gate (E4c lifts it)
                    Decline "char" bumpShapeChar

                else if not g.unanimous then
                    Decline "abiMismatch" bumpAbiMismatch

                else if g.fpUnanimous then
                    StampPap g.rep k

                else
                    Decline "bodyMismatch" bumpBodyMismatch

            else
                papScan fargs fret argCount rest noMatch


kindIdFor : Int -> StampCtx -> ( Int, StampCtx )
kindIdFor m ctx =
    case Dict.get m ctx.kindIds of
        Just kid ->
            ( kid, ctx )

        Nothing ->
            ( ctx.nextKind
            , { ctx | kindIds = Dict.insert m ctx.nextKind ctx.kindIds, nextKind = ctx.nextKind + 1 }
            )


bumpBlocked : StampCtx -> StampCtx
bumpBlocked ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = { stats | declinedBlocked = stats.declinedBlocked + 1 } }


{-| E9.5 (plans/lss-post-settle-fn-global-devirt.md §3): resolve a
noInstance singleton to its post-settle direct-call target, or `Nothing`
(fall through to the ordinary decline).

Guards, every one load-bearing:

  - flag (`ctx.postSettle`) — flag-off this returns before touching state,
    keeping the pass byte-identical;
  - member origin is `OriginGlobal`/`OriginCtor` (k| kernels need ABI
    derivation + the E9.2 guards — E10's arm, not this one; l| lambdas are
    CAPTURING values, undevirtable without the very instance that is
    missing; a| accessors measured 0);
  - callee is a plain `MonoVarLocal` (a var read is effect-and-bottom-free,
    so replacing it is sound — LSS_015's clause);
  - EXACT saturation: argCount == the callee type's own arrow arity. With
    `spineArity = False`, standalone members live on the HEAD arrow only,
    so a partially-applied value's remaining spine never carries the
    member; this guard is the belt to that suspender — it proves the value
    is the zero-capture bare global/ctor;
  - an `eqLayout` spec of the target exists; the MINIMUM SpecId among
    matches is chosen (deterministic, order-free — `specsByGlobal` lists
    are unsorted). Spec choice among same-layout candidates is covered by
    LSS_005 (capture-free, see the call-site comment).

No `lssBlockedMembers` check: blocked members are INSERTED into the index
(blocked = True), so they take the `Just` path (`declinedBlocked`) and
never reach the noInstance arm.

-}
type PostSettleOutcome
    = PsStamp Mono.SpecId Bool -- Bool = ctor half (census split)
    | PsNoSpec -- every guard passed, no eqLayout spec — counted
    | PsNotCandidate


postSettleTarget : Int -> Mono.MonoExpr -> Int -> StampCtx -> PostSettleOutcome
postSettleTarget m func argCount ctx =
    if not ctx.postSettle then
        PsNotCandidate

    else
        let
            targetOf origin =
                case origin of
                    Mono.OriginGlobal g ->
                        Just ( g, False )

                    Mono.OriginCtor g ->
                        Just ( g, True )

                    _ ->
                        Nothing
        in
        case ( func, Dict.get m ctx.origins |> Maybe.andThen targetOf ) of
            ( Mono.MonoVarLocal _ calleeType, Just ( target, isCtor ) ) ->
                let
                    arity =
                        case calleeType of
                            Mono.MFunction _ _ params _ ->
                                List.length params

                            _ ->
                                0
                in
                if arity >= 1 && arity == argCount then
                    case
                        Dict.get (Mono.toComparableGlobal target) ctx.specsByGlobal
                            |> Maybe.withDefault []
                            |> List.filter (\( _, specType ) -> Mono.eqLayout specType calleeType)
                            |> List.map Tuple.first
                            |> List.minimum
                    of
                        Just specId ->
                            PsStamp specId isCtor

                        Nothing ->
                            PsNoSpec

                else
                    PsNotCandidate

            _ ->
                PsNotCandidate


bumpNoInstance : StampCtx -> StampCtx
bumpNoInstance ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = { stats | declinedNoInstance = stats.declinedNoInstance + 1 } }


{-| H6.0b: every shape decline bumps the aggregate AND one sub-reason, so
the sub-counters always sum to declinedShape.
-}
bumpShapeWith : (AbiCloningStats -> AbiCloningStats) -> StampCtx -> StampCtx
bumpShapeWith sub ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = sub { stats | declinedShape = stats.declinedShape + 1 } }


bumpShapeArityZero : StampCtx -> StampCtx
bumpShapeArityZero =
    bumpShapeWith
        (\st ->
            { st
                | declinedShapeArity = st.declinedShapeArity + 1
                , declinedShapeArityZero = st.declinedShapeArityZero + 1
            }
        )


bumpShapeArityUnder : StampCtx -> StampCtx
bumpShapeArityUnder =
    bumpShapeWith
        (\st ->
            { st
                | declinedShapeArity = st.declinedShapeArity + 1
                , declinedShapeArityUnder = st.declinedShapeArityUnder + 1
            }
        )


bumpShapeArityOver : StampCtx -> StampCtx
bumpShapeArityOver =
    bumpShapeWith
        (\st ->
            { st
                | declinedShapeArity = st.declinedShapeArity + 1
                , declinedShapeArityOver = st.declinedShapeArityOver + 1
            }
        )


bumpShapeBucketMiss : StampCtx -> StampCtx
bumpShapeBucketMiss =
    bumpShapeWith (\st -> { st | declinedShapeBucketMiss = st.declinedShapeBucketMiss + 1 })


bumpShapeLayout : StampCtx -> StampCtx
bumpShapeLayout =
    bumpShapeWith (\st -> { st | declinedShapeLayout = st.declinedShapeLayout + 1 })


bumpShapeChar : StampCtx -> StampCtx
bumpShapeChar =
    bumpShapeWith (\st -> { st | declinedShapeChar = st.declinedShapeChar + 1 })


bumpShapeNonArrow : StampCtx -> StampCtx
bumpShapeNonArrow =
    bumpShapeWith (\st -> { st | declinedShapeNonArrow = st.declinedShapeNonArrow + 1 })


bumpAbiMismatch : StampCtx -> StampCtx
bumpAbiMismatch ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = { stats | declinedAbiMismatch = stats.declinedAbiMismatch + 1 } }


bumpBodyMismatch : StampCtx -> StampCtx
bumpBodyMismatch ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = { stats | declinedBodyMismatch = stats.declinedBodyMismatch + 1 } }




-- ============================================================================
-- ====== LSS_024 FINGERPRINT (the F fence serializer) ======
-- ============================================================================


{-| Canonical VERBATIM serialization of one closure instance
(plans/lss-layout-qualified-members.md §2.4): regions are OMITTED (the
`CafHoist.zeroRegions` intent, achieved by never rendering them), the
instance's OWN fresh lambdaIds are numbered positionally in first-encounter
order, and EVERYTHING else is verbatim — annotations (types render through
the annotation-SENSITIVE `toComparableMonoType`, which is what separates the
E11 divergent clones), member ids, SpecId references, names, literals, the
full CallInfo, and full deciders. Two instances with equal fingerprints are
textually identical clones modulo source position and lambda-supply
numbering — LSS_009's interchangeability premise, discharged by comparison.
(Serializer precedent: `MonoSolver.Diff.serNode`; that one is deliberately
lossy on CallInfo and deciders, which is exactly what this one must not be.)

Fragments accumulate REVERSED onto a list and concatenate once (the
`toComparableFragments` discipline); the positional lambda map threads
through as state. Cost discipline: `fpOf` runs only from `joinGroup`'s
distinct-lambdaId arm while the group's stamp is still live, so
single-instance groups — the vast majority — never serialize anything.
-}
fpOf : Instance -> String
fpOf inst =
    instanceFingerprint inst.info inst.body


{-| The fingerprint as a standalone entry point, for the OTHER
representative-premise consumer: `Borrow.buildLambdaSigs` gates its
per-member representative signature on fingerprint unanimity with exactly
this function (the §7.2 obligation of plans/lss-layout-qualified-members.md
— under LSS_024 id sharing, "stored sigs equal by construction" needs the
same textual-identity discharge as the dispatch stamps).
-}
instanceFingerprint : Mono.ClosureInfo -> Mono.MonoExpr -> String
instanceFingerprint info body =
    let
        ( frags, _ ) =
            fpClosureParts info body ( [], { lamMap = Dict.empty, nextLam = 0, nameMap = Dict.empty, nextName = 0 } )
    in
    String.concat (List.reverse frags)


{-| A LOCAL name occurrence (binder or reference): positional in
first-encounter order, so consistently-freshened verbatim copies compare
equal while structurally divergent reference patterns still differ.
-}
fpName : String -> FpState -> FpState
fpName name ( acc, ctx ) =
    case Dict.get name ctx.nameMap of
        Just pos ->
            ( ("n" ++ String.fromInt pos) :: acc, ctx )

        Nothing ->
            ( ("n" ++ String.fromInt ctx.nextName) :: acc
            , { ctx | nameMap = Dict.insert name ctx.nextName ctx.nameMap, nextName = ctx.nextName + 1 }
            )


type alias FpCtx =
    { lamMap : Dict Int Int -- own lambdaId uid -> position (first-encounter order)
    , nextLam : Int
    , nameMap : Dict String Int -- LOCAL names -> position (first-encounter order). MonoInlineSimplify freshens let-bound names in verbatim inline copies (freshenLetBoundNames), so local names — binders AND references — must compare positionally or every inliner copy false-mismatches (measured: 163 lost flag-off stamps). Semantic names (record fields, ctors, globals, kernels) stay verbatim. Aliasing capture-expr OUTER references across copies is sound: captures are per-object runtime VALUES loaded from the actual object — LSS_009's capture-layout unanimity is the gate for those, not the fingerprint.
    , nextName : Int
    }


type alias FpState =
    ( List String, FpCtx )


fpStr : String -> FpState -> FpState
fpStr s ( acc, ctx ) =
    ( s :: acc, ctx )


fpTy : Mono.MonoType -> FpState -> FpState
fpTy t st =
    fpStr (Mono.toComparableMonoType t) st


{-| A lambda DEFINITION occurrence: assign (or reuse) its positional number.
-}
fpLam : Mono.LambdaId -> FpState -> FpState
fpLam (Mono.AnonymousLambda _ uid) ( acc, ctx ) =
    case Dict.get uid ctx.lamMap of
        Just pos ->
            ( ("l" ++ String.fromInt pos) :: acc, ctx )

        Nothing ->
            ( ("l" ++ String.fromInt ctx.nextLam) :: acc
            , { ctx | lamMap = Dict.insert uid ctx.nextLam ctx.lamMap, nextLam = ctx.nextLam + 1 }
            )


{-| A lambda REFERENCE (fastEvaluator): positional when it names one of the
instance's own lambdas, raw otherwise (a foreign reference is identity-
bearing; rendering it raw can only cause a sound decline).
-}
fpLamRef : Mono.LambdaId -> FpState -> FpState
fpLamRef (Mono.AnonymousLambda _ uid) (( _, ctx ) as st) =
    case Dict.get uid ctx.lamMap of
        Just pos ->
            fpStr ("l" ++ String.fromInt pos) st

        Nothing ->
            fpStr ("x" ++ String.fromInt uid) st


fpClosureParts : Mono.ClosureInfo -> Mono.MonoExpr -> FpState -> FpState
fpClosureParts info body st =
    st
        |> fpStr "Clo("
        |> fpLam info.lambdaId
        |> fpStr ";src="
        |> fpStr
            (case info.srcLambda of
                Just sl ->
                    String.fromInt (Id.toComparable sl)

                Nothing ->
                    "-"
            )
        |> fpStr (";mem=" ++ fpMaybeInt info.lssMember ++ ";caps=[")
        |> fpCaps info.captures
        |> fpStr "];params=["
        |> fpParams info.params
        |> fpStr ("];ck=" ++ fpClosureKind info.closureKind ++ ";cabi=")
        |> fpCaptureAbi info.captureAbi
        |> fpStr ";"
        |> fpExpr body
        |> fpStr ")"


fpCaps : List ( String, Mono.MonoExpr, Bool ) -> FpState -> FpState
fpCaps caps st =
    List.foldl
        (\( n, e, b ) a ->
            a
                |> fpName n
                |> fpStr
                    (if b then
                        "!"

                     else
                        "="
                    )
                |> fpExpr e
                |> fpStr ","
        )
        st
        caps


fpParams : List ( String, Mono.MonoType ) -> FpState -> FpState
fpParams params st =
    List.foldl (\( n, t ) a -> a |> fpName n |> fpStr ":" |> fpTy t |> fpStr ",") st params


fpMaybeInt : Maybe Int -> String
fpMaybeInt m =
    case m of
        Just i ->
            String.fromInt i

        Nothing ->
            "-"


fpClosureKind : Mono.MaybeClosureKind -> String
fpClosureKind mck =
    case mck of
        Just (Mono.Known (Mono.ClosureKindId k)) ->
            "K" ++ String.fromInt k

        Nothing ->
            "-"


fpCaptureAbi : Maybe Mono.CaptureABI -> FpState -> FpState
fpCaptureAbi mabi st =
    case mabi of
        Nothing ->
            fpStr "-" st

        Just abi ->
            st
                |> fpStr "{c="
                |> fpTys abi.captureTypes
                |> fpStr ";p="
                |> fpTys abi.paramTypes
                |> fpStr ";r="
                |> fpTy abi.returnType
                |> fpStr "}"


fpTys : List Mono.MonoType -> FpState -> FpState
fpTys ts st =
    List.foldl (\t a -> a |> fpTy t |> fpStr ",") st ts


fpInts : List Int -> String
fpInts xs =
    String.join "," (List.map String.fromInt xs)


fpCallInfo : Mono.CallInfo -> FpState -> FpState
fpCallInfo ci st =
    st
        |> fpStr
            ((case ci.callModel of
                Mono.FlattenedExternal ->
                    "FE"

                Mono.StageCurried ->
                    "SC"
             )
                ++ "|sa="
                ++ fpInts ci.stageArities
                ++ (if ci.isSingleStageSaturated then
                        "|s1"

                    else
                        "|s0"
                   )
                ++ "|ir="
                ++ String.fromInt ci.initialRemaining
                ++ "|ra="
                ++ fpInts ci.remainingStageArities
                ++ "|ck="
                ++ fpClosureKind ci.closureKind
                ++ "|ca="
            )
        |> fpCaptureAbi ci.captureAbi
        |> fpStr "|fe="
        |> (\a ->
                case ci.fastEvaluator of
                    Just lid ->
                        fpLamRef lid a

                    Nothing ->
                        fpStr "-" a
           )
        |> fpStr
            ("|pp="
                ++ fpMaybeInt ci.fastPapPrefix
                ++ "|"
                ++ (case ci.callKind of
                        Mono.CallDirectKnownSegmentation ->
                            "KS"

                        Mono.CallDirectFlat ->
                            "DF"

                        Mono.CallGenericApply ->
                            "GA"

                        Mono.CallSegmentationUnknown ->
                            "SU"
                   )
                ++ "|rt="
            )
        |> fpTy ci.evaluatorReturnType


fpExpr : Mono.MonoExpr -> FpState -> FpState
fpExpr expr st =
    case expr of
        Mono.MonoLiteral lit t ->
            st |> fpStr ("Li(" ++ fpLit lit ++ "):") |> fpTy t

        Mono.MonoVarLocal name t ->
            st |> fpStr "VL(" |> fpName name |> fpStr "):" |> fpTy t

        Mono.MonoVarGlobal _ specId t ->
            st |> fpStr ("VG(" ++ String.fromInt specId ++ "):") |> fpTy t

        Mono.MonoVarKernel _ prefix home name t ->
            st |> fpStr ("VK(" ++ prefix ++ "." ++ home ++ "." ++ name ++ "):") |> fpTy t

        Mono.MonoList _ items t ->
            st |> fpStr "Ls[" |> fpExprs items |> fpStr "]:" |> fpTy t

        Mono.MonoClosure info body t ->
            st |> fpClosureParts info body |> fpStr ":" |> fpTy t

        Mono.MonoCall _ func args t callInfo ->
            st
                |> fpStr "Ca("
                |> fpExpr func
                |> fpStr ",["
                |> fpExprs args
                |> fpStr "];ci="
                |> fpCallInfo callInfo
                |> fpStr "):"
                |> fpTy t

        Mono.MonoTailCall name args t ->
            st
                |> fpStr "TC("
                |> fpName name
                |> fpStr ",["
                |> (\a -> List.foldl (\( n, e ) acc -> acc |> fpName n |> fpStr "=" |> fpExpr e |> fpStr ",") a args)
                |> fpStr "]):"
                |> fpTy t

        Mono.MonoIf branches final t ->
            st
                |> fpStr "If(["
                |> (\a -> List.foldl (\( c, b ) acc -> acc |> fpExpr c |> fpStr "->" |> fpExpr b |> fpStr ";") a branches)
                |> fpStr "],"
                |> fpExpr final
                |> fpStr "):"
                |> fpTy t

        Mono.MonoLet def body t ->
            st |> fpStr "Le(" |> fpDef def |> fpStr "," |> fpExpr body |> fpStr "):" |> fpTy t

        Mono.MonoDestruct dtor body t ->
            st |> fpStr "De(" |> fpDtor dtor |> fpStr "," |> fpExpr body |> fpStr "):" |> fpTy t

        Mono.MonoCase n1 n2 decider jumps t ->
            st
                |> fpStr "Cs("
                |> fpName n1
                |> fpStr ","
                |> fpName n2
                |> fpStr ","
                |> fpDecider decider
                |> fpStr ",j=["
                |> (\a -> List.foldl (\( i, e ) acc -> acc |> fpStr (String.fromInt i ++ "=") |> fpExpr e |> fpStr ",") a jumps)
                |> fpStr "]):"
                |> fpTy t

        Mono.MonoRecordCreate fields t ->
            st |> fpStr "Rc[" |> fpNamedExprs fields |> fpStr "]:" |> fpTy t

        Mono.MonoRecordAccess record name t ->
            st |> fpStr "Ra(" |> fpExpr record |> fpStr ("." ++ name ++ "):") |> fpTy t

        Mono.MonoRecordUpdate record updates t ->
            st |> fpStr "Ru(" |> fpExpr record |> fpStr ",[" |> fpNamedExprs updates |> fpStr "]):" |> fpTy t

        Mono.MonoTupleCreate _ items t ->
            st |> fpStr "Tu[" |> fpExprs items |> fpStr "]:" |> fpTy t

        Mono.MonoUnit ->
            fpStr "U" st

        Mono.MonoAccessorValue _ name t ->
            st |> fpStr ("Av(" ++ name ++ "):") |> fpTy t


fpExprs : List Mono.MonoExpr -> FpState -> FpState
fpExprs items st =
    List.foldl (\e a -> a |> fpExpr e |> fpStr ",") st items


fpNamedExprs : List ( String, Mono.MonoExpr ) -> FpState -> FpState
fpNamedExprs fields st =
    List.foldl (\( n, e ) a -> a |> fpStr (n ++ "=") |> fpExpr e |> fpStr ",") st fields


fpLit : Mono.Literal -> String
fpLit lit =
    case lit of
        Mono.LBool b ->
            if b then
                "BT"

            else
                "BF"

        Mono.LInt i ->
            "I" ++ String.fromInt i

        Mono.LFloat f ->
            "F" ++ String.fromFloat f

        Mono.LChar c ->
            "C" ++ c

        Mono.LStr s ->
            "S" ++ s


fpDef : Mono.MonoDef -> FpState -> FpState
fpDef def st =
    case def of
        Mono.MonoDef name e ->
            st |> fpName name |> fpStr "=" |> fpExpr e

        Mono.MonoTailDef name params e ->
            st |> fpName name |> fpStr "([" |> fpParams params |> fpStr "])=" |> fpExpr e


fpDtor : Mono.MonoDestructor -> FpState -> FpState
fpDtor (Mono.MonoDestructor name path t) st =
    st |> fpName name |> fpStr "<-" |> fpPath path |> fpStr ":" |> fpTy t


fpPath : Mono.MonoPath -> FpState -> FpState
fpPath path st =
    case path of
        Mono.MonoIndex i ck t sub ->
            st |> fpStr ("Ix" ++ String.fromInt i ++ fpContainer ck ++ ":") |> fpTy t |> fpStr "." |> fpPath sub

        Mono.MonoField name t sub ->
            st |> fpStr ("Fd" ++ name ++ ":") |> fpTy t |> fpStr "." |> fpPath sub

        Mono.MonoUnbox t sub ->
            st |> fpStr "Ub:" |> fpTy t |> fpStr "." |> fpPath sub

        Mono.MonoRoot name t ->
            st |> fpStr "Rt" |> fpName name |> fpStr ":" |> fpTy t


fpContainer : Mono.ContainerKind -> String
fpContainer ck =
    case ck of
        Mono.ListContainer ->
            "@L"

        Mono.Tuple2Container ->
            "@2"

        Mono.Tuple3Container ->
            "@3"

        Mono.CustomContainer n ->
            "@C" ++ n


fpDecider : Mono.Decider Mono.MonoChoice -> FpState -> FpState
fpDecider decider st =
    case decider of
        Mono.Leaf choice ->
            st |> fpStr "Lf(" |> fpChoice choice |> fpStr ")"

        Mono.Chain tests success failure ->
            st
                |> fpStr "Ch(["
                |> (\a -> List.foldl (\( p, t ) acc -> acc |> fpDtPath p |> fpStr ("?" ++ DT.testToComparable t ++ ";")) a tests)
                |> fpStr "],"
                |> fpDecider success
                |> fpStr ","
                |> fpDecider failure
                |> fpStr ")"

        Mono.FanOut path edges fallback ->
            st
                |> fpStr "Fo("
                |> fpDtPath path
                |> fpStr ",["
                |> (\a -> List.foldl (\( t, d ) acc -> acc |> fpStr (DT.testToComparable t ++ "->") |> fpDecider d |> fpStr ";") a edges)
                |> fpStr "],"
                |> fpDecider fallback
                |> fpStr ")"


fpChoice : Mono.MonoChoice -> FpState -> FpState
fpChoice choice st =
    case choice of
        Mono.Inline e ->
            st |> fpStr "In(" |> fpExpr e |> fpStr ")"

        Mono.Jump j ->
            fpStr ("Jm" ++ String.fromInt j) st


fpDtPath : Mono.MonoDtPath -> FpState -> FpState
fpDtPath path st =
    case path of
        Mono.DtRoot name t ->
            st |> fpStr "dR" |> fpName name |> fpStr ":" |> fpTy t

        Mono.DtIndex i ck t sub ->
            st |> fpStr ("dI" ++ String.fromInt i ++ fpContainer ck ++ ":") |> fpTy t |> fpStr "." |> fpDtPath sub

        Mono.DtUnbox t sub ->
            st |> fpStr "dU:" |> fpTy t |> fpStr "." |> fpDtPath sub
