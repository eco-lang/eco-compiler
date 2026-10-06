module TestLogic.Generate.MonoLayoutIntegrity exposing
    ( expectCtorLayoutsConsistent
    , expectLayoutsCanonical
    , expectRecordAccessMatchesLayout
    , expectRecordTupleLayoutsComplete
    )

{-| Expectations that a program's monomorphized graph agrees with itself about
the shape of its records, tuples and custom types, so that a record built
without one of its fields, a record access naming a field its record's type
lacks, or a constructor tag out of step with constructor order, is reported by
a test rather than left for code generation.

The _monomorphized graph_ is the program after each polymorphic definition
has been specialized to the types it is used at
(`Compiler.AST.Monomorphized.MonoGraph`). Code generation computes the heap
layout of a record or tuple from its type alone, so the type carried by each
construction must describe exactly what is built. The graph's `ctorShapes`
table holds, for each custom type in the graph, the list of that type's
constructors, each with a name, a runtime tag and field types.

Each exposed expectation takes one source module and runs it through
`TestLogic.TestPipeline.runToMono`, so the module must meet that function's
requirements (it must define `testValue`). Monomorphization there is the
production pipeline's (the solver engine with lambda-set specialization). If
`runToMono` returns an error, the expectation fails with its message. Otherwise
it builds a list of checks from the graph and fails if any of them fails.

Types are compared with `Mono.eqLayout`, not `==`: lambda-set annotations are
per occurrence under the solver engine (LSS\_006) and a ⊤ carries a provenance
code, so two occurrences of one layout can differ in annotation only.

Every expression of every node is visited, at any depth, including the
branches a `case` holds inline in its decision tree (`MonoTraverse.foldExpr`).

What the expectations establish:

  - `expectRecordTupleLayoutsComplete` (MONO\_006): a record creation names
    exactly the fields of its record type, each with an expression of that
    field's type; a tuple creation has as many elements as its tuple type,
    each of the element's type; a record update's type is the type of the
    record it updates; and every tuple type anywhere in the graph has 2 or 3
    elements.
  - `expectRecordAccessMatchesLayout` (MONO\_007): for each record access, the
    accessed expression has a record type that has the field, and the access
    has that field's type; for each record update, the updated expression has
    a record type holding every updated field.
  - `expectCtorLayoutsConsistent`: in every `ctorShapes` entry, the
    constructor at position `i` of the list has the tag
    `Compiler.Data.CtorTag.effective` gives it: `i`, except for elm/core's
    `Dict.RBNode_elm_builtin`, which has a reserved tag.
  - `expectLayoutsCanonical` (MONO\_014): every record and tuple type in the
    graph, at any depth, carries the packed hash that `Mono.mRecord` /
    `Mono.mTuple` give its structure. Layout tables are keyed by that hash, so
    two structurally equal types with different hashes could be given two
    layouts.

Among what is not tested: constructor field counts and field types; the graph
after global optimization.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Data.CtorTag as CtorTag
import Compiler.Data.Index as Index
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Returns an expectation that monomorphizes `srcModule` and checks that its
record and tuple constructions are complete, as the module documentation
describes for MONO\_006.
-}
expectRecordTupleLayoutsComplete : Src.Module -> Expect.Expectation
expectRecordTupleLayoutsComplete srcModule =
    expectOnGraph srcModule
        (\graph -> collectExprChecks checkConstruction graph ++ collectTupleArityChecks graph)


{-| Returns an expectation that monomorphizes `srcModule` and fails if a record
access or record update names a field that the type of the record expression
does not have, is applied to an expression whose type is not a record, or (for
an access) has a type other than the field's.
-}
expectRecordAccessMatchesLayout : Src.Module -> Expect.Expectation
expectRecordAccessMatchesLayout srcModule =
    expectOnGraph srcModule (collectExprChecks checkRecordAccess)


{-| Returns an expectation that monomorphizes `srcModule` and fails if, for any
custom type in the graph's `ctorShapes` table, a constructor's tag differs
from the one `CtorTag.effective` gives its position.
-}
expectCtorLayoutsConsistent : Src.Module -> Expect.Expectation
expectCtorLayoutsConsistent srcModule =
    expectOnGraph srcModule collectCtorLayoutChecks


{-| Returns an expectation that monomorphizes `srcModule` and fails if a record
or tuple type in the graph carries a packed hash other than the one its smart
constructor computes from its structure.
-}
expectLayoutsCanonical : Src.Module -> Expect.Expectation
expectLayoutsCanonical srcModule =
    expectOnGraph srcModule collectCanonicalityChecks


{-| Monomorphizes `srcModule` and applies `collect` to the graph.
-}
expectOnGraph : Src.Module -> (Mono.MonoGraph -> List (() -> Expect.Expectation)) -> Expect.Expectation
expectOnGraph srcModule collect =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            case collect monoGraph of
                [] ->
                    Expect.pass

                checks ->
                    Expect.all checks ()



