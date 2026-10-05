module TestLogic.LocalOpt.FunctionTypeEncode exposing (expectFunctionTypesEncoded)

{-| Checks that each function expression in the typed optimizer's output has
the type its parameters and body give it. Without the check, a function whose
own type disagrees with its parameters or its body, for instance one with
fewer arrows than it has parameters, would leave typed optimization unnoticed.

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
  - The type of each function expression, with `p1 ... pn` its parameter
    types and `r` its body's type, matches `p1 -> ... -> pn -> r` under
    `TestLogic.LocalOpt.Typed.TypeEq.alphaEqStrict` (aliases are expanded, and
    type variables may be renamed consistently). A failure names the
    top-level definition it was found in and, when it lies in a let or cycle
    def, that def's kind and name.

Every expression is walked: the bodies of definitions and ports, the function
definitions and the values of a `Cycle`, and in a `case` both the branches its
decision tree holds inline and its jump targets.

Among what is not tested:

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
import TestLogic.LocalOpt.Typed.TypeEq as TypeEq
import TestLogic.TestPipeline as Pipeline


{-| Runs `srcModule` to typed optimization and expects each function expression
in its local graph to have the type its parameters and body give it, as the
module docstring describes.

Fails with the pipeline's message if the pipeline reports an error; a module
that defines no `testValue` crashes the run instead.

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


{-| Returns one failing expectation for each function expression in the
graph's nodes whose type does not match its parameters and body. A function
that passes adds nothing, so an empty list means every function passed.
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
a `Define`, `TrackedDefine`, `PortIncoming` or `PortOutgoing`, and each value
and the body of each def of a `Cycle`. Every other kind of node gives none.
-}
checkNodeFunctionTypes : String -> TOpt.Node Name -> List (() -> Expect.Expectation)
checkNodeFunctionTypes context node =
    case node of
        TOpt.Define expr _ _ ->
            collectExprFunctionTypeChecks context expr

        TOpt.TrackedDefine _ expr _ _ ->
            collectExprFunctionTypeChecks context expr

        TOpt.Cycle _ values defs _ ->
            List.concatMap (\( name, valueExpr ) -> collectExprFunctionTypeChecks (context ++ " value " ++ name) valueExpr) values
                ++ List.concatMap (\def -> checkDefFunctionTypes context def) defs

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

A `Case` is searched through the expressions inlined in its decision tree and
through its jump targets.

-}
collectExprFunctionTypeChecks : String -> TOpt.Expr Name -> List (() -> Expect.Expectation)
collectExprFunctionTypeChecks context expr =
    case expr of
        TOpt.Function _ params bodyExpr fnMeta ->
            let
                paramTypes =
                    List.map Tuple.second params

                typeCheck =
                    functionTypeCheck context "Function" paramTypes bodyExpr fnMeta.tipe
            in
            typeCheck ++ collectExprFunctionTypeChecks context bodyExpr

        TOpt.TrackedFunction _ params bodyExpr fnMeta ->
            let
                paramTypes =
                    List.map Tuple.second params

                typeCheck =
                    functionTypeCheck context "TrackedFunction" paramTypes bodyExpr fnMeta.tipe
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

        TOpt.Case _ _ decider branches _ ->
            List.concatMap (collectExprFunctionTypeChecks context) (inlineLeaves decider)
                ++ List.concatMap (\( _, branchExpr ) -> collectExprFunctionTypeChecks context branchExpr) branches

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


{-| Returns the expressions at the `Inline` leaves of a decision tree.
-}
inlineLeaves : TOpt.Decider (TOpt.Choice Name) -> List (TOpt.Expr Name)
inlineLeaves decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            [ e ]

        TOpt.Leaf (TOpt.Jump _) ->
            []

        TOpt.Chain _ success failure ->
            inlineLeaves success ++ inlineLeaves failure

        TOpt.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> inlineLeaves d) edges ++ inlineLeaves fallback


{-| Returns a failure, labelled `context` and `kind`, when `fnType` does not
match the type built from `paramTypes` and the type of `body`,
`p1 -> ... -> pn -> r`, under `TypeEq.alphaEqStrict`.
-}
functionTypeCheck : String -> String -> List (Can.Type Name) -> TOpt.Expr Name -> Can.Type Name -> List (() -> Expect.Expectation)
functionTypeCheck context kind paramTypes body fnType =
    let
        expected =
            List.foldr Can.tLambda (TOpt.typeOf body) paramTypes
    in
    if TypeEq.alphaEqStrict fnType expected then
        []

    else
        [ \() ->
            Expect.fail
                (context
                    ++ ": "
                    ++ kind
                    ++ " expression type does not match its parameters and body:\n  stored:   "
                    ++ Debug.toString fnType
                    ++ "\n  expected: "
                    ++ Debug.toString expected
                )
        ]
