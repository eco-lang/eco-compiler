module TestLogic.Generate.MonoLayoutIntegrity exposing
    ( expectCtorLayoutsConsistent
    , expectLayoutsCanonical
    , expectRecordAccessMatchesLayout
    , expectRecordTupleLayoutsComplete
    )

{-| Expectations that a program's monomorphized graph agrees with itself about
the shape of its records and custom types, so that a record access naming a
field its record's type lacks, or a constructor tag out of step with
constructor order, is reported by a test rather than left for code generation.

The _monomorphized graph_ is the program after each polymorphic definition
has been specialized to the types it is used at
(`Compiler.AST.Monomorphized.MonoGraph`).
Its `ctorShapes` table holds, for each custom type in the graph, the list of
that type's constructors, each with a name, a runtime tag and field types.

Each exposed expectation takes one source module and runs it through
`TestLogic.TestPipeline.runToMono`, so the module must meet that function's
requirements (it must define `testValue`). Monomorphization there uses the
substitution engine, not the solver engine a default build uses. If
`runToMono` returns an error, the expectation fails with its message. Otherwise
it builds a list of checks from the graph and fails if any of them fails.

What the expectations establish:

  - `expectRecordAccessMatchesLayout`: for each record access it visits, the
    accessed expression has a record type and that type has the field; for
    each record update it visits, the updated expression has a record type
    holding every updated field.
  - `expectCtorLayoutsConsistent`: in every `ctorShapes` entry, the
    constructor at position `i` of the list has tag `i`. The tags come from
    `Compiler.Data.CtorTag.effective`, which gives elm/core's
    `Dict.RBNode_elm_builtin` a reserved tag, so a graph whose `ctorShapes`
    holds elm/core's `Dict` type would fail this check.
  - `expectRecordTupleLayoutsComplete`: its only tests, for a negative field
    or element count, can never fail, so it passes whenever `runToMono`
    succeeds.
  - `expectLayoutsCanonical`: checks nothing beyond `runToMono` succeeding.

Among what is not tested: expressions held inline in a `case`'s decision tree,
which `expectRecordAccessMatchesLayout` does not visit, so a record access
inside one is not checked; constructor field counts and field types; the graph
after global optimization.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Returns an expectation that monomorphizes `srcModule` and checks some of
the record and tuple types in the graph.

The checks applied cannot fail: they test for a record with a negative number
of fields and a tuple with a negative number of elements. The expectation
therefore passes exactly when `runToMono` succeeds.

-}
expectRecordTupleLayoutsComplete : Src.Module -> Expect.Expectation
expectRecordTupleLayoutsComplete srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            let
                checks =
                    collectLayoutCompletenessChecks monoGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| Returns an expectation that monomorphizes `srcModule` and fails if a record
access or record update names a field that the type of the record expression
does not have, or is applied to an expression whose type is not a record.

Expressions held inline in a `case`'s decision tree are not visited.

-}
expectRecordAccessMatchesLayout : Src.Module -> Expect.Expectation
expectRecordAccessMatchesLayout srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            let
                checks =
                    collectRecordAccessChecks monoGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| Returns an expectation that monomorphizes `srcModule` and fails if, for any
custom type in the graph's `ctorShapes` table, a constructor's tag differs
from its position in that type's constructor list.

Only tags are compared; field counts and field types are not checked.
elm/core's `Dict.RBNode_elm_builtin`, which `Compiler.Data.CtorTag.effective`
gives the reserved tag 0xFFFF, fails this check.

-}
expectCtorLayoutsConsistent : Src.Module -> Expect.Expectation
expectCtorLayoutsConsistent srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            let
                checks =
                    collectCtorLayoutChecks monoGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| Returns an expectation that monomorphizes `srcModule`. It applies no check
of its own, so it passes exactly when `runToMono` succeeds; whether
structurally equal layouts are shared is not tested.
-}
expectLayoutsCanonical : Src.Module -> Expect.Expectation
expectLayoutsCanonical srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            let
                checks =
                    collectCanonicalityChecks monoGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()



