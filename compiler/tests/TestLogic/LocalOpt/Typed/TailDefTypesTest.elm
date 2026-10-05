module TestLogic.LocalOpt.Typed.TailDefTypesTest exposing (suite)

{-| Tests that the typed optimizer gives a tail-recursive function's `TailDef`
the parameter types that the function's annotation declares, and a body whose
type is the annotation's result type. The substitution monomorphizer gives a
tail-recursive function's parameters the types stored in its `TailDef`, so
without these tests a parameter could carry a wrong type, or a type variable
the solver left unconstrained, into monomorphization unnoticed.

A `TailDef` is the typed optimizer's form of a definition that calls itself in
tail position. It holds each parameter with the type of its pattern, its body,
and the type of the whole definition. A recursive top-level `TailDef` sits
among the functions of a `Cycle` node, the node that holds a group of mutually
recursive top-level definitions, which may be one definition that refers to
itself.

There are two fixtures, each compiled with `TestLogic.TestPipeline.runToTypedOpt`,
which requires `testValue` because the synthetic `main` it adds to the module
refers to it. `sumHelperModule` defines `sumHelper : Int -> Int -> Int`, and
`sumListModule` defines `sumList : List Int -> Int -> Int`, which matches on
its list; both are annotated, self-recursive, with plain-variable parameters,
and called from `testValue`.

Types are compared with `TestLogic.LocalOpt.Typed.TypeEq.alphaEqStrict`, so a
type's arguments are compared too, and a type variable never matches a concrete
type.

Each test finds the `TailDef` of its function in a `Cycle` node of the typed
local graph and checks:

  - that the `TailDef` exists, and that the function has an annotation;
  - that the `TailDef` has as many parameters as the annotation has arrows;
  - that each parameter's type matches the annotation's type at that position;
  - that the type stored on the `TailDef` matches the whole annotation, so the
    field holds the definition's type and not only its result type. The stored
    type is taken from the same table of annotations, so this guards the
    field's meaning rather than the optimizer's typing;
  - that the type of the `TailDef`'s body, which the optimizer computes,
    matches what is left of the annotation after every arrow.

Among what is not tested: parameters bound by destructuring patterns, type
variables or aliases in the annotation, a `TailDef` local to a `let`, a cycle
of more than one definition, and the erased optimizer.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , ifExpr
        , intExpr
        , listExpr
        , makeModuleWithTypedDefs
        , pCons
        , pList
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as Name exposing (Name)
import Data.Map
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.LocalOpt.Typed.TypeEq as TypeEq
import TestLogic.TestPipeline as Pipeline


{-| The two tests, each checking one fixture's `TailDef` against its
annotation.
-}
suite : Test
suite =
    Test.describe "TailDef type invariants (TOPT_TAILDEF_001)"
        [ Test.test "TailDef args and return type match annotation for sumHelper (Int -> Int -> Int)" <|
            \_ -> checkFixture "sumHelper" sumHelperModule
        , Test.test "TailDef args and return type match annotation for sumList (List Int -> Int -> Int)" <|
            \_ -> checkFixture "sumList" sumListModule
        ]



-- ============================================================================
-- TEST: sumHelper : Int -> Int -> Int
-- ============================================================================


{-| A module with an annotated, tail-recursive `sumHelper` and a `testValue`
that calls it. As Elm source:

    sumHelper : Int -> Int -> Int
    sumHelper acc n =
        if n <= 0 then
            acc

        else
            sumHelper (acc + n) (n - 1)

    testValue : Int
    testValue =
        sumHelper 0 10

-}
sumHelperModule : Src.Module
sumHelperModule =
    let
        intType =
            tType "Int" []

        funcType =
            tLambda intType (tLambda intType intType)
    in
    makeModuleWithTypedDefs "Test"
        [ { name = "sumHelper"
          , args = [ pVar "acc", pVar "n" ]
          , tipe = funcType
          , body =
                ifExpr
                    (binopsExpr [ ( varExpr "n", "<=" ) ] (intExpr 0))
                    (varExpr "acc")
                    (callExpr (varExpr "sumHelper")
                        [ binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "n")
                        , binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                        ]
                    )
          }
        , { name = "testValue"
          , args = []
          , tipe = intType
          , body = callExpr (varExpr "sumHelper") [ intExpr 0, intExpr 10 ]
          }
        ]


{-| A module with an annotated, tail-recursive `sumList` that matches on its
list, and a `testValue` that calls it. As Elm source:

    sumList : List Int -> Int -> Int
    sumList xs acc =
        case xs of
            [] ->
                acc

            x :: rest ->
                sumList rest (acc + x)

    testValue : Int
    testValue =
        sumList [ 1, 2, 3 ] 0

-}
sumListModule : Src.Module
sumListModule =
    let
        intType =
            tType "Int" []
    in
    makeModuleWithTypedDefs "Test"
        [ { name = "sumList"
          , args = [ pVar "xs", pVar "acc" ]
          , tipe = tLambda (tType "List" [ intType ]) (tLambda intType intType)
          , body =
                caseExpr (varExpr "xs")
                    [ ( pList [], varExpr "acc" )
                    , ( pCons (pVar "x") (pVar "rest")
                      , callExpr (varExpr "sumList")
                            [ varExpr "rest"
                            , binopsExpr [ ( varExpr "acc", "+" ) ] (varExpr "x")
                            ]
                      )
                    ]
          }
        , { name = "testValue"
          , args = []
          , tipe = intType
          , body = callExpr (varExpr "sumList") [ listExpr [ intExpr 1, intExpr 2, intExpr 3 ], intExpr 0 ]
          }
        ]


