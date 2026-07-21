module Compiler.GlobalOpt.AbiCloning exposing (AbiCloningStats, abiCloningPass, emptyStats)

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
    , multiInstanceGroups : Int -- Fix B probe (LSS_009/LSS_017 verifier): layout groups holding ≥2 distinct lambdaIds. MUST be 0 under qualified members; >0 = clones sharing a member = the §11.6 representative-hijack precondition.

    -- Census (2026-07-21, plans/lss-dispatch-value-extraction.md open
    -- questions). Stats-only — never touches the graph; the maps are
    -- bounded by consulted-site populations.
    , declineByMember : Dict Int Int -- consulted-singleton DECLINES per member id (dominated by the Over class) — the residue-attribution join key
    , memberReps : Dict Int (List Mono.LambdaId) -- group-representative lambdaIds for members recorded in declineByMember/multiSetMembers (symbol join)
    , multiSetSiteHist : Dict Int Int -- E3 de-risk: |set| -> consulted call sites carrying a MULTI-member set
    , multiSetMembers : Dict Int Int -- E3 de-risk: member id -> occurrences across multi-set sites
    , topSiteShapes : Dict String Int -- E8 split: LTop-annotated call sites by callee-expression shape (escape proxy: recordAccess/callResult vs local/global)
    , stampedWrapperInstances : Int -- E7 trigger: stamped sites whose representative is a staging wrapper (collision signal)
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
    , multiInstanceGroups = 0
    , declineByMember = Dict.empty
    , memberReps = Dict.empty
    , multiSetSiteHist = Dict.empty
    , multiSetMembers = Dict.empty
    , topSiteShapes = Dict.empty
    , stampedWrapperInstances = 0
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
    , buckets : Dict String (List LayoutGroup)
    }


{-| All instances sharing one param+return layout. `rep` is the FIRST in
deterministic node-walk order (the stamped representative). `unanimous`
tracks capture-layout agreement across the group; `charFree` tracks the
absence of Char captures (both checked against `rep` as members join).
`paramCount` is denormalized for the integer guard.
-}
type alias LayoutGroup =
    { rep : Instance
    , paramCount : Int
    , unanimous : Bool
    , charFree : Bool
    , multi : Bool -- Fix B probe (LSS_009 verifier): ≥2 DISTINCT lambdaIds joined this group. Sound only when instances are verbatim copies sharing one lambdaId — any True is counted in `multiInstanceGroups` (must be 0 under LSS_017 qualified members).
    }


type alias Instance =
    { lambdaId : Mono.LambdaId
    , captureTypes : List Mono.MonoType
    , paramTypes : List Mono.MonoType
    , returnType : Mono.MonoType
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


collectInstances : Mono.MonoGraph -> Dict Int MemberInfo
collectInstances (Mono.MonoGraph record) =
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just node ->
                    List.foldl collectGo acc (nodeExprs node)

                Nothing ->
                    acc
        )
        Dict.empty
        record.nodes


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
collectGo : Mono.MonoExpr -> Dict Int MemberInfo -> Dict Int MemberInfo
collectGo expr acc =
    case expr of
        Mono.MonoClosure closureInfo body tipe ->
            let
                acc1 =
                    case instanceMember closureInfo tipe of
                        Just ( m, isAdopted ) ->
                            if isAdopted || isWrapperHome closureInfo.lambdaId then
                                -- Blocked members never stamp; drop any buckets.
                                Dict.insert m { blocked = True, buckets = Dict.empty } acc

                            else
                                Dict.update m
                                    (\present ->
                                        case present of
                                            Just mi ->
                                                if mi.blocked then
                                                    present

                                                else
                                                    Just { mi | buckets = insertInstance closureInfo body mi.buckets }

                                            Nothing ->
                                                Just { blocked = False, buckets = insertInstance closureInfo body Dict.empty }
                                    )
                                    acc

                        Nothing ->
                            acc

                acc2 =
                    List.foldl (\( _, e, _ ) a -> collectGo e a) acc1 closureInfo.captures
            in
            collectGo body acc2

        Mono.MonoCall _ func args _ _ ->
            List.foldl collectGo (collectGo func acc) args

        Mono.MonoTailCall _ args _ ->
            List.foldl (\( _, e ) a -> collectGo e a) acc args

        Mono.MonoIf branches final _ ->
            collectGo final (List.foldl (\( c, t ) a -> collectGo t (collectGo c a)) acc branches)

        Mono.MonoLet def body _ ->
            collectGo body (collectGoDef def acc)

        Mono.MonoDestruct _ inner _ ->
            collectGo inner acc

        Mono.MonoCase _ _ decider jumps _ ->
            List.foldl (\( _, e ) a -> collectGo e a) (collectGoDecider decider acc) jumps

        Mono.MonoList _ items _ ->
            List.foldl collectGo acc items

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> collectGo e a) acc fields

        Mono.MonoRecordAccess inner _ _ ->
            collectGo inner acc

        Mono.MonoRecordUpdate record updates _ ->
            List.foldl (\( _, e ) a -> collectGo e a) (collectGo record acc) updates

        Mono.MonoTupleCreate _ elements _ ->
            List.foldl collectGo acc elements

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