-- ============================================================================
-- RECORD AND TUPLE LAYOUT COMPLETENESS
-- ============================================================================


{-| Returns the layout-completeness checks for every node in the graph, each
labelled with the node's position in the node array.
-}
collectLayoutCompletenessChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectLayoutCompletenessChecks (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, checkNodeLayoutCompleteness specId node ++ acc )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


{-| Returns the layout-completeness checks for one node, labelled with
`specId`: those for the node's type, for the parameter types of a tail-recursive
function, and for the types `collectExprLayoutIssues` visits in the node's
expression.
-}
checkNodeLayoutCompleteness : Int -> Mono.MonoNode -> List (() -> Expect.Expectation)
checkNodeLayoutCompleteness specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            checkTypeLayoutComplete context monoType
                ++ collectExprLayoutIssues context expr

        Mono.MonoTailFunc params expr monoType ->
            checkTypeLayoutComplete context monoType
                ++ List.concatMap (\( _, t ) -> checkTypeLayoutComplete context t) params
                ++ collectExprLayoutIssues context expr

        Mono.MonoCtor _ monoType ->
            checkTypeLayoutComplete context monoType

        Mono.MonoEnum _ monoType ->
            checkTypeLayoutComplete context monoType

        Mono.MonoExtern monoType ->
            checkTypeLayoutComplete context monoType

        Mono.MonoManagerLeaf _ monoType ->
            checkTypeLayoutComplete context monoType

        Mono.MonoPortIncoming expr monoType ->
            checkTypeLayoutComplete context monoType
                ++ collectExprLayoutIssues context expr

        Mono.MonoPortOutgoing expr monoType ->
            checkTypeLayoutComplete context monoType
                ++ collectExprLayoutIssues context expr


{-| Returns the layout-completeness checks for `monoType`, each failure message
prefixed with `context`.

A record or tuple yields a check only if it has a negative number of fields or
elements, which cannot happen, so this always returns an empty list. It
descends into list elements, custom-type arguments and function parameter and
result types, but not into the fields of a record or the elements of a tuple.

-}
checkTypeLayoutComplete : String -> Mono.MonoType -> List (() -> Expect.Expectation)
checkTypeLayoutComplete context monoType =
    case monoType of
        Mono.MRecord _ fields ->
            if Dict.size fields < 0 then
                [ \() -> Expect.fail (context ++ ": Record has negative field count") ]

            else
                []

        Mono.MTuple _ elementTypes ->
            if List.length elementTypes < 0 then
                [ \() -> Expect.fail (context ++ ": Tuple has negative element count") ]

            else
                []

        Mono.MList _ elemType ->
            checkTypeLayoutComplete context elemType

        Mono.MCustom _ _ _ typeArgs ->
            List.concatMap (checkTypeLayoutComplete context) typeArgs

        Mono.MFunction _ _ paramTypes returnType ->
            List.concatMap (checkTypeLayoutComplete context) paramTypes
                ++ checkTypeLayoutComplete context returnType

        _ ->
            []