-- ============================================================================
-- WALKS
-- ============================================================================


{-| Returns the node bodies of the graph with a label naming each node's
SpecId. Nodes without a body give none.
-}
nodeBodies : Mono.MonoGraph -> List ( String, Mono.MonoExpr )
nodeBodies (Mono.MonoGraph data) =
    Array.toIndexedList data.nodes
        |> List.filterMap
            (\( specId, maybeNode ) ->
                let
                    context =
                        "SpecId " ++ String.fromInt specId
                in
                case maybeNode of
                    Just (Mono.MonoDefine expr _) ->
                        Just ( context, expr )

                    Just (Mono.MonoTailFunc _ expr _) ->
                        Just ( context, expr )

                    Just (Mono.MonoPortIncoming expr _) ->
                        Just ( context, expr )

                    Just (Mono.MonoPortOutgoing expr _) ->
                        Just ( context, expr )

                    _ ->
                        Nothing
            )


{-| Applies `check` to every expression of every node body, at any depth, and
gathers the failure messages as checks.
-}
collectExprChecks : (String -> Mono.MonoExpr -> List String) -> Mono.MonoGraph -> List (() -> Expect.Expectation)
collectExprChecks check graph =
    nodeBodies graph
        |> List.concatMap
            (\( context, body ) ->
                MonoTraverse.foldExpr (\e acc -> check context e ++ acc) [] body
            )
        |> List.map (\msg -> \() -> Expect.fail msg)


{-| Returns whether `p` holds of `monoType` or of any type inside it.
-}
anyTypeWithin : (Mono.MonoType -> Bool) -> Mono.MonoType -> Bool
anyTypeWithin p monoType =
    p monoType
        || (case monoType of
                Mono.MList _ elemType ->
                    anyTypeWithin p elemType

                Mono.MTuple _ elemTypes ->
                    List.any (anyTypeWithin p) elemTypes

                Mono.MRecord _ fields ->
                    List.any (anyTypeWithin p) (Dict.values fields)

                Mono.MCustom _ _ _ typeArgs ->
                    List.any (anyTypeWithin p) typeArgs

                Mono.MFunction _ _ paramTypes returnType ->
                    List.any (anyTypeWithin p) paramTypes || anyTypeWithin p returnType

                _ ->
                    False
           )


{-| One failing check per node in which some type, at any position
`MonoTraverse.anyNodeType` reaches and at any depth, satisfies `bad`.
-}
collectTypeChecks : String -> (Mono.MonoType -> Bool) -> Mono.MonoGraph -> List (() -> Expect.Expectation)
collectTypeChecks message bad (Mono.MonoGraph data) =
    Array.toIndexedList data.nodes
        |> List.filterMap
            (\( specId, maybeNode ) ->
                case maybeNode of
                    Just node ->
                        if MonoTraverse.anyNodeType (anyTypeWithin bad) node then
                            Just (\() -> Expect.fail ("SpecId " ++ String.fromInt specId ++ ": " ++ message))

                        else
                            Nothing

                    Nothing ->
                        Nothing
            )



-- ============================================================================
-- RECORD AND TUPLE LAYOUT COMPLETENESS (MONO_006)
-- ============================================================================


{-| The failure messages for one expression if it is a record creation, a
tuple creation or a record update that does not match its type.
-}
checkConstruction : String -> Mono.MonoExpr -> List String
checkConstruction context expr =
    case expr of
        Mono.MonoRecordCreate fieldExprs monoType ->
            case monoType of
                Mono.MRecord _ fieldTypes ->
                    let
                        created =
                            List.map Tuple.first fieldExprs

                        missing =
                            List.filter (\name -> not (List.member name created)) (Dict.keys fieldTypes)

                        mismatched =
                            List.filterMap
                                (\( name, e ) ->
                                    case Dict.get name fieldTypes of
                                        Nothing ->
                                            Just (context ++ ": record creation has field " ++ name ++ " that its type lacks")

                                        Just t ->
                                            if Mono.eqLayout (Mono.typeOf e) t then
                                                Nothing

                                            else
                                                Just (context ++ ": record creation field " ++ name ++ " has an expression of another type than the field")
                                )
                                fieldExprs
                    in
                    List.map (\name -> context ++ ": record creation lacks field " ++ name ++ " of its type") missing
                        ++ mismatched

                _ ->
                    [ context ++ ": record creation with a non-record type" ]

        Mono.MonoTupleCreate _ elementExprs monoType ->
            case monoType of
                Mono.MTuple _ elementTypes ->
                    if List.length elementTypes /= List.length elementExprs then
                        [ context
                            ++ ": tuple creation has "
                            ++ String.fromInt (List.length elementExprs)
                            ++ " elements but its type has "
                            ++ String.fromInt (List.length elementTypes)
                        ]

                    else if not (List.all identity (List.map2 Mono.eqLayout (List.map Mono.typeOf elementExprs) elementTypes)) then
                        [ context ++ ": tuple creation element types differ from its type's" ]

                    else
                        []

                _ ->
                    [ context ++ ": tuple creation with a non-tuple type" ]

        Mono.MonoRecordUpdate recordExpr _ monoType ->
            if Mono.eqLayout (Mono.typeOf recordExpr) monoType then
                []

            else
                [ context ++ ": record update's type differs from the type of the record it updates" ]

        _ ->
            []


