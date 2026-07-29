module Compiler.GlobalOpt.MonoInlineSimplify exposing (Metrics, optimize, buildBodyLookup, countClosures, residualTaxonomy, functionResultCensus)

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
    , partialMerges : Int
    , hofLoopified : Int
    , loopifiable : Int
    , letEliminations : Int
    , closureDCE : Int
    , arityRaised : Int
    , arityRaiseSkipped : Int
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


{-| H6.0c static residual taxonomy (`ECO_INLINE_REPORT=1`): classify every
surviving expression-position `MonoClosure` by its CONSUMPTION CONTEXT, so
the census says which mechanism gap dominates the residual allocations:

  - `arg-to-loopifiable` — argument of a call to a spec H5 COULD loopify
    (the call site failed qualification: non-literal, multi-stage lambda…)
  - `arg-to-tailfunc` — argument to a tail-recursive spec H5 can't loopify
    (cost / self-ref / param analysis)
  - `arg-to-global` — argument to a plain function spec (`List.foldr`
    class: non-tail recursion or general HOFs)
  - `arg-to-ctor` / `arg-to-kernel` / `arg-to-local` — escaping into data
    constructors, kernel calls, or dynamically-dispatched callees
  - `stored-data` — element of a list / record / tuple literal
  - `let-bound` — bound and kept (multi-use or escaping uses)
  - `captured` — a literal directly in another closure's capture list
  - `callee` — literal in callee position (pending beta — should be ~0)
  - `tailcall-arg` / `value` / `other`

Counts include closures nested inside other closures' bodies (they
allocate when the outer body runs).
-}
residualTaxonomy : Config.InlineConfig -> MonoGraph -> List ( String, Int )
residualTaxonomy inlineConfig (MonoGraph { nodes }) =
    let
        loopifiables =
            buildLoopifiables inlineConfig nodes

        specKind : Int -> String
        specKind specId =
            case Array.get specId nodes of
                Just (Just (MonoTailFunc _ _ _)) ->
                    if Dict.member specId loopifiables then
                        "arg-to-loopifiable"

                    else
                        "arg-to-tailfunc"

                Just (Just (MonoCtor _ _)) ->
                    "arg-to-ctor"

                Just (Just (MonoDefine _ _)) ->
                    "arg-to-global"

                _ ->
                    "arg-to-other-spec"

        bump bucket acc =
            Dict.insert bucket (1 + Maybe.withDefault 0 (Dict.get bucket acc)) acc

        -- `here` = the bucket a closure at THIS position would land in.
        taxExpr : String -> MonoExpr -> Dict String Int -> Dict String Int
        taxExpr here expr acc =
            case expr of
                MonoClosure info body _ ->
                    let
                        acc1 =
                            bump here acc

                        acc2 =
                            List.foldl (\( _, ce, _ ) a -> taxExpr "captured" ce a) acc1 info.captures
                    in
                    taxExpr "value" body acc2

                MonoCall _ func args _ _ ->
                    let
                        argBucket =
                            case func of
                                MonoVarGlobal _ specId _ ->
                                    specKind specId

                                MonoVarKernel _ _ _ _ _ ->
                                    "arg-to-kernel"

                                _ ->
                                    "arg-to-local"

                        acc1 =
                            taxExpr "callee" func acc
                    in
                    List.foldl (taxExpr argBucket) acc1 args

                MonoLet def body _ ->
                    let
                        acc1 =
                            case def of
                                Mono.MonoDef _ bound ->
                                    taxExpr "let-bound" bound acc

                                Mono.MonoTailDef _ _ bound ->
                                    taxExpr "value" bound acc
                    in
                    taxExpr here body acc1

                MonoIf branches final _ ->
                    let
                        acc1 =
                            List.foldl (\( c, t ) a -> taxExpr "other" c (taxExpr here t a)) acc branches
                    in
                    taxExpr here final acc1

                MonoCase _ _ decider branches _ ->
                    let
                        acc1 =
                            taxDecider here decider acc
                    in
                    List.foldl (\( _, e ) a -> taxExpr here e a) acc1 branches

                MonoDestruct _ inner _ ->
                    taxExpr here inner acc

                MonoList _ items _ ->
                    List.foldl (taxExpr "stored-data") acc items

                MonoRecordCreate fields _ ->
                    List.foldl (\( _, e ) a -> taxExpr "stored-data" e a) acc fields

                MonoRecordUpdate inner updates _ ->
                    List.foldl (\( _, e ) a -> taxExpr "stored-data" e a) (taxExpr "other" inner acc) updates

                MonoTupleCreate _ items _ ->
                    List.foldl (taxExpr "stored-data") acc items

                MonoTailCall _ entries _ ->
                    List.foldl (\( _, e ) a -> taxExpr "tailcall-arg" e a) acc entries

                _ ->
                    acc

        taxDecider here decider acc =
            case decider of
                Mono.Leaf (Mono.Inline e) ->
                    taxExpr here e acc

                Mono.Leaf (Mono.Jump _) ->
                    acc

                Mono.Chain _ success failure ->
                    taxDecider here failure (taxDecider here success acc)

                Mono.FanOut _ tests fallback ->
                    taxDecider here fallback (List.foldl (\( _, d ) a -> taxDecider here d a) acc tests)

        taxNode node acc =
            case node of
                MonoDefine (MonoClosure _ body _) _ ->
                    taxExpr "value" body acc

                MonoDefine expr _ ->
                    taxExpr "value" expr acc

                MonoTailFunc _ expr _ ->
                    taxExpr "value" expr acc

                MonoPortIncoming expr _ ->
                    taxExpr "value" expr acc

                MonoPortOutgoing expr _ ->
                    taxExpr "value" expr acc

                _ ->
                    acc
    in
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just node ->
                    taxNode node acc

                Nothing ->
                    acc
        )
        Dict.empty
        nodes
        |> Dict.toList
        |> List.sortBy (\( _, n ) -> negate n)


