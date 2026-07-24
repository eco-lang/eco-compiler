module Compiler.GlobalOpt.CafHoist exposing
    ( Stats, emptyStats, run, renderStats
    , zeroRegions, fingerprintOf, typeTouchesBytes
    )

{-| CAF hoisting (plans/caf-hoist-closed-expressions.md, CGEN_069).

Moves every eligible MAXIMAL closed subexpression inside a function body —
a subtree referencing no locals bound outside itself — into a freshly
minted nullary `MonoDefine` spec, replacing the site with a
`MonoVarGlobal`. The existing CAF slot machinery (CGEN_068) then evaluates
each hoisted expression once per process instead of once per call. The
move is VERBATIM: CallInfo/staging/LSS annotations travel with the tree
(all per-node — plan DQ3), and `MonoCase` jump indices are case-local.

MAXIMALITY (plan DQ7, revised after H0 falsified the layered scheme:
layered=12,668 vs maximal-eligible=4,642 — 2.1× mint inflation for no
additional first-order win). Two phases per body:

1.  `collectExpr` — pure bottom-up walk producing the ELIGIBLE-MAXIMAL
    candidate subtree VALUES: a closed+eligible node collects itself and
    discards its children's collections; a closed-but-INELIGIBLE or open
    node passes its children's collections through (so eligible children
    of e.g. bytes-excluded parents still hoist).
2.  `replaceExpr` — top-down rebuild that replaces any node structurally
    equal to a collected candidate (structure-shared `==`, fails fast on
    constructor mismatch; candidate lists per body are tiny) and stops
    descending at a replacement. Two equal maximal candidates in one body
    both match and share one deduped spec — correct.

No dead specs can result (every minted spec is referenced by at least one
replaced site), and nothing is minted for nested candidates.

Dedupe (plan DQ2): closure-free subtrees merge by region-zeroed
STRUCTURAL EQUALITY — collision-impossible — bucketed by a cheap
fingerprint. Closure-containing subtrees hoist per-site un-deduped
(`MonoClosure.lambdaId` is identity-bearing; verbatim move only).

Exclusions (plan DQ4/DQ6): pkg-`bytes`-typed or -headed candidates
(fusion's reified form beats memoization and its strict reifier does not
look through bare globals in operand position); Debug-containing subtrees
(inner `Debug.log` cardinality is not changed silently); scalar-ABI
results (HEAP_035); sizes below `minNodes`.

Determinism (plan DQ8): specId-order fold, structural traversal order,
encounter-order minting during replacement; the dedupe Dict is only ever
looked up, never iterated for output.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Reporting.Annotation as A
import Dict exposing (Dict)
import Set exposing (Set)
import System.TypeCheck.IO as IO
import Utils.Crash


type alias Stats =
    { hoisted : Int -- specs minted
    , sites : Int -- sites replaced (>= hoisted when dedupe hits)
    , deduped : Int -- sites served by an existing spec
    , skippedBudget : Int
    , skippedBytes : Int
    , skippedDebug : Int
    , skippedScalar : Int
    , skippedFnType : Int -- function-typed candidates (callee-shape hazard, plan DQ6.4b)
    , origNodes : Int -- sum of ORIGINAL sizes over replaced sites
    }


emptyStats : Stats
emptyStats =
    { hoisted = 0
    , sites = 0
    , deduped = 0
    , skippedBudget = 0
    , skippedBytes = 0
    , skippedDebug = 0
    , skippedScalar = 0
    , skippedFnType = 0
    , origNodes = 0
    }


renderStats : Stats -> String
renderStats s =
    "caf-hoist: hoisted="
        ++ String.fromInt s.hoisted
        ++ " sites="
        ++ String.fromInt s.sites
        ++ " deduped="
        ++ String.fromInt s.deduped
        ++ " skippedBudget="
        ++ String.fromInt s.skippedBudget
        ++ " skippedBytes="
        ++ String.fromInt s.skippedBytes
        ++ " skippedDebug="
        ++ String.fromInt s.skippedDebug
        ++ " skippedScalar="
        ++ String.fromInt s.skippedScalar
        ++ " skippedFnType="
        ++ String.fromInt s.skippedFnType
        ++ " origNodes="
        ++ String.fromInt s.origNodes


{-| Per-subtree analysis for the collect phase.
-}
type alias Info =
    { free : Set Name.Name
    , size : Int
    , hasClosure : Bool
    , hasDebug : Bool
    }


leafInfo : Info
leafInfo =
    { free = Set.empty, size = 0, hasClosure = False, hasDebug = False }