{-| One failing check per node holding a tuple type with other than 2 or 3
elements.
-}
collectTupleArityChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectTupleArityChecks =
    collectTypeChecks "tuple type with other than 2 or 3 elements"
        (\t ->
            case t of
                Mono.MTuple _ elems ->
                    List.length elems < 2 || List.length elems > 3

                _ ->
                    False
        )



-- ============================================================================
-- RECORD ACCESS CONSISTENCY (MONO_007)
-- ============================================================================


{-| The failure messages for one expression if it is a record access or update
that does not match the type of its record expression.
-}
checkRecordAccess : String -> Mono.MonoExpr -> List String
checkRecordAccess context expr =
    case expr of
        Mono.MonoRecordAccess recordExpr fieldName accessType ->
            case Mono.typeOf recordExpr of
                Mono.MRecord _ fields ->
                    case Dict.get fieldName fields of
                        Just fieldType ->
                            if Mono.eqLayout fieldType accessType then
                                []

                            else
                                [ context ++ ": Record access ." ++ fieldName ++ " has a type other than the field's" ]

                        Nothing ->
                            [ context ++ ": Record access ." ++ fieldName ++ " not found in record type" ]

                _ ->
                    [ context ++ ": Record access ." ++ fieldName ++ " on non-record type" ]

        Mono.MonoRecordUpdate recordExpr updates _ ->
            case Mono.typeOf recordExpr of
                Mono.MRecord _ fields ->
                    List.filterMap
                        (\( fName, _ ) ->
                            if Dict.member fName fields then
                                Nothing

                            else
                                Just (context ++ ": Record update has invalid field name " ++ fName)
                        )
                        updates

                _ ->
                    [ context ++ ": Record update on non-record type" ]

        _ ->
            []



-- ============================================================================
-- CONSTRUCTOR TAG ORDER
-- ============================================================================


{-| Returns a failing check for each constructor in the graph's `ctorShapes`
whose tag differs from the one `CtorTag.effective` gives its position in its
type's constructor list.
-}
collectCtorLayoutChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCtorLayoutChecks (Mono.MonoGraph data) =
    Mono.layoutMapFoldl
        (\customType ctors acc ->
            case customType of
                Mono.MCustom _ home typeName _ ->
                    List.indexedMap
                        (\idx shape ->
                            let
                                expected =
                                    CtorTag.effective home shape.name (indexFromInt idx)
                            in
                            if shape.tag /= expected then
                                Just
                                    (\() ->
                                        Expect.fail
                                            ("Constructor "
                                                ++ shape.name
                                                ++ " of "
                                                ++ typeName
                                                ++ " at position "
                                                ++ String.fromInt idx
                                                ++ " has tag "
                                                ++ String.fromInt shape.tag
                                                ++ ", expected "
                                                ++ String.fromInt expected
                                            )
                                    )

                            else
                                Nothing
                        )
                        ctors
                        |> List.filterMap identity
                        |> (\checks -> checks ++ acc)

                _ ->
                    (\() -> Expect.fail "ctorShapes has an entry whose key is not a custom type") :: acc
        )
        []
        data.ctorShapes


{-| The zero-based index `n`.
-}
indexFromInt : Int -> Index.ZeroBased
indexFromInt n =
    if n <= 0 then
        Index.first

    else
        Index.next (indexFromInt (n - 1))



-- ============================================================================
-- LAYOUT CANONICALITY (MONO_014)
-- ============================================================================


{-| One failing check per node holding a record or tuple type whose packed hash
is not the one its smart constructor computes from its structure.
-}
collectCanonicalityChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCanonicalityChecks =
    collectTypeChecks "record or tuple type whose packed hash does not match its structure (MONO_014)"
        (\t ->
            case t of
                Mono.MRecord hash fields ->
                    case Mono.mRecord fields of
                        Mono.MRecord rebuilt _ ->
                            hash /= rebuilt

                        _ ->
                            True

                Mono.MTuple hash elems ->
                    case Mono.mTuple elems of
                        Mono.MTuple rebuilt _ ->
                            hash /= rebuilt

                        _ ->
                            True

                _ ->
                    False
        )
