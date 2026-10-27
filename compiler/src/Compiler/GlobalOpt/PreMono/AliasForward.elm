module Compiler.GlobalOpt.PreMono.AliasForward exposing
    ( run, Metrics, emptyMetrics
    , Target(..), aliasMap
    )

{-| Calls through one-line wrapper definitions hide the function that is really
called, so this pass, which runs before monomorphization, points each
reference at the real target instead.

An _alias definition_ is a top-level value with no parameters whose whole body
is a bare reference to another global or to a kernel, such as
`add = Elm.Kernel.Basics.add` or `fromChars = P.text`. Without this pass a call
`add x y` stays a call to the wrapper, and later analysis sees the wrapper
rather than the kernel or function behind it.

_Forwarding_ is reference substitution, not inlining. A reference to an alias
`f` is replaced by a reference to `f`'s target, carrying the caller's own
reference metadata (its type) unchanged. No node, type variable, lambda id or
arrow id is created, so the `GlobalMVarState` passes through `run` untouched.

`aliasMap` finds the alias definitions and follows chains (`f = g`, `g = h`)
to their final target. A target is either another global (`ToGlobal`) or a
kernel (`ToKernel`).

`run` then rewrites every expression in the graph, by position:

  - A call or value reference to a `ToGlobal` alias is forwarded.
  - A call of a `ToKernel` alias is forwarded, as a direct kernel call, only
    when three things hold. The target's `abiFixed` flag must be true (see
    `Target`). The caller's reference type must have the same outer arrow spine as
    the kernel's own type, because synthesized references can carry
    placeholder types that are not function types at all. And the call must
    supply exactly as many arguments as that spine has; an under-applied or
    over-applied call keeps the alias. Each kept call is counted by reason.
  - A value reference to a `ToKernel` alias, one not in call position, is
    always kept, and counted.
  - The alias definitions themselves are not rewritten.

The walk covers every node kind that holds an expression, `Cycle` bodies
included, so a reference is treated the same way wherever it occurs. A node
whose body gained a reference to a target gets that target added to its
`deps` (`TOpt.toKernelGlobal home` for a kernel target); the alias it no
longer references is left in `deps`.

Most of the file is the expression walk and the `Metrics` counters it keeps.

@docs run, Metrics, emptyMetrics
@docs Target, aliasMap

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Monomorphize.EntryPrep as EntryPrep
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Dict as CoreDict



-- ============================================================================
-- ====== METRICS ======
-- ============================================================================


{-| The counts one run of the pass reports: what `aliasMap` found, and what the
walk forwarded and kept.

`chainsMax` is the longest chain followed, in hops from an alias to its final
target (`f = g` is 1). `cycles` counts aliases whose chain revisits an alias,
not distinct cycles. `bodiesSeen` counts the node bodies walked, so a zero
rewrite count can be told apart from a walk that saw nothing. `depsExtended`
counts walked nodes in which at least one reference was forwarded, not the
entries added; those targets may already have been in `deps`.

-}
type alias Metrics =
    { aliases : Int
    , globalTargets : Int
    , kernelTargets : Int
    , chainsMax : Int
    , cycles : Int
    , callsRewritten : Int
    , callsRewrittenKernel : Int -- the subset of `callsRewritten` whose target is a kernel
    , callsKeptKernelPartial : Int -- under-applied kernel-alias calls, kept
    , callsKeptKernelOver : Int -- over-applied kernel-alias calls, kept
    , callsKeptKernelPoly : Int -- kernel-alias calls kept because `abiFixed` is false
    , callsKeptKernelMeta : Int -- kernel-alias calls kept because the reference's spine differs from the kernel's
    , argRefsRewritten : Int -- value references (not in call position) forwarded
    , argRefsKeptKernel : Int -- value references to kernel aliases, kept
    , depsExtended : Int
    , bodiesSeen : Int

    -- forwarded references per target, keyed by comparable global or `k|Home.name`
    , byTarget : CoreDict.Dict String Int
    }


