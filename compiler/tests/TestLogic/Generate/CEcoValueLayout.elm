module TestLogic.Generate.CEcoValueLayout exposing (expectValidCEcoValueLayout)

{-| A checker meant to catch a type variable left open by monomorphization
deciding how a value is laid out at run time. As written it finds nothing, so
the expectation it builds passes exactly when the program monomorphizes.

After monomorphization a `MonoType` can still contain a type variable, an
`MVar`. One whose constraint is `CEcoValue` stands for a value that the back
end holds as a boxed `eco.value`, whatever its Elm type;
`Compiler.AST.Monomorphized` (`Constraint`) owns that meaning. The property
this module is named for is that such a variable does not decide the layout of
a record, tuple or constructor, or how a function is called.

`expectValidCEcoValueLayout` runs a source module through the test pipeline as
far as monomorphization (`TestLogic.TestPipeline.runToMono`) and walks every
node of the resulting graph: each node's type, the parameter types of tail
functions, closures and let-bound tail definitions, the shape of each
constructor, and the expressions of defines, tail functions and ports.

What the walk establishes:

  - Nothing beyond the pipeline succeeding. A `CEcoValue` variable, a record,
    and every type with no case of its own are accepted outright. Lists, custom
    types and functions are accepted when their parts are, which comes down to
    the same acceptance. A tuple or a constructor shape is rejected only for a
    negative number of elements or fields, which a list length cannot be. So
    the expectation fails only when `runToMono` returns an error.

Among what is not tested: where a `CEcoValue` variable appears in any type, the
layout of records, tuples and constructors, and the expressions held in a
`case`'s decision tree rather than in its jump branches, which the walk does
not visit.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Runs `srcModule` through the test pipeline to monomorphization and passes
when the walk of the resulting graph finds no issue.

A pipeline error fails with the pipeline's message, and found issues fail with
one issue per line. The walk finds none for any graph, so in effect this passes
exactly when monomorphization succeeds.

-}
expectValidCEcoValueLayout : Src.Module -> Expect.Expectation
expectValidCEcoValueLayout srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            let
                issues =
                    collectCEcoValueLayoutIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- CECOVALUE LAYOUT VERIFICATION
-- ============================================================================


{-| Returns the issues found in every node of the graph, each labelled with the
SpecId of its node.

A node's SpecId is its index in `nodes`, and empty slots are skipped. Issues
from later nodes come first in the list.

-}
collectCEcoValueLayoutIssues : Mono.MonoGraph -> List String
collectCEcoValueLayoutIssues (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, checkNodeCEcoValueLayout specId node ++ acc )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


{-| Returns the issues in one node, labelled `SpecId <specId>`: those in the
node's type, in a tail function's parameter types, in a constructor's shape, and
in the expression of a define, tail function or port.
-}
checkNodeCEcoValueLayout : Int -> Mono.MonoNode -> List String
checkNodeCEcoValueLayout specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            checkCEcoValueInLayoutPosition context monoType
                ++ collectExprCEcoValueIssues context expr

        Mono.MonoTailFunc params expr monoType ->
            checkCEcoValueInLayoutPosition context monoType
                ++ List.concatMap (\( _, t ) -> checkCEcoValueInLayoutPosition context t) params
                ++ collectExprCEcoValueIssues context expr

        Mono.MonoCtor ctorShape monoType ->
            checkCtorShapeCEcoValue context ctorShape
                ++ checkCEcoValueInLayoutPosition context monoType

        Mono.MonoEnum _ monoType ->
            checkCEcoValueInLayoutPosition context monoType

        Mono.MonoExtern monoType ->
            checkCEcoValueInLayoutPosition context monoType

        Mono.MonoManagerLeaf _ monoType ->
            checkCEcoValueInLayoutPosition context monoType

        Mono.MonoPortIncoming expr monoType ->
            checkCEcoValueInLayoutPosition context monoType
                ++ collectExprCEcoValueIssues context expr

        Mono.MonoPortOutgoing expr monoType ->
            checkCEcoValueInLayoutPosition context monoType
                ++ collectExprCEcoValueIssues context expr