{-| H6.2 U0 (`ECO_INLINE_REPORT=1`): census of FUNCTION-TYPED-RESULT specs
(`f : args -> (s -> r)` — the TypeCheck.IO monadic-bind shape) and how
their saturated call results are consumed. Decision input for U2b
result-arity raising: `applied` / `let-bound` sites are reachable by
intra-function rewrites alone; everything else (returned / stored /
passed on) needs the raised-worker ABI to collapse.

Buckets: `fnres-specs` (spec population), then per saturated call site
`fnres-applied` (callee position — result immediately applied),
`fnres-let-bound`, `fnres-arg` (passed to another call), `fnres-stored`
(data), `fnres-returned` (value position), `fnres-other`.

H6.2.5 Lever 2 refactor: the walk now tallies PER SPEC
(`fnResultSiteCensus`), because the arity-raise gate needs each spec's
applied share; the aggregate report derives from the per-spec census
unchanged.
-}
fnResultSiteCensus : Array (Maybe MonoNode) -> Dict Int (Dict String Int)
fnResultSiteCensus nodes =
    let
        fnResultSpecs : Dict Int Int
        fnResultSpecs =
            Array.foldl
                (\maybeNode ( acc, specId ) ->
                    case maybeNode of
                        Just (MonoDefine (MonoClosure info body _) _) ->
                            case Mono.typeOf body of
                                Mono.MFunction _ _ _ ->
                                    ( Dict.insert specId (List.length info.params) acc, specId + 1 )

                                _ ->
                                    ( acc, specId + 1 )

                        _ ->
                            ( acc, specId + 1 )
                )
                ( Dict.empty, 0 )
                nodes
                |> Tuple.first

        -- Every fn-result spec gets an entry (possibly empty) so the
        -- population size survives into the derived report.
        emptyCensus : Dict Int (Dict String Int)
        emptyCensus =
            Dict.map (\_ _ -> Dict.empty) fnResultSpecs

        bump specId bucket acc =
            Dict.update specId
                (Maybe.map
                    (\d -> Dict.insert bucket (1 + Maybe.withDefault 0 (Dict.get bucket d)) d)
                )
                acc

        siteBucket here =
            case here of
                "callee" ->
                    "fnres-applied"

                "let-bound" ->
                    "fnres-let-bound"

                "arg" ->
                    "fnres-arg"

                "stored" ->
                    "fnres-stored"

                "value" ->
                    "fnres-returned"

                _ ->
                    "fnres-other"

        cenExpr : String -> MonoExpr -> Dict Int (Dict String Int) -> Dict Int (Dict String Int)
        cenExpr here expr acc =
            case expr of
                MonoCall _ func args _ _ ->
                    let
                        acc1 =
                            case func of
                                MonoVarGlobal _ specId _ ->
                                    case Dict.get specId fnResultSpecs of
                                        Just nParams ->
                                            if List.length args == nParams then
                                                bump specId (siteBucket here) acc

                                            else
                                                acc

                                        Nothing ->
                                            acc

                                _ ->
                                    acc

                        acc2 =
                            cenExpr "callee" func acc1
                    in
                    List.foldl (cenExpr "arg") acc2 args

                MonoClosure _ body _ ->
                    cenExpr "value" body acc

                MonoLet def body _ ->
                    let
                        acc1 =
                            case def of
                                Mono.MonoDef _ bound ->
                                    cenExpr "let-bound" bound acc

                                Mono.MonoTailDef _ _ bound ->
                                    cenExpr "value" bound acc
                    in
                    cenExpr here body acc1

                MonoIf branches final _ ->
                    let
                        acc1 =
                            List.foldl (\( c, t ) a -> cenExpr "other" c (cenExpr here t a)) acc branches
                    in
                    cenExpr here final acc1

                MonoCase _ _ decider branches _ ->
                    let
                        acc1 =
                            cenDecider here decider acc
                    in
                    List.foldl (\( _, e ) a -> cenExpr here e a) acc1 branches

                MonoDestruct _ inner _ ->
                    cenExpr here inner acc

                MonoList _ items _ ->
                    List.foldl (cenExpr "stored") acc items

                MonoRecordCreate fields _ ->
                    List.foldl (\( _, e ) a -> cenExpr "stored" e a) acc fields

                MonoRecordUpdate inner updates _ ->
                    List.foldl (\( _, e ) a -> cenExpr "stored" e a) (cenExpr "other" inner acc) updates

                MonoTupleCreate _ items _ ->
                    List.foldl (cenExpr "stored") acc items

                MonoTailCall _ entries _ ->
                    List.foldl (\( _, e ) a -> cenExpr "arg" e a) acc entries

                _ ->
                    acc

        cenDecider here decider acc =
            case decider of
                Mono.Leaf (Mono.Inline e) ->
                    cenExpr here e acc

                Mono.Leaf (Mono.Jump _) ->
                    acc

                Mono.Chain _ success failure ->
                    cenDecider here failure (cenDecider here success acc)

                Mono.FanOut _ tests fallback ->
                    cenDecider here fallback (List.foldl (\( _, d ) a -> cenDecider here d a) acc tests)

        cenNode node acc =
            case node of
                MonoDefine (MonoClosure _ body _) _ ->
                    cenExpr "value" body acc

                MonoDefine expr _ ->
                    cenExpr "value" expr acc

                MonoTailFunc _ expr _ ->
                    cenExpr "value" expr acc

                _ ->
                    acc
    in
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just node ->
                    cenNode node acc

                Nothing ->
                    acc
        )
        emptyCensus
        nodes


{-| The aggregate U0 report, derived from the per-spec census (output
identical to the pre-H6.2.5 direct tally).
-}
functionResultCensus : MonoGraph -> List ( String, Int )
functionResultCensus (MonoGraph { nodes }) =
    let
        perSpec =
            fnResultSiteCensus nodes
    in
    Dict.foldl
        (\_ buckets acc ->
            Dict.foldl
                (\bucket n a -> Dict.insert bucket (n + Maybe.withDefault 0 (Dict.get bucket a)) a)
                acc
                buckets
        )
        (Dict.singleton "fnres-specs" (Dict.size perSpec))
        perSpec
        |> Dict.toList
        |> List.sortBy (\( _, n ) -> negate n)


{-| H6.2.5 Lever 2: does spec `specId`'s site profile justify raising?
`applied * 100 >= total * minPercent`, requiring at least one applied
site. Specs with NO observed saturated sites are refused under any
nonzero threshold (no evidence of a win; escapes-only specs only pay
the PAP-extend tax when raised). Callers bypass this entirely at
`minPercent <= 0` (raise-everything, the pre-Lever-2 behaviour).
-}
raiseAllowedBySites : Int -> Dict Int (Dict String Int) -> Int -> Bool
raiseAllowedBySites minPercent census specId =
    case Dict.get specId census of
        Nothing ->
            False

        Just buckets ->
            let
                applied =
                    Maybe.withDefault 0 (Dict.get "fnres-applied" buckets)

                total =
                    Dict.foldl (\_ n s -> s + n) 0 buckets
            in
            applied > 0 && applied * 100 >= total * minPercent


{-| H6.1 F3: arity of a global-bodied point-free alias, chasing at most
`fuel` links (alias-of-alias chains are short; cycles are cut by fuel).
Kernel-bodied links use the FLAT arity — the convention the emitted
wrapper spec and papCreate `arity` attr already use.
-}
aliasArity : Array (Maybe MonoNode) -> Int -> Int -> Maybe Int
aliasArity nodes fuel specId =
    if fuel <= 0 then
        Nothing

    else
        case Array.get specId nodes of
            Just (Just (MonoDefine (MonoClosure info _ _) _)) ->
                Just (List.length info.params)

            Just (Just (MonoTailFunc params _ _)) ->
                Just (List.length params)

            Just (Just (MonoDefine (MonoVarKernel _ _ _ _ kernelType) _)) ->
                let
                    n =
                        flatArrowArity kernelType
                in
                if n > 0 then
                    Just n

                else
                    Nothing

            Just (Just (MonoDefine (MonoVarGlobal _ target _) _)) ->
                aliasArity nodes (fuel - 1) target

            _ ->
                Nothing


{-| H6.2 U2b (`ECO_ARITY_RAISE=1`, default off): uncurry a staged spec —
`MonoDefine (MonoClosure [p…] body) : … -> (s… -> r)` becomes a FLAT
`MonoClosure [p… ++ s…]` — when its stage-1 work is trivial (body IS a
closure literal: the `andThen f ma = \s0 -> …` combinator shape) or cheap
(body is a call within the inline threshold: the `unify a b =
andThen … (…)` solver shape, wrapped as `MonoCall body svars` for the
merge arm to collapse).

Why this is the H6.2 lever: bind continuations escape because the state
application happens in the CALLER. Raising moves the application point
INTO each raised spec, where the existing merge / ForwardPartialCall /
inline+beta fixpoint collapses the chain. Existing call sites need no
rewrite: a saturated-at-old-arity call is simply a strictly-partial call
of the raised spec (a PAP — the same single allocation the closure cost
today), and `annotateCallStaging` re-derives all staging AFTER this pass.
The raised closure clears srcLambda/closureKind/captureAbi (LSS_009 — the
reshaped closure must not impersonate its source member). The hand-eta'd
`TypeCheck.IO.map`/`foldrM` prove the raised shape is fully supported
downstream — this pass mechanizes that source idiom.

Semantics note (why default-off): delaying a cheap PURE stage-1 body to
application time is unobservable in Elm except for ⊥ timing (crash moves
to first application) and `Debug.log` ordering.
-}
raiseStagedSpecs : Config.InlineConfig -> (Int -> Bool) -> Array (Maybe MonoNode) -> ( Array (Maybe MonoNode), ( Int, Int ) )
raiseStagedSpecs inlineConfig allowSpec nodes =
    Array.foldl
        (\maybeNode ( acc, specId, ( nRaised, nSkipped ) ) ->
            case maybeNode of
                Just (MonoDefine (MonoClosure info body cty) defTy) ->
                    case raiseOne inlineConfig specId info body cty defTy of
                        Just raised ->
                            -- H6.2.5 Lever 2: the spec QUALIFIES structurally;
                            -- the applied-share predicate decides whether its
                            -- site profile pays for raising. Refused specs
                            -- stay staged (identical to flag-off treatment).
                            if allowSpec specId then
                                ( Array.push (Just raised) acc, specId + 1, ( nRaised + 1, nSkipped ) )

                            else
                                ( Array.push maybeNode acc, specId + 1, ( nRaised, nSkipped + 1 ) )

                        Nothing ->
                            ( Array.push maybeNode acc, specId + 1, ( nRaised, nSkipped ) )

                _ ->
                    ( Array.push maybeNode acc, specId + 1, ( nRaised, nSkipped ) )
        )
        ( Array.empty, 0, ( 0, 0 ) )
        nodes
        |> (\( acc, _, counters ) -> ( acc, counters ))


