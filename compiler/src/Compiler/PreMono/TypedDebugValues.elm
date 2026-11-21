module Compiler.PreMono.TypedDebugValues exposing
    ( Metrics, emptyMetrics
    , run
    )

{-| Rewrites `Debug.toString` and `Debug.log` used as function values into
lambdas around saturated calls, before monomorphization, so that they print
through the type table like direct calls
(plans/constructor-representation-followups.md F3).

A saturated `Debug.toString x` or `Debug.log label x` is lowered with the type
of `x`, so it prints constructor and field names. A `Debug` kernel used as a
value is lowered as a closure over the kernel's untyped symbol, which prints a
custom value as `Ctor0 …` and a record as `{ f0 = … }`. This pass gives every
such value the shape a user's `show = Debug.toString` already has after
monomorphization: a function whose body is a saturated call.

The rules, applied bottom-up in every expression of every node:

  - `Debug.log label` applied to one more argument (`(Debug.log label) x`) is
    flattened into the saturated call `Debug.log label x`;
  - `Debug.toString` not in call position becomes `\_dbgN -> Debug.toString _dbgN`;
  - `Debug.log` not in call position becomes
    `\_dbgN _dbgM -> Debug.log _dbgN _dbgM`;
  - `Debug.log label` (one argument) becomes `\_dbgN -> Debug.log label _dbgN`,
    with a `label` that is not a literal or a variable bound outside the lambda
    first (`let _dbgN = label in …`), so it is evaluated once: it may itself
    call `Debug.log`.

Saturated calls and `Debug.todo` are left alone. A `Debug` function is matched
in both forms: `TOpt.VarDebug`, which user code holds, and a direct kernel
reference `Elm.Kernel.Debug.toString`/`log` (`TOpt.VarKernel`), except a node
whose whole body is such a reference (a kernel alias, such as elm/core's own
`toString = Elm.Kernel.Debug.toString`).

A `VarDebug` carries the generic type of `Debug`'s annotation, whose variables
`AssignMVarIds` resolves by name in the enclosing node's scope, so they may be
the enclosing definition's own `a` or `number`. The reference's type is
therefore freshened first (`Fresh.freshenType`), and the lambda's parameters
take the freshened types: monomorphization then fixes them from the context the
lambda is used in. Where the context leaves a parameter a type variable (a
let-bound value, a record field), the body prints untyped, as before.

Every node this pass builds goes through `Fresh.mintNewNode`, and a type it
places at a new position has its arrow slots cleared first, as in
`Compiler.PreMono.EtaExpand`.

@docs Metrics, emptyMetrics
@docs run

-}

import Compiler.Core.Annotation as A
import Compiler.Core.Name exposing (Name)
import Compiler.Core.TypeIds as TypeIds
import Compiler.IR.Canonical as Can
import Compiler.IR.Typed.Optimized as TOpt
import Compiler.PreMono.AssignMVarIds as AssignMVarIds
import Compiler.PreMono.Fresh as Fresh
import Data.Map as Dict
import Data.NonEmptyList as NE
import Dict as CoreDict



-- ====== METRICS ======


{-| What one run did: `rewritten` counts the `Debug` values turned into lambdas,
`flattened` the `(Debug.log label) x` calls made saturated.
-}
type alias Metrics =
    { rewritten : Int
    , flattened : Int
    }


{-| Metrics with every count at zero.
-}
emptyMetrics : Metrics
emptyMetrics =
    { rewritten = 0, flattened = 0 }


type alias Ctx =
    { state : AssignMVarIds.GlobalMVarState
    , fresh : Int
    , metrics : Metrics
    }



-- ====== THE PASS ======


{-| Rewrites every node of `graph`, and returns the graph, the advanced id
state, and the metrics.
-}
run :
    AssignMVarIds.GlobalMVarState
    -> TOpt.GlobalGraph TypeIds.MVarId
    -> ( TOpt.GlobalGraph TypeIds.MVarId, AssignMVarIds.GlobalMVarState, Metrics )
run state (TOpt.GlobalGraph nodes fields annotations schemeRoots varSupers) =
    let
        ( newNodes, ctx1 ) =
            Dict.foldl
                (\g node ( acc, c ) ->
                    let
                        ( newNode, c1 ) =
                            rewriteNode c node
                    in
                    ( Dict.insert TOpt.toComparableGlobal g newNode acc, c1 )
                )
                ( Dict.empty, { state = state, fresh = 0, metrics = emptyMetrics } )
                nodes
    in
    ( TOpt.GlobalGraph newNodes fields annotations schemeRoots varSupers, ctx1.state, ctx1.metrics )