mergeInfo : Info -> Info -> Info
mergeInfo a b =
    { free = Set.union a.free b.free
    , size = a.size + b.size
    , hasClosure = a.hasClosure || b.hasClosure
    , hasDebug = a.hasDebug || b.hasDebug
    }


{-| An eligible-maximal candidate: the subtree value plus the analysis
facts the mint step needs.
-}
type alias Candidate =
    { expr : Mono.MonoExpr
    , size : Int
    , hasClosure : Bool
    }


type alias Ctx =
    { nextId : Int
    , minted : List ( Mono.MonoExpr, Mono.MonoType ) -- REVERSED mint order
    , dedupe : Dict String (List ( Mono.MonoExpr, Int )) -- fingerprint -> [(zeroed, specId)]
    , stats : Stats
    , maxHoists : Int
    }



-- ====== PUBLIC ENTRY ======


run : { minNodes : Int, maxHoists : Int } -> Mono.MonoGraph -> ( Mono.MonoGraph, Stats )
run cfg (Mono.MonoGraph g) =
    let
        nodesLen =
            Array.length g.nodes

        _ =
            -- Append-only surgery precondition (plan DQ5): specIds are dense
            -- and the registry arrays are nodes-parallel. Never observed to
            -- fail; guards silent drift loudly.
            if g.registry.nextId /= nodesLen || Array.length g.registry.reverseMapping /= nodesLen then
                Utils.Crash.crash
                    ("CafHoist: registry drift: nextId="
                        ++ String.fromInt g.registry.nextId
                        ++ " nodes="
                        ++ String.fromInt nodesLen
                        ++ " reverseMapping="
                        ++ String.fromInt (Array.length g.registry.reverseMapping)
                    )

            else
                ()

        ctx0 : Ctx
        ctx0 =
            { nextId = g.registry.nextId
            , minted = []
            , dedupe = Dict.empty
            , stats = emptyStats
            , maxHoists = cfg.maxHoists
            }

        ( newNodes, ctxFinal ) =
            Array.foldl
                (\maybeNode ( accNodes, accCtx ) ->
                    case maybeNode of
                        Just node ->
                            let
                                ( node1, accCtx1 ) =
                                    hoistNode cfg.minNodes accCtx node
                            in
                            ( Array.push (Just node1) accNodes, accCtx1 )

                        Nothing ->
                            ( Array.push Nothing accNodes, accCtx )
                )
                ( Array.empty, ctx0 )
                g.nodes

        mintedInOrder =
            List.reverse ctxFinal.minted

        nodesWithHoists =
            List.foldl
                (\( expr, ty ) acc -> Array.push (Just (Mono.MonoDefine expr ty)) acc)
                newNodes
                mintedInOrder

        ( reverseMappingWithHoists, _ ) =
            List.foldl
                (\( _, ty ) ( acc, ordinal ) ->
                    ( Array.push
                        (Just
                            ( Mono.Global
                                (IO.Canonical ( "eco", "hoisted" ) "CafHoist")
                                ("hoist_" ++ String.fromInt ordinal)
                            , ty
                            )
                        )
                        acc
                    , ordinal + 1
                    )
                )
                ( g.registry.reverseMapping, 0 )
                mintedInOrder

        registry1 =
            { nextId = ctxFinal.nextId
            , mapping = g.registry.mapping
            , reverseMapping = reverseMappingWithHoists
            }
    in
    ( Mono.MonoGraph
        { g
            | nodes = nodesWithHoists
            , registry = registry1
        }
    , ctxFinal.stats
    )


{-| Bodies walked for hoisting (plan DQ6): function bodies + capture
exprs, and tail-function bodies (loop-invariant hoists). Nullary define
bodies are already memoized whole; ctors/enums/externs/manager
leaves/ports untouched.
-}
hoistNode : Int -> Ctx -> Mono.MonoNode -> ( Mono.MonoNode, Ctx )
hoistNode minNodes ctx node =
    case node of
        Mono.MonoDefine (Mono.MonoClosure info body cty) ty ->
            let
                ( body1, ctx1 ) =
                    hoistBody minNodes ctx body

                ( capturesRev, ctx2 ) =
                    List.foldl
                        (\( n, ce, b ) ( acc, c ) ->
                            let
                                ( ce1, c1 ) =
                                    hoistBody minNodes c ce
                            in
                            ( ( n, ce1, b ) :: acc, c1 )
                        )
                        ( [], ctx1 )
                        info.captures
            in
            ( Mono.MonoDefine
                (Mono.MonoClosure { info | captures = List.reverse capturesRev } body1 cty)
                ty
            , ctx2
            )

        Mono.MonoDefine _ _ ->
            ( node, ctx )

        Mono.MonoTailFunc params body ty ->
            let
                ( body1, ctx1 ) =
                    hoistBody minNodes ctx body
            in
            ( Mono.MonoTailFunc params body1 ty, ctx1 )

        _ ->
            ( node, ctx )


