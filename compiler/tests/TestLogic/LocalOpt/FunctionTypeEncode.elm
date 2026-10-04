module TestLogic.LocalOpt.FunctionTypeEncode exposing (expectFunctionTypesEncoded)

{-| Checks that each function expression the walk reaches in the typed
optimizer's output has a type with an arrow for each of its parameters.
Without the check, a function whose own type has fewer arrows than it has
parameters would leave typed optimization unnoticed.

A _function expression_ is a `Function` or `TrackedFunction` in the
typed-optimized IR (`Compiler.AST.TypedOptimized`). It carries its parameters,
each with its type, its body, and in its `Meta` the type of the function as a
whole. An _arrow_ is one `Can.TLambda` layer of that type, so a function of
two parameters needs a type of the shape `a -> (b -> r)`.

The fixture is the source module the caller passes to
`expectFunctionTypesEncoded`. It is run through
`TestLogic.TestPipeline.runToTypedOpt`, which first adds a synthetic `main`,
and the check reads the typed local graph that results. The synthetic `main`
refers to `testValue`, so the module must define `testValue`; without it the
run crashes. The module must not define its own `main`, which the synthetic one
would duplicate.

What the check establishes, for that one module:

  - If the pipeline reports an error, the check fails with that message.
  - Each function expression the walk reaches has at least as many nested
    `Can.TLambda` layers in its type as it has parameters. A failure names the
    top-level definition it was found in and, when it lies in a let or cycle
    def, that def's kind and name.

Among what is not tested:

  - Whether each parameter type equals the argument type of its arrow, or
    whether what is left after the last parameter is the body's type. Arrows
    are counted, not compared.
  - Function expressions in a `Cycle` node's values, and in the branches a
    `Case` inlines into its decision tree. The walk does not visit either.
  - The parameters of a `TailDef` against the def's type. Only function
    expressions in its body are checked.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Data.Map
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Runs `srcModule` to typed optimization and expects each function expression
in its local graph to have a type with at least one `Can.TLambda` layer per
parameter. Parameters are counted; their types are not compared with the arrows.

Fails with the pipeline's message if the pipeline reports an error; a module
that defines no `testValue` crashes the run instead. Function expressions in a
`Cycle` node's values, or inlined into a `Case`'s decision tree, are not
examined.

-}
expectFunctionTypesEncoded : Src.Module -> Expect.Expectation
expectFunctionTypesEncoded srcModule =
    case Pipeline.runToTypedOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                checks =
                    collectFunctionTypeChecks result.localGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()



-- ============================================================================
-- FUNCTION TYPE ENCODING VERIFICATION
-- ============================================================================


{-| Returns one failing expectation for each function expression the walk
reaches in the graph's nodes whose type has too few arrows. Function
expressions in a `Cycle`'s values and in a `Case`'s inlined choices are not
reached. A function that passes adds nothing, so an empty list means every
function examined passed.
-}
collectFunctionTypeChecks : TOpt.LocalGraph Name -> List (() -> Expect.Expectation)
collectFunctionTypeChecks (TOpt.LocalGraph data) =
    Data.Map.foldl
        (\global node acc ->
            let
                context =
                    globalToString global
            in
            checkNodeFunctionTypes context node ++ acc
        )
        []
        data.nodes


{-| Returns `Module.name` for a global, without its package, for use in failure
messages.
-}
globalToString : TOpt.Global -> String
globalToString (TOpt.Global home name) =
    case home of
        ModuleName.Canonical _ moduleName ->
            moduleName ++ "." ++ name


{-| Returns the failures for the function expressions in one node: the body of
a `Define`, `TrackedDefine`, `PortIncoming` or `PortOutgoing`, and the body of
each def of a `Cycle`. A `Cycle`'s values, and every other kind of node, give
none.
-}
checkNodeFunctionTypes : String -> TOpt.Node Name -> List (() -> Expect.Expectation)
checkNodeFunctionTypes context node =
    case node of
        TOpt.Define expr _ _ ->
            collectExprFunctionTypeChecks context expr

        TOpt.TrackedDefine _ expr _ _ ->
            collectExprFunctionTypeChecks context expr

        TOpt.Cycle _ _ defs _ ->
            List.concatMap (\def -> checkDefFunctionTypes context def) defs

        TOpt.PortIncoming expr _ _ ->
            collectExprFunctionTypeChecks context expr

        TOpt.PortOutgoing expr _ _ ->
            collectExprFunctionTypeChecks context expr

        _ ->
            []


