module Compiler.GlobalOpt.MonoInlineSimplify exposing (Metrics, optimize, buildBodyLookup, countClosures)

{-| Mono IR Inliner and Simplifier.

This pass runs after monomorphization and before MLIR generation to
reduce/eliminate higher-order "pipeline plumbing" before it becomes
ECO closures/PAPs.

Key optimizations:

  - Small-function inlining (with recursion guard)
  - Beta-reduction of immediate lambdas
  - Let-callee forwarding (a let-bound closure whose single use is the
    callee of a call is beta-reduced into that call site)
  - Let-sinking/let-elimination
  - Dead code elimination (incl. chain-aware dead closure bindings)
  - Case simplifications

@docs Metrics, optimize, buildBodyLookup, countClosures

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..), MonoGraph(..), MonoNode(..), SpecId)
import Compiler.Data.BitSet as BitSet
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.Graph as Graph
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.MonoTraverse as Traverse
import Compiler.Reporting.Annotation as A exposing (Region)
import Dict exposing (Dict)
import System.TypeCheck.IO as IO



-- ============================================================================
-- ====== PUBLIC API ======
-- ============================================================================


{-| Metrics collected during optimization, available for debugging and the
`ECO_INLINE_REPORT=1` census (HOF-elimination plan H0.2/H1.3):

  - `betaForwards` counts let-bound closures forwarded into their single
    callee-position use (H1.1).
  - `closureDCE` counts dead closure bindings dropped by the chain-aware
    let simplifier (H1.2).
  - `inlinedByCallee` tallies successful direct-call inlines per callee
    global ("Module.name").

-}
type alias Metrics =
    { inlineCount : Int
    , betaReductions : Int
    , betaForwards : Int
    , letEliminations : Int
    , closureDCE : Int
    , inlinedByCallee : Dict String Int
    }


{-| Public reifier-facing helper: build a `SpecId -> (params, body)`
lookup table over the final, post-inline `MonoGraph.nodes` array,
excluding recursive specs so the consumer (typically the bytes-fusion
reifier doing beta-reduction at reify time) can't accidentally loop on
self-referential helpers.

Mirrors the eligibility checks the inliner itself uses
(`isRecursive` + `getInlinableBody`), but consumes the
post-optimisation graph so each entry reflects the function's body as
it would actually execute (any nested helpers it called have already
been inlined into its body).

Used by `Compiler.Generate.MLIR.BytesFusion.Reify.reifyMapBody`'s
`MonoVarGlobal` arm — closure conversion turns inline lambdas into
global function references, so the reifier needs this lookup to apply
a per-element encoder lambda to a synthetic iteration variable.

-}
buildBodyLookup : MonoGraph -> Dict SpecId ( List ( Name, Mono.MonoType ), MonoExpr )
buildBodyLookup (MonoGraph { nodes, callEdges }) =
    let
        callGraph =
            buildCallGraph nodes callEdges
    in
    Array.foldl
        (\maybeNode ( accDict, specId ) ->
            case maybeNode of
                Nothing ->
                    ( accDict, specId + 1 )

                Just node ->
                    let
                        isRecursive =
                            Dict.get specId callGraph.isRecursive
                                |> Maybe.withDefault False
                    in
                    if isRecursive then
                        ( accDict, specId + 1 )

                    else
                        case getInlinableBody node of
                            Nothing ->
                                ( accDict, specId + 1 )

                            Just ( params, body ) ->
                                -- Keep case bodies out of THIS lookup even
                                -- though the inliner proper accepts them
                                -- (H2.0): the consumer is the bytes-fusion
                                -- reifier's reify-time beta-reducer, whose
                                -- tolerance for case bodies has not been
                                -- verified.
                                if isCase body then
                                    ( accDict, specId + 1 )

                                else
                                    ( Dict.insert specId ( params, body ) accDict, specId + 1 )
        )
        ( Dict.empty, 0 )
        nodes
        |> Tuple.first


{-| Static census helper (`ECO_INLINE_REPORT=1`): count the `MonoClosure`
nodes remaining in the graph. Top-level closures of function definitions are
skipped — they lower to `func.func`s, not runtime allocations; only closures
in expression position (which become `eco.papCreate`s at reference sites)
are counted.
-}
countClosures : MonoGraph -> Int
countClosures (MonoGraph { nodes }) =
    let
        countInExpr : MonoExpr -> Int
        countInExpr e =
            Traverse.foldExpr
                (\sub acc ->
                    case sub of
                        MonoClosure _ _ _ ->
                            acc + 1

                        _ ->
                            acc
                )
                0
                e

        countInNode : MonoNode -> Int
        countInNode node =
            case node of
                MonoDefine (MonoClosure _ body _) _ ->
                    countInExpr body

                MonoDefine expr _ ->
                    countInExpr expr

                MonoTailFunc _ expr _ ->
                    countInExpr expr

                MonoPortIncoming expr _ ->
                    countInExpr expr

                MonoPortOutgoing expr _ ->
                    countInExpr expr

                _ ->
                    0
    in
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just node ->
                    acc + countInNode node

                Nothing ->
                    acc
        )
        0
        nodes


{-| Optimize a MonoGraph by inlining small functions and simplifying expressions.
-}
optimize : Config.InlineConfig -> MonoGraph -> ( MonoGraph, Metrics )
optimize inlineConfig graph =
    let
        (MonoGraph { nodes, main, registry, ctorShapes, nextLambdaIndex, callEdges, ports, flagsDecoder }) =
            graph

        callGraph =
            buildCallGraph nodes callEdges

        ctx =
            initRewriteCtx inlineConfig nodes registry callGraph nextLambdaIndex

        -- Convert nodes to a list so the Array can be GC'd during the fold.
        -- List.foldl releases consumed cons cells, enabling incremental GC
        -- of the input graph while building the output graph.
        nodesList =
            Array.toList nodes
    in
    -- Call a separate function so `nodes` (Array) goes out of scope
    -- and becomes GC-eligible. Only `nodesList` is passed forward.
    optimizeNodes nodesList ctx main registry ctorShapes ports flagsDecoder


optimizeNodes :
    List (Maybe MonoNode)
    -> RewriteCtx
    -> Maybe Mono.MainInfo
    -> Mono.SpecializationRegistry
    -> Dict String (List Mono.CtorShape)
    -> List Mono.PortRegistration
    -> Maybe Mono.SpecId
    -> ( MonoGraph, Metrics )
optimizeNodes nodesList ctx main registry ctorShapes ports flagsDecoder =
    let
        ( optimizedNodesList, finalCtx, _ ) =
            List.foldl
                (\maybeNode ( accList, accCtx, specId ) ->
                    case maybeNode of
                        Nothing ->
                            ( Nothing :: accList, accCtx, specId + 1 )

                        Just node ->
                            let
                                ( optimizedNode, newCtx ) =
                                    optimizeNode accCtx specId node
                            in
                            ( Just optimizedNode :: accList, newCtx, specId + 1 )
                )
                ( [], ctx, 0 )
                nodesList

        optimizedNodes =
            Array.fromList (List.reverse optimizedNodesList)

        metrics =
            finalCtx.metrics
    in
    ( MonoGraph
        { nodes = optimizedNodes
        , main = main
        , registry = registry
        , ctorShapes = ctorShapes
        , nextLambdaIndex = finalCtx.lambdaCounter
        , callEdges = Array.empty
        , specHasEffects = BitSet.empty
        , specValueUsed = BitSet.empty
        , ports = ports
        , flagsDecoder = flagsDecoder
        }
    , metrics
    )



-- ============================================================================
-- ====== WHITELIST ======
-- ============================================================================


{-| List of qualified names (module.name) that should always be inlined.
Using a List since the whitelist is expected to be small.
The format is "Module.Path.name" where the module path is joined with dots.
-}
type alias InlineWhitelist =
    List String


{-| Default whitelist of qualified names that always inline, bypassing the
cost threshold. Two groups:

  - elm/bytes public API primitives — thin wrappers around the I8/I16/U8/…
    encoder constructors and the matching Bytes.Decode combinators. Inlining
    them exposes the constructor / kernel-call shape to the bytes-fusion
    reifier at the call site.

  - Eco-internal encoder/decoder helpers (Utils.Bytes.{Encode,Decode}._,
    Mlir.Bytecode.VarInt._, Mlir.Bytecode.Section.encodeSection). These are
    above the default cost threshold but are pure compositions of elm/bytes
    primitives. Inlining substitutes their body at the call site, where the
    general fusion reifier patterns (literal-list + cons-of-List.map ELoop)
    can match the substituted code.

`Bytes.Encode.encode` and `Bytes.Decode.decode` are deliberately omitted:
those are the fusion entry points the recognizer matches on; inlining them
would replace them with the C++ kernel call and defeat fusion.

`isRecursive` already gates inlining for recursive functions independently,
so a recursive helper on this list still won't inline. The shell of a
recursive helper inlines if its non-recursive cost remains under budget,
but recursive bodies stay as function calls.

-}
defaultWhitelist : InlineWhitelist
defaultWhitelist =
    [ -- elm/bytes encoder primitives (constructor wrappers + small helpers)
      "Bytes.Encode.signedInt8"
    , "Bytes.Encode.signedInt16"
    , "Bytes.Encode.signedInt32"
    , "Bytes.Encode.unsignedInt8"
    , "Bytes.Encode.unsignedInt16"
    , "Bytes.Encode.unsignedInt32"
    , "Bytes.Encode.float32"
    , "Bytes.Encode.float64"
    , "Bytes.Encode.bytes"
    , "Bytes.Encode.string"
    , "Bytes.Encode.sequence"
    , "Bytes.Encode.getStringWidth"

    -- elm/bytes decoder primitives + combinators
    , "Bytes.Decode.signedInt8"
    , "Bytes.Decode.signedInt16"
    , "Bytes.Decode.signedInt32"
    , "Bytes.Decode.unsignedInt8"
    , "Bytes.Decode.unsignedInt16"
    , "Bytes.Decode.unsignedInt32"
    , "Bytes.Decode.float32"
    , "Bytes.Decode.float64"
    , "Bytes.Decode.bytes"
    , "Bytes.Decode.string"
    , "Bytes.Decode.succeed"
    , "Bytes.Decode.fail"
    , "Bytes.Decode.map"
    , "Bytes.Decode.map2"
    , "Bytes.Decode.map3"
    , "Bytes.Decode.map4"
    , "Bytes.Decode.map5"
    , "Bytes.Decode.andThen"

    -- Eco-internal encoder helpers. Inlining-only; the reifier never sees
    -- these names (it only sees the elm/bytes primitives + List.map/cons
    -- that they expand into).
    , "Utils.Bytes.Encode.unit"
    , "Utils.Bytes.Encode.bool"
    , "Utils.Bytes.Encode.int"
    , "Utils.Bytes.Encode.float"
    , "Utils.Bytes.Encode.string"
    , "Utils.Bytes.Encode.maybe"
    , "Utils.Bytes.Encode.result"
    , "Utils.Bytes.Encode.list"
    , "Utils.Bytes.Encode.nonempty"
    , "Utils.Bytes.Encode.stdDict"
    , "Utils.Bytes.Encode.assocListDict"
    , "Utils.Bytes.Encode.everySet"
    , "Utils.Bytes.Encode.jsonPair"
    , "Utils.Bytes.Encode.oneOrMore"

    -- Eco-internal decoder helpers
    , "Utils.Bytes.Decode.unit"
    , "Utils.Bytes.Decode.bool"
    , "Utils.Bytes.Decode.int"
    , "Utils.Bytes.Decode.float"
    , "Utils.Bytes.Decode.string"
    , "Utils.Bytes.Decode.maybe"
    , "Utils.Bytes.Decode.result"
    , "Utils.Bytes.Decode.list"
    , "Utils.Bytes.Decode.nonempty"
    , "Utils.Bytes.Decode.stdDict"
    , "Utils.Bytes.Decode.assocListDict"
    , "Utils.Bytes.Decode.everySet"
    , "Utils.Bytes.Decode.jsonPair"
    , "Utils.Bytes.Decode.oneOrMore"

    -- MLIR bytecode encoder helpers used in the compiler's own .mlir output
    , "Mlir.Bytecode.VarInt.encodeVarInt"
    , "Mlir.Bytecode.VarInt.encodeSignedVarInt"
    , "Mlir.Bytecode.Section.encodeSection"
    ]


{-| Convert a Global to a qualified name string for whitelist lookup.
Format is "Module.name" where Module is the module path.
-}
globalToQualifiedName : Mono.Global -> Maybe String
globalToQualifiedName global =
    case global of
        Mono.Global (IO.Canonical _ moduleName) name ->
            Just (moduleName ++ "." ++ name)

        Mono.Accessor _ ->
            Nothing


isWhitelisted : InlineWhitelist -> Mono.Global -> Bool
isWhitelisted whitelist global =
    case globalToQualifiedName global of
        Just qualifiedName ->
            List.member qualifiedName whitelist

        Nothing ->
            False



-- ============================================================================
-- ====== CALL GRAPH ======
-- ============================================================================


{-| Call graph with SCC-based recursion detection.
-}
type alias CallGraph =
    { edges : Array (Maybe (List SpecId))
    , isRecursive : Dict SpecId Bool
    }