{-| Phase 1 + phase 2 for one body: collect eligible-maximal candidates,
then replace matching sites. Bodies with no candidates (the overwhelming
majority) return verbatim after the pure collect walk.
-}
hoistBody : Int -> Ctx -> Mono.MonoExpr -> ( Mono.MonoExpr, Ctx )
hoistBody minNodes ctx body =
    let
        ( _, cands, ctx1 ) =
            collectExpr minNodes ctx body
    in
    if List.isEmpty cands then
        ( body, ctx1 )

    else
        replaceExpr cands ctx1 body



-- ====== PHASE 1: COLLECT (pure analysis; Ctx only for skip counters) ======


collectExpr : Int -> Ctx -> Mono.MonoExpr -> ( Info, List Candidate, Ctx )
collectExpr minNodes ctx expr =
    let
        ( innerInfo, childCands, ctx1 ) =
            collectChildren minNodes ctx expr

        info =
            { innerInfo | size = innerInfo.size + 1 }
    in
    if Set.isEmpty info.free && candidateKind expr then
        let
            ty =
                Mono.typeOf expr

            bump f =
                { ctx1 | stats = f ctx1.stats }
        in
        if info.size < minNodes then
            ( info, childCands, ctx1 )

        else if not (valueAbi ty) then
            ( info, childCands, bump (\s -> { s | skippedScalar = s.skippedScalar + 1 }) )

        else if isFnType ty then
            -- Function-typed subtrees are EXCLUDED (found via the flag-on
            -- corpus: Combinator* SIGABRTs): a composed-function value
            -- hoisted out of CALLEE position leaves the enclosing MonoCall's
            -- staged CallInfo describing a callee shape that no longer
            -- exists — the typed-apply arity assert fires. CallInfo is
            -- per-node (plan DQ3) but derives FROM the callee expr; the
            -- callee's shape must not change under it.
            ( info, childCands, bump (\s -> { s | skippedFnType = s.skippedFnType + 1 }) )

        else if info.hasDebug then
            ( info, childCands, bump (\s -> { s | skippedDebug = s.skippedDebug + 1 }) )

        else if typeTouchesBytes ty || bytesHeaded expr then
            ( info, childCands, bump (\s -> { s | skippedBytes = s.skippedBytes + 1 }) )

        else
            -- Eligible-maximal: collect SELF, discard nested candidates.
            ( info
            , [ { expr = expr, size = info.size, hasClosure = info.hasClosure } ]
            , ctx1
            )

    else
        ( info, childCands, ctx1 )


