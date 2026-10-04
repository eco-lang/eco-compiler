module TestLogic.LocalOpt.Typed.TailDefTypesTest exposing (suite)

{-| Tests that the typed optimizer gives a tail-recursive function's `TailDef`
the parameter types that the function's annotation declares. The substitution
monomorphizer gives a tail-recursive function's parameters the types stored in
its `TailDef`, so without these tests a parameter could carry a wrong type, or
a type variable the solver left unconstrained, into monomorphization
unnoticed.

A `TailDef` is the typed optimizer's form of a definition that calls itself in
tail position. It holds each parameter with the type of its pattern, and the
type of the whole definition. A recursive top-level `TailDef` sits among the
functions of a `Cycle` node, the node that holds a group of mutually recursive
top-level definitions, which may be one definition that refers to itself.

The fixture, `sumHelperModule`, defines the annotated, self-recursive
`sumHelper : Int -> Int -> Int`, whose two parameters are plain variables, and
a `testValue` that calls it. It is compiled with
`TestLogic.TestPipeline.runToTypedOpt`, which requires `testValue` because the
synthetic `main` it adds to the module refers to it.

Types are compared with `typesMatch`, which is not equality. A type
constructor matches on its home module, its name and its number of arguments,
without comparing the arguments, and a type variable on the optimizer's side
never matches.

The one test finds the `TailDef` named `sumHelper` in a `Cycle` node of the
typed local graph and checks:

  - that the `TailDef` exists, and that `sumHelper` has an annotation;
  - that the `TailDef` has as many parameters as the annotation has arrows;
  - that each parameter's type matches the annotation's type at that position;
  - that the result type left after every arrow of the `TailDef`'s stored type
    matches what is left of the annotation after every arrow. The stored type
    is the annotation itself, taken from the same table of annotations, so
    this comparison cannot fail for this fixture.

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
        , ifExpr
        , intExpr
        , makeModuleWithTypedDefs
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
import TestLogic.TestPipeline as Pipeline


{-| A suite of one test, which checks the `TailDef` of `sumHelper` against its
annotation.
-}
suite : Test
suite =
    Test.describe "TailDef type invariants (TOPT_TAILDEF_001)"
        [ Test.test "TailDef args and return type match annotation for sumHelper (Int -> Int -> Int)" <|
            \_ -> checkSumHelper
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


{-| The expectation of the one test: `sumHelperModule` compiles to a typed
local graph whose `TailDef` for `sumHelper` agrees with its annotation, as
`checkTailDefTypes` decides. A pipeline failure fails the test with the
pipeline's message.
-}
checkSumHelper : Expectation
checkSumHelper =
    case Pipeline.runToTypedOpt sumHelperModule of
        Err msg ->
            Expect.fail ("Pipeline failed: " ++ msg)

        Ok { localGraph, annotations } ->
            checkTailDefTypes "sumHelper" localGraph annotations



-- ============================================================================
-- VERIFICATION HELPERS
-- ============================================================================


{-| Checks the `TailDef` named `funcName` in the `Cycle` nodes of a typed local
graph against the annotation for `funcName` in `annotations`.

It fails if no such `TailDef` or annotation exists, if the parameter count
differs from the annotation's arrow count, or if a parameter type or the
result type does not match by `typesMatch`. The result type compared is what
is left of the `TailDef`'s stored type, the type of the whole definition,
after every arrow. A count mismatch is reported alone; the type mismatches
are reported together.

-}
checkTailDefTypes : String -> TOpt.LocalGraph Name -> Dict Name.Name (Can.Annotation Name) -> Expectation
checkTailDefTypes funcName (TOpt.LocalGraph data) annotations =
    let
        maybeTailDef =
            Data.Map.toList TOpt.compareGlobal data.nodes
                |> List.filterMap
                    (\( _, node ) ->
                        case node of
                            TOpt.Cycle _ _ defs _ ->
                                List.filterMap
                                    (\def ->
                                        case def of
                                            TOpt.TailDef _ name args _ returnType _ ->
                                                if name == funcName then
                                                    Just ( args, returnType )

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

        ( Just ( args, defType ), Just (Can.Forall _ annType) ) ->
            let
                ( expectedArgTypes, expectedReturnType ) =
                    splitFunctionType annType

                ( _, actualReturnType ) =
                    splitFunctionType defType

                actualArgTypes =
                    List.map (\( _, t ) -> t) args

                argTypesMatch =
                    List.length actualArgTypes == List.length expectedArgTypes

                argTypeErrors =
                    List.map2
                        (\actual expected ->
                            if typesMatch actual expected then
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

                returnTypeError =
                    if typesMatch actualReturnType expectedReturnType then
                        Nothing

                    else
                        Just
                            ("Return type mismatch: expected "
                                ++ typeToString expectedReturnType
                                ++ ", got "
                                ++ typeToString actualReturnType
                            )

                allErrors =
                    argTypeErrors ++ Maybe.withDefault [] (Maybe.map List.singleton returnTypeError)
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


{-| Returns whether the optimizer's type `actual` matches the annotation's type
`expected`. This is a loose structural comparison, sufficient for `Int`.

Two type constructors match when their home modules, names and numbers of
arguments agree; the arguments themselves are not compared. Two functions
match when their parameter and result types match, whatever their arrow
slots. A `Filled` alias on either side is replaced by its expansion. Unit
matches unit. Everything else fails, including a type variable in `actual`,
a `Holey` alias, and any record or tuple, even an identical one.

-}
typesMatch : Can.Type Name -> Can.Type Name -> Bool
typesMatch actual expected =
    case ( actual, expected ) of
        ( Can.TType home1 name1 args1, Can.TType home2 name2 args2 ) ->
            home1 == home2 && name1 == name2 && List.length args1 == List.length args2

        ( Can.TLambda _ from1 to1, Can.TLambda _ from2 to2 ) ->
            typesMatch from1 from2 && typesMatch to1 to2

        ( Can.TVar _, _ ) ->
            False

        ( Can.TUnit, Can.TUnit ) ->
            True

        ( Can.TAlias _ _ _ (Can.Filled inner1), _ ) ->
            typesMatch inner1 expected

        ( _, Can.TAlias _ _ _ (Can.Filled inner2) ) ->
            typesMatch actual inner2

        _ ->
            False


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