rewriteNode : Ctx -> TOpt.Node TypeIds.MVarId -> ( TOpt.Node TypeIds.MVarId, Ctx )
rewriteNode ctx node =
    case node of
        TOpt.Define (TOpt.VarKernel _ _ _ _ _) _ _ ->
            ( node, ctx )

        TOpt.TrackedDefine _ (TOpt.VarKernel _ _ _ _ _) _ _ ->
            ( node, ctx )

        TOpt.Define expr deps meta ->
            Tuple.mapFirst (\e -> TOpt.Define e deps meta) (rewriteExpr ctx expr)

        TOpt.TrackedDefine region expr deps meta ->
            Tuple.mapFirst (\e -> TOpt.TrackedDefine region e deps meta) (rewriteExpr ctx expr)

        TOpt.Cycle names values funcDefs deps ->
            let
                ( newValues, ctxV ) =
                    mapList ctx values (\c ( n, e ) -> Tuple.mapFirst (Tuple.pair n) (rewriteExpr c e))

                ( newFuncs, ctxF ) =
                    mapList ctxV funcDefs rewriteDef
            in
            ( TOpt.Cycle names newValues newFuncs deps, ctxF )

        TOpt.PortIncoming expr deps meta ->
            Tuple.mapFirst (\e -> TOpt.PortIncoming e deps meta) (rewriteExpr ctx expr)

        TOpt.PortOutgoing expr deps meta ->
            Tuple.mapFirst (\e -> TOpt.PortOutgoing e deps meta) (rewriteExpr ctx expr)

        _ ->
            ( node, ctx )


rewriteDef : Ctx -> TOpt.Def TypeIds.MVarId -> ( TOpt.Def TypeIds.MVarId, Ctx )
rewriteDef ctx def =
    case def of
        TOpt.Def region name bound tipe ->
            Tuple.mapFirst (\b -> TOpt.Def region name b tipe) (rewriteExpr ctx bound)

        TOpt.TailDef region name args body tipe tvar ->
            Tuple.mapFirst (\b -> TOpt.TailDef region name args b tipe tvar) (rewriteExpr ctx body)


{-| Rewrites `expr`, its children first. A `Debug.toString` or `Debug.log` that
is not the function of a call becomes a lambda (`valueLambda`); calls are handled
by `rewriteCall`.
-}
rewriteExpr : Ctx -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
rewriteExpr ctx expr =
    case expr of
        TOpt.VarDebug _ _ _ _ _ ->
            valueOrSelf ctx expr

        TOpt.VarKernel _ _ _ _ _ ->
            valueOrSelf ctx expr

        TOpt.Call region func args meta ->
            let
                ( args1, ctx1 ) =
                    mapList ctx args rewriteExpr

                ( func1, ctx2 ) =
                    rewriteCallee ctx1 func
            in
            rewriteCall ctx2 region func1 args1 meta

        TOpt.List region items meta ->
            Tuple.mapFirst (\xs -> TOpt.List region xs meta) (mapList ctx items rewriteExpr)

        TOpt.Function lamId params body meta ->
            Tuple.mapFirst (\b -> TOpt.Function lamId params b meta) (rewriteExpr ctx body)

        TOpt.TrackedFunction lamId params body meta ->
            Tuple.mapFirst (\b -> TOpt.TrackedFunction lamId params b meta) (rewriteExpr ctx body)

        TOpt.TailCall name args meta ->
            Tuple.mapFirst (\xs -> TOpt.TailCall name xs meta)
                (mapList ctx args (\c ( n, e ) -> Tuple.mapFirst (Tuple.pair n) (rewriteExpr c e)))

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
            Tuple.mapFirst (\b -> TOpt.Destruct destructor b meta) (rewriteExpr ctx body)

        TOpt.Case label root decider jumps meta ->
            let
                ( newDecider, ctx1 ) =
                    rewriteDecider ctx decider

                ( newJumps, ctx2 ) =
                    mapList ctx1 jumps (\c ( i, e ) -> Tuple.mapFirst (Tuple.pair i) (rewriteExpr c e))
            in
            ( TOpt.Case label root newDecider newJumps meta, ctx2 )

        TOpt.Access inner region field meta ->
            Tuple.mapFirst (\i -> TOpt.Access i region field meta) (rewriteExpr ctx inner)

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
                    case rest of
                        Just c ->
                            Tuple.mapFirst Just (rewriteExpr ctx2 c)

                        Nothing ->
                            ( Nothing, ctx2 )
            in
            ( TOpt.Tuple region a1 b1 rest1 meta, ctx3 )

        _ ->
            ( expr, ctx )