collectGoDef : Mono.MonoDef -> Dict Int MemberInfo -> Dict Int MemberInfo
collectGoDef def acc =
    case def of
        Mono.MonoDef _ e ->
            collectGo e acc

        Mono.MonoTailDef _ _ e ->
            collectGo e acc


collectGoDecider : Mono.Decider Mono.MonoChoice -> Dict Int MemberInfo -> Dict Int MemberInfo
collectGoDecider decider acc =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            collectGo e acc

        Mono.Leaf (Mono.Jump _) ->
            acc

        Mono.Chain _ success failure ->
            collectGoDecider failure (collectGoDecider success acc)

        Mono.FanOut _ edges fallback ->
            collectGoDecider fallback (List.foldl (\( _, d ) a -> collectGoDecider d a) acc edges)


insertInstance : Mono.ClosureInfo -> Mono.MonoExpr -> Dict String (List LayoutGroup) -> Dict String (List LayoutGroup)
insertInstance closureInfo body buckets =
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
            }
    in
    Dict.update (siteFingerprint paramTypes returnType)
        (\present -> Just (joinGroup inst (Maybe.withDefault [] present)))
        buckets


{-| Add an instance to its layout group within a fingerprint bucket (or
start a new group). Group facts update incrementally against `rep`:
capture unanimity and Char-freedom, both with the allocation-free
`eqLayout`. Order of groups and the identity of `rep` follow the
deterministic node walk.
-}
joinGroup : Instance -> List LayoutGroup -> List LayoutGroup
joinGroup inst groups =
    case groups of
        [] ->
            [ { rep = inst
              , paramCount = List.length inst.paramTypes
              , unanimous = True
              , charFree = not (List.any ((==) Mono.MChar) inst.captureTypes)
              , multi = False
              }
            ]

        g :: rest ->
            if sameSignatureLayout g.rep inst then
                { g
                    | unanimous = g.unanimous && sameCaptureLayout g.rep inst
                    , multi = g.multi || inst.lambdaId /= g.rep.lambdaId
                }
                    :: rest

            else
                g :: joinGroup inst rest


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
    }