buildCallGraph : Array (Maybe MonoNode) -> Array (Maybe (List SpecId)) -> CallGraph
buildCallGraph nodes edges =
    let
        -- Step 1: Assign dense indices 0..n-1 to each live SpecId
        specIds : List SpecId
        specIds =
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Just _ ->
                            ( specId + 1, specId :: acc )

                        Nothing ->
                            ( specId + 1, acc )
                )
                ( 0, [] )
                nodes
                |> Tuple.second
                |> List.reverse

        n : Int
        n =
            List.length specIds

        indexToSpecId : Array SpecId
        indexToSpecId =
            Array.fromList specIds

        idToIndex : Dict SpecId Int
        idToIndex =
            List.foldl
                (\( idx, specId ) acc -> Dict.insert specId idx acc)
                Dict.empty
                (List.indexedMap Tuple.pair specIds)

        -- Step 2: Build forward and transposed adjacency + selfLoop bitset
        -- Accumulate in Dict first, then convert to Array in one pass
        buildResult =
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Nothing ->
                            ( specId + 1, acc )

                        Just _ ->
                            let
                                idx =
                                    Dict.get specId idToIndex
                                        |> Maybe.withDefault -1

                                neighborSpecIds =
                                    Array.get specId edges
                                        |> Maybe.andThen identity
                                        |> Maybe.withDefault []

                                neighborIdxs =
                                    List.filterMap
                                        (\sid -> Dict.get sid idToIndex)
                                        neighborSpecIds

                                hasSelfLoop =
                                    List.member idx neighborIdxs

                                newFwd =
                                    if idx >= 0 then
                                        Dict.insert idx neighborIdxs acc.fwd

                                    else
                                        acc.fwd

                                newTrans =
                                    List.foldl
                                        (\target t ->
                                            let
                                                existing =
                                                    Dict.get target t |> Maybe.withDefault []
                                            in
                                            Dict.insert target (idx :: existing) t
                                        )
                                        acc.trans
                                        neighborIdxs

                                newSelfLoops =
                                    if hasSelfLoop && idx >= 0 then
                                        BitSet.insert idx acc.selfLoops

                                    else
                                        acc.selfLoops
                            in
                            ( specId + 1, { fwd = newFwd, trans = newTrans, selfLoops = newSelfLoops } )
                )
                ( 0, { fwd = Dict.empty, trans = Dict.empty, selfLoops = BitSet.emptyWithSize n } )
                nodes
                |> Tuple.second

        fwdArray : Array (List Int)
        fwdArray =
            Array.initialize n (\i -> Dict.get i buildResult.fwd |> Maybe.withDefault [])

        transArray : Array (List Int)
        transArray =
            Array.initialize n (\i -> Dict.get i buildResult.trans |> Maybe.withDefault [])

        -- Step 3: Run SCC on IntGraph
        sccsInt : List (Graph.SCC Int)
        sccsInt =
            Graph.stronglyConnCompInt
                { fwd = fwdArray
                , trans = transArray
                , selfLoops = buildResult.selfLoops
                , size = n
                }

        -- Step 4: Mark recursive nodes (those in CyclicSCC)
        isRecursiveFromSCC =
            List.foldl
                (\scc acc ->
                    case scc of
                        Graph.AcyclicSCC _ ->
                            acc

                        Graph.CyclicSCC idxs ->
                            List.foldl
                                (\idx innerAcc ->
                                    case Array.get idx indexToSpecId of
                                        Just sid ->
                                            Dict.insert sid True innerAcc

                                        Nothing ->
                                            innerAcc
                                )
                                acc
                                idxs
                )
                Dict.empty
                sccsInt
    in
    { edges = edges
    , isRecursive = isRecursiveFromSCC
    }



-- ============================================================================
-- ====== COST MODEL ======
-- ============================================================================


sumBy : (a -> Int) -> List a -> Int
sumBy f list =
    List.foldl (\x acc -> acc + f x) 0 list


computeCost : MonoExpr -> Int
computeCost expr =
    case expr of
        MonoLiteral _ _ ->
            1

        MonoVarLocal _ _ ->
            1

        MonoVarGlobal _ _ _ ->
            1

        MonoVarKernel _ _ _ _ _ ->
            1

        MonoUnit ->
            1

        MonoAccessorValue _ _ _ ->
            1

        MonoList _ items _ ->
            3 + sumBy computeCost items

        MonoClosure _ body _ ->
            5 + computeCost body

        MonoCall _ func args _ _ ->
            5 + computeCost func + sumBy computeCost args

        MonoTailCall _ args _ ->
            5 + sumBy (\( _, e ) -> computeCost e) args

        MonoIf branches final _ ->
            2 + sumBy (\( c, t ) -> computeCost c + computeCost t) branches + computeCost final

        MonoLet def body _ ->
            2 + computeCostDef def + computeCost body

        MonoDestruct _ inner _ ->
            2 + computeCost inner

        MonoCase _ _ decider branches _ ->
            -- Count the decider's Inline leaf bodies too: they are real code,
            -- and before the H2.0 case-guard lift this hole was masked (case
            -- bodies never inlined). Without it a case whose branches all
            -- live in Inline leaves costs 3 regardless of size.
            3 + computeCostDecider decider + sumBy (\( _, e ) -> computeCost e) branches

        MonoRecordCreate fields _ ->
            3 + sumBy (\( _, e ) -> computeCost e) fields

        MonoRecordAccess inner _ _ ->
            1 + computeCost inner

        MonoRecordUpdate inner updates _ ->
            3 + computeCost inner + sumBy (\( _, e ) -> computeCost e) updates

        MonoTupleCreate _ items _ ->
            3 + sumBy computeCost items


computeCostDef : Mono.MonoDef -> Int
computeCostDef def =
    case def of
        Mono.MonoDef _ bound ->
            computeCost bound

        Mono.MonoTailDef _ _ bound ->
            computeCost bound


computeCostDecider : Mono.Decider Mono.MonoChoice -> Int
computeCostDecider decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            computeCost e

        Mono.Leaf (Mono.Jump _) ->
            0

        Mono.Chain _ success failure ->
            1 + computeCostDecider success + computeCostDecider failure

        Mono.FanOut _ tests fallback ->
            1
                + sumBy (\( _, d ) -> computeCostDecider d) tests
                + computeCostDecider fallback



-- ============================================================================
-- ====== REWRITE CONTEXT ======
-- ============================================================================


type alias RewriteCtx =
    -- (params, body, exactOnly): exactOnly candidates were admitted via the
    -- H2 hofBudget (cost above the general threshold, not whitelisted) and
    -- may inline at EXACT application only — the partial-application rebuild
    -- produces a re-staged closure whose runtime arity metadata the typed
    -- over-application path cannot chain (spliceArgsForSaturatedCall assert;
    -- CombinatorB* corpus pins). Legacy and whitelisted candidates keep full
    -- pre-H2 privileges.
    { inlineCandidates : Dict Int ( List ( Name, Mono.MonoType ), MonoExpr, Bool )
    , registry : Mono.SpecializationRegistry
    , whitelist : InlineWhitelist
    , maxInlinesPerFunction : Int
    , maxIterations : Int
    , inlineCountThisFunction : Int
    , varCounter : Int
    , lambdaCounter : Int
    , metrics : InternalMetrics
    }


type alias InternalMetrics =
    { inlineCount : Int
    , betaReductions : Int
    , betaForwards : Int
    , letEliminations : Int
    , closureDCE : Int
    , inlinedByCallee : Dict String Int
    }


bumpBetaReductions : RewriteCtx -> RewriteCtx
bumpBetaReductions ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | betaReductions = m.betaReductions + 1 } }


bumpBetaForwards : RewriteCtx -> RewriteCtx
bumpBetaForwards ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | betaForwards = m.betaForwards + 1 } }


bumpLetElimination : RewriteCtx -> RewriteCtx
bumpLetElimination ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | letEliminations = m.letEliminations + 1 } }


bumpClosureDCE : RewriteCtx -> RewriteCtx
bumpClosureDCE ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | closureDCE = m.closureDCE + 1 } }


{-| Record a successful direct-call inline: global count, per-callee tally,
and the per-function budget counter.
-}
recordInline : SpecId -> RewriteCtx -> RewriteCtx
recordInline specId ctx =
    let
        m =
            ctx.metrics

        calleeKey =
            Array.get specId ctx.registry.reverseMapping
                |> Maybe.andThen identity
                |> Maybe.andThen (\( g, _ ) -> globalToQualifiedName g)
                |> Maybe.withDefault ("spec:" ++ String.fromInt specId)
    in
    { ctx
        | metrics =
            { m
                | inlineCount = m.inlineCount + 1
                , inlinedByCallee =
                    Dict.insert calleeKey
                        (1 + Maybe.withDefault 0 (Dict.get calleeKey m.inlinedByCallee))
                        m.inlinedByCallee
            }
        , inlineCountThisFunction = ctx.inlineCountThisFunction + 1
    }


{-| H2 "called-param" heuristic: does the candidate have a function-typed
parameter that appears in CALLEE position in its body? Such candidates get
the wider `hofThreshold` budget — inlining them lets a lambda argument
beta-reduce away at the call site (`Maybe.andThen`-style case+call bodies).
A function-typed param that is merely STORED (a `Task.andThen`-style body
that tucks the callback into a structure) does not qualify: inlining those
is pure code growth, the lambda escapes into data either way.

The callee check is name-based without shadow tracking — sound as a
heuristic: canonicalization forbids shadowing, and a false positive merely
widens one candidate's budget.
-}
hasCalledFunctionParam : List ( Name, Mono.MonoType ) -> MonoExpr -> Bool
hasCalledFunctionParam params body =
    let
        funcParams =
            List.filterMap
                (\( n, pt ) ->
                    case pt of
                        Mono.MFunction _ _ _ ->
                            Just n

                        _ ->
                            Nothing
                )
                params
    in
    not (List.isEmpty funcParams)
        && Traverse.foldExpr
            (\e acc ->
                acc
                    || (case e of
                            MonoCall _ (MonoVarLocal n _) _ _ _ ->
                                List.member n funcParams

                            _ ->
                                False
                       )
            )
            False
            body


initRewriteCtx : Config.InlineConfig -> Array (Maybe MonoNode) -> Mono.SpecializationRegistry -> CallGraph -> Int -> RewriteCtx
initRewriteCtx inlineConfig nodes registry callGraph nextLambdaIndex =
    let
        -- Effective whitelist: built-in defaults plus config additions, minus
        -- the config blacklist (see Compiler.Eco.Config.InlineConfig).
        effectiveWhitelist =
            List.filter
                (\name -> not (List.member name inlineConfig.blacklist))
                (defaultWhitelist ++ inlineConfig.whitelist)

        -- H2: budget for candidates with a CALLED function-typed parameter.
        -- `max` so a raised general threshold is never undercut.
        hofBudget =
            max inlineConfig.threshold inlineConfig.hofThreshold

        candidates =
            Array.foldl
                (\maybeNode ( accDict, specId ) ->
                    case maybeNode of
                        Nothing ->
                            ( accDict, specId + 1 )

                        Just node ->
                            let
                                isRecursive =
                                    Dict.get specId callGraph.isRecursive
                                        |> Maybe.withDefault False
                            in
                            if isRecursive then
                                ( accDict, specId + 1 )

                            else
                                case getInlinableBody node of
                                    Nothing ->
                                        ( accDict, specId + 1 )

                                    Just ( params, body ) ->
                                        let
                                            cost =
                                                computeCost body

                                            maybeGlobal =
                                                Array.get specId registry.reverseMapping
                                                    |> Maybe.andThen identity
                                                    |> Maybe.map (\( g, _ ) -> g)

                                            whitelisted =
                                                maybeGlobal
                                                    |> Maybe.map (isWhitelisted effectiveWhitelist)
                                                    |> Maybe.withDefault False

                                            -- Ordered so the body scan only
                                            -- runs for candidates over the
                                            -- general threshold (the common
                                            -- case stays one int compare).
                                            withinBudget =
                                                cost
                                                    <= inlineConfig.threshold
                                                    || (cost
                                                            <= hofBudget
                                                            && hasCalledFunctionParam params body
                                                       )

                                            exactOnly =
                                                cost > inlineConfig.threshold && not whitelisted
                                        in
                                        if not withinBudget && not whitelisted then
                                            ( accDict, specId + 1 )

                                        else
                                            ( Dict.insert specId ( params, body, exactOnly ) accDict, specId + 1 )
                )
                ( Dict.empty, 0 )
                nodes
                |> Tuple.first
    in
    { inlineCandidates = candidates
    , registry = registry
    , whitelist = effectiveWhitelist
    , maxInlinesPerFunction = inlineConfig.maxPerFunction
    , maxIterations = inlineConfig.fixpointIterations
    , inlineCountThisFunction = 0
    , varCounter = 0
    , lambdaCounter = nextLambdaIndex
    , metrics =
        { inlineCount = 0
        , betaReductions = 0
        , betaForwards = 0
        , letEliminations = 0
        , closureDCE = 0
        , inlinedByCallee = Dict.empty
        }
    }


freshVar : RewriteCtx -> ( Name, RewriteCtx )
freshVar ctx =
    ( "mono_inline_" ++ String.fromInt ctx.varCounter
    , { ctx | varCounter = ctx.varCounter + 1 }
    )


{-| Generate a fresh lambda ID to avoid duplicate lambda names when inlining.
-}
freshLambdaId : RewriteCtx -> IO.Canonical -> ( Mono.LambdaId, RewriteCtx )
freshLambdaId ctx home =
    ( Mono.AnonymousLambda home ctx.lambdaCounter
    , { ctx | lambdaCounter = ctx.lambdaCounter + 1 }
    )


{-| Generate a fresh lambda ID for a specialization, looking up the home module.
-}
freshLambdaIdForSpec : RewriteCtx -> Mono.SpecId -> ( Mono.LambdaId, RewriteCtx )
freshLambdaIdForSpec ctx specId =
    let
        home =
            case Array.get specId ctx.registry.reverseMapping |> Maybe.andThen identity of
                Just ( Mono.Global h _, _ ) ->
                    h

                Just ( Mono.Accessor _, _ ) ->
                    -- Accessor doesn't have a home, use a placeholder
                    IO.Canonical ( "", "" ) ""

                Nothing ->
                    -- Fallback if not found
                    IO.Canonical ( "", "" ) ""
    in
    freshLambdaId ctx home


{-| Generate a fresh lambda ID for a closure.
This is called after children are processed, so nested closures get IDs first.
-}
remapClosureLambdaId : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
remapClosureLambdaId ctx expr =
    case expr of
        MonoClosure info body closureType ->
            let
                home =
                    case info.lambdaId of
                        Mono.AnonymousLambda h _ ->
                            h

                ( newLambdaId, ctx1 ) =
                    freshLambdaId ctx home

                newInfo =
                    { info | lambdaId = newLambdaId }
            in
            ( MonoClosure newInfo body closureType, ctx1 )

        _ ->
            ( expr, ctx )


{-| Remap all lambda IDs in an expression to fresh values.
This is necessary when inlining to avoid duplicate lambda function names in MLIR.
-}
remapLambdaIds : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
remapLambdaIds =
    Traverse.traverseExpr remapClosureLambdaId


{-| A binding created during beta reduction or inlining.
-}
type alias Binding =
    { origName : Name
    , freshName : Name
    , arg : MonoExpr
    , argType : Mono.MonoType
    }



-- ============================================================================
-- ====== NODE OPTIMIZATION ======
-- ============================================================================


optimizeNode : RewriteCtx -> SpecId -> MonoNode -> ( MonoNode, RewriteCtx )
optimizeNode ctx _ node =
    -- Reset per-function inline count at start of each node
    let
        ctxForNode =
            { ctx | inlineCountThisFunction = 0 }
    in
    case node of
        MonoDefine expr tipe ->
            let
                ( optimized, newCtx ) =
                    fixpoint ctxForNode expr
            in
            ( MonoDefine optimized tipe, newCtx )

        MonoTailFunc params expr tipe ->
            let
                ( optimized, newCtx ) =
                    fixpoint ctxForNode expr
            in
            ( MonoTailFunc params optimized tipe, newCtx )

        MonoPortIncoming expr tipe ->
            let
                ( optimized, newCtx ) =
                    fixpoint ctxForNode expr
            in
            ( MonoPortIncoming optimized tipe, newCtx )

        MonoPortOutgoing expr tipe ->
            let
                ( optimized, newCtx ) =
                    fixpoint ctxForNode expr
            in
            ( MonoPortOutgoing optimized tipe, newCtx )

        -- MonoCtor, MonoEnum, MonoExtern, MonoManagerLeaf pass through unchanged
        _ ->
            ( node, ctx )