{-| Metrics with every count zero and no targets, the starting point `run`
fills in.
-}
emptyMetrics : Metrics
emptyMetrics =
    { aliases = 0
    , globalTargets = 0
    , kernelTargets = 0
    , chainsMax = 0
    , cycles = 0
    , callsRewritten = 0
    , callsRewrittenKernel = 0
    , callsKeptKernelPartial = 0
    , callsKeptKernelOver = 0
    , callsKeptKernelPoly = 0
    , callsKeptKernelMeta = 0
    , argRefsRewritten = 0
    , argRefsKeptKernel = 0
    , depsExtended = 0
    , bodiesSeen = 0
    , byTarget = CoreDict.empty
    }



-- ============================================================================
-- ====== THE ALIAS MAP ======
-- ============================================================================


{-| The final target of an alias definition, once chains are followed.

`ToGlobal` names another global, one that is not itself an alias definition.

`ToKernel` carries the kernel's prefix, home and name, then its spine and
`abiFixed`. The spine is the number of arguments along the outer arrow spine
of the kernel's type as the alias body records it, aliases followed; a call is
forwarded only when it supplies exactly that many. `abiFixed` is the condition
under which such a call may be forwarded at all: the kernel's home is not
`Debug` (a module in `KernelAbi.alwaysPolymorphicModules`), and either its type
has no free type variable or it is in `KernelAbi.suffixSelectingKernels`, whose
call sites select a type-specific variant by name. Otherwise the kernel's
signature is derived from each use's type, as `KernelAbi` describes, and
forwarding the caller's concrete type to it would be unsafe.

-}
type Target
    = ToGlobal TOpt.Global
    | ToKernel Name Name Name Int Bool


{-| Returns the alias definitions of a graph, keyed by comparable global and
each resolved to its final target, together with the longest chain followed
and the number of aliases dropped because their chain revisits an alias.

An alias definition is a `Define` or `TrackedDefine` whose body is exactly a
bare `VarGlobal` or `VarKernel`, other than the synthesized flags decoder
(`EntryPrep.flagsDecoderName`). Any other body, and any other node kind, is not
an alias. Chain length is counted in hops: `f = inc` is 1, and `f = g`,
`g = h` is 2.

-}
aliasMap : TOpt.GlobalGraph TypeIds.MVarId -> ( CoreDict.Dict String Target, Int, Int )
aliasMap (TOpt.GlobalGraph nodes _ _ _ _) =
    let
        raw : CoreDict.Dict String Target
        raw =
            Dict.foldl
                (\g node acc ->
                    case rawTarget g node of
                        Just t ->
                            CoreDict.insert (TOpt.toComparableGlobal g) t acc

                        Nothing ->
                            acc
                )
                CoreDict.empty
                nodes
    in
    CoreDict.foldl
        (\key t0 ( acc, maxDepth, cycles ) ->
            case chase raw (CoreDict.singleton key ()) 1 t0 of
                Just ( t, depth ) ->
                    ( CoreDict.insert key t acc, max maxDepth depth, cycles )

                Nothing ->
                    ( acc, maxDepth, cycles + 1 )
        )
        ( CoreDict.empty, 0, 0 )
        raw


{-| Returns the unresolved target of a node if it is an alias definition:
a `Define` or `TrackedDefine` with a bare-reference body, excluding the
synthesized flags decoder.
-}
rawTarget : TOpt.Global -> TOpt.Node TypeIds.MVarId -> Maybe Target
rawTarget (TOpt.Global _ nodeName) node =
    if nodeName == EntryPrep.flagsDecoderName then
        Nothing

    else
        case node of
            TOpt.Define body _ _ ->
                bareReference body

            TOpt.TrackedDefine _ body _ _ ->
                bareReference body

            _ ->
                Nothing


{-| Returns the target a body names when the body is exactly a `VarGlobal` or
`VarKernel`, and `Nothing` for any other expression.
-}
bareReference : TOpt.Expr TypeIds.MVarId -> Maybe Target
bareReference body =
    case body of
        TOpt.VarGlobal _ g _ ->
            Just (ToGlobal g)

        TOpt.VarKernel _ kernelPrefix home name meta ->
            Just (ToKernel kernelPrefix home name (arrowSpine meta.tipe) (abiFixedBy home name meta.tipe))

        _ ->
            Nothing


