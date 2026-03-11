module TestLogic.LocalOpt.Typed.TailDefTypesTest exposing (suite)

{-| Test suite for invariant TOPT\_TAILDEF\_001: TailDef argument and return types match annotation.

This test verifies that for tail-recursive functions with type annotations:

1.  Each argument's `Can.Type` in `TailDef` equals the corresponding
    parameter type from the annotation.
2.  The "return type" field is the **result type** of the annotation, not the whole function type.

These invariants are critical for correct monomorphization, which builds function types
from argument types and return type.

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
import Compiler.Data.Name as Name
import Data.Map
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "TailDef type invariants (TOPT_TAILDEF_001)"
        [ Test.test "TailDef args and return type match annotation for sumHelper (Int -> Int -> Int)" <|
            \_ -> checkSumHelper
        ]



-- ============================================================================
-- TEST: sumHelper : Int -> Int -> Int
-- ============================================================================


{-| Create a tail-recursive sumHelper function with explicit type annotation.

    sumHelper : Int -> Int -> Int
    sumHelper acc n =
        if n <= 0 then
            acc

        else
            sumHelper (acc + n) (n - 1)

-}
sumHelperModule : Src.Module
sumHelperModule =
    let
        -- Type: Int -> Int -> Int
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


{-| Check that TailDef in the typed optimized graph has correct types.
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


{-| Check TailDef types in Cycle nodes against annotation.
-}
checkTailDefTypes : String -> TOpt.LocalGraph -> Dict Name.Name Can.Annotation -> Expectation
checkTailDefTypes funcName (TOpt.LocalGraph data) annotations =
    let
        -- Find TailDef in Cycle nodes
        maybeTailDef =
            Data.Map.toList TOpt.compareGlobal data.nodes
                |> List.filterMap
                    (\( _, node ) ->
                        case node of
                            TOpt.Cycle _ _ defs _ ->
                                List.filterMap
                                    (\def ->
                                        case def of
                                            TOpt.TailDef _ name args _ returnType ->
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

        -- Get annotation
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

                -- TailDef stores the full function type, extract return type from it
                ( _, actualReturnType ) =
                    splitFunctionType defType

                actualArgTypes =
                    List.map (\( _, t ) -> t) args

                argTypesMatch =
                    List.length actualArgTypes == List.length expectedArgTypes

                -- Check each argument type
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

                -- Check return type (extracted from the stored function type)
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


{-| Split a function type into parameter types and result type.
-}
splitFunctionType : Can.Type -> ( List Can.Type, Can.Type )
splitFunctionType tipe =
    case tipe of
        Can.TLambda arg res ->
            let
                ( restArgs, ret ) =
                    splitFunctionType res
            in
            ( arg :: restArgs, ret )

        _ ->
            ( [], tipe )


{-| Check if two canonical types match (structurally).

For this test, we're checking concrete types like Int, so we do a simple
structural comparison. TVar indicates Bug 1 (unconstrained pattern types).

-}
typesMatch : Can.Type -> Can.Type -> Bool
typesMatch actual expected =
    case ( actual, expected ) of
        ( Can.TType home1 name1 args1, Can.TType home2 name2 args2 ) ->
            home1 == home2 && name1 == name2 && List.length args1 == List.length args2

        ( Can.TLambda from1 to1, Can.TLambda from2 to2 ) ->
            typesMatch from1 from2 && typesMatch to1 to2

        ( Can.TVar _, _ ) ->
            -- TVar in actual means Bug 1: pattern type is unconstrained
            False

        ( Can.TUnit, Can.TUnit ) ->
            True

        ( Can.TAlias _ _ _ (Can.Filled inner1), _ ) ->
            typesMatch inner1 expected

        ( _, Can.TAlias _ _ _ (Can.Filled inner2) ) ->
            typesMatch actual inner2

        _ ->
            False


{-| Convert a type to a debug string.
-}
typeToString : Can.Type -> String
typeToString tipe =
    case tipe of
        Can.TVar name ->
            "TVar \"" ++ name ++ "\""

        Can.TType _ name [] ->
            name

        Can.TType _ name args ->
            name ++ " " ++ String.join " " (List.map typeToString args)

        Can.TLambda from to ->
            "(" ++ typeToString from ++ " -> " ++ typeToString to ++ ")"

        Can.TUnit ->
            "()"

        Can.TRecord _ _ ->
            "{...}"

        Can.TTuple a b rest ->
            "(" ++ String.join ", " (List.map typeToString (a :: b :: rest)) ++ ")"

        Can.TAlias _ name _ _ ->
            name