raiseOne : Config.InlineConfig -> Int -> Mono.ClosureInfo -> MonoExpr -> Mono.MonoType -> Mono.MonoType -> Maybe MonoNode
raiseOne inlineConfig specId info body cty defTy =
    case ( flattenArrowOnce cty, flattenArrowOnce defTy ) of
        ( Just ctyFlat, Just defTyFlat ) ->
            case body of
                MonoClosure innerInfo innerBody _ ->
                    -- Combinator shape: splice the inner body directly. The
                    -- inner params are already distinct from the outer ones
                    -- (same source function — Elm forbids shadowing), so no
                    -- freshening is needed.
                    Just
                        (MonoDefine
                            (MonoClosure
                                { info
                                    | params = info.params ++ innerInfo.params
                                    , srcLambda = Nothing
                                    , lssMember = Nothing
                                    , closureKind = Nothing
                                    , captureAbi = Nothing
                                }
                                innerBody
                                ctyFlat
                            )
                            defTyFlat
                        )

                MonoCall _ (MonoVarLocal _ _) _ _ _ ->
                    -- Param-callee bodies (`apR x f = f x`): raising these is
                    -- a strict LOSS. Pre-raise they inline at every saturated
                    -- site and the pipe collapses to a single partial of the
                    -- real callee; raised, the old-arity call becomes a PAP
                    -- that wraps ANOTHER layer around the value, and every
                    -- escaping pipe pays 2-4 allocations instead of 1
                    -- (measured: raised apR wrappers carried 20.6M runtime
                    -- extends on the self-compile census). Callers THROUGH
                    -- such combinators still collapse: the unraised tiny spec
                    -- inlines during the fixpoint and the merge arm proceeds.
                    Nothing

                MonoCall region _ _ _ _ ->
                    -- Call shape: apply the old body to fresh stage-2 params.
                    -- The nested application is exactly what the merge arm
                    -- collapses in the fixpoint. Deliberately NOT
                    -- cost-bounded: bind-chain bodies carry closure-literal
                    -- args (cost 5+body each), so any real chain blows a
                    -- static bound — yet that construction work is exactly
                    -- what collapses once the chain merges. The residual risk
                    -- (an ESCAPING multi-applied staged value re-runs its
                    -- cheap pure stage-1 per application) is the experiment
                    -- this flag exists to measure.
                    case Mono.typeOf body of
                        Mono.MFunction _ stageTys retTy ->
                            let
                                freshParams =
                                    List.indexedMap
                                        (\i ty -> ( "_h62ar" ++ String.fromInt specId ++ "_" ++ String.fromInt i, ty ))
                                        stageTys

                                argRefs =
                                    List.map (\( n, ty ) -> MonoVarLocal n ty) freshParams
                            in
                            Just
                                (MonoDefine
                                    (MonoClosure
                                        { info
                                            | params = info.params ++ freshParams
                                            , srcLambda = Nothing
                                            , lssMember = Nothing
                                            , closureKind = Nothing
                                            , captureAbi = Nothing
                                        }
                                        (MonoCall region body argRefs retTy Mono.defaultCallInfo)
                                        ctyFlat
                                    )
                                    defTyFlat
                                )

                        _ ->
                            Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


{-| H6.2 U2b: flatten one stage boundary of an arrow type. The inner
stage's lambda-set annotation is dropped — the raised closure is a new
shape with no source member to claim (annotation soundness over
precision).
-}
flattenArrowOnce : Mono.MonoType -> Maybe Mono.MonoType
flattenArrowOnce ty =
    case ty of
        Mono.MFunction anno stage1 (Mono.MFunction _ stage2 ret) ->
            Just (Mono.MFunction anno (stage1 ++ stage2) ret)

        _ ->
            Nothing


{-| Optimize a MonoGraph by inlining small functions and simplifying expressions.
-}
optimize : Config.InlineConfig -> MonoGraph -> ( MonoGraph, Metrics )
optimize inlineConfig graph =
    let
        (MonoGraph { nodes, main, registry, ctorShapes, nextLambdaIndex, callEdges, ports, flagsDecoder, lssMemberOrigins }) =
            graph

        ( raisedNodes, raiseCounters ) =
            if inlineConfig.arityRaise then
                let
                    -- H6.2.5 Lever 2: gate raising on the per-spec applied
                    -- share. The site census walk is skipped entirely at
                    -- threshold 0 (raise-everything, zero added cost).
                    allowSpec =
                        if inlineConfig.raiseAppliedShareMin <= 0 then
                            \_ -> True

                        else
                            raiseAllowedBySites inlineConfig.raiseAppliedShareMin
                                (fnResultSiteCensus nodes)
                in
                raiseStagedSpecs inlineConfig allowSpec nodes

            else
                ( nodes, ( 0, 0 ) )

        rNodes =
            if inlineConfig.arityRaise then
                -- Raising erases inner lambdas whose lambda-set annotations
                -- still live on USE-site types (loadType-minted arrows) —
                -- AbiCloning would stamp fast dispatch for members that no
                -- longer exist and the runtime would misread the actual PAP
                -- (found live: RaiseProbe returned garbage via a stale
                -- `_capture_abi` stamp). Widen every anno to LTop flag-on:
                -- annotation soundness over dispatch precision.
                Array.map
                    (Maybe.map (Traverse.mapNodeTypes Mono.widenSets))
                    raisedNodes

            else
                raisedNodes

        callGraph =
            buildCallGraph rNodes callEdges

        ctx =
            initRewriteCtx inlineConfig rNodes registry callGraph nextLambdaIndex

        -- Convert nodes to a list so the Array can be GC'd during the fold.
        -- List.foldl releases consumed cons cells, enabling incremental GC
        -- of the input graph while building the output graph.
        nodesList =
            Array.toList rNodes
    in
    -- Call a separate function so `nodes` (Array) goes out of scope
    -- and becomes GC-eligible. Only `nodesList` is passed forward (the
    -- raise counters are plain Ints — no graph state retained).
    optimizeNodes nodesList ctx main registry ctorShapes ports flagsDecoder lssMemberOrigins
        |> Tuple.mapSecond
            (\m ->
                { m
                    | arityRaised = Tuple.first raiseCounters
                    , arityRaiseSkipped = Tuple.second raiseCounters
                }
            )


optimizeNodes :
    List (Maybe MonoNode)
    -> RewriteCtx
    -> Maybe Mono.MainInfo
    -> Mono.SpecializationRegistry
    -> Dict String (List Mono.CtorShape)
    -> List Mono.PortRegistration
    -> Maybe Mono.SpecId
    -> Dict Int Mono.MemberOrigin
    -> ( MonoGraph, Metrics )
optimizeNodes nodesList ctx main registry ctorShapes ports flagsDecoder lssMemberOrigins =
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
        , lssMemberOrigins = lssMemberOrigins
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
    -- may inline at EXACT application only. This is permanent by design, not
    -- a temporary containment (H2.5 step 2): partially inlining a GLOBAL
    -- replaces its PAP value with a genuinely re-arited closure, and callers
    -- compiled against the global's curried TYPE may over-apply it — the
    -- runtime typed-apply cannot chain over-application of a real closure
    -- (spliceArgsForSaturatedCall assert; CombinatorB* corpus pins).
    -- Partials of globals stay PAPs per mono-uncurry's design principle;
    -- application MERGING collapses the profitable single-use shapes.
    -- Legacy and whitelisted candidates keep full pre-H2 privileges.
    { inlineCandidates : Dict Int ( List ( Name, Mono.MonoType ), MonoExpr, Bool )
    , specArities : Dict Int Int -- H2.5: param count per spec (incl. recursive), for application merging
    , loopifiables : Dict Int LoopifyInfo -- H5: tail-func specs whose closure param can be loopified
    , loopifyEnabled : Bool
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
    , partialMerges : Int
    , hofLoopified : Int
    , loopifiable : Int
    , letEliminations : Int
    , closureDCE : Int
    , arityRaised : Int
    , arityRaiseSkipped : Int
    , inlinedByCallee : Dict String Int
    }