-- ============================================================================
-- ====== FIXPOINT LOOP ======
-- ============================================================================


fixpoint : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
fixpoint ctx expr =
    iterate 0 expr ctx


iterate : Int -> MonoExpr -> RewriteCtx -> ( MonoExpr, RewriteCtx )
iterate n current ctx =
    if n >= ctx.maxIterations then
        ( current, ctx )

    else
        let
            ( rewritten, ctx1 ) =
                rewriteExpr ctx current

            ( simplified, ctx2 ) =
                simplifyLets ctx1 rewritten
        in
        if exprEqual simplified current then
            ( simplified, ctx2 )

        else
            iterate (n + 1) simplified ctx2


{-| Check if two expressions are structurally equal.
This is a simple structural comparison.
-}
exprEqual : MonoExpr -> MonoExpr -> Bool
exprEqual e1 e2 =
    -- For simplicity, we use string representation comparison
    -- In production, we'd want a proper structural equality check
    e1 == e2



-- ============================================================================
-- ====== EXPRESSION REWRITING ======
-- ============================================================================


rewriteExpr : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
rewriteExpr ctx expr =
    case expr of
        -- Beta reduction: ((\\x -> body) arg)
        MonoCall region (MonoClosure info closureBody _) args resultType _ ->
            betaReduce ctx region info closureBody args resultType

        -- Direct call inlining
        MonoCall region (MonoVarGlobal varRegion specId funcType) args resultType callInfo ->
            let
                ( maybeInlined, ctx1 ) =
                    tryInlineCall ctx specId args resultType
            in
            case maybeInlined of
                Just inlinedExpr ->
                    -- Recursively rewrite the inlined expression
                    rewriteExpr ctx1 inlinedExpr

                Nothing ->
                    -- Can't inline, just rewrite children
                    let
                        ( rewrittenArgs, ctx2 ) =
                            rewriteExprs ctx1 args
                    in
                    ( MonoCall region (MonoVarGlobal varRegion specId funcType) rewrittenArgs resultType callInfo, ctx2 )

        -- Let-callee hoisting (H2): `(let d in f) a` ⇒ `let d in (f a)`.
        -- Inlining a curried callee exactly leaves its closure-literal body
        -- wrapped in the argument lets, and the ENCLOSING call then applies
        -- that let-wrapped closure — a shape codegen mis-arities at runtime
        -- (spliceArgsForSaturatedCall assertion; the CombinatorB* corpus
        -- tests catch it at hofThreshold ≥ the combinators' cost). Hoisting
        -- preserves evaluation order exactly (defs, callee, args) and cannot
        -- capture (names are unique post-freshening); the inner call then
        -- beta-reduces against the exposed literal on the recursive rewrite.
        -- The hoisted lets adopt the call's result type (chain-tail typing,
        -- the wrapInLets invariant).
        MonoCall region ((MonoLet _ _ _) as callee) args resultType callInfo ->
            let
                ( calleeSpine, calleeInner ) =
                    splitLetSpine callee

                rebuilt =
                    List.foldr
                        (\( d, _ ) acc -> MonoLet d acc resultType)
                        (MonoCall region calleeInner args resultType callInfo)
                        calleeSpine
            in
            rewriteExpr ctx rebuilt

        -- Recursive cases - rewrite children
        MonoCall region func args resultType callInfo ->
            let
                ( rewrittenFunc, ctx1 ) =
                    rewriteExpr ctx func

                ( rewrittenArgs, ctx2 ) =
                    rewriteExprs ctx1 args
            in
            ( MonoCall region rewrittenFunc rewrittenArgs resultType callInfo, ctx2 )

        MonoClosure info body closureType ->
            let
                ( rewrittenCaptures, ctx1 ) =
                    rewriteCaptures ctx info.captures

                ( rewrittenBody, ctx2 ) =
                    rewriteExpr ctx1 body
            in
            ( MonoClosure { info | captures = rewrittenCaptures } rewrittenBody closureType, ctx2 )

        MonoList region items itemType ->
            let
                ( rewrittenItems, ctx1 ) =
                    rewriteExprs ctx items
            in
            ( MonoList region rewrittenItems itemType, ctx1 )

        MonoIf branches final resultType ->
            let
                ( rewrittenBranches, ctx1 ) =
                    rewriteBranches ctx branches

                ( rewrittenFinal, ctx2 ) =
                    rewriteExpr ctx1 final
            in
            -- Simplify if with known condition
            case rewrittenBranches of
                [ ( MonoLiteral (Mono.LBool True) _, thenBranch ) ] ->
                    ( thenBranch, ctx2 )

                [ ( MonoLiteral (Mono.LBool False) _, _ ) ] ->
                    ( rewrittenFinal, ctx2 )

                _ ->
                    ( MonoIf rewrittenBranches rewrittenFinal resultType, ctx2 )

        MonoLet _ _ _ ->
            -- Let CHAINS are rewritten as a group: the let-callee forwarding
            -- decision (H1.1) needs to see uses of a def's name in EVERY
            -- sibling def of the chain, including EARLIER ones — letrec
            -- sibling closures reference each other in both directions, and
            -- from an inner let node an earlier sibling is an ancestor,
            -- invisible to a subtree usage count (the same reason
            -- freshenLetChain and simplifyLetChain work on the whole spine).
            rewriteLetChain ctx expr

        MonoDestruct destructor inner resultType ->
            let
                ( rewrittenInner, ctx1 ) =
                    rewriteExpr ctx inner
            in
            ( MonoDestruct destructor rewrittenInner resultType, ctx1 )

        MonoCase scrutName scrutType decider branches resultType ->
            let
                ( rewrittenDecider, ctx1 ) =
                    rewriteDecider ctx decider

                ( rewrittenBranches, ctx2 ) =
                    rewriteCaseBranches ctx1 branches
            in
            ( MonoCase scrutName scrutType rewrittenDecider rewrittenBranches resultType, ctx2 )

        MonoRecordCreate fields recordType ->
            let
                ( rewrittenFields, ctx1 ) =
                    rewriteNamedFields ctx fields
            in
            ( MonoRecordCreate rewrittenFields recordType, ctx1 )

        MonoRecordAccess inner fieldName resultType ->
            let
                ( rewrittenInner, ctx1 ) =
                    rewriteExpr ctx inner
            in
            ( MonoRecordAccess rewrittenInner fieldName resultType, ctx1 )

        MonoRecordUpdate inner updates recordType ->
            let
                ( rewrittenInner, ctx1 ) =
                    rewriteExpr ctx inner

                ( rewrittenUpdates, ctx2 ) =
                    rewriteNamedFields ctx1 updates
            in
            ( MonoRecordUpdate rewrittenInner rewrittenUpdates recordType, ctx2 )

        MonoTupleCreate region items tupleType ->
            let
                ( rewrittenItems, ctx1 ) =
                    rewriteExprs ctx items
            in
            ( MonoTupleCreate region rewrittenItems tupleType, ctx1 )

        MonoTailCall name args resultType ->
            -- Never inline MonoTailCall to preserve tail-call optimization
            let
                ( rewrittenArgs, ctx1 ) =
                    rewriteTailCallArgs ctx args
            in
            ( MonoTailCall name rewrittenArgs resultType, ctx1 )

        -- Leaves - no children to rewrite
        MonoLiteral _ _ ->
            ( expr, ctx )

        MonoVarLocal _ _ ->
            ( expr, ctx )

        MonoVarGlobal _ _ _ ->
            ( expr, ctx )

        MonoVarKernel _ _ _ _ _ ->
            ( expr, ctx )

        MonoUnit ->
            ( expr, ctx )

        MonoAccessorValue _ _ _ ->
            ( expr, ctx )


rewriteExprs : RewriteCtx -> List MonoExpr -> ( List MonoExpr, RewriteCtx )
rewriteExprs ctx exprs =
    let
        ( revExprs, finalCtx ) =
            List.foldl
                (\expr ( acc, accCtx ) ->
                    let
                        ( rewritten, newCtx ) =
                            rewriteExpr accCtx expr
                    in
                    ( rewritten :: acc, newCtx )
                )
                ( [], ctx )
                exprs
    in
    ( List.reverse revExprs, finalCtx )


rewriteCaptures : RewriteCtx -> List ( Name, MonoExpr, Bool ) -> ( List ( Name, MonoExpr, Bool ), RewriteCtx )
rewriteCaptures ctx captures =
    let
        ( revCaptures, finalCtx ) =
            List.foldl
                (\( name, expr, isUnboxed ) ( acc, accCtx ) ->
                    let
                        ( rewritten, newCtx ) =
                            rewriteExpr accCtx expr
                    in
                    ( ( name, rewritten, isUnboxed ) :: acc, newCtx )
                )
                ( [], ctx )
                captures
    in
    ( List.reverse revCaptures, finalCtx )


rewriteBranches : RewriteCtx -> List ( MonoExpr, MonoExpr ) -> ( List ( MonoExpr, MonoExpr ), RewriteCtx )
rewriteBranches ctx branches =
    let
        ( revBranches, finalCtx ) =
            List.foldl
                (\( cond, body ) ( acc, accCtx ) ->
                    let
                        ( rewrittenCond, ctx1 ) =
                            rewriteExpr accCtx cond

                        ( rewrittenBody, ctx2 ) =
                            rewriteExpr ctx1 body
                    in
                    ( ( rewrittenCond, rewrittenBody ) :: acc, ctx2 )
                )
                ( [], ctx )
                branches
    in
    ( List.reverse revBranches, finalCtx )


rewriteDef : RewriteCtx -> Mono.MonoDef -> ( Mono.MonoDef, RewriteCtx )
rewriteDef ctx def =
    case def of
        Mono.MonoDef name bound ->
            let
                ( rewritten, newCtx ) =
                    rewriteExpr ctx bound
            in
            ( Mono.MonoDef name rewritten, newCtx )

        Mono.MonoTailDef name params bound ->
            let
                ( rewritten, newCtx ) =
                    rewriteExpr ctx bound
            in
            ( Mono.MonoTailDef name params rewritten, newCtx )


rewriteCaseBranches : RewriteCtx -> List ( Int, MonoExpr ) -> ( List ( Int, MonoExpr ), RewriteCtx )
rewriteCaseBranches ctx branches =
    let
        ( revBranches, finalCtx ) =
            List.foldl
                (\( idx, body ) ( acc, accCtx ) ->
                    let
                        ( rewritten, newCtx ) =
                            rewriteExpr accCtx body
                    in
                    ( ( idx, rewritten ) :: acc, newCtx )
                )
                ( [], ctx )
                branches
    in
    ( List.reverse revBranches, finalCtx )


rewriteDecider : RewriteCtx -> Mono.Decider Mono.MonoChoice -> ( Mono.Decider Mono.MonoChoice, RewriteCtx )
rewriteDecider ctx decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    let
                        ( rewritten, ctx1 ) =
                            rewriteExpr ctx expr
                    in
                    ( Mono.Leaf (Mono.Inline rewritten), ctx1 )

                Mono.Jump _ ->
                    ( decider, ctx )

        Mono.Chain testChain success failure ->
            let
                ( rewrittenSuccess, ctx1 ) =
                    rewriteDecider ctx success

                ( rewrittenFailure, ctx2 ) =
                    rewriteDecider ctx1 failure
            in
            ( Mono.Chain testChain rewrittenSuccess rewrittenFailure, ctx2 )

        Mono.FanOut path edges fallback ->
            let
                ( revEdges, ctx1 ) =
                    List.foldl
                        (\( test, d ) ( acc, accCtx ) ->
                            let
                                ( rewritten, newCtx ) =
                                    rewriteDecider accCtx d
                            in
                            ( ( test, rewritten ) :: acc, newCtx )
                        )
                        ( [], ctx )
                        edges

                rewrittenEdges =
                    List.reverse revEdges

                ( rewrittenFallback, ctx2 ) =
                    rewriteDecider ctx1 fallback
            in
            ( Mono.FanOut path rewrittenEdges rewrittenFallback, ctx2 )


rewriteNamedFields : RewriteCtx -> List ( Name, MonoExpr ) -> ( List ( Name, MonoExpr ), RewriteCtx )
rewriteNamedFields ctx fields =
    let
        ( revFields, finalCtx ) =
            List.foldl
                (\( name, expr ) ( acc, accCtx ) ->
                    let
                        ( rewritten, newCtx ) =
                            rewriteExpr accCtx expr
                    in
                    ( ( name, rewritten ) :: acc, newCtx )
                )
                ( [], ctx )
                fields
    in
    ( List.reverse revFields, finalCtx )


rewriteTailCallArgs : RewriteCtx -> List ( Name, MonoExpr ) -> ( List ( Name, MonoExpr ), RewriteCtx )
rewriteTailCallArgs ctx args =
    let
        ( revArgs, finalCtx ) =
            List.foldl
                (\( name, expr ) ( acc, accCtx ) ->
                    let
                        ( rewritten, newCtx ) =
                            rewriteExpr accCtx expr
                    in
                    ( ( name, rewritten ) :: acc, newCtx )
                )
                ( [], ctx )
                args
    in
    ( List.reverse revArgs, finalCtx )



-- ============================================================================
-- ====== BETA REDUCTION ======
-- ============================================================================


betaReduce : RewriteCtx -> Region -> Mono.ClosureInfo -> MonoExpr -> List MonoExpr -> Mono.MonoType -> ( MonoExpr, RewriteCtx )
betaReduce ctx region info closureBody args resultType =
    let
        params =
            info.params

        numParams =
            List.length params

        numArgs =
            List.length args
    in
    if numArgs == 0 then
        -- No arguments, just return closure
        ( MonoClosure info closureBody (Mono.typeOf (MonoClosure info closureBody resultType)), ctx )

    else if numArgs == numParams then
        -- Exact application: bind all params to args
        let
            ( bindings, ctx1 ) =
                createBindings ctx params args

            ( substituted, ctx2 ) =
                freshenLetBoundNames ctx1 (substituteAll bindings closureBody)
        in
        ( wrapInLets bindings substituted resultType, bumpBetaReductions ctx2 )

    else if numArgs < numParams then
        -- Partial application: bind available params, return closure with remaining
        let
            ( usedParams, remainingParams ) =
                ( List.take numArgs params, List.drop numArgs params )

            ( bindings, ctx1 ) =
                createBindings ctx usedParams args

            ( substituted, ctx2 ) =
                freshenLetBoundNames ctx1 (substituteAll bindings closureBody)

            newClosureType =
                -- Partial-application rebuild: LTop (sound; the original
                -- head anno is not in scope here — precision-only loss).
                Mono.MFunction Mono.LTop (List.map Tuple.second remainingParams) resultType

            -- Recompute captures for the new closure body.
            -- The substitution may have introduced new free variables (the fresh names
            -- bound in the surrounding lets) that need to be captured.
            newCaptures =
                Closure.computeClosureCaptures remainingParams substituted

            newInfo =
                { info | params = remainingParams, captures = newCaptures }
        in
        ( wrapInLets bindings (MonoClosure newInfo substituted newClosureType) newClosureType
        , bumpBetaReductions ctx2
        )

    else
        -- Over-application: apply all params, then call result with extra args
        let
            ( usedArgs, extraArgs ) =
                ( List.take numParams args, List.drop numParams args )

            ( bindings, ctx1 ) =
                createBindings ctx params usedArgs

            ( substituted, ctx2 ) =
                freshenLetBoundNames ctx1 (substituteAll bindings closureBody)

            innerExpr =
                wrapInLets bindings substituted resultType
        in
        ( MonoCall region innerExpr extraArgs resultType Mono.defaultCallInfo
        , bumpBetaReductions ctx2
        )