{-| Returns whether a saturated call of kernel `home.name`, whose reference in
the alias body has type `tipe`, may be forwarded: false for a module in
`KernelAbi.alwaysPolymorphicModules`, and otherwise true when `tipe` has no
free type variable or the kernel is in `KernelAbi.suffixSelectingKernels`.
-}
abiFixedBy : Name -> Name -> Can.Type TypeIds.MVarId -> Bool
abiFixedBy home name tipe =
    not (EverySet.member List.singleton home KernelAbi.alwaysPolymorphicModules)
        && (not (KernelAbi.hasAnyFreeVar tipe)
                || EverySet.member KernelAbi.comparePair ( home, name ) KernelAbi.suffixSelectingKernels
           )


{-| Returns the final target reached from `t` by following `ToGlobal` links
through the unresolved map, with the hop count, starting from `depth`.
Returns `Nothing` when the chain reaches a key already in `visited`.
-}
chase : CoreDict.Dict String Target -> CoreDict.Dict String () -> Int -> Target -> Maybe ( Target, Int )
chase raw visited depth t =
    case t of
        ToKernel _ _ _ _ _ ->
            Just ( t, depth )

        ToGlobal g ->
            let
                key =
                    TOpt.toComparableGlobal g
            in
            if CoreDict.member key visited then
                Nothing

            else
                case CoreDict.get key raw of
                    Just next ->
                        chase raw (CoreDict.insert key () visited) (depth + 1) next

                    Nothing ->
                        Just ( t, depth )


{-| Returns the number of arrows along a type's outer spine, following type
aliases; arrows inside an argument type are not counted, so
`(a -> b) -> List a -> List b` gives 2.
-}
arrowSpine : Can.Type TypeIds.MVarId -> Int
arrowSpine t =
    case t of
        Can.TLambda _ _ to ->
            1 + arrowSpine to

        Can.TAlias _ _ _ (Can.Filled real) ->
            arrowSpine real

        Can.TAlias _ _ _ (Can.Holey real) ->
            arrowSpine real

        _ ->
            0



-- ============================================================================
-- ====== ENTRY POINT ======
-- ============================================================================


{-| The state threaded through the walk: the resolved alias map, the metrics so
far, and the targets the current node's rewrites have referenced.

`depsAdd` holds targets for the node being walked only; `extendDeps` empties it
when the node is finished.

-}
type alias Ctx =
    { aliases : CoreDict.Dict String Target
    , metrics : Metrics
    , depsAdd : List TOpt.Global
    }


{-| Returns the graph with references to alias definitions forwarded to their
targets, the id state unchanged, and the metrics of the run.

When `aliasForward` is off in the config, the walk still runs and its metrics
are returned, but the graph comes back unchanged.

-}
run :
    Config.InlineConfig
    -> AssignMVarIds.GlobalMVarState
    -> TOpt.GlobalGraph TypeIds.MVarId
    -> ( TOpt.GlobalGraph TypeIds.MVarId, AssignMVarIds.GlobalMVarState, Metrics )
run cfg state graph =
    let
        ( aliases, chainsMax, cycles ) =
            aliasMap graph

        ( globalTargets, kernelTargets ) =
            CoreDict.foldl
                (\_ t ( gs, ks ) ->
                    case t of
                        ToGlobal _ ->
                            ( gs + 1, ks )

                        ToKernel _ _ _ _ _ ->
                            ( gs, ks + 1 )
                )
                ( 0, 0 )
                aliases

        ctx0 : Ctx
        ctx0 =
            { aliases = aliases
            , metrics =
                { emptyMetrics
                    | aliases = CoreDict.size aliases
                    , globalTargets = globalTargets
                    , kernelTargets = kernelTargets
                    , chainsMax = chainsMax
                    , cycles = cycles
                }
            , depsAdd = []
            }

        ( graph1, ctx1 ) =
            rewriteGraph ctx0 graph
    in
    if cfg.aliasForward then
        ( graph1, state, ctx1.metrics )

    else
        ( graph, state, ctx1.metrics )


