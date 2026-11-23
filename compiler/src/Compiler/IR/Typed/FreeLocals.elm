module Compiler.IR.Typed.FreeLocals exposing
    ( freeLocals, children
    , lambdaTable
    )

{-| Free local names of typed optimized (`TOpt`) expressions, and the table of
every source lambda's free locals that monomorphization reads when it names a
lambda.

`TOpt` has no free-variable function, so this module has its own: a walk that
tracks bound names, where the binders are lambda parameters, `let` definition
names, a `TailDef`'s label and arguments, and `Destruct` names, and the uses are
local variables, a path's root, a `TailCall`'s label and a `Case`'s root.

`lambdaTable` maps each source lambda's id to the sorted names its body uses
without binding them. The solver engine keys a lambda's member by the lambda
sets of those names (`Compiler.Monomorphize.Solver.Engine.captureSigFor`,
plans/lss-capture-qualified-members.md), and it needs them at mint sites that
hold only the lambda's id, so they are computed once per run, here.

@docs freeLocals, children
@docs lambdaTable

-}

import Compiler.Core.Annotation as A
import Compiler.Core.Id as Id
import Compiler.Core.Name exposing (Name)
import Compiler.Core.TypeIds as TypeIds
import Compiler.IR.Typed.Optimized as TOpt
import Data.Map as Dict
import Data.NonEmptyList as NE
import Dict as CoreDict
import Maybe.Extra as Maybe



-- ============================================================================
-- ====== LAMBDA TABLE ======
-- ============================================================================


{-| Returns, for every `Function` and `TrackedFunction` with a source-lambda id
in the bodies of `nodes`, the id (as `Id.toComparable`) mapped to the names the
lambda uses without binding them, in ascending order. Its own parameters are
bound, so they never appear. Lambdas nested in other lambdas get entries too.
Nodes without a body (constructors, enums, boxes, links, managers) add nothing.
-}
lambdaTable : Dict.Dict comparable TOpt.Global (TOpt.Node TypeIds.MVarId) -> CoreDict.Dict Int (List Name)
lambdaTable nodes =
    Dict.foldl (\_ node acc -> tableNode node acc) CoreDict.empty nodes


{-| Returns `acc` with the lambdas in the body or bodies of `node` added.
-}
tableNode : TOpt.Node TypeIds.MVarId -> CoreDict.Dict Int (List Name) -> CoreDict.Dict Int (List Name)
tableNode node acc =
    case node of
        TOpt.Define body _ _ ->
            tableExpr body acc

        TOpt.TrackedDefine _ body _ _ ->
            tableExpr body acc

        TOpt.PortIncoming body _ _ ->
            tableExpr body acc

        TOpt.PortOutgoing body _ _ ->
            tableExpr body acc

        TOpt.Cycle _ valueDefs funcDefs _ ->
            List.foldl (\d a -> List.foldl tableExpr a (defChildren d))
                (List.foldl (\( _, e ) a -> tableExpr e a) acc valueDefs)
                funcDefs

        _ ->
            acc


{-| Returns `acc` with every lambda in `expr`, `expr` included, added.
-}
tableExpr : TOpt.Expr TypeIds.MVarId -> CoreDict.Dict Int (List Name) -> CoreDict.Dict Int (List Name)
tableExpr expr acc =
    let
        acc1 =
            case expr of
                TOpt.Function (Just lam) _ _ _ ->
                    CoreDict.insert (Id.toComparable lam) (CoreDict.keys (freeLocals expr)) acc

                TOpt.TrackedFunction (Just lam) _ _ _ ->
                    CoreDict.insert (Id.toComparable lam) (CoreDict.keys (freeLocals expr)) acc

                _ ->
                    acc
    in
    List.foldl tableExpr acc1 (children expr)



-- ============================================================================
-- ====== FREE LOCALS ======
-- ============================================================================


{-| Returns the local names `expr` uses without binding them. References to
globals, kernels, cycle values and constructors are not local and never
appear.
-}
freeLocals : TOpt.Expr TypeIds.MVarId -> CoreDict.Dict String ()
freeLocals expr =
    freeGo CoreDict.empty expr CoreDict.empty