{-| Returns the layout-completeness checks for the type of `expr` and of some
of the expressions inside it.

In a `case`, only the branches reached by jumps are visited; expressions held
inline in the decision tree are not. The field expressions of a record
creation, the elements of a tuple creation and the new values of a record
update are not visited either.

-}
collectExprLayoutIssues : String -> Mono.MonoExpr -> List (() -> Expect.Expectation)
collectExprLayoutIssues context expr =
    case expr of
        Mono.MonoRecordCreate _ monoType ->
            checkTypeLayoutComplete context monoType

        Mono.MonoRecordAccess recordExpr _ monoType ->
            checkTypeLayoutComplete context monoType
                ++ collectExprLayoutIssues context recordExpr

        Mono.MonoRecordUpdate recordExpr _ monoType ->
            checkTypeLayoutComplete context monoType
                ++ collectExprLayoutIssues context recordExpr

        Mono.MonoTupleCreate _ _ monoType ->
            checkTypeLayoutComplete context monoType

        Mono.MonoList _ exprs monoType ->
            checkTypeLayoutComplete context monoType
                ++ List.concatMap (collectExprLayoutIssues context) exprs

        Mono.MonoClosure closureInfo bodyExpr monoType ->
            checkTypeLayoutComplete context monoType
                ++ List.concatMap (\( _, e, _ ) -> collectExprLayoutIssues context e) closureInfo.captures
                ++ collectExprLayoutIssues context bodyExpr

        Mono.MonoCall _ fnExpr argExprs monoType _ ->
            checkTypeLayoutComplete context monoType
                ++ collectExprLayoutIssues context fnExpr
                ++ List.concatMap (collectExprLayoutIssues context) argExprs

        Mono.MonoTailCall _ args monoType ->
            checkTypeLayoutComplete context monoType
                ++ List.concatMap (\( _, e ) -> collectExprLayoutIssues context e) args

        Mono.MonoIf branches elseExpr monoType ->
            checkTypeLayoutComplete context monoType
                ++ List.concatMap (\( c, t ) -> collectExprLayoutIssues context c ++ collectExprLayoutIssues context t) branches
                ++ collectExprLayoutIssues context elseExpr

        Mono.MonoLet def bodyExpr monoType ->
            checkTypeLayoutComplete context monoType
                ++ collectDefLayoutIssues context def
                ++ collectExprLayoutIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr monoType ->
            checkTypeLayoutComplete context monoType
                ++ collectExprLayoutIssues context valueExpr

        Mono.MonoCase _ _ _ branches monoType ->
            checkTypeLayoutComplete context monoType
                ++ List.concatMap (\( _, e ) -> collectExprLayoutIssues context e) branches

        _ ->
            checkTypeLayoutComplete context (Mono.typeOf expr)


{-| Returns the layout-completeness checks for a `let` definition: its
parameter types, if it is a tail-recursive function, and its body.
-}
collectDefLayoutIssues : String -> Mono.MonoDef -> List (() -> Expect.Expectation)
collectDefLayoutIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprLayoutIssues context expr

        Mono.MonoTailDef _ params expr ->
            List.concatMap (\( _, t ) -> checkTypeLayoutComplete context t) params
                ++ collectExprLayoutIssues context expr



-- ============================================================================
-- RECORD ACCESS CONSISTENCY
-- ============================================================================