{-| Rewrites the function of a call. A `Debug` reference there is a call, not a
value, and stays; so does the `Debug.log label` of `(Debug.log label) x`, whose
label is rewritten, so that `rewriteCall` can flatten it.
-}
rewriteCallee : Ctx -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
rewriteCallee ctx func =
    case ( debugRef func, func ) of
        ( Just _, _ ) ->
            ( func, ctx )

        ( Nothing, TOpt.Call region dbg [ label ] meta ) ->
            if Maybe.map .name (debugRef dbg) == Just "log" then
                Tuple.mapFirst (\l -> TOpt.Call region dbg [ l ] meta) (rewriteExpr ctx label)

            else
                rewriteExpr ctx func

        _ ->
            rewriteExpr ctx func


{-| Builds the call of `func` to `args`, applying the flattening and the
partial-application rule.
-}
rewriteCall : Ctx -> A.Region -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
rewriteCall ctx region func args meta =
    case ( func, args ) of
        ( TOpt.Call _ dbg [ label ] _, x :: more ) ->
            if Maybe.map .name (debugRef dbg) == Just "log" then
                flatten ctx region dbg label x more meta

            else
                ( TOpt.Call region func args meta, ctx )

        _ ->
            case ( debugRef func, args ) of
                ( Just ref, [ label ] ) ->
                    if ref.name == "log" then
                        partialLog ctx region ref label meta

                    else
                        ( TOpt.Call region func args meta, ctx )

                _ ->
                    ( TOpt.Call region func args meta, ctx )


{-| `Debug.log label x` from `(Debug.log label) x`, applied to the arguments
`more` past `x` if any.
-}
flatten : Ctx -> A.Region -> TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> TOpt.Meta TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
flatten ctx region dbg label x more meta =
    let
        ctx1 =
            bump (\m -> { m | flattened = m.flattened + 1 }) ctx
    in
    if List.isEmpty more then
        ( TOpt.Call region dbg [ label, x ] meta, ctx1 )

    else
        ( TOpt.Call region (TOpt.Call region dbg [ label, x ] (plainMeta (TOpt.typeOf x))) more meta, ctx1 )


{-| A reference to `Debug.toString` or `Debug.log`, in either form, with its
name, its meta, and a way to rebuild it with another meta.
-}
type alias DebugRef =
    { name : Name
    , meta : TOpt.Meta TypeIds.MVarId
    , rebuild : TOpt.Meta TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId
    }


debugRef : TOpt.Expr TypeIds.MVarId -> Maybe DebugRef
debugRef expr =
    case expr of
        TOpt.VarDebug region name home unused meta ->
            if name == "toString" || name == "log" then
                Just { name = name, meta = meta, rebuild = TOpt.VarDebug region name home unused }

            else
                Nothing

        TOpt.VarKernel region prefix "Debug" name meta ->
            if name == "toString" || name == "log" then
                Just { name = name, meta = meta, rebuild = TOpt.VarKernel region prefix "Debug" name }

            else
                Nothing

        _ ->
            Nothing


{-| `expr` rewritten by `valueLambda` when it is a `Debug.toString` or
`Debug.log` reference, else `expr` itself.
-}
valueOrSelf : Ctx -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
valueOrSelf ctx expr =
    case debugRef expr of
        Just ref ->
            valueLambda ctx ref expr

        Nothing ->
            ( expr, ctx )


{-| `\_dbgN -> Debug.toString _dbgN` for "toString", or
`\_dbgN _dbgM -> Debug.log _dbgN _dbgM` for "log". A reference whose type is
not the expected arrow spine is left as it is (`original`).
-}
valueLambda : Ctx -> DebugRef -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
valueLambda ctx ref original =
    let
        ( freshened, state1 ) =
            Fresh.freshenType CoreDict.empty ctx.state ref.meta.tipe

        ( paramTypes, resultType ) =
            spine freshened

        arity =
            if ref.name == "log" then
                2

            else
                1
    in
    if List.length paramTypes /= arity then
        ( original, ctx )

    else
        let
            ( binders, ctx1 ) =
                freshBinders { ctx | state = state1 } paramTypes

            body =
                TOpt.Call A.zero
                    (ref.rebuild { tipe = freshened, tvar = ref.meta.tvar })
                    (List.map binderRef binders)
                    (plainMeta (clearArrows resultType))

            lambda =
                TOpt.Function Nothing binders body (plainMeta (clearArrows freshened))
        in
        mint (bump (\m -> { m | rewritten = m.rewritten + 1 }) ctx1) lambda