collectChildren : Int -> Ctx -> Mono.MonoExpr -> ( Info, List Candidate, Ctx )
collectChildren minNodes ctx expr =
    let
        go =
            collectExpr minNodes

        goList c exprs =
            List.foldl
                (\e ( i, cs, cx ) ->
                    let
                        ( ei, ecs, cx1 ) =
                            go cx e
                    in
                    ( mergeInfo i ei, cs ++ ecs, cx1 )
                )
                ( leafInfo, [], c )
                exprs
    in
    case expr of
        Mono.MonoLiteral _ _ ->
            ( leafInfo, [], ctx )

        Mono.MonoVarLocal n _ ->
            ( { leafInfo | free = Set.singleton n }, [], ctx )

        Mono.MonoVarGlobal _ _ _ ->
            ( leafInfo, [], ctx )

        Mono.MonoVarKernel _ _ home _ _ ->
            ( { leafInfo | hasDebug = home == "Debug" }, [], ctx )

        Mono.MonoUnit ->
            ( leafInfo, [], ctx )

        Mono.MonoAccessorValue _ _ _ ->
            ( leafInfo, [], ctx )

        Mono.MonoList _ items _ ->
            goList ctx items

        Mono.MonoClosure info body _ ->
            let
                ( capInfo, capCands, ctx1 ) =
                    goList ctx (List.map (\( _, ce, _ ) -> ce) info.captures)

                ( bodyInfo, bodyCands, ctx2 ) =
                    go ctx1 body

                bound =
                    Set.fromList
                        (List.map Tuple.first info.params
                            ++ List.map (\( n, _, _ ) -> n) info.captures
                        )

                merged =
                    mergeInfo capInfo { bodyInfo | free = Set.diff bodyInfo.free bound }
            in
            ( { merged | hasClosure = True }, capCands ++ bodyCands, ctx2 )

        Mono.MonoCall _ func args _ _ ->
            goList ctx (func :: args)

        Mono.MonoTailCall n args _ ->
            let
                ( i, cs, ctx1 ) =
                    goList ctx (List.map Tuple.second args)
            in
            ( { i | free = Set.insert n i.free }, cs, ctx1 )

        Mono.MonoIf branches final _ ->
            goList ctx
                (final :: List.concatMap (\( c, t ) -> [ c, t ]) branches)

        Mono.MonoLet def body _ ->
            case def of
                Mono.MonoDef n bound ->
                    let
                        ( bi, bcs, ctx1 ) =
                            go ctx bound

                        ( boi, bocs, ctx2 ) =
                            go ctx1 body
                    in
                    ( mergeInfo bi { boi | free = Set.remove n boi.free }
                    , bcs ++ bocs
                    , ctx2
                    )

                Mono.MonoTailDef n params bound ->
                    let
                        ( bi, bcs, ctx1 ) =
                            go ctx bound

                        paramSet =
                            Set.insert n (Set.fromList (List.map Tuple.first params))

                        ( boi, bocs, ctx2 ) =
                            go ctx1 body
                    in
                    ( mergeInfo { bi | free = Set.diff bi.free paramSet }
                        { boi | free = Set.remove n boi.free }
                    , bcs ++ bocs
                    , ctx2
                    )

        Mono.MonoDestruct (Mono.MonoDestructor n path _) body _ ->
            let
                ( bi, bcs, ctx1 ) =
                    go ctx body
            in
            ( { bi | free = Set.insert (pathRoot path) (Set.remove n bi.free) }
            , bcs
            , ctx1
            )

        Mono.MonoCase s1 s2 decider branches _ ->
            let
                ( di, dcs, ctx1 ) =
                    collectDecider minNodes ctx decider

                ( bi, bcs, ctx2 ) =
                    goList ctx1 (List.map Tuple.second branches)

                merged =
                    mergeInfo di bi
            in
            ( { merged | free = Set.insert s1 (Set.insert s2 merged.free) }
            , dcs ++ bcs
            , ctx2
            )

        Mono.MonoRecordCreate fields _ ->
            goList ctx (List.map Tuple.second fields)

        Mono.MonoRecordAccess rec _ _ ->
            let
                ( ri, rcs, ctx1 ) =
                    go ctx rec
            in
            ( ri, rcs, ctx1 )

        Mono.MonoRecordUpdate rec updates _ ->
            goList ctx (rec :: List.map Tuple.second updates)

        Mono.MonoTupleCreate _ items _ ->
            goList ctx items


collectDecider : Int -> Ctx -> Mono.Decider Mono.MonoChoice -> ( Info, List Candidate, Ctx )
collectDecider minNodes ctx decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            collectExpr minNodes ctx e

        Mono.Leaf (Mono.Jump _) ->
            ( leafInfo, [], ctx )

        Mono.Chain tests succ fail ->
            let
                ( si, scs, ctx1 ) =
                    collectDecider minNodes ctx succ

                ( fi, fcs, ctx2 ) =
                    collectDecider minNodes ctx1 fail

                testFree =
                    List.foldl (\( dtPath, _ ) acc -> Set.insert (dtRoot dtPath) acc)
                        Set.empty
                        tests

                merged =
                    mergeInfo si fi
            in
            ( { merged | free = Set.union testFree merged.free }, scs ++ fcs, ctx2 )

        Mono.FanOut dtPath edges fallback ->
            let
                ( ei, ecs, ctx1 ) =
                    List.foldl
                        (\( _, d ) ( i, cs, c ) ->
                            let
                                ( di, dcs, c1 ) =
                                    collectDecider minNodes c d
                            in
                            ( mergeInfo i di, cs ++ dcs, c1 )
                        )
                        ( leafInfo, [], ctx )
                        edges

                ( fi, fcs, ctx2 ) =
                    collectDecider minNodes ctx1 fallback

                merged =
                    mergeInfo ei fi
            in
            ( { merged | free = Set.insert (dtRoot dtPath) merged.free }
            , ecs ++ fcs
            , ctx2
            )



-- ====== PHASE 2: REPLACE (top-down; stop at a replaced site) ======