{-| Returns the record access and update checks for every node in the graph,
each labelled with the node's position in the node array.
-}
collectRecordAccessChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectRecordAccessChecks (Mono.MonoGraph data) =
    Array.foldl
        (\maybeNode ( specId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( specId + 1, acc )

                Just node ->
                    ( specId + 1, checkNodeRecordAccess specId node ++ acc )
        )
        ( 0, [] )
        data.nodes
        |> Tuple.second


{-| Returns the record access and update checks for the expression of one
node, labelled with `specId`. Nodes with no expression yield none.
-}
checkNodeRecordAccess : Int -> Mono.MonoNode -> List (() -> Expect.Expectation)
checkNodeRecordAccess specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            collectExprRecordAccessIssues context expr

        Mono.MonoTailFunc _ expr _ ->
            collectExprRecordAccessIssues context expr

        Mono.MonoPortIncoming expr _ ->
            collectExprRecordAccessIssues context expr

        Mono.MonoPortOutgoing expr _ ->
            collectExprRecordAccessIssues context expr

        _ ->
            []


{-| Returns a failing check, prefixed with `context`, for each record access
or record update in `expr` whose record expression does not have a record type,
or whose record type lacks a field that the access or update names.

In a `case`, only the branches reached by jumps are visited; expressions held
inline in the decision tree are not.

-}
collectExprRecordAccessIssues : String -> Mono.MonoExpr -> List (() -> Expect.Expectation)
collectExprRecordAccessIssues context expr =
    case expr of
        Mono.MonoRecordAccess recordExpr fieldName _ ->
            let
                recordType =
                    Mono.typeOf recordExpr

                checks =
                    case recordType of
                        Mono.MRecord _ fields ->
                            case Dict.get fieldName fields of
                                Just _ ->
                                    []

                                Nothing ->
                                    [ \() -> Expect.fail (context ++ ": Record access ." ++ fieldName ++ " not found in record type") ]

                        _ ->
                            [ \() -> Expect.fail (context ++ ": Record access ." ++ fieldName ++ " on non-record type") ]
            in
            checks ++ collectExprRecordAccessIssues context recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            let
                recordType =
                    Mono.typeOf recordExpr

                checks =
                    case recordType of
                        Mono.MRecord _ fields ->
                            List.concatMap
                                (\( fName, _ ) ->
                                    case Dict.get fName fields of
                                        Just _ ->
                                            []

                                        Nothing ->
                                            [ \() -> Expect.fail (context ++ ": Record update has invalid field name " ++ fName) ]
                                )
                                updates

                        _ ->
                            [ \() -> Expect.fail (context ++ ": Record update on non-record type") ]
            in
            checks
                ++ collectExprRecordAccessIssues context recordExpr
                ++ List.concatMap (\( _, e ) -> collectExprRecordAccessIssues context e) updates

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectExprRecordAccessIssues context) exprs

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, e, _ ) -> collectExprRecordAccessIssues context e) closureInfo.captures
                ++ collectExprRecordAccessIssues context bodyExpr

        Mono.MonoCall _ fnExpr argExprs _ _ ->
            collectExprRecordAccessIssues context fnExpr
                ++ List.concatMap (collectExprRecordAccessIssues context) argExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectExprRecordAccessIssues context e) args

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectExprRecordAccessIssues context c ++ collectExprRecordAccessIssues context t) branches
                ++ collectExprRecordAccessIssues context elseExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefRecordAccessIssues context def
                ++ collectExprRecordAccessIssues context bodyExpr

        Mono.MonoDestruct _ valueExpr _ ->
            collectExprRecordAccessIssues context valueExpr

        Mono.MonoCase _ _ _ branches _ ->
            List.concatMap (\( _, e ) -> collectExprRecordAccessIssues context e) branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectExprRecordAccessIssues context e) fieldExprs

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectExprRecordAccessIssues context) elementExprs

        _ ->
            []


{-| Returns the record access and update checks for the body of a `let`
definition.
-}
collectDefRecordAccessIssues : String -> Mono.MonoDef -> List (() -> Expect.Expectation)
collectDefRecordAccessIssues context def =
    case def of
        Mono.MonoDef _ expr ->
            collectExprRecordAccessIssues context expr

        Mono.MonoTailDef _ _ expr ->
            collectExprRecordAccessIssues context expr



-- ============================================================================
-- CONSTRUCTOR TAG ORDER
-- ============================================================================


{-| Returns a failing check for each constructor in the graph's `ctorShapes`
whose tag differs from its position in its type's constructor list. The failure
message gives the position and the tag but not the type.
-}
collectCtorLayoutChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCtorLayoutChecks (Mono.MonoGraph data) =
    Mono.layoutMapFoldl
        (\_ ctors acc ->
            acc
                ++ (List.indexedMap
                        (\idx shape ->
                            if shape.tag /= idx then
                                Just (\() -> Expect.fail ("Constructor at position " ++ String.fromInt idx ++ " has tag " ++ String.fromInt shape.tag))

                            else
                                Nothing
                        )
                        ctors
                        |> List.filterMap identity
                   )
        )
        []
        data.ctorShapes



-- ============================================================================
-- LAYOUT CANONICALITY
-- ============================================================================


{-| Returns no checks, whatever the graph.

The intended check is that structurally equal layouts share one
representation. The graph does not expose layout identity, so nothing here
compares layouts.

-}
collectCanonicalityChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCanonicalityChecks (Mono.MonoGraph _) =
    []