{-| Returns the failures for the function expressions in a def's body, with the
def's kind and name added to `context`.
-}
checkDefFunctionTypes : String -> TOpt.Def Name -> List (() -> Expect.Expectation)
checkDefFunctionTypes context def =
    case def of
        TOpt.Def _ name expr _ ->
            collectExprFunctionTypeChecks (context ++ " Def " ++ name) expr

        TOpt.TailDef _ name _ expr _ _ ->
            collectExprFunctionTypeChecks (context ++ " TailDef " ++ name) expr


{-| Returns the failures for `expr` itself and for every function expression
nested in it, each message prefixed with `context`.

A `Case` is searched only through its jump targets, not through the
expressions inlined in its decision tree.

-}
collectExprFunctionTypeChecks : String -> TOpt.Expr Name -> List (() -> Expect.Expectation)
collectExprFunctionTypeChecks context expr =
    case expr of
        TOpt.Function _ params bodyExpr fnMeta ->
            let
                paramTypes =
                    List.map Tuple.second params

                typeCheck =
                    if not (functionTypeMatches paramTypes fnMeta.tipe) then
                        [ \() -> Expect.fail (context ++ ": Function expression type does not match parameter types") ]

                    else
                        []
            in
            typeCheck ++ collectExprFunctionTypeChecks context bodyExpr

        TOpt.TrackedFunction _ params bodyExpr fnMeta ->
            let
                paramTypes =
                    List.map Tuple.second params

                typeCheck =
                    if not (functionTypeMatches paramTypes fnMeta.tipe) then
                        [ \() -> Expect.fail (context ++ ": TrackedFunction expression type does not match parameter types") ]

                    else
                        []
            in
            typeCheck ++ collectExprFunctionTypeChecks context bodyExpr

        TOpt.Call _ fnExpr argExprs _ ->
            collectExprFunctionTypeChecks context fnExpr
                ++ List.concatMap (collectExprFunctionTypeChecks context) argExprs

        TOpt.TailCall _ args _ ->
            List.concatMap (\( _, argExpr ) -> collectExprFunctionTypeChecks context argExpr) args

        TOpt.If branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprFunctionTypeChecks context c ++ collectExprFunctionTypeChecks context t) branches
                ++ collectExprFunctionTypeChecks context elseExpr

        TOpt.Let def bodyExpr _ ->
            checkDefFunctionTypes context def
                ++ collectExprFunctionTypeChecks context bodyExpr

        TOpt.Destruct _ valueExpr _ ->
            collectExprFunctionTypeChecks context valueExpr

        TOpt.Case _ _ _ branches _ ->
            List.concatMap (\( _, branchExpr ) -> collectExprFunctionTypeChecks context branchExpr) branches

        TOpt.List _ exprs _ ->
            List.concatMap (collectExprFunctionTypeChecks context) exprs

        TOpt.Access recordExpr _ _ _ ->
            collectExprFunctionTypeChecks context recordExpr

        TOpt.Update _ recordExpr updates _ ->
            collectExprFunctionTypeChecks context recordExpr
                ++ Data.Map.foldl (\_ updateExpr acc -> collectExprFunctionTypeChecks context updateExpr ++ acc) [] updates

        TOpt.Record fieldExprs _ ->
            Dict.foldl (\_ fieldExpr acc -> collectExprFunctionTypeChecks context fieldExpr ++ acc) [] fieldExprs

        TOpt.TrackedRecord _ fieldExprs _ ->
            Data.Map.foldl (\_ fieldExpr acc -> collectExprFunctionTypeChecks context fieldExpr ++ acc) [] fieldExprs

        TOpt.Tuple _ e1 e2 rest _ ->
            collectExprFunctionTypeChecks context e1
                ++ collectExprFunctionTypeChecks context e2
                ++ List.concatMap (collectExprFunctionTypeChecks context) rest

        _ ->
            []


{-| Returns whether `fnType` has at least one nested `Can.TLambda` layer for
each entry of `paramTypes`, following each arrow into its result.

The parameter types are only counted, never compared with the arrows, and
whatever type remains after the last parameter is accepted. Where an arrow is
still needed, any other type gives `False`, including a `TAlias` whose
definition is a function type.

-}
functionTypeMatches : List (Can.Type Name) -> Can.Type Name -> Bool
functionTypeMatches paramTypes fnType =
    case ( paramTypes, fnType ) of
        ( [], _ ) ->
            True

        ( _ :: restParams, Can.TLambda _ _ restType ) ->
            functionTypeMatches restParams restType

        _ ->
            False