{-| Returns the graph with every node rewritten by `rewriteNode`, and the
context after the last node.
-}
rewriteGraph : Ctx -> TOpt.GlobalGraph TypeIds.MVarId -> ( TOpt.GlobalGraph TypeIds.MVarId, Ctx )
rewriteGraph ctx (TOpt.GlobalGraph nodes fields annotations schemeRoots varSupers) =
    let
        ( newNodes, ctx1 ) =
            Dict.foldl
                (\g node ( acc, c ) ->
                    let
                        ( newNode, c1 ) =
                            rewriteNode c g node
                    in
                    ( Dict.insert TOpt.toComparableGlobal g newNode acc, c1 )
                )
                ( Dict.empty, ctx )
                nodes
    in
    ( TOpt.GlobalGraph newNodes fields annotations schemeRoots varSupers, ctx1 )


{-| Returns node `g` with its expressions rewritten and its `deps` extended.
`Define`, `TrackedDefine`, both port kinds and every value and function
definition of a `Cycle` are walked; each walked body counts in `bodiesSeen`.
An alias definition, and a node kind with no expression, is returned as it is.
-}
rewriteNode : Ctx -> TOpt.Global -> TOpt.Node TypeIds.MVarId -> ( TOpt.Node TypeIds.MVarId, Ctx )
rewriteNode ctx g node =
    if CoreDict.member (TOpt.toComparableGlobal g) ctx.aliases then
        ( node, ctx )

    else
        case node of
            TOpt.Define expr deps meta ->
                let
                    ( e1, c1 ) =
                        rewriteExpr (seeBody ctx) expr

                    ( deps1, c2 ) =
                        extendDeps c1 deps
                in
                ( TOpt.Define e1 deps1 meta, c2 )

            TOpt.TrackedDefine region expr deps meta ->
                let
                    ( e1, c1 ) =
                        rewriteExpr (seeBody ctx) expr

                    ( deps1, c2 ) =
                        extendDeps c1 deps
                in
                ( TOpt.TrackedDefine region e1 deps1 meta, c2 )

            TOpt.PortIncoming expr deps meta ->
                let
                    ( e1, c1 ) =
                        rewriteExpr (seeBody ctx) expr

                    ( deps1, c2 ) =
                        extendDeps c1 deps
                in
                ( TOpt.PortIncoming e1 deps1 meta, c2 )

            TOpt.PortOutgoing expr deps meta ->
                let
                    ( e1, c1 ) =
                        rewriteExpr (seeBody ctx) expr

                    ( deps1, c2 ) =
                        extendDeps c1 deps
                in
                ( TOpt.PortOutgoing e1 deps1 meta, c2 )

            TOpt.Cycle names values funcDefs deps ->
                let
                    ( newValues, ctxV ) =
                        List.foldl
                            (\( n, e ) ( acc, c ) ->
                                let
                                    ( e1, c1 ) =
                                        rewriteExpr (seeBody c) e
                                in
                                ( ( n, e1 ) :: acc, c1 )
                            )
                            ( [], ctx )
                            values

                    ( newFuncs, ctxF ) =
                        List.foldl
                            (\def ( acc, c ) ->
                                let
                                    ( d1, c1 ) =
                                        rewriteDef (seeBody c) def
                                in
                                ( d1 :: acc, c1 )
                            )
                            ( [], ctxV )
                            funcDefs

                    ( deps1, ctxD ) =
                        extendDeps ctxF deps
                in
                ( TOpt.Cycle names (List.reverse newValues) (List.reverse newFuncs) deps1, ctxD )

            _ ->
                ( node, ctx )


{-| Returns `deps` with every target in the context's `depsAdd` inserted, and
the context with `depsAdd` emptied and, if `depsAdd` was
non-empty, `depsExtended` raised by one.
-}
extendDeps : Ctx -> EverySet String TOpt.Global -> ( EverySet String TOpt.Global, Ctx )
extendDeps ctx deps =
    case ctx.depsAdd of
        [] ->
            ( deps, ctx )

        adds ->
            ( List.foldl (\g acc -> EverySet.insert TOpt.toComparableGlobal g acc) deps adds
            , { ctx
                | depsAdd = []
                , metrics = (\m -> { m | depsExtended = m.depsExtended + 1 }) ctx.metrics
              }
            )



-- ============================================================================
-- ====== THE WALK ======
-- ============================================================================