createBindings : RewriteCtx -> List ( Name, Mono.MonoType ) -> List MonoExpr -> ( List Binding, RewriteCtx )
createBindings ctx params args =
    let
        ( revBindings, finalCtx ) =
            List.foldl
                (\( ( paramName, _ ), arg ) ( acc, accCtx ) ->
                    let
                        ( freshName, newCtx ) =
                            freshVar accCtx

                        binding =
                            { origName = paramName
                            , freshName = freshName
                            , arg = arg
                            , argType = Mono.typeOf arg
                            }
                    in
                    ( binding :: acc, newCtx )
                )
                ( [], ctx )
                (List.map2 Tuple.pair params args)
    in
    ( List.reverse revBindings, finalCtx )


wrapInLets : List Binding -> MonoExpr -> Mono.MonoType -> MonoExpr
wrapInLets bindings body resultType =
    List.foldr
        (\binding acc ->
            MonoLet (Mono.MonoDef binding.freshName binding.arg) acc resultType
        )
        body
        bindings


substituteAll : List Binding -> MonoExpr -> MonoExpr
substituteAll bindings expr =
    List.foldl
        (\binding acc ->
            substitute binding.origName binding.freshName binding.argType acc
        )
        expr
        bindings


substitute : Name -> Name -> Mono.MonoType -> MonoExpr -> MonoExpr
substitute oldName newName varType expr =
    case expr of
        MonoVarLocal name _ ->
            if name == oldName then
                MonoVarLocal newName varType

            else
                expr

        MonoLiteral _ _ ->
            expr

        MonoVarGlobal _ _ _ ->
            expr

        MonoVarKernel _ _ _ _ _ ->
            expr

        MonoUnit ->
            expr

        MonoAccessorValue _ _ _ ->
            expr

        MonoList region items itemType ->
            MonoList region (List.map (substitute oldName newName varType) items) itemType

        MonoClosure info body closureType ->
            -- Don't substitute if the name is shadowed by a param
            if List.any (\( n, _ ) -> n == oldName) info.params then
                expr

            else
                let
                    -- When substituting, also rename capture names that match oldName.
                    -- This ensures that if the body now references newName (due to substitution),
                    -- the capture binding also uses newName.
                    newCaptures =
                        List.map
                            (\( n, e, isUnboxed ) ->
                                ( if n == oldName then
                                    newName

                                  else
                                    n
                                , substitute oldName newName varType e
                                , isUnboxed
                                )
                            )
                            info.captures
                in
                MonoClosure { info | captures = newCaptures } (substitute oldName newName varType body) closureType

        MonoCall region func args resultType callInfo ->
            MonoCall region
                (substitute oldName newName varType func)
                (List.map (substitute oldName newName varType) args)
                resultType
                callInfo

        MonoTailCall name args resultType ->
            MonoTailCall name
                (List.map (\( n, e ) -> ( n, substitute oldName newName varType e )) args)
                resultType

        MonoIf branches final resultType ->
            MonoIf
                (List.map (\( c, t ) -> ( substitute oldName newName varType c, substitute oldName newName varType t )) branches)
                (substitute oldName newName varType final)
                resultType

        MonoLet def body resultType ->
            let
                defName =
                    getDefName def
            in
            if defName == oldName then
                -- Name is shadowed, only substitute in the def's bound expression
                MonoLet (substituteDef oldName newName varType def) body resultType

            else
                MonoLet (substituteDef oldName newName varType def) (substitute oldName newName varType body) resultType

        MonoDestruct (Mono.MonoDestructor destructName path destructType) inner resultType ->
            let
                -- The path refers to the source variable, so substitute there
                newPath =
                    substitutePath oldName newName path

                -- The destructName is a NEW binding, don't rename it.
                -- If destructName == oldName, it shadows the param, so don't substitute in inner
                newInner =
                    if destructName == oldName then
                        inner

                    else
                        substitute oldName newName varType inner
            in
            MonoDestruct (Mono.MonoDestructor destructName newPath destructType) newInner resultType

        MonoCase unused rootName decider branches resultType ->
            -- MonoCase has two Name fields: first is unused, second is the root variable
            let
                newRootName =
                    if rootName == oldName then
                        newName

                    else
                        rootName

                newDecider =
                    substituteDecider oldName newName varType decider
            in
            MonoCase unused
                newRootName
                newDecider
                (List.map (\( idx, e ) -> ( idx, substitute oldName newName varType e )) branches)
                resultType

        MonoRecordCreate fields recordType ->
            MonoRecordCreate (List.map (\( n, e ) -> ( n, substitute oldName newName varType e )) fields) recordType

        MonoRecordAccess inner fieldName resultType ->
            MonoRecordAccess (substitute oldName newName varType inner) fieldName resultType

        MonoRecordUpdate inner updates recordType ->
            MonoRecordUpdate
                (substitute oldName newName varType inner)
                (List.map (\( n, e ) -> ( n, substitute oldName newName varType e )) updates)
                recordType

        MonoTupleCreate region items tupleType ->
            MonoTupleCreate region (List.map (substitute oldName newName varType) items) tupleType


substituteDef : Name -> Name -> Mono.MonoType -> Mono.MonoDef -> Mono.MonoDef
substituteDef oldName newName varType def =
    case def of
        Mono.MonoDef name bound ->
            Mono.MonoDef name (substitute oldName newName varType bound)

        Mono.MonoTailDef name params bound ->
            -- Don't substitute if shadowed by a param
            if List.any (\( n, _ ) -> n == oldName) params then
                def

            else
                Mono.MonoTailDef name params (substitute oldName newName varType bound)


substitutePath : Name -> Name -> Mono.MonoPath -> Mono.MonoPath
substitutePath oldName newName path =
    case path of
        Mono.MonoRoot rootName rootType ->
            if rootName == oldName then
                Mono.MonoRoot newName rootType

            else
                path

        Mono.MonoIndex idx container resultType innerPath ->
            Mono.MonoIndex idx container resultType (substitutePath oldName newName innerPath)

        Mono.MonoField fieldIdx resultType innerPath ->
            Mono.MonoField fieldIdx resultType (substitutePath oldName newName innerPath)

        Mono.MonoUnbox resultType innerPath ->
            Mono.MonoUnbox resultType (substitutePath oldName newName innerPath)


substituteDtPath : Name -> Name -> Mono.MonoDtPath -> Mono.MonoDtPath
substituteDtPath oldName newName dtPath =
    case dtPath of
        Mono.DtRoot name ty ->
            if name == oldName then
                Mono.DtRoot newName ty

            else
                dtPath

        Mono.DtIndex idx kind resultTy inner ->
            Mono.DtIndex idx kind resultTy (substituteDtPath oldName newName inner)

        Mono.DtUnbox resultTy inner ->
            Mono.DtUnbox resultTy (substituteDtPath oldName newName inner)


