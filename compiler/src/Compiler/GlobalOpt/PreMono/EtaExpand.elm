module Compiler.GlobalOpt.PreMono.EtaExpand exposing
    ( Metrics, emptyMetrics
    , run
    )

{-| Rewrites definitions and callback lambdas written at a type alias's arity
into their full declared arity before monomorphization, so the calls they make
are saturated rather than partial applications.

The motivating case is a state monad. With `IO a` an alias for
`State -> ( State, a )`, `andThen` and `map` are defined with all three
parameters, but a caller writes `prog = tick |> IO.andThen k` at the alias's
arity. Its body is then a call of `andThen` with two of three arguments, a
partial application (PAP), and every bind in the chain is finally applied
through one generic dispatch on a call result. Written at declared arity, the
same program has a lambda literal in the callback position and a global in the
action position of a saturated call, which later passes can resolve statically.

Three terms are used throughout. The _declared arity_ of a type is the number
of arrows in its spine once aliases are expanded; it is read off the alias's
structure, so a type variable in result position does not change it. The
_syntactic arity_ of a body is the number of parameters it actually writes. The
_deficit_ is declared minus syntactic.

There are two rules.

  - The definition rule: a `Define`, `TrackedDefine` or Cycle `Def` whose node
    type has a deficit gains that many fresh `_eta<n>` parameters (appended to
    its lambda, or in a new wrapper lambda around a bare value), and its body is
    applied to them.
  - The continuation rule: inside every body, bottom up, a lambda literal in
    argument position of a call to a global, cycle member or kernel gains the
    deficit between its own parameters and the parameter type the callee's
    reference type expects at that position. The lambda keeps its
    `SrcLambdaId`.

The new application is then normalised by `apply`: merged into an
under-applied call to a known global, pushed through `Let`, `Destruct`, `If`
and `Case`, and beta-reduced into a lambda head by let-binding.

Both rules are guarded by a cheapness gate, `cheap`. Expansion moves the work
done before the new binders from once (a CAF's evaluation, or one closure
creation) to once per call. That is harmless when the work only builds the PAP
or closure that would be applied anyway, and costly for
`d = let big = expensive in \s -> ...`, so only bodies whose pre-binder work is
construction, a PAP, or a cheap call are expanded.

Some definitions are never expanded. A body that is a bare `VarKernel` is a
kernel alias, and later passes recognise a kernel alias by exactly that shape.
A body that is a bare constructor reference is a constructor alias, and
expanding it would hide the global's name from later passes that match on it.
Also left alone are the flags decoder (`EntryPrep.flagsDecoderName`),
`TailDef`s and Cycle values (both only counted), ports and other non-definition
nodes, globals outside the `etaOnly` allow-list, and any expansion whose
declared arity exceeds `HeapLimits.maxStageArity`.

How far new arguments may be merged into a call is the subtle part. A callee's
type cannot say where its first stage ends, because an arrow chain also counts
the arrows of the result. So the bound is the callee's parameter count in the
graph after this pass (`Gate`), computed once before rewriting, capped by the
arity of the reference's own type.

Every node this pass builds is passed through `Fresh.mintNewNode`. An
`ArrowId` names one syntactic occurrence of an arrow, so a type this pass puts
at a new position has its arrow slots cleared first and is given fresh ids;
new wrapper lambdas get a fresh lambda id, and rebuilt existing lambdas keep
theirs.

`run` returns the original graph when `etaExpand` is off, but still walks it
and returns the metrics.

@docs Metrics, emptyMetrics
@docs run

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.HeapLimits as HeapLimits
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.KernelFacts as KernelFacts
import Compiler.GlobalOpt.PreMono.Fresh as Fresh
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Reporting.Annotation as A
import Data.Map as Dict
import Dict as CoreDict



-- ============================================================================
-- ====== METRICS ======
-- ============================================================================


{-| Counters describing what one run of the pass found and did, reported whether
or not the rewrite is kept.

`bodiesSeen` counts the bodies walked, so a zero there means the pass reached
nothing, as distinct from refusing everything. `defs` and `cycleDefs` count
definition-rule expansions at top level and in cycles, `conts` continuation
expansions, `merged` and `pushed` the normalisation steps of `apply`, and the
most of the remaining plain counters the reasons a site was declined. `byName` and
`notCheapByName` are keyed by the definition being expanded (its comparable
global, or its bare name for a cycle member) or, for a continuation, by the
callee whose argument it is.

-}
type alias Metrics =
    { defs : Int
    , cycleDefs : Int
    , conts : Int
    , merged : Int
    , pushed : Int
    , notCheap : Int
    , noDeficit : Int
    , noSpine : Int
    , tailDef : Int
    , cycleValue : Int
    , kernelAlias : Int
    , ctorAlias : Int
    , bodiesSeen : Int

    -- Deficit histogram (1, 2, 3 or more) over the sites that passed the
    -- arity tests, whether or not they were then expanded.
    , deficit1 : Int
    , deficit2 : Int
    , deficit3 : Int

    -- Sites the cheapness gate admitted, out of those it judged.
    , cheapYes : Int
    , cheapSeen : Int
    , byName : CoreDict.Dict String Int
    , notCheapByName : CoreDict.Dict String Int

    -- Definitions whose body type has fewer arrows than the node type's
    -- deficit; declined rather than mis-typed.
    , noPeel : Int

    -- Sites whose expanded parameter count would exceed
    -- `HeapLimits.maxStageArity`.
    , declinedArityCap : Int
    }


{-| Metrics with every counter zero and both name tallies empty.
-}
emptyMetrics : Metrics
emptyMetrics =
    { defs = 0
    , cycleDefs = 0
    , conts = 0
    , merged = 0
    , pushed = 0
    , notCheap = 0
    , noDeficit = 0
    , noSpine = 0
    , tailDef = 0
    , cycleValue = 0
    , kernelAlias = 0
    , ctorAlias = 0
    , bodiesSeen = 0
    , deficit1 = 0
    , deficit2 = 0
    , deficit3 = 0
    , cheapYes = 0
    , cheapSeen = 0
    , byName = CoreDict.empty
    , notCheapByName = CoreDict.empty
    , noPeel = 0
    , declinedArityCap = 0
    }


{-| The state threaded through the rewrite: the id-minting state, the metrics,
the next `_eta<n>` number, the read-only `Gate`, the name definition-rule
expansions are attributed to, and the `etaOnly` allow-list.
-}
type alias Ctx =
    { state : AssignMVarIds.GlobalMVarState
    , metrics : Metrics
    , fresh : Int

    -- A global with no entry here is neither judged cheap nor merged into.
    , gate : Gate
    , who : String
    , only : List String
    }



-- ============================================================================
-- ====== ENTRY POINT ======
-- ============================================================================


{-| Eta-expands the definitions and continuation lambdas of `graph` to their
declared arity, returning the rewritten graph, the advanced id-minting state
and the metrics.

When `etaExpand` is off the rewrite is still computed for its metrics, but the
original `graph` and `state` are returned.

-}
run :
    Config.InlineConfig
    -> AssignMVarIds.GlobalMVarState
    -> TOpt.GlobalGraph TypeIds.MVarId
    -> ( TOpt.GlobalGraph TypeIds.MVarId, AssignMVarIds.GlobalMVarState, Metrics )
run cfg state graph =
    let
        index : CoreDict.Dict String Callee
        index =
            buildIndex graph

        -- Syntactic arities, straight off the graph.
        gate0 : Gate
        gate0 =
            { threshold = cfg.etaThreshold
            , arity = CoreDict.map (\_ c -> c.arity) index
            , cost = CoreDict.map (\_ c -> c.cost) index
            , aliasCost = buildAliasCost graph
            , ctors = buildCtorSet graph
            }

        -- The arity each definition will have once this pass is done.
        gate1 : Gate
        gate1 =
            { gate0 | arity = buildPostArity gate0 graph }

        ctx0 : Ctx
        ctx0 =
            { state = state
            , metrics = emptyMetrics
            , fresh = 0
            , gate = gate1
            , who = ""
            , only = cfg.etaOnly
            }

        ( graph1, ctx1 ) =
            rewriteGraph ctx0 graph
    in
    if cfg.etaExpand then
        ( graph1, ctx1.state, ctx1.metrics )

    else
        ( graph, state, ctx1.metrics )


{-| Tells whether a global may be rewritten under the `etaOnly` allow-list
`only`: true when the list is empty or the global's `Module.name` starts with
one of its prefixes.
-}
moduleAllowed : List String -> TOpt.Global -> Bool
moduleAllowed only (TOpt.Global (ModuleName.Canonical _ moduleName) name) =
    let
        -- A prefix can name a module or a single definition.
        qualified =
            moduleName ++ "." ++ name
    in
    List.isEmpty only || List.any (\prefix -> String.startsWith prefix qualified) only


{-| Rewrites every node of the graph whose global the allow-list admits, leaving
the other nodes and the rest of the graph as they are.
-}
rewriteGraph : Ctx -> TOpt.GlobalGraph TypeIds.MVarId -> ( TOpt.GlobalGraph TypeIds.MVarId, Ctx )
rewriteGraph ctx (TOpt.GlobalGraph nodes fields annotations schemeRoots varSupers) =
    let
        ( newNodes, ctx1 ) =
            Dict.foldl
                (\g node ( acc, c ) ->
                    let
                        ( newNode, c1 ) =
                            if moduleAllowed c.only g then
                                rewriteNode { c | who = TOpt.toComparableGlobal g } g node

                            else
                                ( node, c )
                    in
                    ( Dict.insert TOpt.toComparableGlobal g newNode acc, c1 )
                )
                ( Dict.empty, ctx )
                nodes
    in
    ( TOpt.GlobalGraph newNodes fields annotations schemeRoots varSupers, ctx1 )


{-| Rewrites one node. `Define` and `TrackedDefine` bodies and Cycle `Def`s get
both rules. Cycle values and `TailDef`s get only the continuation rule inside
them, and a deficit there is counted (`cycleValue`, `tailDef`) but not
expanded. The flags decoder and every other kind of node are returned as they
are.
-}
rewriteNode : Ctx -> TOpt.Global -> TOpt.Node TypeIds.MVarId -> ( TOpt.Node TypeIds.MVarId, Ctx )
rewriteNode ctx (TOpt.Global _ nodeName) node =
    if nodeName == EntryPrep.flagsDecoderName then
        ( node, ctx )

    else
        case node of
            TOpt.Define expr deps meta ->
                let
                    ( body1, ctx1 ) =
                        rewriteExpr (seeBody ctx) expr

                    ( body2, ctx2 ) =
                        expandDefinition ctx1 TopLevel Nothing meta.tipe body1
                in
                ( TOpt.Define body2 deps meta, ctx2 )

            TOpt.TrackedDefine region expr deps meta ->
                let
                    ( body1, ctx1 ) =
                        rewriteExpr (seeBody ctx) expr

                    ( body2, ctx2 ) =
                        expandDefinition ctx1 TopLevel (Just region) meta.tipe body1
                in
                ( TOpt.TrackedDefine region body2 deps meta, ctx2 )

            TOpt.Cycle names values funcDefs deps ->
                let
                    ( newValues, ctxV ) =
                        List.foldl
                            (\( n, e ) ( acc, c ) ->
                                let
                                    ( e1, c1 ) =
                                        rewriteExpr (seeBody c) e

                                    c2 =
                                        if hasDeficit (TOpt.typeOf e) e then
                                            bump (\m -> { m | cycleValue = m.cycleValue + 1 }) c1

                                        else
                                            c1
                                in
                                ( ( n, e1 ) :: acc, c2 )
                            )
                            ( [], ctx )
                            values

                    ( newFuncs, ctxF ) =
                        List.foldl
                            (\def ( acc, c ) ->
                                let
                                    ( d1, c1 ) =
                                        rewriteCycleDef c def
                                in
                                ( d1 :: acc, c1 )
                            )
                            ( [], ctxV )
                            funcDefs
                in
                ( TOpt.Cycle names (List.reverse newValues) (List.reverse newFuncs) deps, ctxF )

            _ ->
                ( node, ctx )


{-| Rewrites one function definition of a cycle. A `Def` gets both rules,
attributed to its bare name. A `TailDef` gets only the continuation rule, and
a deficit is counted as `tailDef`: its `TailCall`s carry exactly the written
parameters, so adding one would mean changing every jump.
-}
rewriteCycleDef : Ctx -> TOpt.Def TypeIds.MVarId -> ( TOpt.Def TypeIds.MVarId, Ctx )
rewriteCycleDef ctx def =
    case def of
        TOpt.Def region name body tipe ->
            let
                ( body1, ctx1 ) =
                    rewriteExpr (seeBody { ctx | who = name }) body

                ( body2, ctx2 ) =
                    expandDefinition ctx1 CycleMember (Just region) tipe body1
            in
            ( TOpt.Def region name body2 tipe, ctx2 )

        TOpt.TailDef region name args body tipe tvar ->
            let
                ( body1, ctx1 ) =
                    rewriteExpr (seeBody { ctx | who = name }) body

                ctx2 =
                    if declaredArity tipe > List.length args then
                        bump (\m -> { m | tailDef = m.tailDef + 1 }) ctx1

                    else
                        ctx1
            in
            ( TOpt.TailDef region name args body1 tipe tvar, ctx2 )



-- ============================================================================
-- ====== RULE 1: DEFINITIONS ======
-- ============================================================================


{-| Returns a definition body expanded by the definition rule to the declared
arity of `declType`, the definition node's own type, or the body unchanged with
the reason counted.

The new parameters take the spine types after the ones already written. When
the body is a lambda they are appended to it and its inner body is applied to
them; otherwise the body is wrapped in a new lambda, tracked when
`maybeRegion` is given. The checks run in order: kernel alias, constructor
alias, no spine, no deficit, the stage-arity cap, a body type that does not
peel, and the cheapness gate.

-}
expandDefinition : Ctx -> Site -> Maybe A.Region -> Can.Type TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
expandDefinition ctx site maybeRegion declType body =
    let
        ( paramTypes, _ ) =
            spine declType

        declared =
            List.length paramTypes

        ( syntactic, inner ) =
            case body of
                TOpt.Function _ ps b _ ->
                    ( List.length ps, b )

                TOpt.TrackedFunction _ ps b _ ->
                    ( List.length ps, b )

                _ ->
                    ( 0, body )

        deficit =
            declared - syntactic
    in
    if isKernelAlias body then
        -- Later passes treat a node whose body is exactly a `VarKernel` as the
        -- kernel itself; expanding it would hide that.
        ( body, bump (\m -> { m | kernelAlias = m.kernelAlias + 1 }) ctx )

    else if isCtorAlias ctx.gate body then
        -- Expanding a constructor alias (`unsignedInt8 = U8`) would let
        -- later inlining replace the global by the bare constructor,
        -- hiding the global's name from passes that match on it.
        ( body, bump (\m -> { m | ctorAlias = m.ctorAlias + 1 }) ctx )

    else if declared == 0 then
        ( body, bump (\m -> { m | noSpine = m.noSpine + 1 }) ctx )

    else if deficit <= 0 then
        ( body, bump (\m -> { m | noDeficit = m.noDeficit + 1 }) ctx )

    else if declared > HeapLimits.maxStageArity then
        ( body, bump (\m -> { m | declinedArityCap = m.declinedArityCap + 1 }) ctx )

    else
        let
            ctxD =
                bump (countDeficit deficit) ctx
        in
        case peelType deficit (TOpt.typeOf inner) of
            Nothing ->
                ( body, bump (\m -> { m | noPeel = m.noPeel + 1 }) ctxD )

            Just resultType ->
                if not (cheap ctxD.gate inner) then
                    ( body
                    , bump
                        (\m ->
                            { m
                                | notCheap = m.notCheap + 1
                                , cheapSeen = m.cheapSeen + 1
                                , notCheapByName = tally ctxD.who m.notCheapByName
                            }
                        )
                        ctxD
                    )

                else
                    let
                        newTypes =
                            List.drop syntactic paramTypes

                        ( binders, ctx1 ) =
                            freshBinders ctxD newTypes

                        ( newInner, ctx2 ) =
                            apply ctx1 inner (List.map binderRef binders) resultType

                        region =
                            Maybe.withDefault A.zero maybeRegion

                        rebuilt =
                            case body of
                                TOpt.Function lamId ps _ meta ->
                                    TOpt.Function lamId (ps ++ binders) newInner meta

                                TOpt.TrackedFunction lamId ps _ meta ->
                                    TOpt.TrackedFunction lamId
                                        (ps ++ List.map (\( n, t ) -> ( A.At region n, t )) binders)
                                        newInner
                                        meta

                                _ ->
                                    -- The wrapped body stays in the tree, so
                                    -- the wrapper's copy of its type is a
                                    -- second occurrence and gets fresh arrow
                                    -- ids. The node's own meta is untouched.
                                    let
                                        wrapperMeta =
                                            { tipe = clearArrows (TOpt.typeOf body)
                                            , tvar = (TOpt.metaOf body).tvar
                                            }
                                    in
                                    case maybeRegion of
                                        Just r ->
                                            TOpt.TrackedFunction Nothing
                                                (List.map (\( n, t ) -> ( A.At r n, t )) binders)
                                                newInner
                                                wrapperMeta

                                        Nothing ->
                                            TOpt.Function Nothing binders newInner wrapperMeta

                        ( minted, state1 ) =
                            Fresh.mintNewNode ctx2.state rebuilt
                    in
                    ( minted
                    , bump
                        (\m0 ->
                            let
                                m =
                                    countSite site m0
                            in
                            { m
                                | cheapYes = m.cheapYes + 1
                                , cheapSeen = m.cheapSeen + 1
                                , byName = tally ctx2.who m.byName
                            }
                        )
                        { ctx2 | state = state1 }
                    )


{-| Tells whether a definition body is a bare kernel reference, which makes
the definition a kernel alias.
-}
isKernelAlias : TOpt.Expr TypeIds.MVarId -> Bool
isKernelAlias body =
    case body of
        TOpt.VarKernel _ _ _ _ _ ->
            True

        _ ->
            False


{-| Tells whether a definition body is a bare constructor reference: a
`VarBox`, a `VarEnum`, or a `VarGlobal` naming a global in `gate.ctors`.
-}
isCtorAlias : Gate -> TOpt.Expr TypeIds.MVarId -> Bool
isCtorAlias gate body =
    case body of
        TOpt.VarBox _ _ _ ->
            True

        TOpt.VarEnum _ _ _ _ ->
            True

        TOpt.VarGlobal _ g _ ->
            CoreDict.member (TOpt.toComparableGlobal g) gate.ctors

        _ ->
            False


{-| Returns the set of `Ctor` globals in the graph, keyed by comparable global
as `buildIndex` is.
-}
buildCtorSet : TOpt.GlobalGraph TypeIds.MVarId -> CoreDict.Dict String ()
buildCtorSet (TOpt.GlobalGraph nodes _ _ _ _) =
    Dict.foldl
        (\g node acc ->
            case node of
                TOpt.Ctor _ _ _ ->
                    CoreDict.insert (TOpt.toComparableGlobal g) () acc

                _ ->
                    acc
        )
        CoreDict.empty
        nodes


{-| Tells whether a body writes fewer parameters than `declType` declares.
-}
hasDeficit : Can.Type TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Bool
hasDeficit declType body =
    let
        syntactic =
            case body of
                TOpt.Function _ ps _ _ ->
                    List.length ps

                TOpt.TrackedFunction _ ps _ _ ->
                    List.length ps

                _ ->
                    0
    in
    declaredArity declType > syntactic



-- ============================================================================
-- ====== RULE 2: CONTINUATION LAMBDAS ======
-- ============================================================================


{-| Returns an expression with the continuation rule applied throughout it.

The walk is bottom up, and that matters. In
`andThen (\x -> andThen (\xs -> ...) (sequence rest)) m` the inner continuation
is expanded first, so when the outer one is expanded its body is already an
under-applied call of `andThen`, and the parameter added to the outer lambda
merges into it.

-}
rewriteExpr : Ctx -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
rewriteExpr ctx expr =
    case expr of
        TOpt.List region items meta ->
            mapExprs ctx items (\xs -> TOpt.List region xs meta)

        TOpt.Function lamId params body meta ->
            let
                ( b, ctx1 ) =
                    rewriteExpr ctx body
            in
            ( TOpt.Function lamId params b meta, ctx1 )

        TOpt.TrackedFunction lamId params body meta ->
            let
                ( b, ctx1 ) =
                    rewriteExpr ctx body
            in
            ( TOpt.TrackedFunction lamId params b meta, ctx1 )

        TOpt.Call region func args meta ->
            let
                ( f1, ctx1 ) =
                    rewriteExpr ctx func

                ( args1, ctx2 ) =
                    mapList ctx1 args rewriteExpr

                ( args2, ctx3 ) =
                    expandArgLambdas ctx2 f1 args1
            in
            ( TOpt.Call region f1 args2 meta, ctx3 )

        TOpt.TailCall name args meta ->
            let
                ( newArgs, ctx1 ) =
                    mapList ctx args (\c ( n, e ) -> Tuple.mapFirst (Tuple.pair n) (rewriteExpr c e))
            in
            ( TOpt.TailCall name newArgs meta, ctx1 )

        TOpt.If branches final meta ->
            let
                ( newBranches, ctx1 ) =
                    mapList ctx
                        branches
                        (\c ( cond, then_ ) ->
                            let
                                ( c1, cx1 ) =
                                    rewriteExpr c cond

                                ( t1, cx2 ) =
                                    rewriteExpr cx1 then_
                            in
                            ( ( c1, t1 ), cx2 )
                        )

                ( newFinal, ctx2 ) =
                    rewriteExpr ctx1 final
            in
            ( TOpt.If newBranches newFinal meta, ctx2 )

        TOpt.Let def body meta ->
            let
                ( newDef, ctx1 ) =
                    rewriteDef ctx def

                ( newBody, ctx2 ) =
                    rewriteExpr ctx1 body
            in
            ( TOpt.Let newDef newBody meta, ctx2 )

        TOpt.Destruct destructor body meta ->
            let
                ( newBody, ctx1 ) =
                    rewriteExpr ctx body
            in
            ( TOpt.Destruct destructor newBody meta, ctx1 )

        TOpt.Case label root decider jumps meta ->
            let
                ( newDecider, ctx1 ) =
                    rewriteDecider ctx decider

                ( newJumps, ctx2 ) =
                    mapList ctx1 jumps (\c ( i, e ) -> Tuple.mapFirst (Tuple.pair i) (rewriteExpr c e))
            in
            ( TOpt.Case label root newDecider newJumps meta, ctx2 )

        TOpt.Access inner region field meta ->
            let
                ( newInner, ctx1 ) =
                    rewriteExpr ctx inner
            in
            ( TOpt.Access newInner region field meta, ctx1 )

        TOpt.Update region record fields meta ->
            let
                ( newRecord, ctx1 ) =
                    rewriteExpr ctx record

                ( newFields, ctx2 ) =
                    Dict.foldl
                        (\k e ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    rewriteExpr c e
                            in
                            ( Dict.insert A.toValue k e1 acc, c1 )
                        )
                        ( Dict.empty, ctx1 )
                        fields
            in
            ( TOpt.Update region newRecord newFields meta, ctx2 )

        TOpt.Record fields meta ->
            let
                ( newFields, ctx1 ) =
                    CoreDict.foldl
                        (\k e ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    rewriteExpr c e
                            in
                            ( CoreDict.insert k e1 acc, c1 )
                        )
                        ( CoreDict.empty, ctx )
                        fields
            in
            ( TOpt.Record newFields meta, ctx1 )

        TOpt.TrackedRecord region fields meta ->
            let
                ( newFields, ctx1 ) =
                    Dict.foldl
                        (\k e ( acc, c ) ->
                            let
                                ( e1, c1 ) =
                                    rewriteExpr c e
                            in
                            ( Dict.insert A.toValue k e1 acc, c1 )
                        )
                        ( Dict.empty, ctx )
                        fields
            in
            ( TOpt.TrackedRecord region newFields meta, ctx1 )

        TOpt.Tuple region a b rest meta ->
            let
                ( a1, ctx1 ) =
                    rewriteExpr ctx a

                ( b1, ctx2 ) =
                    rewriteExpr ctx1 b

                ( rest1, ctx3 ) =
                    mapList ctx2 rest rewriteExpr
            in
            ( TOpt.Tuple region a1 b1 rest1 meta, ctx3 )

        _ ->
            ( expr, ctx )


{-| Applies the continuation rule inside a `let` definition.
-}
rewriteDef : Ctx -> TOpt.Def TypeIds.MVarId -> ( TOpt.Def TypeIds.MVarId, Ctx )
rewriteDef ctx def =
    case def of
        TOpt.Def region name bound tipe ->
            let
                ( b, ctx1 ) =
                    rewriteExpr ctx bound
            in
            ( TOpt.Def region name b tipe, ctx1 )

        TOpt.TailDef region name args body tipe tvar ->
            let
                ( b, ctx1 ) =
                    rewriteExpr ctx body
            in
            ( TOpt.TailDef region name args b tipe tvar, ctx1 )


{-| Applies the continuation rule inside every `Inline` leaf of a decision tree.
-}
rewriteDecider : Ctx -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> ( TOpt.Decider (TOpt.Choice TypeIds.MVarId), Ctx )
rewriteDecider ctx decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            Tuple.mapFirst (TOpt.Leaf << TOpt.Inline) (rewriteExpr ctx e)

        TOpt.Leaf (TOpt.Jump n) ->
            ( TOpt.Leaf (TOpt.Jump n), ctx )

        TOpt.Chain tests ok ko ->
            let
                ( ok1, ctx1 ) =
                    rewriteDecider ctx ok

                ( ko1, ctx2 ) =
                    rewriteDecider ctx1 ko
            in
            ( TOpt.Chain tests ok1 ko1, ctx2 )

        TOpt.FanOut path branches fallback ->
            let
                ( newBranches, ctx1 ) =
                    mapList ctx branches (\c ( t, d ) -> Tuple.mapFirst (Tuple.pair t) (rewriteDecider c d))

                ( newFallback, ctx2 ) =
                    rewriteDecider ctx1 fallback
            in
            ( TOpt.FanOut path newBranches newFallback, ctx2 )


{-| Returns the arguments of a call with the continuation rule applied to each
lambda literal among them.

The expected type at each position is read off the spine of the callee
reference's own type, with aliases expanded: `andThen`'s first parameter
`a -> IO b` expands to `a -> State -> ( State, b )`, so a one-parameter callback
has a deficit of 1. Here the full arrow spine is the right measure, unlike in
`calleeArity`: adding parameters to a lambda is type-safe at any depth, while
merging arguments into a call changes its staging. Arguments past the spine,
arguments that are not lambda literals (a PAP such as `add 5` included), and
calls whose head is not a global, cycle member or kernel are left alone.

-}
expandArgLambdas : Ctx -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> ( List (TOpt.Expr TypeIds.MVarId), Ctx )
expandArgLambdas ctx func args =
    case calleeName func of
        Nothing ->
            ( args, ctx )

        Just callee ->
            let
                ( expectedTypes, _ ) =
                    spine (TOpt.typeOf func)
            in
            List.foldl
                (\( index, arg ) ( acc, c ) ->
                    let
                        ( arg1, c1 ) =
                            case indexOf index expectedTypes of
                                Just expected ->
                                    expandOneLambda c callee expected arg

                                Nothing ->
                                    ( arg, c )
                    in
                    ( arg1 :: acc, c1 )
                )
                ( [], ctx )
                (List.indexedMap Tuple.pair args)
                |> Tuple.mapFirst List.reverse


{-| Returns `arg` expanded to the arity of `expected` when it is a lambda literal
with a deficit that passes the stage-arity cap and the cheapness gate, or
unchanged otherwise. The lambda keeps its `SrcLambdaId`; new tracked
parameters take the region of its first parameter.
-}
expandOneLambda : Ctx -> String -> Can.Type TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
expandOneLambda ctx callee expected arg =
    let
        maybeLambda =
            case arg of
                TOpt.Function lamId ps b meta ->
                    Just ( List.length ps, b, \newPs newBody -> TOpt.Function lamId (ps ++ newPs) newBody meta )

                TOpt.TrackedFunction lamId ps b meta ->
                    Just
                        ( List.length ps
                        , b
                        , \newPs newBody ->
                            TOpt.TrackedFunction lamId
                                (ps ++ List.map (\( n, t ) -> ( A.At (locatedRegion ps) n, t )) newPs)
                                newBody
                                meta
                        )

                _ ->
                    Nothing
    in
    case maybeLambda of
        Nothing ->
            ( arg, ctx )

        Just ( written, body, rebuild ) ->
            let
                ( expectedParams, expectedResult ) =
                    spine expected

                deficit =
                    List.length expectedParams - written
            in
            if deficit <= 0 then
                ( arg, ctx )

            else if List.length expectedParams > HeapLimits.maxStageArity then
                ( arg, bump (\m -> { m | declinedArityCap = m.declinedArityCap + 1 }) ctx )

            else
                let
                    ctxD =
                        bump (countDeficit deficit) ctx
                in
                if not (cheap ctxD.gate body) then
                    ( arg
                    , bump
                        (\m ->
                            { m
                                | notCheap = m.notCheap + 1
                                , cheapSeen = m.cheapSeen + 1
                                , notCheapByName = tally callee m.notCheapByName
                            }
                        )
                        ctxD
                    )

                else
                    let
                        ( binders, ctx1 ) =
                            freshBinders ctxD (List.drop written expectedParams)

                        ( newBody, ctx2 ) =
                            apply ctx1 body (List.map binderRef binders) (clearArrows expectedResult)

                        ( minted, state1 ) =
                            Fresh.mintNewNode ctx2.state (rebuild binders newBody)
                    in
                    ( minted
                    , bump
                        (\m ->
                            { m
                                | conts = m.conts + 1
                                , cheapYes = m.cheapYes + 1
                                , cheapSeen = m.cheapSeen + 1
                                , byName = tally callee m.byName
                            }
                        )
                        { ctx2 | state = state1 }
                    )



-- ============================================================================
-- ====== NORMALISING THE NEW APPLICATION ======
-- ============================================================================


{-| Returns `e` applied to `args`, normalised so the arguments reach the call
that was under-applied instead of being stacked on top of the PAP it builds.

`args` are references to the fresh `_eta<n>` parameters. Being variables, they
can be copied into several branches at no cost.

  - A `Call` of a global or cycle member takes the arguments into its own
    argument list while `calleeArity` has room. Past that bound the callee is
    given exactly its arity and the remaining arguments are applied to the
    result by an outer `Call`. With no known arity, or no room, an outer `Call`
    is built.
  - `Let`, `Destruct`, every `If` branch, and both the `Inline` leaves and the
    `jumps` of a `Case` have the application pushed inside them.
  - A lambda is beta-reduced by `betaLambda`.
  - Anything else gets an outer `Call`.

`resultType` is the type after all of `args` have been applied, and the
outermost node returned is given it. An inner saturated call built for an
over-application gets the callee's type peeled by its arity.

-}
apply : Ctx -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
apply ctx e args resultType =
    if List.isEmpty args then
        ( e, ctx )

    else
        let
            newMeta =
                { tipe = resultType, tvar = Nothing }
        in
        case e of
            TOpt.Call region func callArgs _ ->
                case calleeArity ctx func of
                    Just arity ->
                        let
                            have =
                                List.length callArgs

                            want =
                                have + List.length args
                        in
                        if want <= arity then
                            ( TOpt.Call region func (callArgs ++ args) newMeta
                            , bump (\m -> { m | merged = m.merged + 1 }) ctx
                            )

                        else
                            case ( arity > have, peelType arity (TOpt.typeOf func) ) of
                                ( True, Just innerType ) ->
                                    -- The inner call's type is the callee's
                                    -- type peeled by its arity, not
                                    -- `resultType`.
                                    let
                                        take =
                                            arity - have

                                        inner =
                                            TOpt.Call region
                                                func
                                                (callArgs ++ List.take take args)
                                                { tipe = innerType, tvar = Nothing }
                                    in
                                    ( TOpt.Call region inner (List.drop take args) newMeta
                                    , bump (\m -> { m | merged = m.merged + 1 }) ctx
                                    )

                                _ ->
                                    -- Already saturated, or the type has too
                                    -- few arrows to peel.
                                    ( TOpt.Call region e args newMeta, ctx )

                    Nothing ->
                        ( TOpt.Call region e args newMeta, ctx )

            TOpt.Function _ params body _ ->
                betaLambda ctx params body args resultType

            TOpt.TrackedFunction _ params body _ ->
                betaLambda ctx (List.map (\( n, t ) -> ( A.toValue n, t )) params) body args resultType

            TOpt.Let def body _ ->
                let
                    ( newBody, ctx1 ) =
                        apply ctx body args resultType
                in
                ( TOpt.Let def newBody newMeta, bump (\m -> { m | pushed = m.pushed + 1 }) ctx1 )

            TOpt.Destruct destructor body _ ->
                let
                    ( newBody, ctx1 ) =
                        apply ctx body args resultType
                in
                ( TOpt.Destruct destructor newBody newMeta, bump (\m -> { m | pushed = m.pushed + 1 }) ctx1 )

            TOpt.If branches final _ ->
                let
                    ( newBranches, ctx1 ) =
                        mapList ctx
                            branches
                            (\c ( cond, then_ ) ->
                                Tuple.mapFirst (Tuple.pair cond) (apply c then_ args resultType)
                            )

                    ( newFinal, ctx2 ) =
                        apply ctx1 final args resultType
                in
                ( TOpt.If newBranches newFinal newMeta, bump (\m -> { m | pushed = m.pushed + 1 }) ctx2 )

            TOpt.Case label root decider jumps _ ->
                let
                    ( newDecider, ctx1 ) =
                        applyDecider ctx decider args resultType

                    ( newJumps, ctx2 ) =
                        mapList ctx1 jumps (\c ( i, j ) -> Tuple.mapFirst (Tuple.pair i) (apply c j args resultType))
                in
                ( TOpt.Case label root newDecider newJumps newMeta
                , bump (\m -> { m | pushed = m.pushed + 1 }) ctx2
                )

            _ ->
                ( TOpt.Call (regionOf e) e args newMeta, ctx )


{-| Returns a decision tree with `apply` pushed into every `Inline` leaf;
`Jump` leaves are left for the caller to handle through the `Case`'s `jumps`.
-}
applyDecider : Ctx -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> ( TOpt.Decider (TOpt.Choice TypeIds.MVarId), Ctx )
applyDecider ctx decider args resultType =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            Tuple.mapFirst (TOpt.Leaf << TOpt.Inline) (apply ctx e args resultType)

        TOpt.Leaf (TOpt.Jump n) ->
            ( TOpt.Leaf (TOpt.Jump n), ctx )

        TOpt.Chain tests ok ko ->
            let
                ( ok1, ctx1 ) =
                    applyDecider ctx ok args resultType

                ( ko1, ctx2 ) =
                    applyDecider ctx1 ko args resultType
            in
            ( TOpt.Chain tests ok1 ko1, ctx2 )

        TOpt.FanOut path branches fallback ->
            let
                ( newBranches, ctx1 ) =
                    mapList ctx branches (\c ( t, d ) -> Tuple.mapFirst (Tuple.pair t) (applyDecider c d args resultType))

                ( newFallback, ctx2 ) =
                    applyDecider ctx1 fallback args resultType
            in
            ( TOpt.FanOut path newBranches newFallback, ctx2 )


{-| Returns a lambda with parameters `params` and body `body` applied to `args`,
by let-binding each parameter to its argument and applying the body to any
arguments left over. No substitution is done, so no capture can occur.

Given fewer arguments than parameters, it returns a plain `Call` of a rebuilt
lambda instead.

-}
betaLambda : Ctx -> List ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
betaLambda ctx params body args resultType =
    let
        arity =
            List.length params
    in
    if List.length args < arity then
        ( TOpt.Call A.zero
            (TOpt.Function Nothing params body (TOpt.metaOf body))
            args
            { tipe = resultType, tvar = Nothing }
        , ctx
        )

    else
        let
            ( newBody, ctx1 ) =
                apply ctx body (List.drop arity args) resultType

            wrapped =
                List.foldr
                    (\( ( pname, ptype ), arg ) acc ->
                        -- The `Let`'s copy of its body's type is a second
                        -- occurrence, so its arrow slots are cleared.
                        TOpt.Let (TOpt.Def A.zero pname arg ptype)
                            acc
                            { tipe = clearArrows (TOpt.typeOf acc)
                            , tvar = (TOpt.metaOf acc).tvar
                            }
                    )
                    newBody
                    (List.map2 Tuple.pair params (List.take arity args))
        in
        ( wrapped, bump (\m -> { m | pushed = m.pushed + 1 }) ctx1 )



-- ============================================================================
-- ====== THE CHEAPNESS GATE ======
-- ============================================================================


{-| Tells whether the work an expression does before the new binders would be
cheap to repeat on every call.

Literals, variables, accessors and lambdas (whose bodies are not examined) are
cheap. Lists, tuples, records, updates, accesses, `let`, `Destruct`, `if` and
`case` are cheap when all their parts are. A call is cheap when its arguments
are and `cheapCallee` admits it. `TailCall`, `Shader`, `VarDebug` and anything
else are not.

The gate does let a `crash` or `Debug.log` in the body of a saturated callee
admitted under `etaThreshold` move from one evaluation of the definition to
every application.

-}
cheap : Gate -> TOpt.Expr TypeIds.MVarId -> Bool
cheap ctx expr =
    case expr of
        TOpt.Bool _ _ _ ->
            True

        TOpt.Chr _ _ _ ->
            True

        TOpt.Str _ _ _ ->
            True

        TOpt.Int _ _ _ ->
            True

        TOpt.Float _ _ _ ->
            True

        TOpt.VarLocal _ _ ->
            True

        TOpt.TrackedVarLocal _ _ _ ->
            True

        TOpt.VarGlobal _ _ _ ->
            True

        TOpt.VarEnum _ _ _ _ ->
            True

        TOpt.VarBox _ _ _ ->
            True

        TOpt.VarCycle _ _ _ _ ->
            True

        TOpt.VarKernel _ _ _ _ _ ->
            True

        TOpt.Unit _ ->
            True

        TOpt.Accessor _ _ _ ->
            True

        TOpt.Function _ _ _ _ ->
            True

        TOpt.TrackedFunction _ _ _ _ ->
            True

        TOpt.List _ items _ ->
            List.all (cheap ctx) items

        TOpt.Tuple _ a b rest _ ->
            cheap ctx a && cheap ctx b && List.all (cheap ctx) rest

        TOpt.Record fields _ ->
            List.all (cheap ctx) (CoreDict.values fields)

        TOpt.TrackedRecord _ fields _ ->
            List.all (cheap ctx) (Dict.values fields)

        TOpt.Update _ record fields _ ->
            cheap ctx record && List.all (cheap ctx) (Dict.values fields)

        TOpt.Access inner _ _ _ ->
            cheap ctx inner

        TOpt.Let def body _ ->
            cheapDef ctx def && cheap ctx body

        TOpt.Destruct _ body _ ->
            cheap ctx body

        TOpt.If branches final _ ->
            List.all (\( c, t ) -> cheap ctx c && cheap ctx t) branches && cheap ctx final

        TOpt.Case _ _ decider jumps _ ->
            cheapDecider ctx decider && List.all (\( _, e ) -> cheap ctx e) jumps

        TOpt.Call _ func args _ ->
            List.all (cheap ctx) args && cheapCallee ctx func (List.length args)

        _ ->
            False


{-| Tells whether a call of `func` with `argCount` arguments builds rather than
works. A kernel is admitted only when `KernelFacts` gives it cost class
`CGcLeaf`; a global or cycle member is judged by `cheapGlobalCall`; any other
head is refused.
-}
cheapCallee : Gate -> TOpt.Expr TypeIds.MVarId -> Int -> Bool
cheapCallee ctx func argCount =
    case func of
        TOpt.VarKernel _ prefix home name _ ->
            case KernelFacts.lookup ( prefix, home, name ) of
                Just facts ->
                    KernelFacts.costClass facts == KernelFacts.CGcLeaf

                Nothing ->
                    False

        TOpt.VarGlobal _ g _ ->
            cheapGlobalCall ctx (TOpt.toComparableGlobal g) argCount

        TOpt.VarCycle _ home name _ ->
            cheapGlobalCall ctx (TOpt.toComparableGlobal (TOpt.Global home name)) argCount

        _ ->
            False


{-| Tells whether a call of the global keyed `key` with `argCount` arguments is
cheap: an under-applied call (a PAP) is, a saturated one is when the callee's
body cost is at most the threshold, and an over-applied one or a call of an
unknown global is not. A global of arity 0 is cheap only when it is a kernel
alias whose `aliasCost` is within the threshold.
-}
cheapGlobalCall : Gate -> String -> Int -> Bool
cheapGlobalCall ctx key argCount =
    case CoreDict.get key ctx.arity of
        Nothing ->
            False

        Just arity ->
            if arity <= 0 then
                -- `x :: xs` reaches the kernel alias `List.cons` this way.
                case CoreDict.get key ctx.aliasCost of
                    Just c ->
                        c <= ctx.threshold

                    Nothing ->
                        False

            else if argCount < arity then
                True

            else if argCount == arity then
                Maybe.withDefault (ctx.threshold + 1) (CoreDict.get key ctx.cost) <= ctx.threshold

            else
                False


{-| Tells whether a `let` definition's bound expression or body is cheap.
-}
cheapDef : Gate -> TOpt.Def TypeIds.MVarId -> Bool
cheapDef ctx def =
    case def of
        TOpt.Def _ _ bound _ ->
            cheap ctx bound

        TOpt.TailDef _ _ _ body _ _ ->
            cheap ctx body


{-| Tells whether every `Inline` leaf of a decision tree is cheap; a `Jump` leaf is.
-}
cheapDecider : Gate -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> Bool
cheapDecider ctx decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            cheap ctx e

        TOpt.Leaf (TOpt.Jump _) ->
            True

        TOpt.Chain _ ok ko ->
            cheapDecider ctx ok && cheapDecider ctx ko

        TOpt.FanOut _ branches fallback ->
            List.all (\( _, d ) -> cheapDecider ctx d) branches && cheapDecider ctx fallback



-- ============================================================================
-- ====== BODY COST INDEX ======
-- ============================================================================


{-| What the merge and the cheapness gate need to know about a global before
rewriting: its syntactic parameter count, which is where its first stage ends,
and the size of its body as `cost` measures it.
-}
type alias Callee =
    { arity : Int
    , cost : Int
    }


{-| The per-global facts the cheapness gate and the merge read, built before
rewriting so that the prediction of which definitions will expand can use them
too. `threshold` is the `etaThreshold` body-cost budget.

`arity` answers two questions: whether a call builds a PAP or does work (the
gate), and how many arguments one call may carry (the merge). Both want the
callee's arity after this pass, which the pass itself decides. `run` settles
this in one step. It first fills `arity` with syntactic counts, then replaces
them with `buildPostArity`'s prediction under those counts: the declared arity
for a definition predicted to expand, the syntactic count otherwise. The rewrite
uses the second table.

`cheap` only gains verdicts as arities grow (a saturated call becomes a PAP, an
over-applied one becomes saturated), so a definition predicted to expand under
the first table also passes the gate under the second. A definition the
prediction misses costs only an unmerged call. A prediction that is too high is
what must not happen, because the merge would then carry more arguments than
the callee's first stage takes; `willExpand` must therefore refuse whatever
`expandDefinition` refuses. It currently omits the constructor-alias, flags
decoder and `etaOnly` refusals.

`aliasCost` holds the body cost of kernel-alias globals only. Their arity is 0
in both tables, since they are never expanded; a bare-value definition's arity
can grow between the tables, and judging it by cost at arity 0 could break the
growth property above. `ctors` is the set of `Ctor` globals, used to recognise
constructor aliases.

-}
type alias Gate =
    { threshold : Int
    , arity : CoreDict.Dict String Int
    , cost : CoreDict.Dict String Int
    , aliasCost : CoreDict.Dict String Int
    , ctors : CoreDict.Dict String ()
    }


{-| Returns the `Callee` of every `Define`, `TrackedDefine`, `Ctor` and cycle
function definition, keyed by comparable global. A cycle member is keyed by
its own name in the cycle's home module, so it is found by the same lookup as a
plain definition. Cycle values are not indexed.
-}
buildIndex : TOpt.GlobalGraph TypeIds.MVarId -> CoreDict.Dict String Callee
buildIndex (TOpt.GlobalGraph nodes _ _ _ _) =
    Dict.foldl
        (\g node acc ->
            case node of
                TOpt.Define e _ _ ->
                    CoreDict.insert (TOpt.toComparableGlobal g) (calleeOfBody e) acc

                TOpt.TrackedDefine _ e _ _ ->
                    CoreDict.insert (TOpt.toComparableGlobal g) (calleeOfBody e) acc

                TOpt.Ctor _ arity _ ->
                    CoreDict.insert (TOpt.toComparableGlobal g) { arity = arity, cost = 1 } acc

                TOpt.Cycle _ _ funcDefs _ ->
                    let
                        home =
                            case g of
                                TOpt.Global h _ ->
                                    h
                    in
                    List.foldl
                        (\def inner ->
                            case def of
                                TOpt.Def _ name body _ ->
                                    CoreDict.insert
                                        (TOpt.toComparableGlobal (TOpt.Global home name))
                                        (calleeOfBody body)
                                        inner

                                TOpt.TailDef _ name args body _ _ ->
                                    CoreDict.insert
                                        (TOpt.toComparableGlobal (TOpt.Global home name))
                                        { arity = List.length args, cost = cost body }
                                        inner
                        )
                        acc
                        funcDefs

                _ ->
                    acc
        )
        CoreDict.empty
        nodes


{-| Returns the predicted arity of each global after this pass, judged under
`gate`: the declared arity of a definition `willExpand` admits, the syntactic
count otherwise, the stated arity of a `Ctor`, and the written parameter count
of a `TailDef`.

The declared arity is that of the definition's own node type, never of a call
site's instantiation: `s bf uf x : (a -> b -> c) -> (a -> b) -> a -> c` has
three, although at a site where `c` is instantiated to a function the reference
type has more arrows.

-}
buildPostArity : Gate -> TOpt.GlobalGraph TypeIds.MVarId -> CoreDict.Dict String Int
buildPostArity gate (TOpt.GlobalGraph nodes _ _ _ _) =
    let
        arityAfter ctx declType body =
            let
                base =
                    syntacticArityOf body
            in
            if willExpand ctx declType body then
                declaredArity declType

            else
                base
    in
    Dict.foldl
        (\g node acc ->
            let
                key =
                    TOpt.toComparableGlobal g

                ctx =
                    gate
            in
            case node of
                TOpt.Define e _ meta ->
                    CoreDict.insert key (arityAfter ctx meta.tipe e) acc

                TOpt.TrackedDefine _ e _ meta ->
                    CoreDict.insert key (arityAfter ctx meta.tipe e) acc

                TOpt.Ctor _ arity _ ->
                    CoreDict.insert key arity acc

                TOpt.Cycle _ _ funcDefs _ ->
                    let
                        home =
                            case g of
                                TOpt.Global h _ ->
                                    h
                    in
                    List.foldl
                        (\def inner ->
                            case def of
                                TOpt.Def _ name body tipe ->
                                    CoreDict.insert
                                        (TOpt.toComparableGlobal (TOpt.Global home name))
                                        (arityAfter ctx tipe body)
                                        inner

                                TOpt.TailDef _ name args _ _ _ ->
                                    CoreDict.insert
                                        (TOpt.toComparableGlobal (TOpt.Global home name))
                                        (List.length args)
                                        inner
                        )
                        acc
                        funcDefs

                _ ->
                    acc
        )
        CoreDict.empty
        nodes


{-| Tells whether the definition rule would expand a body of type `declType`
under `ctx`, without building anything. It checks the kernel-alias refusal, the
spine, the deficit, the stage-arity cap, the peel and the cheapness gate; it
does not check the constructor-alias refusal, the flags decoder or the
`etaOnly` allow-list, which `expandDefinition` and its callers also apply.
-}
willExpand : Gate -> Can.Type TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Bool
willExpand ctx declType body =
    let
        declared =
            declaredArity declType

        syntactic =
            syntacticArityOf body

        inner =
            innerBodyOf body
    in
    not (isKernelAlias body)
        && (declared > 0)
        && (declared - syntactic > 0)
        && (declared <= HeapLimits.maxStageArity)
        && (peelType (declared - syntactic) (TOpt.typeOf inner) /= Nothing)
        && cheap ctx inner


{-| Returns the number of parameters a body writes: its lambda's parameter count, or 0.
-}
syntacticArityOf : TOpt.Expr TypeIds.MVarId -> Int
syntacticArityOf body =
    case body of
        TOpt.Function _ ps _ _ ->
            List.length ps

        TOpt.TrackedFunction _ ps _ _ ->
            List.length ps

        _ ->
            0


{-| Returns the body of a lambda, or the expression itself when it is not one.
-}
innerBodyOf : TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId
innerBodyOf body =
    case body of
        TOpt.Function _ _ b _ ->
            b

        TOpt.TrackedFunction _ _ b _ ->
            b

        _ ->
            body


{-| Returns the body cost of every kernel-alias `Define` and `TrackedDefine`,
keyed by comparable global.
-}
buildAliasCost : TOpt.GlobalGraph TypeIds.MVarId -> CoreDict.Dict String Int
buildAliasCost (TOpt.GlobalGraph nodes _ _ _ _) =
    Dict.foldl
        (\g node acc ->
            case node of
                TOpt.Define e _ _ ->
                    if isKernelAlias e then
                        CoreDict.insert (TOpt.toComparableGlobal g) (cost e) acc

                    else
                        acc

                TOpt.TrackedDefine _ e _ _ ->
                    if isKernelAlias e then
                        CoreDict.insert (TOpt.toComparableGlobal g) (cost e) acc

                    else
                        acc

                _ ->
                    acc
        )
        CoreDict.empty
        nodes


{-| Returns the `Callee` of a definition body: a lambda's parameter count and
the cost of its inner body, or arity 0 and the whole body's cost for a bare
value.
-}
calleeOfBody : TOpt.Expr TypeIds.MVarId -> Callee
calleeOfBody expr =
    case expr of
        TOpt.Function _ ps body _ ->
            { arity = List.length ps, cost = cost body }

        TOpt.TrackedFunction _ ps body _ ->
            { arity = List.length ps, cost = cost body }

        _ ->
            -- Arity 0 in the syntactic table; calls are merged into it only
            -- if `buildPostArity` predicts that it will expand.
            { arity = 0, cost = cost expr }


{-| Returns a size estimate of an expression, the measure `etaThreshold` bounds:
a fixed weight per node kind plus the cost of its parts, and 1 for a leaf.
-}
cost : TOpt.Expr TypeIds.MVarId -> Int
cost expr =
    case expr of
        TOpt.List _ items _ ->
            3 + sumBy cost items

        TOpt.Function _ _ body _ ->
            5 + cost body

        TOpt.TrackedFunction _ _ body _ ->
            5 + cost body

        TOpt.Call _ func args _ ->
            5 + cost func + sumBy cost args

        TOpt.TailCall _ args _ ->
            5 + sumBy (\( _, e ) -> cost e) args

        TOpt.If branches final _ ->
            2 + sumBy (\( c, t ) -> cost c + cost t) branches + cost final

        TOpt.Let def body _ ->
            2 + costDef def + cost body

        TOpt.Destruct _ body _ ->
            2 + cost body

        TOpt.Case _ _ decider branches _ ->
            3 + costDecider decider + sumBy (\( _, e ) -> cost e) branches

        TOpt.Access inner _ _ _ ->
            1 + cost inner

        TOpt.Update _ inner fields _ ->
            3 + Dict.foldl (\_ e a -> a + cost e) (cost inner) fields

        TOpt.Record fields _ ->
            3 + CoreDict.foldl (\_ e a -> a + cost e) 0 fields

        TOpt.TrackedRecord _ fields _ ->
            3 + Dict.foldl (\_ e a -> a + cost e) 0 fields

        TOpt.Tuple _ a b rest _ ->
            3 + cost a + cost b + sumBy cost rest

        _ ->
            1


{-| Returns the `cost` of a decision tree: 1 for each `Chain` or `FanOut` node,
1 for each test of a `Chain`, 1 for each `Jump` leaf, and the `cost` of each
`Inline` leaf.
-}
costDecider : TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> Int
costDecider decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            cost e

        TOpt.Leaf (TOpt.Jump _) ->
            1

        TOpt.Chain tests ok ko ->
            1 + List.length tests + costDecider ok + costDecider ko

        TOpt.FanOut _ branches fallback ->
            1 + sumBy (\( _, d ) -> costDecider d) branches + costDecider fallback


{-| Returns the `cost` of a `let` definition's bound expression or body.
-}
costDef : TOpt.Def TypeIds.MVarId -> Int
costDef def =
    case def of
        TOpt.Def _ _ bound _ ->
            cost bound

        TOpt.TailDef _ _ _ body _ _ ->
            cost body


{-| Returns the sum of `f` over a list.
-}
sumBy : (a -> Int) -> List a -> Int
sumBy f =
    List.foldl (\x acc -> acc + f x) 0



-- ============================================================================
-- ====== TYPES: DECLARED ARITY FROM ALIAS STRUCTURE ======
-- ============================================================================


{-| Returns the parameter types of a type's arrow chain, with aliases expanded at
every step, and the type left after them.

Expanding aliases is the point: `IO Int` is `State -> ( State, Int )` and has
one parameter, which the alias name hides. The count follows structure, so
`a -> b` with `b` a variable has one parameter and a bare variable has none.

-}
spine : Can.Type TypeIds.MVarId -> ( List (Can.Type TypeIds.MVarId), Can.Type TypeIds.MVarId )
spine tipe =
    case unAlias tipe of
        Can.TLambda _ from to ->
            let
                ( rest, residual ) =
                    spine to
            in
            ( from :: rest, residual )

        other ->
            ( [], other )


{-| Returns the declared arity of a type: the length of its `spine`.
-}
declaredArity : Can.Type TypeIds.MVarId -> Int
declaredArity tipe =
    List.length (Tuple.first (spine tipe))


{-| Returns a type with alias layers removed from its head until it is not an
alias. A `Holey` body has the alias's arguments substituted for its parameters.
-}
unAlias : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId
unAlias tipe =
    case tipe of
        Can.TAlias _ _ args (Can.Holey body) ->
            unAlias
                (substTypeVars
                    (CoreDict.fromList (List.map (\( pn, t ) -> ( Id.toComparable pn, t )) args))
                    body
                )

        Can.TAlias _ _ _ (Can.Filled body) ->
            unAlias body

        _ ->
            tipe


{-| Returns a type with each type variable that `env` maps (by comparable id)
replaced, except a record's extension variable, which is kept unchanged. An
alias's arguments are substituted into, but its body is not.
-}
substTypeVars : CoreDict.Dict Int (Can.Type TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId
substTypeVars env tipe =
    case tipe of
        Can.TVar n ->
            Maybe.withDefault tipe (CoreDict.get (Id.toComparable n) env)

        Can.TLambda slot a b ->
            Can.TLambda slot (substTypeVars env a) (substTypeVars env b)

        Can.TType h n args ->
            Can.TType h n (List.map (substTypeVars env) args)

        Can.TRecord fields ext ->
            Can.TRecord (CoreDict.map (\_ (Can.FieldType i t) -> Can.FieldType i (substTypeVars env t)) fields) ext

        Can.TUnit ->
            Can.TUnit

        Can.TTuple a b rest ->
            Can.TTuple (substTypeVars env a) (substTypeVars env b) (List.map (substTypeVars env) rest)

        Can.TAlias h n args real ->
            Can.TAlias h n (List.map (\( pn, t ) -> ( pn, substTypeVars env t )) args) real


{-| Returns the result type after applying `n` arguments, with its arrow slots
cleared, or `Nothing` when the type does not have that many arrows once aliases
are expanded.
-}
peelType : Int -> Can.Type TypeIds.MVarId -> Maybe (Can.Type TypeIds.MVarId)
peelType n tipe =
    if n <= 0 then
        Just (clearArrows tipe)

    else
        case unAlias tipe of
            Can.TLambda _ _ to ->
                peelType (n - 1) to

            _ ->
                Nothing


{-| Returns a type with every arrow slot, including those inside alias
arguments and bodies, set to `Can.noArrow`, so that `Fresh.mintNewNode` gives
each a fresh `ArrowId`. A type placed at a new position is a new occurrence,
and keeping the old ids would put one id at two occurrences, which
`Fresh.assertMinted` rejects.
-}
clearArrows : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId
clearArrows tipe =
    case tipe of
        Can.TVar _ ->
            tipe

        Can.TLambda _ a b ->
            Can.TLambda Can.noArrow (clearArrows a) (clearArrows b)

        Can.TType h n args ->
            Can.TType h n (List.map clearArrows args)

        Can.TRecord fields ext ->
            Can.TRecord (CoreDict.map (\_ (Can.FieldType i t) -> Can.FieldType i (clearArrows t)) fields) ext

        Can.TUnit ->
            Can.TUnit

        Can.TTuple a b rest ->
            Can.TTuple (clearArrows a) (clearArrows b) (List.map clearArrows rest)

        Can.TAlias h n args real ->
            Can.TAlias h
                n
                (List.map (\( pn, t ) -> ( pn, clearArrows t )) args)
                (case real of
                    Can.Holey t ->
                        Can.Holey (clearArrows t)

                    Can.Filled t ->
                        Can.Filled (clearArrows t)
                )



-- ============================================================================
-- ====== SMALL HELPERS ======
-- ============================================================================


{-| Returns how many arguments one call of `func` may carry, or `Nothing` when
it is not a global or cycle member with a positive arity in `Gate.arity`.

The bound is the callee's predicted arity after this pass, capped by the
declared arity of the reference's own type. It is not the type's arrow count
alone: an arrow chain also counts the arrows of its result, so at
`b = s (k s) k` the reference to `s` has six arrows while `s bf uf x` takes
three, and merging six arguments into that call is a miscompile. It is not the
pre-pass count either: a definition written at an alias's arity, such as a
recursive `sequence`, takes one more parameter once expanded, and merging only
to the old count would leave a PAP behind.

-}
calleeArity : Ctx -> TOpt.Expr TypeIds.MVarId -> Maybe Int
calleeArity ctx func =
    let
        capped key meta =
            case CoreDict.get key ctx.gate.arity of
                Just arity ->
                    if arity <= 0 then
                        Nothing

                    else
                        Just (min arity (declaredArity meta.tipe))

                Nothing ->
                    Nothing
    in
    case func of
        TOpt.VarGlobal _ g meta ->
            capped (TOpt.toComparableGlobal g) meta

        TOpt.VarCycle _ home name meta ->
            capped (TOpt.toComparableGlobal (TOpt.Global home name)) meta

        _ ->
            -- Kernels included: with no graph node, nothing says where a
            -- kernel's first stage ends.
            Nothing


{-| Returns the attribution key of a call head: the comparable global of a global
or cycle member, `home.name` for a kernel, or `Nothing` for any other head.
-}
calleeName : TOpt.Expr TypeIds.MVarId -> Maybe String
calleeName func =
    case func of
        TOpt.VarGlobal _ g _ ->
            Just (TOpt.toComparableGlobal g)

        TOpt.VarCycle _ home name _ ->
            Just (TOpt.toComparableGlobal (TOpt.Global home name))

        TOpt.VarKernel _ _ home name _ ->
            Just (home ++ "." ++ name)

        _ ->
            Nothing


{-| Returns one fresh `_eta<n>` binder for each of the given types, with the
types' arrow slots cleared, and the counter advanced.

Elm source identifiers cannot begin with `_`, and the counter runs through the
whole pass, so these names collide with no source binder and with no other
binder this run makes.

-}
freshBinders : Ctx -> List (Can.Type TypeIds.MVarId) -> ( List ( Name, Can.Type TypeIds.MVarId ), Ctx )
freshBinders ctx types =
    let
        ( acc, next ) =
            List.foldl
                (\t ( out, n ) ->
                    ( ( "_eta" ++ String.fromInt n, clearArrows t ) :: out, n + 1 )
                )
                ( [], ctx.fresh )
                types
    in
    ( List.reverse acc, { ctx | fresh = next } )


{-| Returns a `VarLocal` reference to a binder.
-}
binderRef : ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId
binderRef ( name, tipe ) =
    TOpt.VarLocal name { tipe = tipe, tvar = Nothing }


{-| Returns the region of a call, global, cycle reference or tracked local, or
`A.zero` for any other expression.
-}
regionOf : TOpt.Expr TypeIds.MVarId -> A.Region
regionOf expr =
    case expr of
        TOpt.Call region _ _ _ ->
            region

        TOpt.VarGlobal region _ _ ->
            region

        TOpt.VarCycle region _ _ _ ->
            region

        TOpt.TrackedVarLocal region _ _ ->
            region

        _ ->
            A.zero


{-| Returns the region of the first parameter, or `A.zero` for an empty list.
-}
locatedRegion : List ( A.Located Name, Can.Type TypeIds.MVarId ) -> A.Region
locatedRegion params =
    case params of
        ( located, _ ) :: _ ->
            A.toRegion located

        [] ->
            A.zero


{-| Returns the element at index `i`, counting from 0, if there is one.
-}
indexOf : Int -> List a -> Maybe a
indexOf i xs =
    List.head (List.drop i xs)


{-| Returns `f` mapped over a list in order, threading the context through.
-}
mapList : Ctx -> List a -> (Ctx -> a -> ( b, Ctx )) -> ( List b, Ctx )
mapList ctx xs f =
    let
        ( acc, ctx1 ) =
            List.foldl
                (\x ( out, c ) ->
                    let
                        ( y, c1 ) =
                            f c x
                    in
                    ( y :: out, c1 )
                )
                ( [], ctx )
                xs
    in
    ( List.reverse acc, ctx1 )


{-| Returns `rebuild` applied to the expressions after `rewriteExpr`.
-}
mapExprs : Ctx -> List (TOpt.Expr TypeIds.MVarId) -> (List (TOpt.Expr TypeIds.MVarId) -> TOpt.Expr TypeIds.MVarId) -> ( TOpt.Expr TypeIds.MVarId, Ctx )
mapExprs ctx xs rebuild =
    Tuple.mapFirst rebuild (mapList ctx xs rewriteExpr)


{-| Returns the context with `f` applied to its metrics.
-}
bump : (Metrics -> Metrics) -> Ctx -> Ctx
bump f ctx =
    { ctx | metrics = f ctx.metrics }


{-| Returns the context with `bodiesSeen` increased by one.
-}
seeBody : Ctx -> Ctx
seeBody =
    bump (\m -> { m | bodiesSeen = m.bodiesSeen + 1 })


{-| Returns the metrics with the deficit histogram bucket for `n` increased: 1, 2, or 3 and above.
-}
countDeficit : Int -> Metrics -> Metrics
countDeficit n m =
    if n == 1 then
        { m | deficit1 = m.deficit1 + 1 }

    else if n == 2 then
        { m | deficit2 = m.deficit2 + 1 }

    else
        { m | deficit3 = m.deficit3 + 1 }


{-| Returns the counts with the one for `key` increased by one.
-}
tally : String -> CoreDict.Dict String Int -> CoreDict.Dict String Int
tally key d =
    CoreDict.update key (\v -> Just (1 + Maybe.withDefault 0 v)) d


{-| Where a definition the definition rule expands sits: a top-level
`Define` or `TrackedDefine`, or a function definition of a cycle. Each is
counted separately, as `defs` and `cycleDefs`.
-}
type Site
    = TopLevel
    | CycleMember


{-| Returns the metrics with the expansion counter for `site` increased by one.
-}
countSite : Site -> Metrics -> Metrics
countSite site m =
    case site of
        TopLevel ->
            { m | defs = m.defs + 1 }

        CycleMember ->
            { m | cycleDefs = m.cycleDefs + 1 }