bumpHofLoopified : RewriteCtx -> RewriteCtx
bumpHofLoopified ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | hofLoopified = m.hofLoopified + 1 } }


bumpPartialMerges : RewriteCtx -> RewriteCtx
bumpPartialMerges ctx =
    let
        m =
            ctx.metrics
    in
    { ctx | metrics = { m | partialMerges = m.partialMerges + 1 } }


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


-- ============================================================================
-- ====== RECURSIVE-HOF LOOPIFICATION (H5) ======
-- ============================================================================


{-| A tail-recursive spec eligible for call-site loopification (plan H5):
`params`/`body` are the spec's own, `flatParams` maps a function-typed
parameter's index to its (uncurried) arity for every parameter that the
body consumes ONLY as (a) exactly one saturated callee-position call plus
(b) verbatim self-tail-call threading.

At a saturated call site passing a lambda LITERAL at such an index, the
call is rewritten to a local specialized loop (`MonoTailDef`) with the
parameter eliminated: the literal replaces the callee of the single
internal call (the existing beta arm reduces it on the next fixpoint
iteration — captures are substituted to their caller-scope variables
first), and self tail calls retarget the local loop with the flattened
entry dropped. The lambda's papCreate disappears at this level; the local
loop's own closure shell (a zero-self-capture papCreate with one saturated
use — verified: pure tail recursion does not self-capture) is elided
downstream by EcoPAPSimplify P1. Design note: this deliberately replaces
the plan's original LSS-keyed spec-cloning formulation — the call-site
literal makes the member identity self-evident, so v1 needs neither the
solver engine nor keyed fan-out; variable-argument callers remain the
LSS-based v2 extension.
-}
type alias LoopifyInfo =
    { params : List ( Name, Mono.MonoType )
    , body : MonoExpr
    , flatParams : Dict Int Int
    }


buildLoopifiables : Config.InlineConfig -> Array (Maybe MonoNode) -> Dict Int LoopifyInfo
buildLoopifiables inlineConfig nodes =
    if not inlineConfig.loopify then
        Dict.empty

    else
        let
            -- Loopification copies the spec body per call site, like
            -- inlining but for recursive HOFs; give it double the HOF
            -- budget (List.foldl/map-class bodies land in the 15–30 range).
            budget =
                2 * max inlineConfig.threshold inlineConfig.hofThreshold
        in
        Array.foldl
            (\maybeNode ( acc, specId ) ->
                case maybeNode of
                    Just (MonoTailFunc params body _) ->
                        if computeCost body > budget || referencesSpec specId body then
                            ( acc, specId + 1 )

                        else
                            let
                                flatParams =
                                    params
                                        |> List.indexedMap Tuple.pair
                                        |> List.filterMap
                                            (\( i, ( pName, pType ) ) ->
                                                case pType of
                                                    Mono.MFunction _ _ _ ->
                                                        let
                                                            arity =
                                                                flatArrowArity pType
                                                        in
                                                        if paramLoopifiable pName arity body then
                                                            Just ( i, arity )

                                                        else
                                                            Nothing

                                                    _ ->
                                                        Nothing
                                            )
                                        |> Dict.fromList
                            in
                            if Dict.isEmpty flatParams then
                                ( acc, specId + 1 )

                            else
                                ( Dict.insert specId (LoopifyInfo params body flatParams) acc, specId + 1 )

                    _ ->
                        ( acc, specId + 1 )
            )
            ( Dict.empty, 0 )
            nodes
            |> Tuple.first


{-| Fully-peeled arrow arity: mono param types keep STAGE structure
(`MFunction [a] (MFunction [b] r)` for a two-stage function), while
internal call sites of a function-typed param apply all stages flat — the
loopify arity must be the peeled total (the staged-currying twin of
Specialize.peelCallResult).
-}
flatArrowArity : Mono.MonoType -> Int
flatArrowArity t =
    case t of
        Mono.MFunction _ argTys ret ->
            List.length argTys + flatArrowArity ret

        _ ->
            0


{-| Any reference to the given spec (a non-tail self-call would make the
copied body re-enter the ORIGINAL function).
-}
referencesSpec : Int -> MonoExpr -> Bool
referencesSpec specId body =
    Traverse.foldExpr
        (\e acc ->
            acc
                || (case e of
                        MonoVarGlobal _ sid _ ->
                            sid == specId

                        _ ->
                            False
                   )
        )
        False
        body


{-| Is param `p` (a function of `arity` args) consumed ONLY as one saturated
callee-position call plus verbatim tail-threading? Uses an accounting
identity over `countUsages` so no context-carrying walk is needed:

  - any use inside a nested closure or inner tail-def bound would inflate
    `usesInsideClosures` / `usesInsideInnerTailDefs` (over-counting for
    nested nesting is fine — the requirement is zero);
  - a use in a call's ARGUMENTS, a case scrutinee, storage, etc. would make
    `totalUses > calleeSites + threadEntries`;
  - rebinding anywhere disqualifies outright (count semantics get murky).

-}
paramLoopifiable : Name -> Int -> MonoExpr -> Bool
paramLoopifiable p arity body =
    let
        totalUses =
            countUsages p body

        rebinds =
            Traverse.foldExpr
                (\e acc ->
                    acc
                        || (case e of
                                MonoLet def _ _ ->
                                    getDefName def
                                        == p
                                        || (case def of
                                                Mono.MonoTailDef _ ps _ ->
                                                    List.any (\( n, _ ) -> n == p) ps

                                                _ ->
                                                    False
                                           )

                                MonoClosure info _ _ ->
                                    List.any (\( n, _ ) -> n == p) info.params

                                MonoDestruct (Mono.MonoDestructor dn _ _) _ _ ->
                                    dn == p

                                _ ->
                                    False
                           )
                )
                False
                body

        usesInsideClosures =
            Traverse.foldExpr
                (\e acc ->
                    case e of
                        MonoClosure info b _ ->
                            acc
                                + List.foldl (\( _, ce, _ ) n -> n + countUsages p ce) 0 info.captures
                                + countUsages p b

                        _ ->
                            acc
                )
                0
                body

        usesInsideInnerTailDefs =
            Traverse.foldExpr
                (\e acc ->
                    case e of
                        MonoLet (Mono.MonoTailDef _ _ b) _ _ ->
                            acc + countUsages p b

                        _ ->
                            acc
                )
                0
                body

        calleeSites =
            Traverse.foldExpr
                (\e acc ->
                    case e of
                        MonoCall _ (MonoVarLocal n _) args _ _ ->
                            if n == p && List.length args == arity then
                                acc + 1

                            else
                                acc

                        _ ->
                            acc
                )
                0
                body

        threadEntries =
            Traverse.foldExpr
                (\e acc ->
                    case e of
                        MonoTailCall _ entries _ ->
                            acc
                                + List.length
                                    (List.filter
                                        (\( an, ae ) ->
                                            an
                                                == p
                                                && (case ae of
                                                        MonoVarLocal n _ ->
                                                            n == p

                                                        _ ->
                                                            False
                                                   )
                                        )
                                        entries
                                    )

                        _ ->
                            acc
                )
                0
                body
    in
    not rebinds
        && usesInsideClosures
        == 0
        && usesInsideInnerTailDefs
        == 0
        && calleeSites
        == 1
        && totalUses
        == calleeSites
        + threadEntries