substituteDecider : Name -> Name -> Mono.MonoType -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
substituteDecider oldName newName varType decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    Mono.Leaf (Mono.Inline (substitute oldName newName varType expr))

                Mono.Jump _ ->
                    decider

        Mono.Chain testChain success failure ->
            Mono.Chain
                (List.map
                    (\( dtPath, test ) ->
                        ( substituteDtPath oldName newName dtPath, test )
                    )
                    testChain
                )
                (substituteDecider oldName newName varType success)
                (substituteDecider oldName newName varType failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut (substituteDtPath oldName newName path)
                (List.map (\( test, d ) -> ( test, substituteDecider oldName newName varType d )) edges)
                (substituteDecider oldName newName varType fallback)


getDefName : Mono.MonoDef -> Name
getDefName def =
    case def of
        Mono.MonoDef name _ ->
            name

        Mono.MonoTailDef name _ _ ->
            name


setDefName : Name -> Mono.MonoDef -> Mono.MonoDef
setDefName newName def =
    case def of
        Mono.MonoDef _ bound ->
            Mono.MonoDef newName bound

        Mono.MonoTailDef _ params bound ->
            Mono.MonoTailDef newName params bound



-- ============================================================================
-- ====== LET-CALLEE FORWARDING (H1.1) ======
-- ============================================================================


{-| Rewrite one let chain as a group: rewrite every def's bound expression
and the final body (exactly what the per-let recursion did before), then
attempt let-callee forwarding with full-chain visibility.
-}
rewriteLetChain : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
rewriteLetChain ctx chainExpr =
    let
        splitSpine : MonoExpr -> List ( Mono.MonoDef, Mono.MonoType ) -> ( List ( Mono.MonoDef, Mono.MonoType ), MonoExpr )
        splitSpine e acc =
            case e of
                MonoLet d b t ->
                    splitSpine b (( d, t ) :: acc)

                _ ->
                    ( List.reverse acc, e )

        ( spine0, finalBody0 ) =
            splitSpine chainExpr []

        ( spineRev, ctx1 ) =
            List.foldl
                (\( d, t ) ( acc, c ) ->
                    let
                        ( d1, c1 ) =
                            rewriteDef c d
                    in
                    ( ( d1, t ) :: acc, c1 )
                )
                ( [], ctx )
                spine0

        ( finalBody1, ctx2 ) =
            rewriteExpr ctx1 finalBody0

        spineFlattened =
            List.concatMap flattenClosureDef (List.reverse spineRev)

        ( spine2, finalBody2, ctx3 ) =
            forwardInChain ctx2 spineFlattened finalBody1
    in
    ( List.foldr (\( d, t ) acc -> MonoLet d acc t) finalBody2 spine2, ctx3 )


{-| H2.0 let-of-closure flattening: `let f = (let a = e in λ) in body` ⇒
`let a = e; f = λ in body`.

`tryInlineCall`'s partial-application branch wraps its rebuilt closure in
the argument bindings (`wrapInLetsForInline`), which hides the closure
LITERAL from let-callee forwarding — the pipe shape `m |> Maybe.andThen λ`
lands exactly there. Splicing the inner bindings into the enclosing chain
preserves evaluation order (a, then the closure, exactly as before) and
cannot capture: all names are unique post-freshening (and Elm forbids
source shadowing). Spliced entries adopt the outer entry's result type —
within a chain every `MonoLet` node carries the chain tail's type
(`wrapInLets` invariant). Only chains ENDING in a closure literal are
flattened; the general rewrite is sound but this is the shape that pays.
-}
flattenClosureDef : ( Mono.MonoDef, Mono.MonoType ) -> List ( Mono.MonoDef, Mono.MonoType )
flattenClosureDef (( d, t ) as entry) =
    case d of
        Mono.MonoDef name ((MonoLet _ _ _) as bound) ->
            let
                ( innerSpine, innerFinal ) =
                    splitLetSpine bound
            in
            case innerFinal of
                MonoClosure _ _ _ ->
                    List.map (\( d2, _ ) -> ( d2, t )) innerSpine
                        ++ [ ( Mono.MonoDef name innerFinal, t ) ]

                _ ->
                    [ entry ]

        _ ->
            [ entry ]


splitLetSpine : MonoExpr -> ( List ( Mono.MonoDef, Mono.MonoType ), MonoExpr )
splitLetSpine expr =
    let
        go e acc =
            case e of
                MonoLet d b t ->
                    go b (( d, t ) :: acc)

                _ ->
                    ( List.reverse acc, e )
    in
    go expr []


{-| Forward let-bound closures into their single callee-position use, with
the whole chain in view. A def is forwardable only when ALL of:

  - it is a plain `MonoDef` bound to a closure literal;
  - the closure does not reference its own name (a recursive closure's
    self-call lives inside its own bound expression, invisible to any
    body-side count — forwarding would delete the binding its body needs);
  - no EARLIER sibling references the name. Letrec siblings reference each
    other in both directions; forwarding into an earlier sibling's bound
    expression would move the closure's capture reads BEFORE bindings they
    may depend on, and deleting the def dangles the earlier capture. (This
    is also why the decision needs the chain view at all: from an inner let
    node an earlier sibling is an ancestor, invisible to a subtree count.)
  - LATER siblings' bounds plus the final body reference the name exactly
    once, and `forwardGo` proves that use is a legal callee position.
    Forwarding INTO a later position is evaluation-order safe: every name
    the closure references was already bound before the def's own position.

Forwarding one def can expose another (counts change), so the pass restarts
until nothing forwards; each success removes a def, so this terminates.
-}
forwardInChain : RewriteCtx -> List ( Mono.MonoDef, Mono.MonoType ) -> MonoExpr -> ( List ( Mono.MonoDef, Mono.MonoType ), MonoExpr, RewriteCtx )
forwardInChain ctx spine finalBody =
    let
        usesInDefsOf : Name -> List ( Mono.MonoDef, Mono.MonoType ) -> Int
        usesInDefsOf name defs =
            List.foldl (\( d, _ ) n -> n + countUsagesInDef name d) 0 defs

        splitSpine : MonoExpr -> List ( Mono.MonoDef, Mono.MonoType ) -> ( List ( Mono.MonoDef, Mono.MonoType ), MonoExpr )
        splitSpine e acc =
            case e of
                MonoLet d b t ->
                    splitSpine b (( d, t ) :: acc)

                _ ->
                    ( List.reverse acc, e )

        tryAt :
            List ( Mono.MonoDef, Mono.MonoType )
            -> List ( Mono.MonoDef, Mono.MonoType )
            -> MonoExpr
            -> RewriteCtx
            -> Maybe ( List ( Mono.MonoDef, Mono.MonoType ), MonoExpr, RewriteCtx )
        tryAt beforeRev after fb c =
            case after of
                [] ->
                    Nothing

                (( d, _ ) as entry) :: rest ->
                    let
                        skip () =
                            tryAt (entry :: beforeRev) rest fb c
                    in
                    case d of
                        Mono.MonoDef name ((MonoClosure cinfo cbody _) as closureExpr) ->
                            if
                                countUsages name closureExpr
                                    == 0
                                    && usesInDefsOf name beforeRev
                                    == 0
                                    && (usesInDefsOf name rest + countUsages name fb)
                                    == 1
                            then
                                -- Rebuild the tail (later defs + final body) as
                                -- one expression so forwardGo can reach a use in
                                -- either place, then split it back.
                                let
                                    tailExpr =
                                        List.foldr (\( d2, t2 ) acc -> MonoLet d2 acc t2) fb rest
                                in
                                case forwardGo c name cinfo cbody tailExpr of
                                    Just ( tail1, c1 ) ->
                                        let
                                            ( rest1, fb1 ) =
                                                splitSpine tail1 []
                                        in
                                        Just ( List.reverse beforeRev ++ rest1, fb1, bumpBetaForwards c1 )

                                    Nothing ->
                                        skip ()

                            else
                                skip ()

                        _ ->
                            skip ()

        loop sp fb c =
            case tryAt [] sp fb c of
                Just ( sp1, fb1, c1 ) ->
                    loop sp1 fb1 c1

                Nothing ->
                    ( sp, fb, c )
    in
    loop spine finalBody ctx


{-| Find the single callee-position use of `name` in `expr` and replace the
call with the beta-reduction of the given closure against the call's args.
Returns `Nothing` when no legal use is found (the caller keeps the let).

PRECONDITION: `countUsages name expr == 1` — the walk replaces the first
qualifying call it finds and relies on the count for uniqueness (any other
occurrence would make the count ≥ 2 and the caller skips forwarding).

Guards (all return "not found here" so the caller conservatively keeps the
let):

  - Never descends into `MonoClosure` captures/bodies or `MonoTailDef`
    bound expressions. For closures this is a CORRECTNESS guard, not just a
    perf one: the forwarded body references outer names, and an enclosing
    closure's `ClosureInfo.captures` was already computed — injecting new
    free variables into its body would violate CGEN_CLOSURE_003 (FV ⊆
    params ∪ captures ∪ siblings). For tail-def bounds it is the sinking
    guard: a partial-application residue would allocate per loop iteration
    instead of once.
  - Never descends past any construct that rebinds `name` (shadowing —
    should not occur post-freshening, but letrec sibling defs make a
    same-named def genuinely ambiguous, so refuse outright).
  - `MonoIf`/`MonoCase` branches are fine: they execute at most once per
    evaluation of the let body.

-}
forwardGo : RewriteCtx -> Name -> Mono.ClosureInfo -> MonoExpr -> MonoExpr -> Maybe ( MonoExpr, RewriteCtx )
forwardGo ctx name cinfo cbody expr =
    case expr of
        MonoCall region func args t ci ->
            case func of
                MonoVarLocal n _ ->
                    if n == name then
                        -- Only SATURATED, GROUND-RESULT uses forward.
                        --
                        -- A partial application would route through
                        -- betaReduce's partial-rebuild branch, and a
                        -- function-typed result means the beta yields a
                        -- closure the enclosing expression applies (curried
                        -- defs like `compose f g = \x -> …`). Both leave a
                        -- closure whose call site carries the mono result
                        -- type while the compiled body keeps the generic
                        -- boxed ABI — a latent CGEN_056 mismatch (saturated
                        -- papExtend result type vs callee return type) that
                        -- the SKI-combinator / identity-composition unit
                        -- fixtures catch. Returning Nothing keeps the let
                        -- (the count precondition means this was the only
                        -- use).
                        if
                            List.length args
                                == List.length cinfo.params
                                && not (isFunctionType t)
                        then
                            Just (betaReduce ctx region cinfo cbody args t)

                        else
                            Nothing

                    else
                        forwardGoList ctx name cinfo cbody args
                            |> Maybe.map (\( args1, c ) -> ( MonoCall region func args1 t ci, c ))

                _ ->
                    case forwardGo ctx name cinfo cbody func of
                        Just ( func1, c ) ->
                            Just ( MonoCall region func1 args t ci, c )

                        Nothing ->
                            forwardGoList ctx name cinfo cbody args
                                |> Maybe.map (\( args1, c ) -> ( MonoCall region func args1 t ci, c ))

        MonoClosure _ _ _ ->
            -- Sinking guard: never move an allocation into a closure body,
            -- and a capture-position use is not a callee anyway.
            Nothing

        MonoLet d b t ->
            if getDefName d == name then
                -- Rebinding (letrec sibling or shadow): everything below is
                -- ambiguous — refuse.
                Nothing

            else
                case d of
                    Mono.MonoDef dn bound ->
                        case forwardGo ctx name cinfo cbody bound of
                            Just ( bound1, c ) ->
                                Just ( MonoLet (Mono.MonoDef dn bound1) b t, c )

                            Nothing ->
                                forwardGo ctx name cinfo cbody b
                                    |> Maybe.map (\( b1, c ) -> ( MonoLet d b1 t, c ))

                    Mono.MonoTailDef _ _ _ ->
                        -- Sinking guard: a tail-def bound expr is a loop body.
                        forwardGo ctx name cinfo cbody b
                            |> Maybe.map (\( b1, c ) -> ( MonoLet d b1 t, c ))

        MonoDestruct ((Mono.MonoDestructor dn _ _) as dtor) inner t ->
            if dn == name then
                Nothing

            else
                forwardGo ctx name cinfo cbody inner
                    |> Maybe.map (\( inner1, c ) -> ( MonoDestruct dtor inner1 t, c ))

        MonoIf branches final t ->
            case forwardGoIfBranches ctx name cinfo cbody branches of
                Just ( branches1, c ) ->
                    Just ( MonoIf branches1 final t, c )

                Nothing ->
                    forwardGo ctx name cinfo cbody final
                        |> Maybe.map (\( final1, c ) -> ( MonoIf branches final1 t, c ))

        MonoCase s r decider branches t ->
            if s == name || r == name then
                -- The case scrutinizes our variable: not a callee use.
                Nothing

            else
                case forwardGoDecider ctx name cinfo cbody decider of
                    Just ( decider1, c ) ->
                        Just ( MonoCase s r decider1 branches t, c )

                    Nothing ->
                        forwardGoSndList ctx name cinfo cbody branches
                            |> Maybe.map (\( branches1, c ) -> ( MonoCase s r decider branches1 t, c ))

        MonoList region items t ->
            forwardGoList ctx name cinfo cbody items
                |> Maybe.map (\( items1, c ) -> ( MonoList region items1 t, c ))

        MonoTailCall n args t ->
            if n == name then
                Nothing

            else
                forwardGoSndList ctx name cinfo cbody args
                    |> Maybe.map (\( args1, c ) -> ( MonoTailCall n args1 t, c ))

        MonoRecordCreate fields t ->
            forwardGoSndList ctx name cinfo cbody fields
                |> Maybe.map (\( fields1, c ) -> ( MonoRecordCreate fields1 t, c ))

        MonoRecordAccess inner f t ->
            forwardGo ctx name cinfo cbody inner
                |> Maybe.map (\( inner1, c ) -> ( MonoRecordAccess inner1 f t, c ))

        MonoRecordUpdate inner updates t ->
            case forwardGo ctx name cinfo cbody inner of
                Just ( inner1, c ) ->
                    Just ( MonoRecordUpdate inner1 updates t, c )

                Nothing ->
                    forwardGoSndList ctx name cinfo cbody updates
                        |> Maybe.map (\( updates1, c ) -> ( MonoRecordUpdate inner updates1 t, c ))

        MonoTupleCreate region items t ->
            forwardGoList ctx name cinfo cbody items
                |> Maybe.map (\( items1, c ) -> ( MonoTupleCreate region items1 t, c ))

        MonoLiteral _ _ ->
            Nothing

        MonoVarLocal _ _ ->
            Nothing

        MonoVarGlobal _ _ _ ->
            Nothing

        MonoVarKernel _ _ _ _ _ ->
            Nothing

        MonoUnit ->
            Nothing

        MonoAccessorValue _ _ _ ->
            Nothing


isFunctionType : Mono.MonoType -> Bool
isFunctionType t =
    case t of
        Mono.MFunction _ _ _ ->
            True

        _ ->
            False


forwardGoList : RewriteCtx -> Name -> Mono.ClosureInfo -> MonoExpr -> List MonoExpr -> Maybe ( List MonoExpr, RewriteCtx )
forwardGoList ctx name cinfo cbody exprs =
    case exprs of
        [] ->
            Nothing

        e :: rest ->
            case forwardGo ctx name cinfo cbody e of
                Just ( e1, c ) ->
                    Just ( e1 :: rest, c )

                Nothing ->
                    forwardGoList ctx name cinfo cbody rest
                        |> Maybe.map (\( rest1, c ) -> ( e :: rest1, c ))


forwardGoSndList : RewriteCtx -> Name -> Mono.ClosureInfo -> MonoExpr -> List ( a, MonoExpr ) -> Maybe ( List ( a, MonoExpr ), RewriteCtx )
forwardGoSndList ctx name cinfo cbody pairs =
    case pairs of
        [] ->
            Nothing

        ( k, e ) :: rest ->
            case forwardGo ctx name cinfo cbody e of
                Just ( e1, c ) ->
                    Just ( ( k, e1 ) :: rest, c )

                Nothing ->
                    forwardGoSndList ctx name cinfo cbody rest
                        |> Maybe.map (\( rest1, c ) -> ( ( k, e ) :: rest1, c ))


forwardGoIfBranches : RewriteCtx -> Name -> Mono.ClosureInfo -> MonoExpr -> List ( MonoExpr, MonoExpr ) -> Maybe ( List ( MonoExpr, MonoExpr ), RewriteCtx )
forwardGoIfBranches ctx name cinfo cbody branches =
    case branches of
        [] ->
            Nothing

        ( cond, then_ ) :: rest ->
            case forwardGo ctx name cinfo cbody cond of
                Just ( cond1, c ) ->
                    Just ( ( cond1, then_ ) :: rest, c )

                Nothing ->
                    case forwardGo ctx name cinfo cbody then_ of
                        Just ( then1, c ) ->
                            Just ( ( cond, then1 ) :: rest, c )

                        Nothing ->
                            forwardGoIfBranches ctx name cinfo cbody rest
                                |> Maybe.map (\( rest1, c ) -> ( ( cond, then_ ) :: rest1, c ))


forwardGoDecider : RewriteCtx -> Name -> Mono.ClosureInfo -> MonoExpr -> Mono.Decider Mono.MonoChoice -> Maybe ( Mono.Decider Mono.MonoChoice, RewriteCtx )
forwardGoDecider ctx name cinfo cbody decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            forwardGo ctx name cinfo cbody e
                |> Maybe.map (\( e1, c ) -> ( Mono.Leaf (Mono.Inline e1), c ))

        Mono.Leaf (Mono.Jump _) ->
            Nothing

        Mono.Chain tests success failure ->
            case forwardGoDecider ctx name cinfo cbody success of
                Just ( s1, c ) ->
                    Just ( Mono.Chain tests s1 failure, c )

                Nothing ->
                    forwardGoDecider ctx name cinfo cbody failure
                        |> Maybe.map (\( f1, c ) -> ( Mono.Chain tests success f1, c ))

        Mono.FanOut path tests fallback ->
            case forwardGoDeciderSndList ctx name cinfo cbody tests of
                Just ( tests1, c ) ->
                    Just ( Mono.FanOut path tests1 fallback, c )

                Nothing ->
                    forwardGoDecider ctx name cinfo cbody fallback
                        |> Maybe.map (\( fb1, c ) -> ( Mono.FanOut path tests fb1, c ))


forwardGoDeciderSndList : RewriteCtx -> Name -> Mono.ClosureInfo -> MonoExpr -> List ( a, Mono.Decider Mono.MonoChoice ) -> Maybe ( List ( a, Mono.Decider Mono.MonoChoice ), RewriteCtx )
forwardGoDeciderSndList ctx name cinfo cbody pairs =
    case pairs of
        [] ->
            Nothing

        ( k, d ) :: rest ->
            case forwardGoDecider ctx name cinfo cbody d of
                Just ( d1, c ) ->
                    Just ( ( k, d1 ) :: rest, c )

                Nothing ->
                    forwardGoDeciderSndList ctx name cinfo cbody rest
                        |> Maybe.map (\( rest1, c ) -> ( ( k, d ) :: rest1, c ))



-- ============================================================================
-- ====== ALPHA-RENAMING OF INSTANTIATED BODIES ======
-- ============================================================================


{-| Alpha-rename every let-bound name in an instantiated (inlined) body to a
fresh name.

`substituteAll` freshens the parameter bindings of an inlined call, but the
body's internal let-bound names are copied verbatim. Inlining the same
function twice into one consumer therefore produces duplicate let names on
one chain, which breaks MLIR codegen: `generateLetSingle` keys SSA
placeholders by name (`addPlaceholderMappings` reuses a same-named sibling
placeholder and `forceResultVar` then renames two defining ops to the same
SSA id — "redefinition of SSA value" / "operand does not dominate this use").

So every instantiation must also freshen the let-bound names (MonoDef and
MonoTailDef, including a tail def's MonoTailCall self-references) of the
body it copies.

Inner lets of a binding are freshened before the binding's own rename, so
by the time a name is renamed no duplicate of it remains in scope and the
rename cannot capture an inner shadowing binding.

-}
freshenLetBoundNames : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
freshenLetBoundNames ctx expr =
    case expr of
        MonoLet _ _ _ ->
            -- A let CHAIN is renamed as a group: sibling defs can reference
            -- each other in BOTH directions (mutually recursive closures, the
            -- reason codegen's currentLetSiblings exists), so each rename must
            -- apply across every def's bound expression and the final body,
            -- not just the lexical body of its own binding.
            freshenLetChain ctx expr

        MonoVarLocal _ _ ->
            ( expr, ctx )

        MonoLiteral _ _ ->
            ( expr, ctx )

        MonoVarGlobal _ _ _ ->
            ( expr, ctx )

        MonoVarKernel _ _ _ _ _ ->
            ( expr, ctx )

        MonoUnit ->
            ( expr, ctx )

        MonoAccessorValue _ _ _ ->
            ( expr, ctx )

        MonoList region items itemType ->
            let
                ( items1, ctx1 ) =
                    freshenLetBoundNamesList ctx items
            in
            ( MonoList region items1 itemType, ctx1 )

        MonoClosure info body closureType ->
            let
                ( capturesRev, ctx1 ) =
                    List.foldl
                        (\( n, e, isUnboxed ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    freshenLetBoundNames c e
                            in
                            ( ( n, e1, isUnboxed ) :: acc, c1 )
                        )
                        ( [], ctx )
                        info.captures

                ( body1, ctx2 ) =
                    freshenLetBoundNames ctx1 body
            in
            ( MonoClosure { info | captures = List.reverse capturesRev } body1 closureType, ctx2 )

        MonoCall region func args resultType callInfo ->
            let
                ( func1, ctx1 ) =
                    freshenLetBoundNames ctx func

                ( args1, ctx2 ) =
                    freshenLetBoundNamesList ctx1 args
            in
            ( MonoCall region func1 args1 resultType callInfo, ctx2 )

        MonoTailCall name args resultType ->
            let
                ( argsRev, ctx1 ) =
                    List.foldl
                        (\( n, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    freshenLetBoundNames c e
                            in
                            ( ( n, e1 ) :: acc, c1 )
                        )
                        ( [], ctx )
                        args
            in
            ( MonoTailCall name (List.reverse argsRev) resultType, ctx1 )

        MonoIf branches final resultType ->
            let
                ( branchesRev, ctx1 ) =
                    List.foldl
                        (\( c, t ) ( acc, cx ) ->
                            let
                                ( c1, cx1 ) =
                                    freshenLetBoundNames cx c

                                ( t1, cx2 ) =
                                    freshenLetBoundNames cx1 t
                            in
                            ( ( c1, t1 ) :: acc, cx2 )
                        )
                        ( [], ctx )
                        branches

                ( final1, ctx2 ) =
                    freshenLetBoundNames ctx1 final
            in
            ( MonoIf (List.reverse branchesRev) final1 resultType, ctx2 )

        MonoDestruct destructor inner resultType ->
            let
                ( inner1, ctx1 ) =
                    freshenLetBoundNames ctx inner
            in
            ( MonoDestruct destructor inner1 resultType, ctx1 )

        MonoCase unused rootName decider jumps resultType ->
            let
                ( decider1, ctx1 ) =
                    freshenLetBoundNamesInDecider ctx decider

                ( jumpsRev, ctx2 ) =
                    List.foldl
                        (\( idx, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    freshenLetBoundNames c e
                            in
                            ( ( idx, e1 ) :: acc, c1 )
                        )
                        ( [], ctx1 )
                        jumps
            in
            ( MonoCase unused rootName decider1 (List.reverse jumpsRev) resultType, ctx2 )

        MonoRecordCreate fields recordType ->
            let
                ( fieldsRev, ctx1 ) =
                    List.foldl
                        (\( n, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    freshenLetBoundNames c e
                            in
                            ( ( n, e1 ) :: acc, c1 )
                        )
                        ( [], ctx )
                        fields
            in
            ( MonoRecordCreate (List.reverse fieldsRev) recordType, ctx1 )

        MonoRecordAccess inner fieldName resultType ->
            let
                ( inner1, ctx1 ) =
                    freshenLetBoundNames ctx inner
            in
            ( MonoRecordAccess inner1 fieldName resultType, ctx1 )

        MonoRecordUpdate inner updates recordType ->
            let
                ( inner1, ctx1 ) =
                    freshenLetBoundNames ctx inner

                ( updatesRev, ctx2 ) =
                    List.foldl
                        (\( n, e ) ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    freshenLetBoundNames c e
                            in
                            ( ( n, e1 ) :: acc, c1 )
                        )
                        ( [], ctx1 )
                        updates
            in
            ( MonoRecordUpdate inner1 (List.reverse updatesRev) recordType, ctx2 )

        MonoTupleCreate region items tupleType ->
            let
                ( items1, ctx1 ) =
                    freshenLetBoundNamesList ctx items
            in
            ( MonoTupleCreate region items1 tupleType, ctx1 )


{-| Freshen one let chain as a group.

1.  Split the spine into its defs and the final (non-let) body.
2.  Freshen recursively INSIDE each def's bound expression and the final
    body. After this no binder anywhere below carries one of the spine's
    old names, so the renames in step 4 are total and capture-free.
3.  Allocate a fresh name per spine def and rename the def itself.
4.  Apply every (old -> fresh) rename across the whole rebuilt chain, so
    backward and forward sibling references both follow their binding.

-}
freshenLetChain : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
freshenLetChain ctx chainExpr =
    let
        splitSpine : MonoExpr -> List ( Mono.MonoDef, Mono.MonoType ) -> ( List ( Mono.MonoDef, Mono.MonoType ), MonoExpr )
        splitSpine e acc =
            case e of
                MonoLet d b t ->
                    splitSpine b (( d, t ) :: acc)

                _ ->
                    ( List.reverse acc, e )

        ( spineRev, finalBody0 ) =
            splitSpine chainExpr []

        -- Step 2: freshen inside each def's bound expr, and the final body
        ( spineFreshenedRev, ctx1 ) =
            List.foldl
                (\( d, t ) ( acc, c ) ->
                    let
                        ( d1, c1 ) =
                            freshenInDef c d
                    in
                    ( ( d1, t ) :: acc, c1 )
                )
                ( [], ctx )
                spineRev

        spineFreshened =
            List.reverse spineFreshenedRev

        ( finalBody1, ctx2 ) =
            freshenLetBoundNames ctx1 finalBody0

        -- Step 3: fresh name per def
        ( renamesRev, spineRenamedRev, ctx3 ) =
            List.foldl
                (\( d, t ) ( rens, defs, c ) ->
                    let
                        ( newName, c1 ) =
                            freshVar c
                    in
                    ( ( getDefName d, newName ) :: rens
                    , ( setDefName newName d, t ) :: defs
                    , c1
                    )
                )
                ( [], [], ctx2 )
                spineFreshened

        rebuilt =
            List.foldl
                (\( d, t ) acc -> MonoLet d acc t)
                finalBody1
                spineRenamedRev

        -- Step 4: apply all renames over the whole chain
        renamed =
            List.foldl
                (\( old, new ) e -> renameLocal old new e)
                rebuilt
                renamesRev
    in
    ( renamed, ctx3 )


freshenLetBoundNamesList : RewriteCtx -> List MonoExpr -> ( List MonoExpr, RewriteCtx )
freshenLetBoundNamesList ctx exprs =
    let
        ( revExprs, ctx1 ) =
            List.foldl
                (\e ( acc, c ) ->
                    let
                        ( e1, c1 ) =
                            freshenLetBoundNames c e
                    in
                    ( e1 :: acc, c1 )
                )
                ( [], ctx )
                exprs
    in
    ( List.reverse revExprs, ctx1 )


{-| Freshen the lets inside a definition's bound expression (not the
definition's own name — the caller renames that).
-}
freshenInDef : RewriteCtx -> Mono.MonoDef -> ( Mono.MonoDef, RewriteCtx )
freshenInDef ctx def =
    case def of
        Mono.MonoDef name bound ->
            let
                ( bound1, ctx1 ) =
                    freshenLetBoundNames ctx bound
            in
            ( Mono.MonoDef name bound1, ctx1 )

        Mono.MonoTailDef name params bound ->
            let
                ( bound1, ctx1 ) =
                    freshenLetBoundNames ctx bound
            in
            ( Mono.MonoTailDef name params bound1, ctx1 )


freshenLetBoundNamesInDecider : RewriteCtx -> Mono.Decider Mono.MonoChoice -> ( Mono.Decider Mono.MonoChoice, RewriteCtx )
freshenLetBoundNamesInDecider ctx decider =
    case decider of
        Mono.Leaf (Mono.Inline expr) ->
            let
                ( expr1, ctx1 ) =
                    freshenLetBoundNames ctx expr
            in
            ( Mono.Leaf (Mono.Inline expr1), ctx1 )

        Mono.Leaf (Mono.Jump _) ->
            ( decider, ctx )

        Mono.Chain testChain success failure ->
            let
                ( success1, ctx1 ) =
                    freshenLetBoundNamesInDecider ctx success

                ( failure1, ctx2 ) =
                    freshenLetBoundNamesInDecider ctx1 failure
            in
            ( Mono.Chain testChain success1 failure1, ctx2 )

        Mono.FanOut path edges fallback ->
            let
                ( edgesRev, ctx1 ) =
                    List.foldl
                        (\( test, d ) ( acc, c ) ->
                            let
                                ( d1, c1 ) =
                                    freshenLetBoundNamesInDecider c d
                            in
                            ( ( test, d1 ) :: acc, c1 )
                        )
                        ( [], ctx )
                        edges

                ( fallback1, ctx2 ) =
                    freshenLetBoundNamesInDecider ctx1 fallback
            in
            ( Mono.FanOut path (List.reverse edgesRev) fallback1, ctx2 )


{-| Rename all references to a let-bound name, preserving each occurrence's
own type (unlike `substitute`, which rewrites the occurrence type to the
binding's type — wrong for tail defs, whose occurrences carry function
types).

Also renames MonoTailCall callee names, which `substitute` never needs to
touch (parameters are not tail-callable) but a tail def's rename must.

-}
renameLocal : Name -> Name -> MonoExpr -> MonoExpr
renameLocal oldName newName expr =
    case expr of
        MonoVarLocal name varType ->
            if name == oldName then
                MonoVarLocal newName varType

            else
                expr

        MonoLiteral _ _ ->
            expr

        MonoVarGlobal _ _ _ ->
            expr

        MonoVarKernel _ _ _ _ _ ->
            expr

        MonoUnit ->
            expr

        MonoAccessorValue _ _ _ ->
            expr

        MonoList region items itemType ->
            MonoList region (List.map (renameLocal oldName newName) items) itemType

        MonoClosure info body closureType ->
            if List.any (\( n, _ ) -> n == oldName) info.params then
                expr

            else
                let
                    newCaptures =
                        List.map
                            (\( n, e, isUnboxed ) ->
                                ( if n == oldName then
                                    newName

                                  else
                                    n
                                , renameLocal oldName newName e
                                , isUnboxed
                                )
                            )
                            info.captures
                in
                MonoClosure { info | captures = newCaptures } (renameLocal oldName newName body) closureType

        MonoCall region func args resultType callInfo ->
            MonoCall region
                (renameLocal oldName newName func)
                (List.map (renameLocal oldName newName) args)
                resultType
                callInfo

        MonoTailCall name args resultType ->
            MonoTailCall
                (if name == oldName then
                    newName

                 else
                    name
                )
                (List.map (\( n, e ) -> ( n, renameLocal oldName newName e )) args)
                resultType

        MonoIf branches final resultType ->
            MonoIf
                (List.map (\( c, t ) -> ( renameLocal oldName newName c, renameLocal oldName newName t )) branches)
                (renameLocal oldName newName final)
                resultType

        MonoLet def body resultType ->
            if getDefName def == oldName then
                -- Name is shadowed, only rename in the def's bound expression
                MonoLet (renameLocalInDef oldName newName def) body resultType

            else
                MonoLet (renameLocalInDef oldName newName def) (renameLocal oldName newName body) resultType

        MonoDestruct (Mono.MonoDestructor destructName path destructType) inner resultType ->
            let
                newPath =
                    substitutePath oldName newName path

                newInner =
                    if destructName == oldName then
                        inner

                    else
                        renameLocal oldName newName inner
            in
            MonoDestruct (Mono.MonoDestructor destructName newPath destructType) newInner resultType

        MonoCase unused rootName decider branches resultType ->
            MonoCase unused
                (if rootName == oldName then
                    newName

                 else
                    rootName
                )
                (renameLocalInDecider oldName newName decider)
                (List.map (\( idx, e ) -> ( idx, renameLocal oldName newName e )) branches)
                resultType

        MonoRecordCreate fields recordType ->
            MonoRecordCreate (List.map (\( n, e ) -> ( n, renameLocal oldName newName e )) fields) recordType

        MonoRecordAccess inner fieldName resultType ->
            MonoRecordAccess (renameLocal oldName newName inner) fieldName resultType

        MonoRecordUpdate inner updates recordType ->
            MonoRecordUpdate
                (renameLocal oldName newName inner)
                (List.map (\( n, e ) -> ( n, renameLocal oldName newName e )) updates)
                recordType

        MonoTupleCreate region items tupleType ->
            MonoTupleCreate region (List.map (renameLocal oldName newName) items) tupleType


renameLocalInDef : Name -> Name -> Mono.MonoDef -> Mono.MonoDef
renameLocalInDef oldName newName def =
    case def of
        Mono.MonoDef name bound ->
            Mono.MonoDef name (renameLocal oldName newName bound)

        Mono.MonoTailDef name params bound ->
            if List.any (\( n, _ ) -> n == oldName) params then
                def

            else
                Mono.MonoTailDef name params (renameLocal oldName newName bound)


renameLocalInDecider : Name -> Name -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
renameLocalInDecider oldName newName decider =
    case decider of
        Mono.Leaf (Mono.Inline expr) ->
            Mono.Leaf (Mono.Inline (renameLocal oldName newName expr))

        Mono.Leaf (Mono.Jump _) ->
            decider

        Mono.Chain testChain success failure ->
            Mono.Chain
                (List.map
                    (\( dtPath, test ) ->
                        ( substituteDtPath oldName newName dtPath, test )
                    )
                    testChain
                )
                (renameLocalInDecider oldName newName success)
                (renameLocalInDecider oldName newName failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut (substituteDtPath oldName newName path)
                (List.map (\( test, d ) -> ( test, renameLocalInDecider oldName newName d )) edges)
                (renameLocalInDecider oldName newName fallback)



-- ============================================================================
-- ====== DIRECT CALL INLINING ======
-- ============================================================================


tryInlineCall : RewriteCtx -> SpecId -> List MonoExpr -> Mono.MonoType -> ( Maybe MonoExpr, RewriteCtx )
tryInlineCall ctx specId args resultType =
    -- Check budget
    if ctx.inlineCountThisFunction >= ctx.maxInlinesPerFunction then
        ( Nothing, ctx )

    else
        -- Look up the callee from pre-filtered inline candidates
        case Dict.get specId ctx.inlineCandidates of
            Nothing ->
                ( Nothing, ctx )

            Just ( params, body, exactOnly ) ->
                let
                    numParams =
                        List.length params

                    numArgs =
                        List.length args
                in
                if exactOnly && numArgs < numParams then
                    -- hofBudget-admitted candidates never inline PARTIALLY:
                    -- the partial rebuild's re-staged closure trips the
                    -- runtime typed-apply arity assert when a caller
                    -- over-applies it (see inlineCandidates doc).
                    ( Nothing, ctx )

                else if numParams == 0 && numArgs > 0 then
                    -- Inlining a non-closure value that's being called.
                    -- The body is likely a function reference. Inline it and
                    -- wrap with a call to apply the remaining arguments.
                    --
                    -- Exception: when the body is a bare MonoVarKernel and the
                    -- call's result is a function type (partial application),
                    -- DON'T inline. Inlining would replace the typed user
                    -- wrapper (e.g. `Basics_add_$_1` whose body is the
                    -- `eco.int.add` intrinsic) with a direct kernel reference
                    -- (`Elm_Kernel_Basics_add`), forcing the partial-app
                    -- target to use the polymorphic boxed kernel decl. The
                    -- user wrapper already specializes correctly via
                    -- registerKernelInstance / monoTypeToAbi, so leaving the
                    -- call alone gets us the typed `papCreate function =
                    -- @Basics_add_$_1` we want.
                    let
                        bodyIsKernelRef =
                            case body of
                                MonoVarKernel _ _ _ _ _ ->
                                    True

                                _ ->
                                    False

                        resultIsFunctionType =
                            case resultType of
                                Mono.MFunction _ _ _ ->
                                    True

                                _ ->
                                    False
                    in
                    if bodyIsKernelRef && resultIsFunctionType then
                        ( Nothing, ctx )

                    else
                        let
                            ( remappedBody, ctx1 ) =
                                remapLambdaIds ctx body

                            inlined =
                                MonoCall A.zero remappedBody args resultType Mono.defaultCallInfo
                        in
                        ( Just inlined
                        , recordInline specId ctx1
                        )

                else if numArgs < numParams then
                    -- Partial application: bind available params, return closure with remaining
                    let
                        ( remappedBody, ctx1 ) =
                            remapLambdaIds ctx body

                        ( usedParams, remainingParams ) =
                            ( List.take numArgs params, List.drop numArgs params )

                        ( bindings, ctx2 ) =
                            createBindingsForInline ctx1 usedParams args

                        ( substituted, ctx2a ) =
                            freshenLetBoundNames ctx2 (substituteAllForInline bindings remappedBody)

                        -- Create a new closure with the remaining parameters
                        ( newLambdaId, ctx3 ) =
                            freshLambdaIdForSpec ctx2a specId

                        newClosureType =
                            -- Partial-application rebuild: LTop (sound; the original
                            -- head anno is not in scope here — precision-only loss).
                            Mono.MFunction Mono.LTop (List.map Tuple.second remainingParams) resultType

                        -- Compute captures for the new closure
                        newCaptures =
                            Closure.computeClosureCaptures remainingParams substituted

                        newClosureInfo =
                            { lambdaId = newLambdaId
                            , srcLambda = Nothing
                            , params = remainingParams
                            , captures = newCaptures
                            , closureKind = Nothing
                            , captureAbi = Nothing
                            }

                        newClosure =
                            MonoClosure newClosureInfo substituted newClosureType

                        inlined =
                            wrapInLetsForInline bindings newClosure newClosureType
                    in
                    ( Just inlined
                    , recordInline specId ctx3
                    )

                else if numArgs > numParams then
                    -- Over-application: apply all params, then call result with extra args
                    let
                        ( remappedBody, ctx1 ) =
                            remapLambdaIds ctx body

                        ( usedArgs, extraArgs ) =
                            ( List.take numParams args, List.drop numParams args )

                        ( bindings, ctx2 ) =
                            createBindingsForInline ctx1 params usedArgs

                        ( substituted, ctx3 ) =
                            freshenLetBoundNames ctx2 (substituteAllForInline bindings remappedBody)

                        innerExpr =
                            wrapInLetsForInline bindings substituted resultType

                        inlined =
                            MonoCall A.zero innerExpr extraArgs resultType Mono.defaultCallInfo
                    in
                    ( Just inlined
                    , recordInline specId ctx3
                    )

                else
                    -- Exact application: bind all params to args
                    let
                        -- First, remap all lambda IDs in the body to avoid duplicate names
                        ( remappedBody, ctx1 ) =
                            remapLambdaIds ctx body

                        ( bindings, ctx2 ) =
                            createBindingsForInline ctx1 params args

                        ( substituted, ctx3 ) =
                            freshenLetBoundNames ctx2 (substituteAllForInline bindings remappedBody)

                        inlined =
                            wrapInLetsForInline bindings substituted resultType
                    in
                    ( Just inlined
                    , recordInline specId ctx3
                    )


getInlinableBody : MonoNode -> Maybe ( List ( Name, Mono.MonoType ), MonoExpr )
getInlinableBody node =
    case node of
        MonoDefine expr _ ->
            -- Check if the define's expression is a closure. Case bodies are
            -- inlinable (H2.0): eco.case is a value-producing expression op
            -- (CGEN_010/CGEN_045), legal in any expression position — pinned
            -- by CasePositionProbe/AndThenProbe. The historical refusal dated
            -- from the terminator-era eco.case design.
            case expr of
                MonoClosure info body _ ->
                    Just ( info.params, body )

                _ ->
                    -- Simple define with no parameters (e.g., constants)
                    Just ( [], expr )

        MonoTailFunc _ _ _ ->
            -- Never inline tail-recursive functions. Their bodies contain
            -- MonoTailCall nodes that are only meaningful inside a MonoTailFunc
            -- (compiled via TailRec.compileTailFuncToWhile). Inlining would
            -- place MonoTailCall in a non-tail-recursive context, producing
            -- orphaned eco.jump ops that crash mkCaseRegionFromDecider.
            Nothing

        _ ->
            Nothing


{-| Check if an expression is a MonoCase (top level only).

Used only to keep case bodies out of `buildBodyLookup` — the bytes-fusion
reifier's reify-time beta-reducer hasn't been verified against them. The
inliner itself accepts case bodies (H2.0): eco.case is value-producing
(CGEN_010/CGEN_045), not a terminator.
-}
isCase : MonoExpr -> Bool
isCase expr =
    case expr of
        MonoCase _ _ _ _ _ ->
            True

        _ ->
            False


createBindingsForInline : RewriteCtx -> List ( Name, Mono.MonoType ) -> List MonoExpr -> ( List Binding, RewriteCtx )
createBindingsForInline ctx params args =
    -- For inlining, we need to handle the case where we have a parameterless define
    if List.isEmpty params then
        ( [], ctx )

    else
        createBindings ctx params args


substituteAllForInline : List Binding -> MonoExpr -> MonoExpr
substituteAllForInline =
    substituteAll


wrapInLetsForInline : List Binding -> MonoExpr -> Mono.MonoType -> MonoExpr
wrapInLetsForInline =
    wrapInLets



-- ============================================================================
-- ====== LET SIMPLIFICATION ======
-- ============================================================================


{-| Simplify one let chain as a group: simplify inside every def's bound
expression and the final body, then drop dead defs.

Two dead-def rules (H1.2):

  - Non-closure pure defs drop when they have zero uses in their lexical
    body (later siblings + final body) — the pre-existing rule, unchanged.
  - Closure defs drop when they have zero uses across ALL other spine defs
    and the final body. Closures need the both-directions check because
    letrec siblings may reference each other backward (an earlier closure's
    capture can point at a later one); a self-reference in the closure's own
    bound expression does not keep it alive (the whole subtree is deleted).

Dropping one def can make another dead (chains of dead closures referencing
each other), so the drop pass iterates to a fixpoint within the chain.

-}
simplifyLetChain : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
simplifyLetChain ctx chainExpr =
    let
        splitSpine : MonoExpr -> List ( Mono.MonoDef, Mono.MonoType ) -> ( List ( Mono.MonoDef, Mono.MonoType ), MonoExpr )
        splitSpine e acc =
            case e of
                MonoLet d b t ->
                    splitSpine b (( d, t ) :: acc)

                _ ->
                    ( List.reverse acc, e )

        ( spine0, finalBody0 ) =
            splitSpine chainExpr []

        ( spineSimplifiedRev, ctx1 ) =
            List.foldl
                (\( d, t ) ( acc, c ) ->
                    let
                        ( bound1, c1 ) =
                            simplifyLets c (getDefBound d)
                    in
                    ( ( setDefBound d bound1, t ) :: acc, c1 )
                )
                ( [], ctx )
                spine0

        ( finalBody1, ctx2 ) =
            simplifyLets ctx1 finalBody0

        ( keptSpine, ctx3 ) =
            dropDeadDefs ctx2 (List.reverse spineSimplifiedRev) finalBody1
    in
    ( List.foldr (\( d, t ) acc -> MonoLet d acc t) finalBody1 keptSpine, ctx3 )


{-| One drop pass over the spine; re-runs itself while anything dropped.
-}
dropDeadDefs : RewriteCtx -> List ( Mono.MonoDef, Mono.MonoType ) -> MonoExpr -> ( List ( Mono.MonoDef, Mono.MonoType ), RewriteCtx )
dropDeadDefs ctx spine finalBody =
    let
        usesInDefs : Name -> List ( Mono.MonoDef, Mono.MonoType ) -> Int
        usesInDefs name defs =
            List.foldl (\( d, _ ) n -> n + countUsagesInDef name d) 0 defs

        go earlierRev remaining c anyDropped =
            case remaining of
                [] ->
                    ( List.reverse earlierRev, c, anyDropped )

                (( d, _ ) as entry) :: rest ->
                    let
                        keep () =
                            go (entry :: earlierRev) rest c anyDropped

                        name =
                            getDefName d

                        bound =
                            getDefBound d
                    in
                    case d of
                        Mono.MonoDef _ _ ->
                            let
                                laterUses =
                                    usesInDefs name rest + countUsages name finalBody
                            in
                            if isClosure bound then
                                if laterUses == 0 && usesInDefs name earlierRev == 0 then
                                    go earlierRev rest (bumpClosureDCE c) True

                                else
                                    keep ()

                            else if laterUses == 0 && isPureExpr bound then
                                go earlierRev rest (bumpLetElimination c) True

                            else
                                keep ()

                        Mono.MonoTailDef _ _ _ ->
                            keep ()

        ( kept, ctxOut, dropped ) =
            go [] spine ctx False
    in
    if dropped then
        dropDeadDefs ctxOut kept finalBody

    else
        ( kept, ctxOut )


simplifyLets : RewriteCtx -> MonoExpr -> ( MonoExpr, RewriteCtx )
simplifyLets ctx expr =
    case expr of
        MonoLet _ _ _ ->
            -- Let CHAINS are simplified as a group so dead-closure elimination
            -- can see sibling references in BOTH directions (letrec closures
            -- may reference each other backward and forward — the same reason
            -- freshenLetChain works on the whole spine).
            simplifyLetChain ctx expr

        -- Recursive cases
        MonoCall region func args resultType callInfo ->
            let
                ( simplifiedFunc, ctx1 ) =
                    simplifyLets ctx func

                ( simplifiedArgs, ctx2 ) =
                    simplifyLetsExprs ctx1 args
            in
            ( MonoCall region simplifiedFunc simplifiedArgs resultType callInfo, ctx2 )

        MonoClosure info body closureType ->
            let
                ( simplifiedCaptures, ctx1 ) =
                    simplifyLetsCaptures ctx info.captures

                ( simplifiedBody, ctx2 ) =
                    simplifyLets ctx1 body
            in
            ( MonoClosure { info | captures = simplifiedCaptures } simplifiedBody closureType, ctx2 )

        MonoList region items itemType ->
            let
                ( simplifiedItems, ctx1 ) =
                    simplifyLetsExprs ctx items
            in
            ( MonoList region simplifiedItems itemType, ctx1 )

        MonoIf branches final resultType ->
            let
                ( simplifiedBranches, ctx1 ) =
                    simplifyLetsBranches ctx branches

                ( simplifiedFinal, ctx2 ) =
                    simplifyLets ctx1 final
            in
            ( MonoIf simplifiedBranches simplifiedFinal resultType, ctx2 )

        MonoDestruct destructor inner resultType ->
            let
                ( simplifiedInner, ctx1 ) =
                    simplifyLets ctx inner
            in
            ( MonoDestruct destructor simplifiedInner resultType, ctx1 )

        MonoCase scrutName scrutType decider branches resultType ->
            let
                ( simplifiedDecider, ctx1 ) =
                    simplifyLetsDecider ctx decider

                ( simplifiedBranches, ctx2 ) =
                    simplifyLetsCaseBranches ctx1 branches
            in
            ( MonoCase scrutName scrutType simplifiedDecider simplifiedBranches resultType, ctx2 )

        MonoRecordCreate fields recordType ->
            let
                ( simplifiedFields, ctx1 ) =
                    simplifyLetsNamedFields ctx fields
            in
            ( MonoRecordCreate simplifiedFields recordType, ctx1 )

        MonoRecordAccess inner fieldName resultType ->
            let
                ( simplifiedInner, ctx1 ) =
                    simplifyLets ctx inner
            in
            ( MonoRecordAccess simplifiedInner fieldName resultType, ctx1 )

        MonoRecordUpdate inner updates recordType ->
            let
                ( simplifiedInner, ctx1 ) =
                    simplifyLets ctx inner

                ( simplifiedUpdates, ctx2 ) =
                    simplifyLetsNamedFields ctx1 updates
            in
            ( MonoRecordUpdate simplifiedInner simplifiedUpdates recordType, ctx2 )

        MonoTupleCreate region items tupleType ->
            let
                ( simplifiedItems, ctx1 ) =
                    simplifyLetsExprs ctx items
            in
            ( MonoTupleCreate region simplifiedItems tupleType, ctx1 )

        MonoTailCall name args resultType ->
            let
                ( simplifiedArgs, ctx1 ) =
                    simplifyLetsTailCallArgs ctx args
            in
            ( MonoTailCall name simplifiedArgs resultType, ctx1 )

        -- Leaves
        _ ->
            ( expr, ctx )


simplifyLetsExprs : RewriteCtx -> List MonoExpr -> ( List MonoExpr, RewriteCtx )
simplifyLetsExprs ctx exprs =
    let
        ( revExprs, finalCtx ) =
            List.foldl
                (\expr ( acc, accCtx ) ->
                    let
                        ( simplified, newCtx ) =
                            simplifyLets accCtx expr
                    in
                    ( simplified :: acc, newCtx )
                )
                ( [], ctx )
                exprs
    in
    ( List.reverse revExprs, finalCtx )


simplifyLetsCaptures : RewriteCtx -> List ( Name, MonoExpr, Bool ) -> ( List ( Name, MonoExpr, Bool ), RewriteCtx )
simplifyLetsCaptures ctx captures =
    let
        ( revCaptures, finalCtx ) =
            List.foldl
                (\( name, expr, isUnboxed ) ( acc, accCtx ) ->
                    let
                        ( simplified, newCtx ) =
                            simplifyLets accCtx expr
                    in
                    ( ( name, simplified, isUnboxed ) :: acc, newCtx )
                )
                ( [], ctx )
                captures
    in
    ( List.reverse revCaptures, finalCtx )


simplifyLetsBranches : RewriteCtx -> List ( MonoExpr, MonoExpr ) -> ( List ( MonoExpr, MonoExpr ), RewriteCtx )
simplifyLetsBranches ctx branches =
    let
        ( revBranches, finalCtx ) =
            List.foldl
                (\( cond, body ) ( acc, accCtx ) ->
                    let
                        ( simplifiedCond, ctx1 ) =
                            simplifyLets accCtx cond

                        ( simplifiedBody, ctx2 ) =
                            simplifyLets ctx1 body
                    in
                    ( ( simplifiedCond, simplifiedBody ) :: acc, ctx2 )
                )
                ( [], ctx )
                branches
    in
    ( List.reverse revBranches, finalCtx )


simplifyLetsCaseBranches : RewriteCtx -> List ( Int, MonoExpr ) -> ( List ( Int, MonoExpr ), RewriteCtx )
simplifyLetsCaseBranches ctx branches =
    let
        ( revBranches, finalCtx ) =
            List.foldl
                (\( idx, body ) ( acc, accCtx ) ->
                    let
                        ( simplified, newCtx ) =
                            simplifyLets accCtx body
                    in
                    ( ( idx, simplified ) :: acc, newCtx )
                )
                ( [], ctx )
                branches
    in
    ( List.reverse revBranches, finalCtx )


simplifyLetsDecider : RewriteCtx -> Mono.Decider Mono.MonoChoice -> ( Mono.Decider Mono.MonoChoice, RewriteCtx )
simplifyLetsDecider ctx decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    let
                        ( simplified, ctx1 ) =
                            simplifyLets ctx expr
                    in
                    ( Mono.Leaf (Mono.Inline simplified), ctx1 )

                Mono.Jump _ ->
                    ( decider, ctx )

        Mono.Chain testChain success failure ->
            let
                ( simplifiedSuccess, ctx1 ) =
                    simplifyLetsDecider ctx success

                ( simplifiedFailure, ctx2 ) =
                    simplifyLetsDecider ctx1 failure
            in
            ( Mono.Chain testChain simplifiedSuccess simplifiedFailure, ctx2 )

        Mono.FanOut path edges fallback ->
            let
                ( revEdges, ctx1 ) =
                    List.foldl
                        (\( test, d ) ( acc, accCtx ) ->
                            let
                                ( simplified, newCtx ) =
                                    simplifyLetsDecider accCtx d
                            in
                            ( ( test, simplified ) :: acc, newCtx )
                        )
                        ( [], ctx )
                        edges

                simplifiedEdges =
                    List.reverse revEdges

                ( simplifiedFallback, ctx2 ) =
                    simplifyLetsDecider ctx1 fallback
            in
            ( Mono.FanOut path simplifiedEdges simplifiedFallback, ctx2 )


simplifyLetsNamedFields : RewriteCtx -> List ( Name, MonoExpr ) -> ( List ( Name, MonoExpr ), RewriteCtx )
simplifyLetsNamedFields ctx fields =
    let
        ( revFields, finalCtx ) =
            List.foldl
                (\( name, expr ) ( acc, accCtx ) ->
                    let
                        ( simplified, newCtx ) =
                            simplifyLets accCtx expr
                    in
                    ( ( name, simplified ) :: acc, newCtx )
                )
                ( [], ctx )
                fields
    in
    ( List.reverse revFields, finalCtx )


simplifyLetsTailCallArgs : RewriteCtx -> List ( Name, MonoExpr ) -> ( List ( Name, MonoExpr ), RewriteCtx )
simplifyLetsTailCallArgs ctx args =
    let
        ( revArgs, finalCtx ) =
            List.foldl
                (\( name, expr ) ( acc, accCtx ) ->
                    let
                        ( simplified, newCtx ) =
                            simplifyLets accCtx expr
                    in
                    ( ( name, simplified ) :: acc, newCtx )
                )
                ( [], ctx )
                args
    in
    ( List.reverse revArgs, finalCtx )


getDefBound : Mono.MonoDef -> MonoExpr
getDefBound def =
    case def of
        Mono.MonoDef _ bound ->
            bound

        Mono.MonoTailDef _ _ bound ->
            bound


setDefBound : Mono.MonoDef -> MonoExpr -> Mono.MonoDef
setDefBound def newBound =
    case def of
        Mono.MonoDef name _ ->
            Mono.MonoDef name newBound

        Mono.MonoTailDef name params _ ->
            Mono.MonoTailDef name params newBound


{-| Check if an expression is a closure.
-}
isClosure : MonoExpr -> Bool
isClosure expr =
    case expr of
        MonoClosure _ _ _ ->
            True

        _ ->
            False


{-| Check if an expression is pure (no side effects).
We're conservative here - only eliminate bindings we're certain are pure.
Function calls might have side effects (like Debug.log), so we don't eliminate them.
-}
isPureExpr : MonoExpr -> Bool
isPureExpr expr =
    case expr of
        MonoLiteral _ _ ->
            True

        MonoVarLocal _ _ ->
            True

        MonoVarGlobal _ _ _ ->
            True

        MonoVarKernel _ _ _ _ _ ->
            -- Kernel functions could have side effects
            False

        MonoUnit ->
            True

        MonoAccessorValue _ _ _ ->
            True

        MonoList _ items _ ->
            List.all isPureExpr items

        MonoClosure _ _ _ ->
            -- Closure creation is pure (evaluation is not)
            True

        MonoCall _ _ _ _ _ ->
            -- Function calls might have side effects
            False

        MonoTailCall _ _ _ ->
            -- Tail calls might have side effects
            False

        MonoIf branches final _ ->
            List.all (\( c, t ) -> isPureExpr c && isPureExpr t) branches
                && isPureExpr final

        MonoLet def body _ ->
            isPureExprDef def && isPureExpr body

        MonoDestruct _ inner _ ->
            isPureExpr inner

        MonoCase _ _ decider branches _ ->
            isPureDecider decider && List.all (\( _, e ) -> isPureExpr e) branches

        MonoRecordCreate fields _ ->
            List.all (\( _, e ) -> isPureExpr e) fields

        MonoRecordAccess inner _ _ ->
            isPureExpr inner

        MonoRecordUpdate inner updates _ ->
            isPureExpr inner && List.all (\( _, e ) -> isPureExpr e) updates

        MonoTupleCreate _ items _ ->
            List.all isPureExpr items


isPureExprDef : Mono.MonoDef -> Bool
isPureExprDef def =
    case def of
        Mono.MonoDef _ bound ->
            isPureExpr bound

        Mono.MonoTailDef _ _ bound ->
            isPureExpr bound


isPureDecider : Mono.Decider Mono.MonoChoice -> Bool
isPureDecider decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    isPureExpr expr

                Mono.Jump _ ->
                    True

        Mono.Chain _ success failure ->
            isPureDecider success && isPureDecider failure

        Mono.FanOut _ tests fallback ->
            List.all (\( _, d ) -> isPureDecider d) tests && isPureDecider fallback


countUsages : Name -> MonoExpr -> Int
countUsages name expr =
    case expr of
        MonoVarLocal n _ ->
            if n == name then
                1

            else
                0

        MonoLiteral _ _ ->
            0

        MonoVarGlobal _ _ _ ->
            0

        MonoVarKernel _ _ _ _ _ ->
            0

        MonoUnit ->
            0

        MonoAccessorValue _ _ _ ->
            0

        MonoList _ items _ ->
            sumBy (countUsages name) items

        MonoClosure info body _ ->
            -- Don't count if shadowed by param
            if List.any (\( n, _ ) -> n == name) info.params then
                sumBy (\( _, e, _ ) -> countUsages name e) info.captures

            else
                sumBy (\( _, e, _ ) -> countUsages name e) info.captures
                    + countUsages name body

        MonoCall _ func args _ _ ->
            countUsages name func + sumBy (countUsages name) args

        MonoTailCall funcName args _ ->
            -- Count if this is a tail call to the variable
            (if funcName == name then
                1

             else
                0
            )
                + sumBy (\( _, e ) -> countUsages name e) args

        MonoIf branches final _ ->
            sumBy (\( c, t ) -> countUsages name c + countUsages name t) branches
                + countUsages name final

        MonoLet def body _ ->
            let
                defName =
                    getDefName def

                boundUsages =
                    countUsagesInDef name def
            in
            if defName == name then
                boundUsages

            else
                boundUsages + countUsages name body

        MonoDestruct (Mono.MonoDestructor _ path _) inner _ ->
            -- Count usage in the path (the source being destructured) + usage in inner
            -- Note: destructName is the OUTPUT binding, not an input usage
            countUsagesInPath name path + countUsages name inner

        MonoCase _ rootName decider branches _ ->
            -- MonoCase has two Names: first is unused, second is the root variable
            let
                rootUsage =
                    if rootName == name then
                        1

                    else
                        0
            in
            rootUsage + countUsagesInDecider name decider + sumBy (\( _, e ) -> countUsages name e) branches

        MonoRecordCreate fields _ ->
            sumBy (\( _, e ) -> countUsages name e) fields

        MonoRecordAccess inner _ _ ->
            countUsages name inner

        MonoRecordUpdate inner updates _ ->
            countUsages name inner + sumBy (\( _, e ) -> countUsages name e) updates

        MonoTupleCreate _ items _ ->
            sumBy (countUsages name) items


countUsagesInDef : Name -> Mono.MonoDef -> Int
countUsagesInDef name def =
    case def of
        Mono.MonoDef _ bound ->
            countUsages name bound

        Mono.MonoTailDef _ params bound ->
            if List.any (\( n, _ ) -> n == name) params then
                0

            else
                countUsages name bound


countUsagesInPath : Name -> Mono.MonoPath -> Int
countUsagesInPath name path =
    case path of
        Mono.MonoRoot rootName _ ->
            if rootName == name then
                1

            else
                0

        Mono.MonoIndex _ _ _ innerPath ->
            countUsagesInPath name innerPath

        Mono.MonoField _ _ innerPath ->
            countUsagesInPath name innerPath

        Mono.MonoUnbox _ innerPath ->
            countUsagesInPath name innerPath


countUsagesInDecider : Name -> Mono.Decider Mono.MonoChoice -> Int
countUsagesInDecider name decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    countUsages name expr

                Mono.Jump _ ->
                    0

        Mono.Chain _ success failure ->
            countUsagesInDecider name success + countUsagesInDecider name failure

        Mono.FanOut _ edges fallback ->
            sumBy (\( _, d ) -> countUsagesInDecider name d) edges
                + countUsagesInDecider name fallback


inlineVar : Name -> MonoExpr -> MonoExpr -> MonoExpr
inlineVar name replacement expr =
    case expr of
        MonoVarLocal n _ ->
            if n == name then
                replacement

            else
                expr

        MonoLiteral _ _ ->
            expr

        MonoVarGlobal _ _ _ ->
            expr

        MonoVarKernel _ _ _ _ _ ->
            expr

        MonoUnit ->
            expr

        MonoAccessorValue _ _ _ ->
            expr

        MonoList region items itemType ->
            MonoList region (List.map (inlineVar name replacement) items) itemType

        MonoClosure info body closureType ->
            if List.any (\( n, _ ) -> n == name) info.params then
                expr

            else
                let
                    newCaptures =
                        List.map
                            (\( n, e, isUnboxed ) -> ( n, inlineVar name replacement e, isUnboxed ))
                            info.captures
                in
                MonoClosure { info | captures = newCaptures } (inlineVar name replacement body) closureType

        MonoCall region func args resultType callInfo ->
            MonoCall region
                (inlineVar name replacement func)
                (List.map (inlineVar name replacement) args)
                resultType
                callInfo

        MonoTailCall n args resultType ->
            MonoTailCall n
                (List.map (\( argName, e ) -> ( argName, inlineVar name replacement e )) args)
                resultType

        MonoIf branches final resultType ->
            MonoIf
                (List.map (\( c, t ) -> ( inlineVar name replacement c, inlineVar name replacement t )) branches)
                (inlineVar name replacement final)
                resultType

        MonoLet def body resultType ->
            let
                defName =
                    getDefName def
            in
            if defName == name then
                MonoLet (inlineVarInDef name replacement def) body resultType

            else
                MonoLet (inlineVarInDef name replacement def) (inlineVar name replacement body) resultType

        MonoDestruct (Mono.MonoDestructor destructName path destructType) inner resultType ->
            let
                newPath =
                    inlineVarInPath name replacement path

                newInner =
                    if destructName == name then
                        inner

                    else
                        inlineVar name replacement inner
            in
            MonoDestruct (Mono.MonoDestructor destructName newPath destructType) newInner resultType

        MonoCase scrutName rootName decider branches resultType ->
            let
                newRootName =
                    if rootName == name then
                        case replacement of
                            MonoVarLocal newName_ _ ->
                                newName_

                            _ ->
                                rootName

                    else
                        rootName
            in
            MonoCase scrutName
                newRootName
                (inlineVarInDecider name replacement decider)
                (List.map (\( idx, e ) -> ( idx, inlineVar name replacement e )) branches)
                resultType

        MonoRecordCreate fields recordType ->
            MonoRecordCreate (List.map (\( n, e ) -> ( n, inlineVar name replacement e )) fields) recordType

        MonoRecordAccess inner fieldName resultType ->
            MonoRecordAccess (inlineVar name replacement inner) fieldName resultType

        MonoRecordUpdate inner updates recordType ->
            MonoRecordUpdate
                (inlineVar name replacement inner)
                (List.map (\( n, e ) -> ( n, inlineVar name replacement e )) updates)
                recordType

        MonoTupleCreate region items tupleType ->
            MonoTupleCreate region (List.map (inlineVar name replacement) items) tupleType


inlineVarInDef : Name -> MonoExpr -> Mono.MonoDef -> Mono.MonoDef
inlineVarInDef name replacement def =
    case def of
        Mono.MonoDef n bound ->
            Mono.MonoDef n (inlineVar name replacement bound)

        Mono.MonoTailDef n params bound ->
            if List.any (\( pn, _ ) -> pn == name) params then
                def

            else
                Mono.MonoTailDef n params (inlineVar name replacement bound)


inlineVarInPath : Name -> MonoExpr -> Mono.MonoPath -> Mono.MonoPath
inlineVarInPath name replacement path =
    case path of
        Mono.MonoRoot rootName rootType ->
            if rootName == name then
                case replacement of
                    MonoVarLocal newName _ ->
                        Mono.MonoRoot newName rootType

                    _ ->
                        -- Can't inline a non-variable expression into a path root
                        path

            else
                path

        Mono.MonoIndex idx container resultType innerPath ->
            Mono.MonoIndex idx container resultType (inlineVarInPath name replacement innerPath)

        Mono.MonoField fieldIdx resultType innerPath ->
            Mono.MonoField fieldIdx resultType (inlineVarInPath name replacement innerPath)

        Mono.MonoUnbox resultType innerPath ->
            Mono.MonoUnbox resultType (inlineVarInPath name replacement innerPath)


inlineVarInDtPath : Name -> MonoExpr -> Mono.MonoDtPath -> Mono.MonoDtPath
inlineVarInDtPath name replacement dtPath =
    case dtPath of
        Mono.DtRoot rootName ty ->
            if rootName == name then
                case replacement of
                    MonoVarLocal newName _ ->
                        Mono.DtRoot newName ty

                    _ ->
                        dtPath

            else
                dtPath

        Mono.DtIndex idx kind resultTy inner ->
            Mono.DtIndex idx kind resultTy (inlineVarInDtPath name replacement inner)

        Mono.DtUnbox resultTy inner ->
            Mono.DtUnbox resultTy (inlineVarInDtPath name replacement inner)


inlineVarInDecider : Name -> MonoExpr -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
inlineVarInDecider name replacement decider =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    Mono.Leaf (Mono.Inline (inlineVar name replacement expr))

                Mono.Jump _ ->
                    decider

        Mono.Chain testChain success failure ->
            Mono.Chain
                (List.map
                    (\( dtPath, test ) ->
                        ( inlineVarInDtPath name replacement dtPath, test )
                    )
                    testChain
                )
                (inlineVarInDecider name replacement success)
                (inlineVarInDecider name replacement failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut (inlineVarInDtPath name replacement path)
                (List.map (\( test, d ) -> ( test, inlineVarInDecider name replacement d )) edges)
                (inlineVarInDecider name replacement fallback)