replaceExpr : List Candidate -> Ctx -> Mono.MonoExpr -> ( Mono.MonoExpr, Ctx )
replaceExpr cands ctx expr =
    case List.filter (\c -> c.expr == expr) cands of
        c :: _ ->
            mintOrDedupe ctx c

        [] ->
            replaceChildren cands ctx expr


mintOrDedupe : Ctx -> Candidate -> ( Mono.MonoExpr, Ctx )
mintOrDedupe ctx cand =
    let
        ty =
            Mono.typeOf cand.expr
    in
    if cand.hasClosure then
        -- Per-site, un-deduped (plan DQ2).
        mintOrBudget ctx cand ty Nothing

    else
        let
            zeroed =
                zeroRegions cand.expr

            fp =
                fingerprintOf cand.expr ty
        in
        case List.filter (\( z, _ ) -> z == zeroed) (Maybe.withDefault [] (Dict.get fp ctx.dedupe)) of
            ( _, sid ) :: _ ->
                let
                    stats0 =
                        ctx.stats

                    stats1 =
                        { stats0
                            | sites = stats0.sites + 1
                            , deduped = stats0.deduped + 1
                            , origNodes = stats0.origNodes + cand.size
                        }
                in
                ( Mono.MonoVarGlobal A.zero sid ty, { ctx | stats = stats1 } )

            [] ->
                mintOrBudget ctx cand ty (Just ( fp, zeroed ))


mintOrBudget : Ctx -> Candidate -> Mono.MonoType -> Maybe ( String, Mono.MonoExpr ) -> ( Mono.MonoExpr, Ctx )
mintOrBudget ctx cand ty maybeKey =
    if ctx.stats.hoisted >= ctx.maxHoists then
        ( cand.expr
        , { ctx | stats = (\s -> { s | skippedBudget = s.skippedBudget + 1 }) ctx.stats }
        )

    else
        let
            sid =
                ctx.nextId

            stats0 =
                ctx.stats

            stats1 =
                { stats0
                    | hoisted = stats0.hoisted + 1
                    , sites = stats0.sites + 1
                    , origNodes = stats0.origNodes + cand.size
                }

            dedupe1 =
                case maybeKey of
                    Just ( fp, zeroed ) ->
                        Dict.insert fp
                            (( zeroed, sid ) :: Maybe.withDefault [] (Dict.get fp ctx.dedupe))
                            ctx.dedupe

                    Nothing ->
                        ctx.dedupe
        in
        ( Mono.MonoVarGlobal A.zero sid ty
        , { ctx
            | nextId = sid + 1
            , minted = ( cand.expr, ty ) :: ctx.minted
            , dedupe = dedupe1
            , stats = stats1
          }
        )