{-| Returns the expression with every alias reference in it forwarded under the
rules in the module docstring, recording each forward or kept reference in
the context.

Only two arms change anything: a `Call` whose callee is a `VarGlobal` naming an
alias, and a `VarGlobal` naming an alias anywhere else. Every other arm only
walks its sub-expressions. Arguments are walked before the callee is examined.

-}
rewriteExpr : Ctx -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Ctx )
rewriteExpr ctx expr =
    case expr of
        TOpt.Call region func args meta ->
            let
                ( args1, c1 ) =
                    rewriteList ctx args
            in
            case func of
                TOpt.VarGlobal fr f fMeta ->
                    case CoreDict.get (TOpt.toComparableGlobal f) c1.aliases of
                        Just (ToGlobal g) ->
                            ( TOpt.Call region (TOpt.VarGlobal fr g fMeta) args1 meta
                            , forwardedCall g c1
                            )

                        Just (ToKernel kernelPrefix home name spine abiFixed) ->
                            let
                                argCount =
                                    List.length args1
                            in
                            if not abiFixed then
                                ( TOpt.Call region func args1 meta
                                , bump (\m -> { m | callsKeptKernelPoly = m.callsKeptKernelPoly + 1 }) c1
                                )

                            else if arrowSpine fMeta.tipe /= spine then
                                ( TOpt.Call region func args1 meta
                                , bump (\m -> { m | callsKeptKernelMeta = m.callsKeptKernelMeta + 1 }) c1
                                )

                            else if argCount == spine then
                                ( TOpt.Call region (TOpt.VarKernel fr kernelPrefix home name fMeta) args1 meta
                                , forwardedKernelCall home name c1
                                )

                            else if argCount < spine then
                                ( TOpt.Call region func args1 meta
                                , bump (\m -> { m | callsKeptKernelPartial = m.callsKeptKernelPartial + 1 }) c1
                                )

                            else
                                ( TOpt.Call region func args1 meta
                                , bump (\m -> { m | callsKeptKernelOver = m.callsKeptKernelOver + 1 }) c1
                                )

                        Nothing ->
                            ( TOpt.Call region func args1 meta, c1 )

                _ ->
                    let
                        ( func1, c2 ) =
                            rewriteExpr c1 func
                    in
                    ( TOpt.Call region func1 args1 meta, c2 )

        TOpt.VarGlobal fr f fMeta ->
            case CoreDict.get (TOpt.toComparableGlobal f) ctx.aliases of
                Just (ToGlobal g) ->
                    ( TOpt.VarGlobal fr g fMeta, forwardedValue g ctx )

                Just (ToKernel _ _ _ _ _) ->
                    ( expr, bump (\m -> { m | argRefsKeptKernel = m.argRefsKeptKernel + 1 }) ctx )

                Nothing ->
                    ( expr, ctx )

        TOpt.Function srcLam params body meta ->
            mapBody ctx body (\b -> TOpt.Function srcLam params b meta)

        TOpt.TrackedFunction srcLam params body meta ->
            mapBody ctx body (\b -> TOpt.TrackedFunction srcLam params b meta)

        TOpt.Let def body meta ->
            let
                ( def1, c1 ) =
                    rewriteDef ctx def

                ( body1, c2 ) =
                    rewriteExpr c1 body
            in
            ( TOpt.Let def1 body1 meta, c2 )

        TOpt.Destruct d body meta ->
            mapBody ctx body (\b -> TOpt.Destruct d b meta)

        TOpt.If branches final meta ->
            let
                ( branches1, c1 ) =
                    List.foldl
                        (\( cond, t ) ( acc, c ) ->
                            let
                                ( cond1, ca ) =
                                    rewriteExpr c cond

                                ( t1, cb ) =
                                    rewriteExpr ca t
                            in
                            ( ( cond1, t1 ) :: acc, cb )
                        )
                        ( [], ctx )
                        branches

                ( final1, c2 ) =
                    rewriteExpr c1 final
            in
            ( TOpt.If (List.reverse branches1) final1 meta, c2 )

        TOpt.Case n1 n2 decider branches meta ->
            let
                ( decider1, c0 ) =
                    rewriteDecider ctx decider

                ( branches1, c1 ) =
                    List.foldl
                        (\( i, e ) ( acc, c ) ->
                            let
                                ( e1, c2 ) =
                                    rewriteExpr c e
                            in
                            ( ( i, e1 ) :: acc, c2 )
                        )
                        ( [], c0 )
                        branches
            in
            ( TOpt.Case n1 n2 decider1 (List.reverse branches1) meta, c1 )

        TOpt.List region items meta ->
            let
                ( items1, c1 ) =
                    rewriteList ctx items
            in
            ( TOpt.List region items1 meta, c1 )

        TOpt.Tuple region a b rest meta ->
            let
                ( a1, c1 ) =
                    rewriteExpr ctx a

                ( b1, c2 ) =
                    rewriteExpr c1 b

                ( rest1, c3 ) =
                    rewriteList c2 rest
            in
            ( TOpt.Tuple region a1 b1 rest1 meta, c3 )

        TOpt.Access inner region field meta ->
            mapBody ctx inner (\i -> TOpt.Access i region field meta)

        TOpt.TailCall name args meta ->
            let
                ( args1, c1 ) =
                    List.foldl
                        (\( n, e ) ( acc, c ) ->
                            let
                                ( e1, c2 ) =
                                    rewriteExpr c e
                            in
                            ( ( n, e1 ) :: acc, c2 )
                        )
                        ( [], ctx )
                        args
            in
            ( TOpt.TailCall name (List.reverse args1) meta, c1 )

        TOpt.Record fields meta ->
            let
                ( fields1, c1 ) =
                    CoreDict.foldl
                        (\k e ( acc, c ) ->
                            let
                                ( e1, c2 ) =
                                    rewriteExpr c e
                            in
                            ( CoreDict.insert k e1 acc, c2 )
                        )
                        ( CoreDict.empty, ctx )
                        fields
            in
            ( TOpt.Record fields1 meta, c1 )

        TOpt.TrackedRecord region fields meta ->
            let
                ( fields1, c1 ) =
                    rewriteLocatedFields ctx fields
            in
            ( TOpt.TrackedRecord region fields1 meta, c1 )

        TOpt.Update region record fields meta ->
            let
                ( record1, c0 ) =
                    rewriteExpr ctx record

                ( fields1, c1 ) =
                    rewriteLocatedFields c0 fields
            in
            ( TOpt.Update region record1 fields1 meta, c1 )

        _ ->
            ( expr, ctx )