{-| `\_dbgN -> Debug.log label _dbgN` for the one-argument call `Debug.log label`,
with a non-trivial `label` let-bound outside the lambda.
-}
partialLog : Ctx -> A.Region -> DebugRef -> TOpt.Expr TypeIds.MVarId -> TOpt.Meta TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
partialLog ctx region ref label callMeta =
    let
        ( freshened, state1 ) =
            Fresh.freshenType CoreDict.empty ctx.state ref.meta.tipe
    in
    case spine freshened of
        ( [ _, valueType ], resultType ) ->
            let
                ( binders, ctx1 ) =
                    freshBinders { ctx | state = state1 } [ valueType ]

                ( labelRef, wrap, ctx2 ) =
                    if trivial label then
                        ( label, identity, ctx1 )

                    else
                        let
                            labelName =
                                "_dbg" ++ String.fromInt ctx1.fresh

                            labelType =
                                TOpt.typeOf label
                        in
                        ( TOpt.VarLocal labelName (plainMeta labelType)
                        , \e -> TOpt.Let (TOpt.Def region labelName label labelType) e (TOpt.metaOf e)
                        , { ctx1 | fresh = ctx1.fresh + 1 }
                        )

                body =
                    TOpt.Call region
                        (ref.rebuild { tipe = freshened, tvar = ref.meta.tvar })
                        (labelRef :: List.map binderRef binders)
                        (plainMeta (clearArrows resultType))

                lambdaType =
                    clearArrows (Can.TLambda Can.noArrow valueType resultType)

                lambda =
                    TOpt.Function Nothing binders body (plainMeta lambdaType)
            in
            mint (bump (\m -> { m | rewritten = m.rewritten + 1 }) ctx2) (wrap lambda)

        _ ->
            ( TOpt.Call region (ref.rebuild ref.meta) [ label ] callMeta, ctx )


{-| Whether evaluating `expr` again inside a lambda costs nothing and has no
effect: a literal, or a reference to a variable or a global.
-}
trivial : TOpt.Expr TypeIds.MVarId -> Bool
trivial expr =
    case expr of
        TOpt.Str _ _ _ ->
            True

        TOpt.Chr _ _ _ ->
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

        _ ->
            False



-- ====== HELPERS ======


mint : Ctx -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
mint ctx expr =
    let
        ( minted, state1 ) =
            Fresh.mintNewNode ctx.state expr
    in
    ( minted, { ctx | state = state1 } )


bump : (Metrics -> Metrics) -> Ctx -> Ctx
bump f ctx =
    { ctx | metrics = f ctx.metrics }


plainMeta : Can.Type TypeIds.MVarId -> TOpt.Meta TypeIds.MVarId
plainMeta tipe =
    { tipe = tipe, tvar = Nothing }


{-| The parameter types and the final result of an arrow spine.
-}
spine : Can.Type TypeIds.MVarId -> ( List (Can.Type TypeIds.MVarId), Can.Type TypeIds.MVarId )
spine tipe =
    case tipe of
        Can.TLambda _ a b ->
            let
                ( rest, result ) =
                    spine b
            in
            ( a :: rest, result )

        _ ->
            ( [], tipe )


freshBinders : Ctx -> List (Can.Type TypeIds.MVarId) -> ( List ( Name, Can.Type TypeIds.MVarId ), Ctx )
freshBinders ctx types =
    List.foldl
        (\t ( acc, c ) -> ( ( "_dbg" ++ String.fromInt c.fresh, clearArrows t ) :: acc, { c | fresh = c.fresh + 1 } ))
        ( [], ctx )
        types
        |> Tuple.mapFirst List.reverse


binderRef : ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId
binderRef ( name, tipe ) =
    TOpt.VarLocal name (plainMeta tipe)


mapList : Ctx -> List a -> (Ctx -> a -> ( b, Ctx )) -> ( List b, Ctx )
mapList ctx items f =
    List.foldl
        (\item ( acc, c ) ->
            let
                ( item1, c1 ) =
                    f c item
            in
            ( item1 :: acc, c1 )
        )
        ( [], ctx )
        items
        |> Tuple.mapFirst List.reverse


mapNonempty : Ctx -> NE.Nonempty a -> (Ctx -> a -> ( b, Ctx )) -> ( NE.Nonempty b, Ctx )
mapNonempty ctx (NE.Nonempty x xs) f =
    let
        ( y, ctx1 ) =
            f ctx x

        ( ys, ctx2 ) =
            mapList ctx1 xs f
    in
    ( NE.Nonempty y ys, ctx2 )


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
                    mapNonempty ctx branches (\c ( t, d ) -> Tuple.mapFirst (Tuple.pair t) (rewriteDecider c d))

                ( newFallback, ctx2 ) =
                    rewriteDecider ctx1 fallback
            in
            ( TOpt.FanOut path newBranches newFallback, ctx2 )


{-| `tipe` with every arrow slot cleared, so that `Fresh.mintNewNode` gives each
a fresh id at its new position. Type-variable ids are kept.
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
            Can.TTuple (clearArrows a) (clearArrows b) (Maybe.map clearArrows rest)

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