{-| Returns `acc` with every local name used in `expr` and bound neither in
`expr` nor in `bound` added.

A `let` definition's name is bound in the `let` body only, not in its own
definition. A `TailDef`'s label is bound in its loop body and in the `let`
body, its arguments only in the loop body. A `Case`'s root is a use; its label
is neither a use nor a binder.

-}
freeGo : CoreDict.Dict String () -> TOpt.Expr TypeIds.MVarId -> CoreDict.Dict String () -> CoreDict.Dict String ()
freeGo bound expr acc =
    case expr of
        TOpt.VarLocal n _ ->
            use bound n acc

        TOpt.TrackedVarLocal _ n _ ->
            use bound n acc

        TOpt.Function _ params body _ ->
            freeGo (List.foldl (\( n, _ ) b -> CoreDict.insert n () b) bound params) body acc

        TOpt.TrackedFunction _ params body _ ->
            freeGo (List.foldl (\( n, _ ) b -> CoreDict.insert (A.toValue n) () b) bound params) body acc

        TOpt.Let def body _ ->
            case def of
                TOpt.Def _ n bound1 _ ->
                    freeGo (CoreDict.insert n () bound) body (freeGo bound bound1 acc)

                TOpt.TailDef _ n args tailBody _ _ ->
                    let
                        inner =
                            List.foldl (\( a, _ ) b -> CoreDict.insert (A.toValue a) () b)
                                (CoreDict.insert n () bound)
                                args
                    in
                    freeGo (CoreDict.insert n () bound) body (freeGo inner tailBody acc)

        TOpt.Destruct (TOpt.Destructor n path _) body _ ->
            freeGo (CoreDict.insert n () bound) body (use bound (pathRoot path) acc)

        TOpt.Case _ root decider jumps _ ->
            List.foldl (\( _, e ) a -> freeGo bound e a)
                (freeDecider bound decider (use bound root acc))
                jumps

        TOpt.TailCall label args _ ->
            List.foldl (\( _, e ) a -> freeGo bound e a) (use bound label acc) args

        _ ->
            List.foldl (\e a -> freeGo bound e a) acc (children expr)


{-| Returns `acc` with the free locals of every `Inline` choice in `decider` added.
`Jump` choices add nothing here; their bodies are the `Case`'s jumps.
-}
freeDecider : CoreDict.Dict String () -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> CoreDict.Dict String () -> CoreDict.Dict String ()
freeDecider bound decider acc =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            freeGo bound e acc

        TOpt.Leaf (TOpt.Jump _) ->
            acc

        TOpt.Chain _ ok ko ->
            freeDecider bound ko (freeDecider bound ok acc)

        TOpt.FanOut _ branches fallback ->
            freeDecider bound fallback (List.foldl (\( _, d ) a -> freeDecider bound d a) acc (NE.toList branches))


{-| Returns `acc` with `n` added, unless `n` is in `bound`.
-}
use : CoreDict.Dict String () -> Name -> CoreDict.Dict String () -> CoreDict.Dict String ()
use bound n acc =
    if CoreDict.member n bound then
        acc

    else
        CoreDict.insert n () acc


{-| Returns the local name a destructuring path starts from.
-}
pathRoot : TOpt.Path -> Name
pathRoot path =
    case path of
        TOpt.Root n ->
            n

        TOpt.Index _ _ inner ->
            pathRoot inner

        TOpt.Field _ inner ->
            pathRoot inner

        TOpt.Unbox inner ->
            pathRoot inner



-- ============================================================================
-- ====== CHILDREN ======
-- ============================================================================


{-| Returns the immediate sub-expressions of `expr`, including a `Case`'s
`Inline` choices and jump bodies and a `let` definition's body.
-}
children : TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
children expr =
    case expr of
        TOpt.List _ items _ ->
            items

        TOpt.Function _ _ body _ ->
            [ body ]

        TOpt.TrackedFunction _ _ body _ ->
            [ body ]

        TOpt.Call _ f args _ ->
            f :: args

        TOpt.TailCall _ args _ ->
            List.map Tuple.second args

        TOpt.If branches final _ ->
            List.concatMap (\( c, t ) -> [ c, t ]) branches ++ [ final ]

        TOpt.Let def body _ ->
            defChildren def ++ [ body ]

        TOpt.Destruct _ body _ ->
            [ body ]

        TOpt.Case _ _ decider jumps _ ->
            deciderChildren decider ++ List.map Tuple.second jumps

        TOpt.Access inner _ _ _ ->
            [ inner ]

        TOpt.Update _ record fields _ ->
            record :: Dict.values fields

        TOpt.Record fields _ ->
            CoreDict.values fields

        TOpt.TrackedRecord _ fields _ ->
            Dict.values fields

        TOpt.Tuple _ a b rest _ ->
            a :: b :: Maybe.toList rest

        _ ->
            []


{-| Returns the expression a `let` definition binds, or a `TailDef`'s loop body.
-}
defChildren : TOpt.Def TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
defChildren def =
    case def of
        TOpt.Def _ _ bound _ ->
            [ bound ]

        TOpt.TailDef _ _ _ body _ _ ->
            [ body ]


{-| Returns the expressions of every `Inline` choice in `decider`.
-}
deciderChildren : TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> List (TOpt.Expr TypeIds.MVarId)
deciderChildren decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            [ e ]

        TOpt.Leaf (TOpt.Jump _) ->
            []

        TOpt.Chain _ ok ko ->
            deciderChildren ok ++ deciderChildren ko

        TOpt.FanOut _ branches fallback ->
            List.concatMap (\( _, d ) -> deciderChildren d) (NE.toList branches)
                ++ deciderChildren fallback