{-| Attempt loopification of a saturated call to a loopifiable spec. The
budget shares `inlineCountThisFunction` (loopification IS a form of
inlining for code-growth purposes).
-}
tryLoopify : RewriteCtx -> Region -> Int -> List MonoExpr -> Mono.MonoType -> Maybe ( MonoExpr, RewriteCtx )
tryLoopify ctx region specId args resultType =
    if not ctx.loopifyEnabled || ctx.inlineCountThisFunction >= ctx.maxInlinesPerFunction then
        Nothing

    else
        case Dict.get specId ctx.loopifiables of
            Nothing ->
                Nothing

            Just info ->
                if List.length args /= List.length info.params then
                    Nothing

                else
                    let
                        qualifying =
                            args
                                |> List.indexedMap Tuple.pair
                                |> List.filterMap
                                    (\( i, arg ) ->
                                        case ( Dict.get i info.flatParams, arg ) of
                                            ( Just lamArity, MonoClosure cinfo cbody ctype ) ->
                                                if
                                                    List.length cinfo.params
                                                        == lamArity
                                                        && List.all
                                                            (\( _, ce, _ ) ->
                                                                case ce of
                                                                    MonoVarLocal _ _ ->
                                                                        True

                                                                    _ ->
                                                                        False
                                                            )
                                                            cinfo.captures
                                                then
                                                    Just ( i, MonoClosure cinfo cbody ctype )

                                                else
                                                    Nothing

                                            _ ->
                                                Nothing
                                    )
                    in
                    if List.isEmpty qualifying then
                        Nothing

                    else
                        Just (loopifyCall ctx region info qualifying args resultType)


loopifyCall : RewriteCtx -> Region -> LoopifyInfo -> List ( Int, MonoExpr ) -> List MonoExpr -> Mono.MonoType -> ( MonoExpr, RewriteCtx )
loopifyCall ctx region info qualifying args resultType =
    let
        qualifyingIdxs =
            List.map Tuple.first qualifying

        ( sF, ctx1 ) =
            freshVar ctx

        -- Fresh names for EVERY spec param (the copied body enters caller
        -- scope; source names could collide with caller locals).
        ( renamesRev, ctx2 ) =
            List.foldl
                (\( old, _ ) ( acc, c ) ->
                    let
                        ( fresh, c1 ) =
                            freshVar c
                    in
                    ( ( old, fresh ) :: acc, c1 )
                )
                ( [], ctx1 )
                info.params

        renames =
            List.reverse renamesRev

        renameOf old =
            List.filterMap
                (\( o, n ) ->
                    if o == old then
                        Just n

                    else
                        Nothing
                )
                renames
                |> List.head
                |> Maybe.withDefault old

        -- The lambda that replaces the flattened param's single call site:
        -- every capture is re-bound to an INLINER-FRESH name in a prelude
        -- let OUTSIDE the loop, and the capture references substitute to
        -- that fresh name. Substituting to the caller variable DIRECTLY is
        -- unsound: the copied spec body's own binders come from a different
        -- source function and may collide (List.member's capture `x` vs
        -- List.any's destructured head `x` — the loop would rebind the
        -- capture to the element; EqualityBoolListMemberTest is the pin).
        -- Fresh names cannot collide with anything. The prelude lets also
        -- make the values free variables of the loop body, so the lifted
        -- loop closure captures them exactly like the lambda used to.
        ( lambdaPairs, preludeRev, ctxCaps ) =
            List.foldl
                (\( i, lamExpr ) ( accPairs, accPrelude, c ) ->
                    case lamExpr of
                        MonoClosure cinfo cbody ctype ->
                            let
                                ( cbody1, accPrelude1, c1 ) =
                                    List.foldl
                                        (\( capName, capExpr, _ ) ( e, pre, cc ) ->
                                            case capExpr of
                                                MonoVarLocal _ vt ->
                                                    let
                                                        ( freshCap, cc1 ) =
                                                            freshVar cc
                                                    in
                                                    ( substitute capName freshCap vt e
                                                    , ( freshCap, capExpr ) :: pre
                                                    , cc1
                                                    )

                                                _ ->
                                                    ( e, pre, cc )
                                        )
                                        ( cbody, accPrelude, c )
                                        cinfo.captures
                            in
                            ( ( i, MonoClosure { cinfo | captures = [] } cbody1 ctype ) :: accPairs
                            , accPrelude1
                            , c1
                            )

                        _ ->
                            ( ( i, lamExpr ) :: accPairs, accPrelude, c )
                )
                ( [], [], ctx2 )
                qualifying

        lambdasByOldName =
            lambdaPairs
                |> List.filterMap
                    (\( i, lam ) ->
                        info.params
                            |> List.indexedMap Tuple.pair
                            |> List.filterMap
                                (\( j, ( pn, _ ) ) ->
                                    if j == i then
                                        Just pn

                                    else
                                        Nothing
                                )
                            |> List.head
                            |> Maybe.map (\pn -> ( renameOf pn, lam ))
                    )
                |> Dict.fromList

        flatOldNames =
            info.params
                |> List.indexedMap Tuple.pair
                |> List.filterMap
                    (\( j, ( pn, _ ) ) ->
                        if List.member j qualifyingIdxs then
                            Just pn

                        else
                            Nothing
                    )

        -- Copy the spec body: fresh lambda ids, fresh internal lets, then
        -- rename every param reference (VarLocals only — tail-call entry
        -- keys and callee retargeting happen in loopifyBody).
        ( bodyA, ctx3 ) =
            remapLambdaIds ctxCaps info.body

        ( bodyB, ctx4 ) =
            freshenLetBoundNames ctx3 bodyA

        bodyC =
            List.foldl
                (\( ( old, pt ), ( _, fresh ) ) e -> substitute old fresh pt e)
                bodyB
                (List.map2 Tuple.pair info.params renames)

        bodyD =
            loopifyBody sF renames flatOldNames lambdasByOldName [] bodyC

        newParams =
            info.params
                |> List.indexedMap Tuple.pair
                |> List.filterMap
                    (\( j, ( pn, pt ) ) ->
                        if List.member j qualifyingIdxs then
                            Nothing

                        else
                            Just ( renameOf pn, pt )
                    )

        remainingArgs =
            args
                |> List.indexedMap Tuple.pair
                |> List.filterMap
                    (\( j, a ) ->
                        if List.member j qualifyingIdxs then
                            Nothing

                        else
                            Just a
                    )

        loopFnType =
            Mono.MFunction Mono.LTop (List.map Tuple.second newParams) resultType

        invocation =
            MonoCall region (MonoVarLocal sF loopFnType) remainingArgs resultType Mono.defaultCallInfo

        result =
            List.foldl
                (\( freshCap, capExpr ) acc ->
                    MonoLet (Mono.MonoDef freshCap capExpr) acc resultType
                )
                (MonoLet (Mono.MonoTailDef sF newParams bodyD) invocation resultType)
                preludeRev

        ctx5 =
            bumpHofLoopified { ctx4 | inlineCountThisFunction = ctx4.inlineCountThisFunction + 1 }
    in
    ( result, ctx5 )


{-| The loopification body walk: retarget self tail calls to the local loop
(renaming entry keys to the fresh param names and dropping the flattened
entries), and replace the flattened params' single callee-position uses
with their lambda literals. Inner tail defs keep their own tail calls (any
callee in `innerNames` is left alone); closures are not descended into —
the eligibility analysis proved the flattened params do not occur there,
and their contents are otherwise untouched copies.
-}
loopifyBody : Name -> List ( Name, Name ) -> List Name -> Dict Name MonoExpr -> List Name -> MonoExpr -> MonoExpr
loopifyBody sF renames flatOldNames lambdas innerNames expr =
    let
        go =
            loopifyBody sF renames flatOldNames lambdas innerNames

        renameOf old =
            List.filterMap
                (\( o, n ) ->
                    if o == old then
                        Just n

                    else
                        Nothing
                )
                renames
                |> List.head
                |> Maybe.withDefault old
    in
    case expr of
        MonoTailCall callee entries t ->
            if List.member callee innerNames then
                MonoTailCall callee (List.map (\( an, ae ) -> ( an, go ae )) entries) t

            else
                MonoTailCall sF
                    (entries
                        |> List.filterMap
                            (\( an, ae ) ->
                                if List.member an flatOldNames then
                                    Nothing

                                else
                                    Just ( renameOf an, go ae )
                            )
                    )
                    t

        MonoCall r ((MonoVarLocal n nt) as callee) cargs t ci ->
            case Dict.get n lambdas of
                Just lam ->
                    MonoCall r lam (List.map go cargs) t ci

                Nothing ->
                    MonoCall r callee (List.map go cargs) t ci

        MonoCall r f cargs t ci ->
            MonoCall r (go f) (List.map go cargs) t ci

        MonoClosure _ _ _ ->
            expr

        MonoLet ((Mono.MonoTailDef tn tps tb) as d) b t ->
            let
                inner1 =
                    tn :: innerNames
            in
            MonoLet (Mono.MonoTailDef tn tps (loopifyBody sF renames flatOldNames lambdas inner1 tb))
                (loopifyBody sF renames flatOldNames lambdas inner1 b)
                t

        MonoLet (Mono.MonoDef dn db) b t ->
            MonoLet (Mono.MonoDef dn (go db)) (go b) t

        MonoIf branches final t ->
            MonoIf (List.map (\( c, th ) -> ( go c, go th )) branches) (go final) t

        MonoDestruct d inner t ->
            MonoDestruct d (go inner) t

        MonoCase s r0 decider branches t ->
            MonoCase s r0 (loopifyDecider sF renames flatOldNames lambdas innerNames decider) (List.map (\( i, e ) -> ( i, go e )) branches) t

        MonoList r items t ->
            MonoList r (List.map go items) t

        MonoRecordCreate fields t ->
            MonoRecordCreate (List.map (\( n, e ) -> ( n, go e )) fields) t

        MonoRecordAccess inner f t ->
            MonoRecordAccess (go inner) f t

        MonoRecordUpdate inner updates t ->
            MonoRecordUpdate (go inner) (List.map (\( n, e ) -> ( n, go e )) updates) t

        MonoTupleCreate r items t ->
            MonoTupleCreate r (List.map go items) t

        MonoLiteral _ _ ->
            expr

        MonoVarLocal _ _ ->
            expr

        MonoVarGlobal _ _ _ ->
            expr

        MonoVarKernel _ _ _ _ _ ->
            expr

        MonoUnit ->
            expr

        MonoAccessorValue _ _ _ ->
            expr