{-| The expectation of one test: `srcModule` compiles to a typed local graph
whose `TailDef` for `funcName` agrees with its annotation, as
`checkTailDefTypes` decides. A pipeline failure fails the test with the
pipeline's message.
-}
checkFixture : String -> Src.Module -> Expectation
checkFixture funcName srcModule =
    case Pipeline.runToTypedOpt srcModule of
        Err msg ->
            Expect.fail ("Pipeline failed: " ++ msg)

        Ok { localGraph, annotations } ->
            checkTailDefTypes funcName localGraph annotations



-- ============================================================================
-- VERIFICATION HELPERS
-- ============================================================================


{-| Checks the `TailDef` named `funcName` in the `Cycle` nodes of a typed local
graph against the annotation for `funcName` in `annotations`.

It fails if no such `TailDef` or annotation exists, if the parameter count
differs from the annotation's arrow count, if a parameter type does not match
the annotation's, if the stored type does not match the whole annotation, or
if the body's type does not match the annotation's result type, all under
`TypeEq.alphaEqStrict`. A count mismatch is reported alone; the type
mismatches are reported together.

-}
checkTailDefTypes : String -> TOpt.LocalGraph Name -> Dict Name.Name (Can.Annotation Name) -> Expectation
checkTailDefTypes funcName (TOpt.LocalGraph data) annotations =
    let
        maybeTailDef =
            Data.Map.toList data.nodes
                |> List.filterMap
                    (\( _, node ) ->
                        case node of
                            TOpt.Cycle _ _ defs _ ->
                                List.filterMap
                                    (\def ->
                                        case def of
                                            TOpt.TailDef _ name args body defType _ ->
                                                if name == funcName then
                                                    Just ( args, body, defType )

                                                else
                                                    Nothing

                                            _ ->
                                                Nothing
                                    )
                                    defs
                                    |> List.head

                            _ ->
                                Nothing
                    )
                |> List.head

        maybeAnnotation =
            Dict.get funcName annotations
    in
    case ( maybeTailDef, maybeAnnotation ) of
        ( Nothing, _ ) ->
            Expect.fail "TailDef not found in any Cycle node"

        ( Just ( args, body, defType ), Just (Can.Forall _ annType) ) ->
            let
                ( expectedArgTypes, expectedReturnType ) =
                    splitFunctionType annType

                actualReturnType =
                    TOpt.typeOf body

                actualArgTypes =
                    List.map (\( _, t ) -> t) args

                argTypesMatch =
                    List.length actualArgTypes == List.length expectedArgTypes

                argTypeErrors =
                    List.map2
                        (\actual expected ->
                            if TypeEq.alphaEqStrict actual expected then
                                Nothing

                            else
                                Just
                                    ("Arg type mismatch: expected "
                                        ++ typeToString expected
                                        ++ ", got "
                                        ++ typeToString actual
                                    )
                        )
                        actualArgTypes
                        expectedArgTypes
                        |> List.filterMap identity

                defTypeError =
                    if TypeEq.alphaEqStrict defType annType then
                        []

                    else
                        [ "Stored TailDef type mismatch: expected the whole annotation "
                            ++ typeToString annType
                            ++ ", got "
                            ++ typeToString defType
                        ]

                returnTypeError =
                    if TypeEq.alphaEqStrict actualReturnType expectedReturnType then
                        []

                    else
                        [ "Body type mismatch: expected "
                            ++ typeToString expectedReturnType
                            ++ ", got "
                            ++ typeToString actualReturnType
                        ]

                allErrors =
                    argTypeErrors ++ defTypeError ++ returnTypeError
            in
            if not argTypesMatch then
                Expect.fail
                    ("Arg count mismatch: expected "
                        ++ String.fromInt (List.length expectedArgTypes)
                        ++ ", got "
                        ++ String.fromInt (List.length actualArgTypes)
                    )

            else if List.isEmpty allErrors then
                Expect.pass

            else
                Expect.fail (String.join "; " allErrors)

        ( Just _, Nothing ) ->
            Expect.fail ("No annotation found for " ++ funcName)



-- ============================================================================
-- TYPE UTILITIES
-- ============================================================================


{-| Splits a type into the parameter types of all its arrows and the result
type after the last one. A type that is not a function gives no parameters
and itself as the result. An alias is not looked through.
-}
splitFunctionType : Can.Type Name -> ( List (Can.Type Name), Can.Type Name )
splitFunctionType tipe =
    case tipe of
        Can.TLambda _ arg res ->
            let
                ( restArgs, ret ) =
                    splitFunctionType res
            in
            ( arg :: restArgs, ret )

        _ ->
            ( [], tipe )


{-| Renders a type for a failure message. Records render as `{...}`, an alias
as its name alone, and type arguments without parentheses.
-}
typeToString : Can.Type Name -> String
typeToString tipe =
    case tipe of
        Can.TVar name ->
            "TVar \"" ++ name ++ "\""

        Can.TType _ name [] ->
            name

        Can.TType _ name args ->
            name ++ " " ++ String.join " " (List.map typeToString args)

        Can.TLambda _ from to ->
            "(" ++ typeToString from ++ " -> " ++ typeToString to ++ ")"

        Can.TUnit ->
            "()"

        Can.TRecord _ _ ->
            "{...}"

        Can.TTuple a b rest ->
            "(" ++ String.join ", " (List.map typeToString (a :: b :: rest)) ++ ")"

        Can.TAlias _ name _ _ ->
            name