{-| Returns record fields keyed by located name with each value rewritten.
-}
rewriteLocatedFields :
    Ctx
    -> Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId)
    -> ( Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId), Ctx )
rewriteLocatedFields ctx fields =
    Dict.foldl
        (\k e ( acc, c ) ->
            let
                ( e1, c2 ) =
                    rewriteExpr c e
            in
            ( Dict.insert A.toValue k e1 acc, c2 )
        )
        ( Dict.empty, ctx )
        fields


{-| Returns a decision tree with the expressions inlined at its leaves
rewritten; jump leaves and tests are unchanged.
-}
rewriteDecider : Ctx -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> ( TOpt.Decider (TOpt.Choice TypeIds.MVarId), Ctx )
rewriteDecider ctx decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            let
                ( e1, c1 ) =
                    rewriteExpr ctx e
            in
            ( TOpt.Leaf (TOpt.Inline e1), c1 )

        TOpt.Leaf (TOpt.Jump i) ->
            ( TOpt.Leaf (TOpt.Jump i), ctx )

        TOpt.Chain tests ok ko ->
            let
                ( ok1, c1 ) =
                    rewriteDecider ctx ok

                ( ko1, c2 ) =
                    rewriteDecider c1 ko
            in
            ( TOpt.Chain tests ok1 ko1, c2 )

        TOpt.FanOut path branches fallback ->
            let
                ( branches1, c1 ) =
                    List.foldl
                        (\( t, d ) ( acc, c ) ->
                            let
                                ( d1, c2 ) =
                                    rewriteDecider c d
                            in
                            ( ( t, d1 ) :: acc, c2 )
                        )
                        ( [], ctx )
                        branches

                ( fallback1, cf ) =
                    rewriteDecider c1 fallback
            in
            ( TOpt.FanOut path (List.reverse branches1) fallback1, cf )