{-| Returns the issues in `monoType`, each prefixed with `context`.

It looks into a list's element type, a custom type's arguments, and a
function's parameter and return types, and accepts a `CEcoValue` variable, a
record and every type with no case of its own outright. A tuple is rejected
only when its element list has a negative length, which cannot happen, so the
result is always empty.

-}
checkCEcoValueInLayoutPosition : String -> Mono.MonoType -> List String
checkCEcoValueInLayoutPosition context monoType =
    case monoType of
        Mono.MVar _ Mono.CEcoValue ->
            []

        Mono.MList _ elemType ->
            checkCEcoValueInLayoutPosition context elemType

        Mono.MRecord _ _ ->
            []

        Mono.MTuple _ elementTypes ->
            if List.length elementTypes < 0 then
                [ context ++ ": Tuple has invalid element count" ]

            else
                []

        Mono.MCustom _ _ _ typeArgs ->
            List.concatMap (checkCEcoValueInLayoutPosition context) typeArgs

        Mono.MFunction _ _ paramTypes returnType ->
            List.concatMap (checkCEcoValueInLayoutPosition context) paramTypes
                ++ checkCEcoValueInLayoutPosition context returnType

        _ ->
            []


{-| Returns the issues in a constructor shape, prefixed with `context`.

The field types are not examined. The one issue it can report is a negative
number of fields, which a list length cannot be, so the result is always empty.

-}
checkCtorShapeCEcoValue : String -> Mono.CtorShape -> List String
checkCtorShapeCEcoValue context shape =
    if List.length shape.fieldTypes < 0 then
        [ context ++ ": Constructor has invalid field count" ]

    else
        []


{-| Returns the issues in `expr` and the expressions inside it.

The types checked are the parameter types of each closure and of each let-bound
tail definition. The walk goes into closure captures and bodies, list
elements, calls, tail calls, `if` branches, `let` definitions and bodies, the
body of a destructuring, the jump branches of a `case`, and the parts of record
and tuple expressions. It does not go into the expressions held in a `case`'s
decision tree, and every other expression contributes nothing.

-}
collectExprCEcoValueIssues : String -> Mono.MonoExpr -> List String
collectExprCEcoValueIssues context expr =
    case expr of
        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, t ) -> checkCEcoValueInLayoutPosition context t) closureInfo.params
                ++ List.concatMap (\( _, e, _ ) -> collectExprCEcoValueIssues context e) closureInfo.captures
                ++ collectExprCEcoValueIssues context bodyExpr

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprCEcoValueIssues context) exprs

        Mono.MonoCall _ fnExpr argExprs _ _ ->
            collectExprCEcoValueIssues context fnExpr
                ++ List.concatMap (collectExprCEcoValueIssues context) argExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectExprCEcoValueIssues context e) args

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprCEcoValueIssues context c ++ collectExprCEcoValueIssues context t) branches
                ++ collectExprCEcoValueIssues context elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefCEcoValueIssues context def
                ++ collectExprCEcoValueIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprCEcoValueIssues context valueExpr

        Mono.MonoCase _ _ _ branches _ ->
            List.concatMap (\( _, e ) -> collectExprCEcoValueIssues context e) branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectExprCEcoValueIssues context e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectExprCEcoValueIssues context recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectExprCEcoValueIssues context recordExpr
                ++ List.concatMap (\( _, e ) -> collectExprCEcoValueIssues context e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectExprCEcoValueIssues context) elementExprs

        _ ->
            []


{-| Returns the issues in a let-bound definition: those in its expression and,
for a tail definition, in its parameter types.
-}
collectDefCEcoValueIssues : String -> Mono.MonoDef -> List String
collectDefCEcoValueIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprCEcoValueIssues context expr

        Mono.MonoTailDef _ params expr ->
            List.concatMap (\( _, t ) -> checkCEcoValueInLayoutPosition context t) params
                ++ collectExprCEcoValueIssues context expr
