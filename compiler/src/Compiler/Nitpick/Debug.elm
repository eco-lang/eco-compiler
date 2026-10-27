module Compiler.Nitpick.Debug exposing (hasDebugUses)

{-| Finds whether a module uses `Debug`, so that a build which forbids `Debug`
can reject it.

A use of a `Debug` function survives optimization as a `VarDebug` expression
(see `Compiler.AST.Optimized`). `hasDebugUses` searches one module's local
graph for such an expression, looking inside every definition, port, recursive
group, nested expression and pattern-match decision tree. Nothing else counts:
kernel references, shaders and the nodes that carry no expression are never
reported.


# Detection

@docs hasDebugUses

-}

import Compiler.AST.Optimized as Opt
import Compiler.Data.Map.Utils as Map
import Data.Map as EveryDict
import Dict



-- ====== HAS DEBUG USES ======


{-| Returns whether any node of the module's local graph contains a `VarDebug`
expression, that is, a use of any `Debug` function.
-}
hasDebugUses : Opt.LocalGraph -> Bool
hasDebugUses (Opt.LocalGraph _ graph _) =
    Map.any nodeHasDebug graph


{-| Returns whether a graph node contains a `VarDebug` expression. Constructor,
enum, box, link, effect manager and kernel nodes hold no expression and are
always `False`.
-}
nodeHasDebug : Opt.Node -> Bool
nodeHasDebug node =
    case node of
        Opt.Define expr _ ->
            hasDebug expr

        Opt.TrackedDefine _ expr _ ->
            hasDebug expr

        Opt.Ctor _ _ ->
            False

        Opt.Enum _ ->
            False

        Opt.Box ->
            False

        Opt.Link _ ->
            False

        Opt.Cycle _ vs fs _ ->
            List.any (Tuple.second >> hasDebug) vs || List.any defHasDebug fs

        Opt.Manager _ ->
            False

        Opt.Kernel _ _ ->
            False

        Opt.PortIncoming expr _ ->
            hasDebug expr

        Opt.PortOutgoing expr _ ->
            hasDebug expr


{-| Returns whether an expression contains a `VarDebug` anywhere inside it.
A shader is never searched.
-}
hasDebug : Opt.Expr -> Bool
hasDebug expression =
    case expression of
        Opt.Bool _ _ ->
            False

        Opt.Chr _ _ ->
            False

        Opt.Str _ _ ->
            False

        Opt.Int _ _ ->
            False

        Opt.Float _ _ ->
            False

        Opt.VarLocal _ ->
            False

        Opt.TrackedVarLocal _ _ ->
            False

        Opt.VarGlobal _ _ ->
            False

        Opt.VarEnum _ _ _ ->
            False

        Opt.VarBox _ _ ->
            False

        Opt.VarCycle _ _ _ ->
            False

        Opt.VarDebug _ _ _ _ ->
            True

        Opt.VarKernel _ _ _ _ ->
            False

        Opt.List _ exprs ->
            List.any hasDebug exprs

        Opt.Function _ expr ->
            hasDebug expr

        Opt.TrackedFunction _ expr ->
            hasDebug expr

        Opt.Call _ e es ->
            hasDebug e || List.any hasDebug es

        Opt.TailCall _ args ->
            List.any (Tuple.second >> hasDebug) args

        Opt.If conds finally ->
            List.any (\( c, e ) -> hasDebug c || hasDebug e) conds || hasDebug finally

        Opt.Let def body ->
            defHasDebug def || hasDebug body

        Opt.Destruct _ expr ->
            hasDebug expr

        Opt.Case _ _ d jumps ->
            deciderHasDebug d || List.any (Tuple.second >> hasDebug) jumps

        Opt.Accessor _ _ ->
            False

        Opt.Access r _ _ ->
            hasDebug r

        Opt.Update _ r fs ->
            hasDebug r || List.any hasDebug (EveryDict.values fs)

        Opt.Record fs ->
            List.any hasDebug (Dict.values fs)

        Opt.TrackedRecord _ fs ->
            List.any hasDebug (EveryDict.values fs)

        Opt.Unit ->
            False

        Opt.Tuple _ a b cs ->
            hasDebug a || hasDebug b || List.any hasDebug cs

        Opt.Shader _ _ _ ->
            False


{-| Returns whether the body of a definition contains a `VarDebug`.
-}
defHasDebug : Opt.Def -> Bool
defHasDebug def =
    case def of
        Opt.Def _ _ expr ->
            hasDebug expr

        Opt.TailDef _ _ _ expr ->
            hasDebug expr


{-| Returns whether a decision tree contains a `VarDebug` in a branch body
written inline at a leaf. Jump leaves are `False` here; the bodies they jump to
are searched by `hasDebug` at the enclosing `Case`.
-}
deciderHasDebug : Opt.Decider Opt.Choice -> Bool
deciderHasDebug decider =
    case decider of
        Opt.Leaf (Opt.Inline expr) ->
            hasDebug expr

        Opt.Leaf (Opt.Jump _) ->
            False

        Opt.Chain _ success failure ->
            deciderHasDebug success || deciderHasDebug failure

        Opt.FanOut _ tests fallback ->
            List.any (Tuple.second >> deciderHasDebug) tests || deciderHasDebug fallback