loopifyDecider : Name -> List ( Name, Name ) -> List Name -> Dict Name MonoExpr -> List Name -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
loopifyDecider sF renames flatOldNames lambdas innerNames decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            Mono.Leaf (Mono.Inline (loopifyBody sF renames flatOldNames lambdas innerNames e))

        Mono.Leaf (Mono.Jump _) ->
            decider

        Mono.Chain tests success failure ->
            Mono.Chain tests
                (loopifyDecider sF renames flatOldNames lambdas innerNames success)
                (loopifyDecider sF renames flatOldNames lambdas innerNames failure)

        Mono.FanOut path tests fallback ->
            Mono.FanOut path
                (List.map (\( k, d ) -> ( k, loopifyDecider sF renames flatOldNames lambdas innerNames d )) tests)
                (loopifyDecider sF renames flatOldNames lambdas innerNames fallback)


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
        specArities =
            Array.foldl
                (\maybeNode ( acc, specId ) ->
                    case maybeNode of
                        Just (MonoDefine (MonoClosure info _ _) _) ->
                            ( Dict.insert specId (List.length info.params) acc, specId + 1 )

                        Just (MonoTailFunc params _ _) ->
                            ( Dict.insert specId (List.length params) acc, specId + 1 )

                        -- H6.1 F3: point-free specs. A kernel alias
                        -- (`and = Elm.Kernel.Bitwise.and`) or a global alias
                        -- (`userAnd = Bitwise.and`) has no closure literal, so
                        -- the closure/tailfunc arms above never record it and
                        -- `<|`-styled partials of it can never merge — the
                        -- Array.setHelp papCreate+extend+extend chains of the
                        -- H6.0 census. Kernel-bodied: the annotation's first
                        -- stage is the kernel's real parameter list (deeper
                        -- stages are the kernel's own business — never merged
                        -- past stage one). Global-bodied: chase the alias,
                        -- bounded.
                        Just (MonoDefine (MonoVarKernel _ _ _ _ kernelType) _) ->
                            let
                                n =
                                    flatArrowArity kernelType
                            in
                            if n > 0 then
                                ( Dict.insert specId n acc, specId + 1 )

                            else
                                ( acc, specId + 1 )

                        Just (MonoDefine (MonoVarGlobal _ target _) _) ->
                            case aliasArity nodes 4 target of
                                Just n ->
                                    ( Dict.insert specId n acc, specId + 1 )

                                Nothing ->
                                    ( acc, specId + 1 )

                        _ ->
                            ( acc, specId + 1 )
                )
                ( Dict.empty, 0 )
                nodes
                |> Tuple.first

        loopifiables =
            buildLoopifiables inlineConfig nodes
    in
    { inlineCandidates = candidates
    , specArities = specArities
    , loopifiables = loopifiables
    , loopifyEnabled = inlineConfig.loopify
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
        , partialMerges = 0
        , hofLoopified = 0
        , loopifiable = Dict.size loopifiables
        , letEliminations = 0
        , closureDCE = 0

        -- Overwritten by `optimize` from the raise pre-pass counters.
        , arityRaised = 0
        , arityRaiseSkipped = 0
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
            -- Recursive-HOF loopification (H5) first: recursive specs are
            -- never inline candidates, so there is no overlap with
            -- tryInlineCall. The loopified expression is returned as-is;
            -- the fixpoint's next iteration beta-reduces the inlined lambda
            -- literal and continues normal rewriting inside the loop.
            case tryLoopify ctx region specId args resultType of
                Just ( loopified, ctxL ) ->
                    ( loopified, ctxL )

                Nothing ->
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

        -- Application merging (H2.5 step 1): `(f a1s) a2s` ⇒ `f (a1s ++ a2s)`
        -- when f's arity is statically known and the total does not exceed
        -- it. A partial inner application only creates a PAP (no body runs),
        -- so merging preserves evaluation order exactly; the merged
        -- saturated call then takes the EXACT inline path — no residual
        -- closure, no partial rebuild. Over-application totals are refused:
        -- there the inner call executes the body, and merging would change
        -- the call's shape into runtime over-application.
        MonoCall region ((MonoCall _ innerFunc innerArgs _ _) as innerCall) outerArgs resultType callInfo ->
            let
                mergeable =
                    case calleeArity ctx innerFunc of
                        Just arity ->
                            List.length innerArgs + List.length outerArgs <= arity

                        Nothing ->
                            False
            in
            if mergeable then
                rewriteExpr (bumpPartialMerges ctx)
                    (MonoCall region innerFunc (innerArgs ++ outerArgs) resultType Mono.defaultCallInfo)

            else
                let
                    ( rewrittenFunc, ctx1 ) =
                        rewriteExpr ctx innerCall

                    ( rewrittenArgs, ctx2 ) =
                        rewriteExprs ctx1 outerArgs
                in
                ( MonoCall region rewrittenFunc rewrittenArgs resultType callInfo, ctx2 )

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
                residualClosureType remainingParams resultType

            -- Recompute captures for the new closure body.
            -- The substitution may have introduced new free variables (the fresh names
            -- bound in the surrounding lets) that need to be captured.
            newCaptures =
                Closure.computeClosureCaptures remainingParams substituted

            newInfo =
                -- The residual is a NEW function, not a verbatim copy of the
                -- source lambda: params and capture layout differ. Claiming
                -- the source's srcLambda would let AbiCloning treat it as an
                -- interchangeable instance of the member (LSS_009
                -- impersonation); clear the identity like tryInlineCall's
                -- partial branch does. closureKind/captureAbi are stale for
                -- the new capture set for the same reason (normally still
                -- unset at inline time — AbiCloning runs later — but don't
                -- rely on that).
                { info
                    | params = remainingParams
                    , captures = newCaptures
                    , srcLambda = Nothing
                    , lssMember = Nothing
                    , closureKind = Nothing
                    , captureAbi = Nothing
                }
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


{-| H2.5 step 2: the type of the residual closure a partial-application
rebuild produces.

`peelCallResult` (Specialize.elm) already types a partial call node as the
PEELED arrow — `MFunction anno remainingTypes result` — so the residual
closure's type IS the call's result type, verbatim. The old construction
wrapped it AGAIN (`MFunction LTop remTypes resultType` where resultType was
itself the residual arrow), declaring a phantom extra application level:
result-kind, staging, and arity metadata downstream all read the
double-wrapped arrow, which is the root of the CGEN_056 result-type
mismatches and the runtime `spliceArgsForSaturatedCall` arity assert
(plan H2.5, lesson 4).

The shape check is defensive: if some producer typed the call differently
(non-arrow, or an arrow whose param count disagrees with the actual
remaining params), fall back to the legacy construction — no worse than the
historical behavior, and the guards that contain the legacy path remain.
-}
residualClosureType : List ( Name, Mono.MonoType ) -> Mono.MonoType -> Mono.MonoType
residualClosureType remainingParams resultType =
    case resultType of
        Mono.MFunction _ paramTypes _ ->
            if List.length paramTypes == List.length remainingParams then
                resultType

            else
                Mono.MFunction Mono.LTop (List.map Tuple.second remainingParams) resultType

        _ ->
            Mono.MFunction Mono.LTop (List.map Tuple.second remainingParams) resultType


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
-- ====== LET-CALLEE FORWARDING (H1.1 / H2.5) ======
-- ============================================================================


{-| What a forwardable let binding carries to its single callee-position use:

  - `ForwardClosure`: a closure literal — beta-reduced at the use
    (saturated, ground-result uses only).
  - `ForwardPartialCall`: a strictly-partial application of a known global —
    merged with the use's arguments into one ordinary call (total ≤ arity),
    so no residual closure is ever rebuilt (H2.5 step 1c).

-}
type ForwardPayload
    = ForwardClosure Mono.ClosureInfo MonoExpr
    | ForwardPartialCall MonoExpr (List MonoExpr) Int


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

                        -- Shared eligibility: no self-reference in the bound
                        -- expr, no earlier-sibling references, exactly one
                        -- use across later siblings + final body. On a hit,
                        -- rebuild the tail (later defs + final body) as one
                        -- expression so forwardGo can reach a use in either
                        -- place, then split it back.
                        attempt name boundExpr payload bumper =
                            if
                                countUsages name boundExpr
                                    == 0
                                    && usesInDefsOf name beforeRev
                                    == 0
                                    && (usesInDefsOf name rest + countUsages name fb)
                                    == 1
                            then
                                let
                                    tailExpr =
                                        List.foldr (\( d2, t2 ) acc -> MonoLet d2 acc t2) fb rest
                                in
                                case forwardGo c name payload tailExpr of
                                    Just ( tail1, c1 ) ->
                                        let
                                            ( rest1, fb1 ) =
                                                splitSpine tail1 []
                                        in
                                        Just ( List.reverse beforeRev ++ rest1, fb1, bumper c1 )

                                    Nothing ->
                                        skip ()

                            else
                                skip ()
                    in
                    case d of
                        Mono.MonoDef name ((MonoClosure cinfo cbody _) as closureExpr) ->
                            attempt name closureExpr (ForwardClosure cinfo cbody) bumpBetaForwards

                        Mono.MonoDef name ((MonoCall _ ((MonoVarGlobal _ _ _) as funcExpr) boundArgs _ _) as boundCall) ->
                            -- H2.5 step 1c: a STRICTLY-PARTIAL application of
                            -- a known global (binding evaluation only creates
                            -- a PAP, no body runs) with pure, relocatable
                            -- args. The pipe shape `m |> andThen λ` leaves
                            -- exactly this binding behind after apR inlining.
                            case calleeArity c funcExpr of
                                Just arity ->
                                    if
                                        List.length boundArgs
                                            < arity
                                            && List.all isPureExpr boundArgs
                                    then
                                        attempt name boundCall (ForwardPartialCall funcExpr boundArgs arity) bumpPartialMerges

                                    else
                                        skip ()

                                Nothing ->
                                    skip ()

                        Mono.MonoDef name ((MonoCall _ ((MonoVarKernel _ _ _ _ _) as funcExpr) boundArgs _ _) as boundCall) ->
                            -- H6.1 F3: same rule for a strictly-partial KERNEL
                            -- call — point-free kernel aliases inline to a bare
                            -- VarKernel, so the `<|`-partial (`Bitwise.and
                            -- bitMask <| …` in elm/core Array internals) binds
                            -- exactly this shape. Merging within the first
                            -- stage re-saturates it onto the intrinsics path.
                            case calleeArity c funcExpr of
                                Just arity ->
                                    if
                                        List.length boundArgs
                                            < arity
                                            && List.all isPureExpr boundArgs
                                    then
                                        attempt name boundCall (ForwardPartialCall funcExpr boundArgs arity) bumpPartialMerges

                                    else
                                        skip ()

                                Nothing ->
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
forwardGo : RewriteCtx -> Name -> ForwardPayload -> MonoExpr -> Maybe ( MonoExpr, RewriteCtx )
forwardGo ctx name payload expr =
    case expr of
        MonoCall region func args t ci ->
            case func of
                MonoVarLocal n _ ->
                    if n == name then
                        case payload of
                            ForwardClosure cinfo cbody ->
                                -- Only SATURATED closure uses forward — a
                                -- partial use would route through the
                                -- partial-rebuild path at a NEW site.
                                -- Function-typed results are allowed since
                                -- H2.5 step 2: an exact beta yields the
                                -- source body (no rebuild), and if the
                                -- enclosing expression applies it, hoisting
                                -- + beta consume it on later iterations;
                                -- if it is stored, it is a source-typed
                                -- literal. (The old ground-result refusal
                                -- predates hoisting and the faithful
                                -- residual type — SKI/identity-composition
                                -- unit fixtures and HofCurriedForwardTest
                                -- pin the relaxation.)
                                if List.length args == List.length cinfo.params then
                                    Just (betaReduce ctx region cinfo cbody args t)

                                else if
                                    (List.length args > List.length cinfo.params)
                                        && not (List.isEmpty cinfo.params)
                                then
                                    -- H6.2 layer 3: a source-level multi-stage
                                    -- application (`f a s1`) is ONE call node
                                    -- carrying both stages' args, so the exact
                                    -- check above never fires for a 1-param
                                    -- literal and the whole bind-collapse
                                    -- cascade stalls at its first link. Beta
                                    -- the first stage EXACTLY (evaluation
                                    -- order identical: stage-1 body runs at
                                    -- application) and re-apply the rest to
                                    -- the result — let-callee hoisting and
                                    -- the merge arm consume the residual on
                                    -- later fixpoint iterations.
                                    let
                                        nParams =
                                            List.length cinfo.params

                                        ( inner, ctx1 ) =
                                            betaReduce ctx region cinfo cbody (List.take nParams args) (Mono.typeOf cbody)
                                    in
                                    Just
                                        ( MonoCall region inner (List.drop nParams args) t Mono.defaultCallInfo
                                        , ctx1
                                        )

                                else
                                    Nothing

                            ForwardPartialCall funcExpr boundArgs arity ->
                                -- H2.5 step 1c: merge a strictly-partial
                                -- bound call with its single callee-position
                                -- use. The merged node is an ordinary call
                                -- of the original callee — no residual
                                -- closure, staging metadata recomputed
                                -- downstream. Over-application totals are
                                -- refused (the residual would be applied
                                -- again — the shape merging exists to avoid).
                                if List.length boundArgs + List.length args <= arity then
                                    Just
                                        ( MonoCall region funcExpr (boundArgs ++ args) t Mono.defaultCallInfo
                                        , ctx
                                        )

                                else
                                    Nothing

                    else
                        forwardGoList ctx name payload args
                            |> Maybe.map (\( args1, c ) -> ( MonoCall region func args1 t ci, c ))

                _ ->
                    case forwardGo ctx name payload func of
                        Just ( func1, c ) ->
                            Just ( MonoCall region func1 args t ci, c )

                        Nothing ->
                            forwardGoList ctx name payload args
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
                        case forwardGo ctx name payload bound of
                            Just ( bound1, c ) ->
                                Just ( MonoLet (Mono.MonoDef dn bound1) b t, c )

                            Nothing ->
                                forwardGo ctx name payload b
                                    |> Maybe.map (\( b1, c ) -> ( MonoLet d b1 t, c ))

                    Mono.MonoTailDef _ _ _ ->
                        -- Sinking guard: a tail-def bound expr is a loop body.
                        forwardGo ctx name payload b
                            |> Maybe.map (\( b1, c ) -> ( MonoLet d b1 t, c ))

        MonoDestruct ((Mono.MonoDestructor dn _ _) as dtor) inner t ->
            if dn == name then
                Nothing

            else
                forwardGo ctx name payload inner
                    |> Maybe.map (\( inner1, c ) -> ( MonoDestruct dtor inner1 t, c ))

        MonoIf branches final t ->
            case forwardGoIfBranches ctx name payload branches of
                Just ( branches1, c ) ->
                    Just ( MonoIf branches1 final t, c )

                Nothing ->
                    forwardGo ctx name payload final
                        |> Maybe.map (\( final1, c ) -> ( MonoIf branches final1 t, c ))

        MonoCase s r decider branches t ->
            if s == name || r == name then
                -- The case scrutinizes our variable: not a callee use.
                Nothing

            else
                case forwardGoDecider ctx name payload decider of
                    Just ( decider1, c ) ->
                        Just ( MonoCase s r decider1 branches t, c )

                    Nothing ->
                        forwardGoSndList ctx name payload branches
                            |> Maybe.map (\( branches1, c ) -> ( MonoCase s r decider branches1 t, c ))

        MonoList region items t ->
            forwardGoList ctx name payload items
                |> Maybe.map (\( items1, c ) -> ( MonoList region items1 t, c ))

        MonoTailCall n args t ->
            if n == name then
                Nothing

            else
                forwardGoSndList ctx name payload args
                    |> Maybe.map (\( args1, c ) -> ( MonoTailCall n args1 t, c ))

        MonoRecordCreate fields t ->
            forwardGoSndList ctx name payload fields
                |> Maybe.map (\( fields1, c ) -> ( MonoRecordCreate fields1 t, c ))

        MonoRecordAccess inner f t ->
            forwardGo ctx name payload inner
                |> Maybe.map (\( inner1, c ) -> ( MonoRecordAccess inner1 f t, c ))

        MonoRecordUpdate inner updates t ->
            case forwardGo ctx name payload inner of
                Just ( inner1, c ) ->
                    Just ( MonoRecordUpdate inner1 updates t, c )

                Nothing ->
                    forwardGoSndList ctx name payload updates
                        |> Maybe.map (\( updates1, c ) -> ( MonoRecordUpdate inner updates1 t, c ))

        MonoTupleCreate region items t ->
            forwardGoList ctx name payload items
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


{-| H2.5: static arity of a callee expression, when knowable. Only closure
literals and globals with function/tail-func nodes qualify — everything
else (locals, kernel refs, computed callees) returns Nothing and is never
merged.
-}
calleeArity : RewriteCtx -> MonoExpr -> Maybe Int
calleeArity ctx funcExpr =
    case funcExpr of
        MonoClosure info _ _ ->
            Just (List.length info.params)

        MonoVarGlobal _ specId _ ->
            Dict.get specId ctx.specArities

        MonoVarKernel _ _ _ _ kernelType ->
            -- H6.1 F3: partials with a bare kernel callee. Kernel types are
            -- stored STAGED (`Int -> (Int -> Int)`), but emission flattens —
            -- the wrapper spec and the papCreate `arity` attr both use
            -- flatArrowArity — so the FLAT arity is the correct merge bound:
            -- a merged saturated call reproduces exactly the shape a direct
            -- source-level saturated call takes (intrinsics included).
            let
                n =
                    flatArrowArity kernelType
            in
            if n > 0 then
                Just n

            else
                Nothing

        _ ->
            Nothing


forwardGoList : RewriteCtx -> Name -> ForwardPayload -> List MonoExpr -> Maybe ( List MonoExpr, RewriteCtx )
forwardGoList ctx name payload exprs =
    case exprs of
        [] ->
            Nothing

        e :: rest ->
            case forwardGo ctx name payload e of
                Just ( e1, c ) ->
                    Just ( e1 :: rest, c )

                Nothing ->
                    forwardGoList ctx name payload rest
                        |> Maybe.map (\( rest1, c ) -> ( e :: rest1, c ))


forwardGoSndList : RewriteCtx -> Name -> ForwardPayload -> List ( a, MonoExpr ) -> Maybe ( List ( a, MonoExpr ), RewriteCtx )
forwardGoSndList ctx name payload pairs =
    case pairs of
        [] ->
            Nothing

        ( k, e ) :: rest ->
            case forwardGo ctx name payload e of
                Just ( e1, c ) ->
                    Just ( ( k, e1 ) :: rest, c )

                Nothing ->
                    forwardGoSndList ctx name payload rest
                        |> Maybe.map (\( rest1, c ) -> ( ( k, e ) :: rest1, c ))


forwardGoIfBranches : RewriteCtx -> Name -> ForwardPayload -> List ( MonoExpr, MonoExpr ) -> Maybe ( List ( MonoExpr, MonoExpr ), RewriteCtx )
forwardGoIfBranches ctx name payload branches =
    case branches of
        [] ->
            Nothing

        ( cond, then_ ) :: rest ->
            case forwardGo ctx name payload cond of
                Just ( cond1, c ) ->
                    Just ( ( cond1, then_ ) :: rest, c )

                Nothing ->
                    case forwardGo ctx name payload then_ of
                        Just ( then1, c ) ->
                            Just ( ( cond, then1 ) :: rest, c )

                        Nothing ->
                            forwardGoIfBranches ctx name payload rest
                                |> Maybe.map (\( rest1, c ) -> ( ( cond, then_ ) :: rest1, c ))


forwardGoDecider : RewriteCtx -> Name -> ForwardPayload -> Mono.Decider Mono.MonoChoice -> Maybe ( Mono.Decider Mono.MonoChoice, RewriteCtx )
forwardGoDecider ctx name payload decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            forwardGo ctx name payload e
                |> Maybe.map (\( e1, c ) -> ( Mono.Leaf (Mono.Inline e1), c ))

        Mono.Leaf (Mono.Jump _) ->
            Nothing

        Mono.Chain tests success failure ->
            case forwardGoDecider ctx name payload success of
                Just ( s1, c ) ->
                    Just ( Mono.Chain tests s1 failure, c )

                Nothing ->
                    forwardGoDecider ctx name payload failure
                        |> Maybe.map (\( f1, c ) -> ( Mono.Chain tests success f1, c ))

        Mono.FanOut path tests fallback ->
            case forwardGoDeciderSndList ctx name payload tests of
                Just ( tests1, c ) ->
                    Just ( Mono.FanOut path tests1 fallback, c )

                Nothing ->
                    forwardGoDecider ctx name payload fallback
                        |> Maybe.map (\( fb1, c ) -> ( Mono.FanOut path tests fb1, c ))


forwardGoDeciderSndList : RewriteCtx -> Name -> ForwardPayload -> List ( a, Mono.Decider Mono.MonoChoice ) -> Maybe ( List ( a, Mono.Decider Mono.MonoChoice ), RewriteCtx )
forwardGoDeciderSndList ctx name payload pairs =
    case pairs of
        [] ->
            Nothing

        ( k, d ) :: rest ->
            case forwardGoDecider ctx name payload d of
                Just ( d1, c ) ->
                    Just ( ( k, d1 ) :: rest, c )

                Nothing ->
                    forwardGoDeciderSndList ctx name payload rest
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

        MonoDestruct (Mono.MonoDestructor destructName path destructType) inner resultType ->
            -- Destructure BINDERS are let-bound names too. Leaving them
            -- unrenamed captures a same-named caller variable used after the
            -- inlined segment: found live as the ECO_ARITY_RAISE self-compile
            -- segfault (raised andThen's `let (s1, a) = ma s0` binder `a`
            -- captured constrainTupleWithIds' source param `a`;
            -- RaiseProbe.elm probe2 pins it — 212 instead of 512 pre-fix).
            -- Flag-off the closure boundary happens to shield today's
            -- inlinable bodies, but the freshener must not rely on that.
            -- Inner is freshened FIRST (matching the def-rename policy), so
            -- the binder rename cannot capture an inner shadowing binding.
            let
                ( inner0, ctx1 ) =
                    freshenLetBoundNames ctx inner

                ( newName, ctx2 ) =
                    freshVar ctx1
            in
            ( MonoDestruct (Mono.MonoDestructor newName path destructType)
                (renameLocal destructName newName inner0)
                resultType
            , ctx2
            )

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
                            residualClosureType remainingParams resultType

                        -- Compute captures for the new closure
                        newCaptures =
                            Closure.computeClosureCaptures remainingParams substituted

                        newClosureInfo =
                            { lambdaId = newLambdaId
                            , srcLambda = Nothing
                            , lssMember = Nothing
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