replaceChildren : List Candidate -> Ctx -> Mono.MonoExpr -> ( Mono.MonoExpr, Ctx )
replaceChildren cands ctx expr =
    let
        go =
            replaceExpr cands

        goList c exprs =
            let
                ( rev, c1 ) =
                    List.foldl
                        (\e ( acc, cx ) ->
                            let
                                ( e1, cx1 ) =
                                    go cx e
                            in
                            ( e1 :: acc, cx1 )
                        )
                        ( [], c )
                        exprs
            in
            ( List.reverse rev, c1 )
    in
    case expr of
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

        Mono.MonoList region items ty ->
            let
                ( items1, ctx1 ) =
                    goList ctx items
            in
            ( Mono.MonoList region items1 ty, ctx1 )

        Mono.MonoClosure info body ty ->
            let
                ( capturesRev, ctx1 ) =
                    List.foldl
                        (\( n, ce, b ) ( acc, c ) ->
                            let
                                ( ce1, c1 ) =
                                    go c ce
                            in
                            ( ( n, ce1, b ) :: acc, c1 )
                        )
                        ( [], ctx )
                        info.captures

                ( body1, ctx2 ) =
                    go ctx1 body
            in
            ( Mono.MonoClosure { info | captures = List.reverse capturesRev } body1 ty
            , ctx2
            )

        Mono.MonoCall region func args ty callInfo ->
            let
                ( func1, ctx1 ) =
                    go ctx func

                ( args1, ctx2 ) =
                    goList ctx1 args
            in
            ( Mono.MonoCall region func1 args1 ty callInfo, ctx2 )

        Mono.MonoTailCall n args ty ->
            let
                ( argsRev, ctx1 ) =
                    List.foldl
                        (\( an, ae ) ( acc, c ) ->
                            let
                                ( ae1, c1 ) =
                                    go c ae
                            in
                            ( ( an, ae1 ) :: acc, c1 )
                        )
                        ( [], ctx )
                        args
            in
            ( Mono.MonoTailCall n (List.reverse argsRev) ty, ctx1 )

        Mono.MonoIf branches final ty ->
            let
                ( branchesRev, ctx1 ) =
                    List.foldl
                        (\( c, t ) ( acc, cx ) ->
                            let
                                ( c1, cx1 ) =
                                    go cx c

                                ( t1, cx2 ) =
                                    go cx1 t
                            in
                            ( ( c1, t1 ) :: acc, cx2 )
                        )
                        ( [], ctx )
                        branches

                ( final1, ctx2 ) =
                    go ctx1 final
            in
            ( Mono.MonoIf (List.reverse branchesRev) final1 ty, ctx2 )

        Mono.MonoLet def body ty ->
            let
                ( def1, ctx1 ) =
                    case def of
                        Mono.MonoDef n bound ->
                            let
                                ( bound1, c1 ) =
                                    go ctx bound
                            in
                            ( Mono.MonoDef n bound1, c1 )

                        Mono.MonoTailDef n params bound ->
                            let
                                ( bound1, c1 ) =
                                    go ctx bound
                            in
                            ( Mono.MonoTailDef n params bound1, c1 )

                ( body1, ctx2 ) =
                    go ctx1 body
            in
            ( Mono.MonoLet def1 body1 ty, ctx2 )

        Mono.MonoDestruct d body ty ->
            let
                ( body1, ctx1 ) =
                    go ctx body
            in
            ( Mono.MonoDestruct d body1 ty, ctx1 )

        Mono.MonoCase s1 s2 decider branches ty ->
            let
                ( decider1, ctx1 ) =
                    replaceDecider cands ctx decider

                ( branchesRev, ctx2 ) =
                    List.foldl
                        (\( idx, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    go c e
                            in
                            ( ( idx, e1 ) :: acc, c1 )
                        )
                        ( [], ctx1 )
                        branches
            in
            ( Mono.MonoCase s1 s2 decider1 (List.reverse branchesRev) ty, ctx2 )

        Mono.MonoRecordCreate fields ty ->
            let
                ( fieldsRev, ctx1 ) =
                    List.foldl
                        (\( n, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    go c e
                            in
                            ( ( n, e1 ) :: acc, c1 )
                        )
                        ( [], ctx )
                        fields
            in
            ( Mono.MonoRecordCreate (List.reverse fieldsRev) ty, ctx1 )

        Mono.MonoRecordAccess rec field ty ->
            let
                ( rec1, ctx1 ) =
                    go ctx rec
            in
            ( Mono.MonoRecordAccess rec1 field ty, ctx1 )

        Mono.MonoRecordUpdate rec updates ty ->
            let
                ( rec1, ctx1 ) =
                    go ctx rec

                ( updatesRev, ctx2 ) =
                    List.foldl
                        (\( n, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    go c e
                            in
                            ( ( n, e1 ) :: acc, c1 )
                        )
                        ( [], ctx1 )
                        updates
            in
            ( Mono.MonoRecordUpdate rec1 (List.reverse updatesRev) ty, ctx2 )

        Mono.MonoTupleCreate region items ty ->
            let
                ( items1, ctx1 ) =
                    goList ctx items
            in
            ( Mono.MonoTupleCreate region items1 ty, ctx1 )


replaceDecider : List Candidate -> Ctx -> Mono.Decider Mono.MonoChoice -> ( Mono.Decider Mono.MonoChoice, Ctx )
replaceDecider cands ctx decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            let
                ( e1, ctx1 ) =
                    replaceExpr cands ctx e
            in
            ( Mono.Leaf (Mono.Inline e1), ctx1 )

        Mono.Leaf (Mono.Jump j) ->
            ( Mono.Leaf (Mono.Jump j), ctx )

        Mono.Chain tests succ fail ->
            let
                ( succ1, ctx1 ) =
                    replaceDecider cands ctx succ

                ( fail1, ctx2 ) =
                    replaceDecider cands ctx1 fail
            in
            ( Mono.Chain tests succ1 fail1, ctx2 )

        Mono.FanOut dtPath edges fallback ->
            let
                ( edgesRev, ctx1 ) =
                    List.foldl
                        (\( t, d ) ( acc, c ) ->
                            let
                                ( d1, c1 ) =
                                    replaceDecider cands c d
                            in
                            ( ( t, d1 ) :: acc, c1 )
                        )
                        ( [], ctx )
                        edges

                ( fallback1, ctx2 ) =
                    replaceDecider cands ctx1 fallback
            in
            ( Mono.FanOut dtPath (List.reverse edgesRev) fallback1, ctx2 )



-- ====== ELIGIBILITY ======


candidateKind : Mono.MonoExpr -> Bool
candidateKind expr =
    case expr of
        Mono.MonoCall _ _ _ _ _ ->
            True

        Mono.MonoLet _ _ _ ->
            True

        Mono.MonoIf _ _ _ ->
            True

        Mono.MonoCase _ _ _ _ _ ->
            True

        Mono.MonoDestruct _ _ _ ->
            True

        Mono.MonoRecordCreate _ _ ->
            True

        Mono.MonoRecordUpdate _ _ _ ->
            True

        Mono.MonoTupleCreate _ _ _ ->
            True

        Mono.MonoList _ items _ ->
            not (List.isEmpty items)

        _ ->
            False


{-| Scalar-ABI results are outside the slot scope (HEAP_035): mirrors
Types.monoTypeToAbi without a Generate-layer import.
-}
valueAbi : Mono.MonoType -> Bool
valueAbi t =
    case t of
        Mono.MInt ->
            False

        Mono.MFloat ->
            False

        Mono.MChar ->
            False

        Mono.MVar _ Mono.CNumber ->
            False

        _ ->
            True


{-| Function-typed exclusion (plan DQ6.4b): see the eligibility comment.
`MVar CEcoValue` can in principle erase a function type — accepted residual
risk, gated by the corpus (erased types cannot sit in staged callee
position, which is the hazard).
-}
isFnType : Mono.MonoType -> Bool
isFnType t =
    case t of
        Mono.MFunction _ _ _ ->
            True

        _ ->
            False


{-| pkg-`bytes` exclusion, TYPE side (plan DQ4): never hoist a value whose
type reaches an elm/bytes type (Encoder/Decoder/Bytes) — those are
fusion's operands; the strict reifier does not look through bare globals.
`MFunction` is a barrier (encoder-RETURNING functions are fine).
-}
typeTouchesBytes : Mono.MonoType -> Bool
typeTouchesBytes t =
    case t of
        Mono.MCustom (IO.Canonical pkg _) _ args ->
            pkg == ( "elm", "bytes" ) || List.any typeTouchesBytes args

        Mono.MList inner ->
            typeTouchesBytes inner

        Mono.MTuple items ->
            List.any typeTouchesBytes items

        Mono.MRecord fields ->
            Dict.foldl (\_ ft acc -> acc || typeTouchesBytes ft) False fields

        Mono.MFunction _ _ _ ->
            False

        _ ->
            False


{-| pkg-`bytes` exclusion, HEAD side (belt to the type rule): a call whose
head is a Bytes kernel. Global heads are covered by the type rule (their
results are bytes-typed when it matters).
-}
bytesHeaded : Mono.MonoExpr -> Bool
bytesHeaded expr =
    case expr of
        Mono.MonoCall _ (Mono.MonoVarKernel _ _ "Bytes" _ _) _ _ _ ->
            True

        _ ->
            False


pathRoot : Mono.MonoPath -> Name.Name
pathRoot path =
    case path of
        Mono.MonoRoot n _ ->
            n

        Mono.MonoIndex _ _ _ rest ->
            pathRoot rest

        Mono.MonoField _ _ rest ->
            pathRoot rest

        Mono.MonoUnbox _ rest ->
            pathRoot rest


dtRoot : Mono.MonoDtPath -> Name.Name
dtRoot path =
    case path of
        Mono.DtRoot n _ ->
            n

        Mono.DtIndex _ _ _ rest ->
            dtRoot rest

        Mono.DtUnbox _ rest ->
            dtRoot rest



-- ====== DEDUPE MACHINERY (plan DQ2 / §3) ======


{-| Rewrite every Region (the ONLY non-semantic payload in MonoExpr) to
A.zero so structural equality compares meaning, not source positions.
Only called on closure-free subtrees (closure-containing candidates never
dedupe), but handles MonoClosure anyway for totality.
-}
zeroRegions : Mono.MonoExpr -> Mono.MonoExpr
zeroRegions expr =
    case expr of
        Mono.MonoLiteral l ty ->
            Mono.MonoLiteral l ty

        Mono.MonoVarLocal n ty ->
            Mono.MonoVarLocal n ty

        Mono.MonoVarGlobal _ sid ty ->
            Mono.MonoVarGlobal A.zero sid ty

        Mono.MonoVarKernel _ p h n ty ->
            Mono.MonoVarKernel A.zero p h n ty

        Mono.MonoUnit ->
            Mono.MonoUnit

        Mono.MonoAccessorValue _ n ty ->
            Mono.MonoAccessorValue A.zero n ty

        Mono.MonoList _ items ty ->
            Mono.MonoList A.zero (List.map zeroRegions items) ty

        Mono.MonoClosure info body ty ->
            Mono.MonoClosure
                { info | captures = List.map (\( n, ce, b ) -> ( n, zeroRegions ce, b )) info.captures }
                (zeroRegions body)
                ty

        Mono.MonoCall _ func args ty callInfo ->
            Mono.MonoCall A.zero (zeroRegions func) (List.map zeroRegions args) ty callInfo

        Mono.MonoTailCall n args ty ->
            Mono.MonoTailCall n (List.map (\( an, ae ) -> ( an, zeroRegions ae )) args) ty

        Mono.MonoIf branches final ty ->
            Mono.MonoIf
                (List.map (\( c, t ) -> ( zeroRegions c, zeroRegions t )) branches)
                (zeroRegions final)
                ty

        Mono.MonoLet def body ty ->
            Mono.MonoLet (zeroRegionsDef def) (zeroRegions body) ty

        Mono.MonoDestruct d body ty ->
            Mono.MonoDestruct d (zeroRegions body) ty

        Mono.MonoCase s1 s2 decider branches ty ->
            Mono.MonoCase s1
                s2
                (zeroRegionsDecider decider)
                (List.map (\( i, e ) -> ( i, zeroRegions e )) branches)
                ty

        Mono.MonoRecordCreate fields ty ->
            Mono.MonoRecordCreate (List.map (\( n, e ) -> ( n, zeroRegions e )) fields) ty

        Mono.MonoRecordAccess rec field ty ->
            Mono.MonoRecordAccess (zeroRegions rec) field ty

        Mono.MonoRecordUpdate rec updates ty ->
            Mono.MonoRecordUpdate (zeroRegions rec)
                (List.map (\( n, e ) -> ( n, zeroRegions e )) updates)
                ty

        Mono.MonoTupleCreate _ items ty ->
            Mono.MonoTupleCreate A.zero (List.map zeroRegions items) ty


zeroRegionsDef : Mono.MonoDef -> Mono.MonoDef
zeroRegionsDef def =
    case def of
        Mono.MonoDef n e ->
            Mono.MonoDef n (zeroRegions e)

        Mono.MonoTailDef n params e ->
            Mono.MonoTailDef n params (zeroRegions e)


zeroRegionsDecider : Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
zeroRegionsDecider decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            Mono.Leaf (Mono.Inline (zeroRegions e))

        Mono.Leaf (Mono.Jump j) ->
            Mono.Leaf (Mono.Jump j)

        Mono.Chain tests succ fail ->
            Mono.Chain tests (zeroRegionsDecider succ) (zeroRegionsDecider fail)

        Mono.FanOut path edges fallback ->
            Mono.FanOut path
                (List.map (\( t, d ) -> ( t, zeroRegionsDecider d )) edges)
                (zeroRegionsDecider fallback)


{-| Cheap bucket key; equality within a bucket is exact (`==` on zeroed
trees), so this only affects bucket sizes, never correctness.
-}
fingerprintOf : Mono.MonoExpr -> Mono.MonoType -> String
fingerprintOf expr ty =
    let
        kindTag =
            case expr of
                Mono.MonoCall _ func _ _ _ ->
                    "c:" ++ headTag func

                Mono.MonoLet _ _ _ ->
                    "l"

                Mono.MonoIf _ _ _ ->
                    "i"

                Mono.MonoCase _ _ _ _ _ ->
                    "k"

                Mono.MonoDestruct _ _ _ ->
                    "d"

                Mono.MonoRecordCreate _ _ ->
                    "r"

                Mono.MonoRecordUpdate _ _ _ ->
                    "u"

                Mono.MonoTupleCreate _ _ _ ->
                    "t"

                Mono.MonoList _ items _ ->
                    "s" ++ String.fromInt (List.length items)

                _ ->
                    "x"

        headTag func =
            case func of
                Mono.MonoVarGlobal _ sid _ ->
                    "g" ++ String.fromInt sid

                Mono.MonoVarKernel _ _ home name _ ->
                    "k" ++ home ++ "." ++ name

                _ ->
                    "dyn"
    in
    kindTag ++ "|" ++ Mono.toComparableMonoType ty