{-| Returns a `let` or `Cycle` definition with its bound expression or body
rewritten.
-}
rewriteDef : Ctx -> TOpt.Def TypeIds.MVarId -> ( TOpt.Def TypeIds.MVarId, Ctx )
rewriteDef ctx def =
    case def of
        TOpt.Def region name bound tipe ->
            let
                ( b1, c1 ) =
                    rewriteExpr ctx bound
            in
            ( TOpt.Def region name b1 tipe, c1 )

        TOpt.TailDef region name args body tipe tvar ->
            let
                ( b1, c1 ) =
                    rewriteExpr ctx body
            in
            ( TOpt.TailDef region name args b1 tipe tvar, c1 )


{-| Rewrites one sub-expression and rebuilds the enclosing expression around it
with `rebuild`.
-}
mapBody : Ctx -> TOpt.Expr TypeIds.MVarId -> (TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId) -> ( TOpt.Expr TypeIds.MVarId, Ctx )
mapBody ctx body rebuild =
    let
        ( body1, c1 ) =
            rewriteExpr ctx body
    in
    ( rebuild body1, c1 )


{-| Returns the expressions rewritten in order, threading the context through
them.
-}
rewriteList : Ctx -> List (TOpt.Expr TypeIds.MVarId) -> ( List (TOpt.Expr TypeIds.MVarId), Ctx )
rewriteList ctx items =
    let
        ( rev, c ) =
            List.foldl
                (\e ( acc, cc ) ->
                    let
                        ( e1, c1 ) =
                            rewriteExpr cc e
                    in
                    ( e1 :: acc, c1 )
                )
                ( [], ctx )
                items
    in
    ( List.reverse rev, c )



-- ============================================================================
-- ====== COUNTERS ======
-- ============================================================================


{-| Records a call forwarded to global `g`: adds `g` to the node's pending deps,
counts it in `callsRewritten` and tallies it under `g`.
-}
forwardedCall : TOpt.Global -> Ctx -> Ctx
forwardedCall g ctx =
    { ctx
        | depsAdd = g :: ctx.depsAdd
        , metrics =
            (\m ->
                { m
                    | callsRewritten = m.callsRewritten + 1
                    , byTarget = tally (TOpt.toComparableGlobal g) m.byTarget
                }
            )
                ctx.metrics
    }


{-| Records a call forwarded to kernel `home.name`: adds the kernel's global to
the node's pending deps, counts it in `callsRewritten` and
`callsRewrittenKernel`, and tallies it under `k|home.name`.
-}
forwardedKernelCall : Name -> Name -> Ctx -> Ctx
forwardedKernelCall home name ctx =
    { ctx
        | depsAdd = TOpt.toKernelGlobal home :: ctx.depsAdd
        , metrics =
            (\m ->
                { m
                    | callsRewritten = m.callsRewritten + 1
                    , callsRewrittenKernel = m.callsRewrittenKernel + 1
                    , byTarget = tally ("k|" ++ home ++ "." ++ name) m.byTarget
                }
            )
                ctx.metrics
    }


{-| Records a value reference forwarded to global `g`: adds `g` to the node's
pending deps, counts it in `argRefsRewritten` and tallies it under `g`.
-}
forwardedValue : TOpt.Global -> Ctx -> Ctx
forwardedValue g ctx =
    { ctx
        | depsAdd = g :: ctx.depsAdd
        , metrics =
            (\m ->
                { m
                    | argRefsRewritten = m.argRefsRewritten + 1
                    , byTarget = tally (TOpt.toComparableGlobal g) m.byTarget
                }
            )
                ctx.metrics
    }


{-| Applies `f` to the context's metrics.
-}
bump : (Metrics -> Metrics) -> Ctx -> Ctx
bump f ctx =
    { ctx | metrics = f ctx.metrics }


{-| Counts one more walked body in `bodiesSeen`.
-}
seeBody : Ctx -> Ctx
seeBody =
    bump (\m -> { m | bodiesSeen = m.bodiesSeen + 1 })


{-| Adds one to the count under `key`, starting from zero.
-}
tally : String -> CoreDict.Dict String Int -> CoreDict.Dict String Int
tally key d =
    CoreDict.update key (\v -> Just (Maybe.withDefault 0 v + 1)) d