{-| Run the ABI cloning pass on a MonoGraph.

With LSS off (or no singleton sets), the instance index is empty and the
graph is returned untouched — the pass is inert by construction, so the
flag-off pipeline stays byte-identical.

-}
abiCloningPass : Mono.MonoGraph -> ( Mono.MonoGraph, AbiCloningStats )
abiCloningPass ((Mono.MonoGraph record) as graph) =
    let
        index =
            collectInstances graph
    in
    if Dict.isEmpty index then
        ( graph, emptyStats )

    else
        let
            -- Fix B probe: count multi-instance groups up front (index-time
            -- fact, independent of stamping outcomes).
            stats0 =
                { emptyStats | multiInstanceGroups = countMultiInstanceGroups index }

            ( nodes1, finalCtx ) =
                Array.foldl
                    (\maybeNode ( accNodes, accCtx ) ->
                        case maybeNode of
                            Just node ->
                                let
                                    ( newNode, ctx1 ) =
                                        stampNode index accCtx node
                                in
                                ( Array.push (Just newNode) accNodes, ctx1 )

                            Nothing ->
                                ( Array.push Nothing accNodes, accCtx )
                    )
                    ( Array.empty, { kindIds = Dict.empty, nextKind = 0, stats = stats0 } )
                    record.nodes
        in
        ( Mono.MonoGraph { record | nodes = nodes1 }, finalCtx.stats )


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
                    case resolveRepresentative (Mono.typeOf func) (List.length args) memberInfo of
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
                            , { ctx1
                                | stats =
                                    { stats1
                                        | dispatchUpgraded = stats1.dispatchUpgraded + 1
                                        , stampedWrapperInstances = stats1.stampedWrapperInstances + wrapperInc
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
                                    }

                                stats1 =
                                    ctx1.stats
                            in
                            ( Mono.MonoCall region func args resultType stamped
                            , { ctx1 | stats = { stats1 | stampedStaged = stats1.stampedStaged + 1 } }
                            )

                        Decline bump ->
                            -- census: attribute the decline to the member and
                            -- capture its group reps (the runtime-join key).
                            let
                                ctxB =
                                    bump ctx

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
                    ( Mono.MonoCall region func args resultType callInfo, bumpNoInstance ctx )

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
            ( Mono.MonoCall region func args resultType callInfo, { ctx | stats = statsMembers } )

        Mono.LTop ->
            -- census (E8 split): an unknowable-callee site — classify the
            -- callee expression shape (escape proxy).
            let
                stats0 =
                    ctx.stats
            in
            ( Mono.MonoCall region func args resultType callInfo
            , { ctx | stats = { stats0 | topSiteShapes = bumpDictStr (calleeShape func) stats0.topSiteShapes } }
            )


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
    | Decline (StampCtx -> StampCtx)


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
resolveRepresentative : Mono.MonoType -> Int -> MemberInfo -> Resolution
resolveRepresentative calleeType argCount memberInfo =
    if memberInfo.blocked then
        Decline bumpBlocked

    else
        case calleeType of
            Mono.MFunction _ fargs fret ->
                if argCount == 0 then
                    Decline bumpShapeArityZero

                else if argCount < List.length fargs then
                    Decline bumpShapeArityUnder

                else if argCount > List.length fargs then
                    -- E2.7 (LSS_014, v2 staged stamping): the site applies
                    -- MORE args than its callee type's first stage — a flat
                    -- multi-stage call. If an instance matches the site's
                    -- FIRST stage exactly (params + return, layout-wise),
                    -- the runtime callee IS that instance (LSS_009) and
                    -- applying |inst.paramTypes| args saturates the
                    -- instance's own stage — stamp batch 1; emission applies
                    -- the remainder generically to the intermediate. Misses
                    -- keep the Over census bucket. No PAP fallback here (an
                    -- over-applied PAP is v3).
                    resolveStagedFirstStage fargs fret memberInfo

                else
                    case Dict.get (siteFingerprint fargs fret) memberInfo.buckets of
                        Nothing ->
                            resolvePapSuffix fargs fret argCount memberInfo bumpShapeBucketMiss

                        Just groups ->
                            resolveInGroups fargs fret argCount groups memberInfo

            _ ->
                Decline bumpShapeNonArrow


resolveInGroups : List Mono.MonoType -> Mono.MonoType -> Int -> List LayoutGroup -> MemberInfo -> Resolution
resolveInGroups fargs fret argCount groups memberInfo =
    case groups of
        [] ->
            resolvePapSuffix fargs fret argCount memberInfo bumpShapeLayout

        g :: rest ->
            if g.paramCount == argCount && eqLayoutLists g.rep.paramTypes fargs && Mono.eqLayout g.rep.returnType fret then
                if not g.charFree then
                    Decline bumpShapeChar

                else if g.unanimous then
                    Stamp g.rep

                else
                    Decline bumpAbiMismatch

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
            Decline bumpShapeArityOver

        Just groups ->
            stagedScan fargs fret groups


stagedScan : List Mono.MonoType -> Mono.MonoType -> List LayoutGroup -> Resolution
stagedScan fargs fret groups =
    case groups of
        [] ->
            Decline bumpShapeArityOver

        g :: rest ->
            if g.paramCount == List.length fargs && eqLayoutLists g.rep.paramTypes fargs && Mono.eqLayout g.rep.returnType fret then
                if not g.charFree then
                    Decline bumpShapeChar

                else if g.unanimous then
                    StampStaged g.rep

                else
                    Decline bumpAbiMismatch

            else
                stagedScan fargs fret rest


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
            Decline noMatch

        g :: rest ->
            let
                k =
                    g.paramCount - argCount
            in
            if k >= 1 && eqLayoutLists (List.drop k g.rep.paramTypes) fargs && Mono.eqLayout g.rep.returnType fret then
                if not g.charFree || List.any ((==) Mono.MChar) (List.take k g.rep.paramTypes) then
                    -- the k prefix slots are loaded by the same capture-load
                    -- code as real captures — same i16 gate (E4c lifts it)
                    Decline bumpShapeChar

                else if g.unanimous then
                    StampPap g.rep k

                else
                    Decline bumpAbiMismatch

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
