module TestLogic.Monomorphize.TailFuncSpecializationTest exposing (suite)

{-| Test suite for invariant MONO\_TAILFUNC\_001: TailFunc specialization types match annotation.

This test verifies that for tail-recursive functions:

1.  When we build a `MonoType` from argument types and return type,
    the resulting type matches what the monomorphizer produces.

2.  The MonoTailFunc node's argument count and return type match
    the expected monomorphized function type.

Note: Under the stage-aware design, MFunction types are nested (one per TLambda),
not flattened. For `Int -> Int -> Int`, we get `MFunction [MInt] (MFunction [MInt] MInt)`.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
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
import Compiler.Data.Name as Name
import Data.Map as Dict
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "MonoTailFunc specialization type invariants (MONO_TAILFUNC_001)"
        [ Test.test "sumHelper MonoTailFunc has nested MFunction [MInt] (MFunction [MInt] MInt)" <|
            \_ -> checkSumHelperMono
        , Test.test "MonoTailFunc arg count matches expected arity" <|
            \_ -> checkMonoTailFuncArity
        ]



-- ============================================================================
-- TEST: sumHelper : Int -> Int -> Int -> MonoType
-- ============================================================================


{-| Create a tail-recursive sumHelper function with explicit type annotation.

    sumHelper : Int -> Int -> Int
    sumHelper acc n =
        if n <= 0 then
            acc

        else
            sumHelper (acc + n) (n - 1)

Expected MonoType: MFunction [MInt] (MFunction [MInt] MInt)

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
          , body =
                -- Call sumHelper with concrete Int args to trigger monomorphization
                callExpr (varExpr "sumHelper") [ intExpr 0, intExpr 10 ]
          }
        ]


{-| Check that the MonoTailFunc node has the expected MonoType.

For sumHelper : Int -> Int -> Int, we expect:

  - MonoTailFunc with 2 arguments (acc: MInt, n: MInt)
  - Return type: MInt
  - Overall function type: MFunction [MInt] (MFunction [MInt] MInt)

-}
checkSumHelperMono : Expectation
checkSumHelperMono =
    case Pipeline.runToMono sumHelperModule of
        Err msg ->
            Expect.fail ("Pipeline failed: " ++ msg)

        Ok { monoGraph } ->
            checkMonoTailFuncType "sumHelper" monoGraph


{-| Check the MonoTailFunc argument count matches expected arity.
-}
checkMonoTailFuncArity : Expectation
checkMonoTailFuncArity =
    case Pipeline.runToMono sumHelperModule of
        Err msg ->
            Expect.fail ("Pipeline failed: " ++ msg)

        Ok { monoGraph } ->
            checkMonoTailFuncArgCount "sumHelper" 2 monoGraph



-- ============================================================================
-- VERIFICATION HELPERS
-- ============================================================================


{-| Check MonoTailFunc types against expected values.

For sumHelper : Int -> Int -> Int, we expect:

  - MonoTailFunc with 2 arguments (acc: MInt, n: MInt)
  - MonoType field: MFunction [MInt] (MFunction [MInt] MInt) (nested per stage-aware design)

-}
checkMonoTailFuncType : String -> Mono.MonoGraph -> Expectation
checkMonoTailFuncType funcName (Mono.MonoGraph data) =
    let
        -- Find MonoTailFunc node(s)
        tailFuncNodes =
            Dict.toList compare data.nodes
                |> List.filterMap
                    (\( _, node ) ->
                        case node of
                            Mono.MonoTailFunc args _ monoType ->
                                Just ( args, monoType )

                            _ ->
                                Nothing
                    )
    in
    case tailFuncNodes of
        [] ->
            Expect.fail ("No MonoTailFunc node found for " ++ funcName)

        ( args, monoType ) :: _ ->
            let
                actualArgTypes =
                    List.map Tuple.second args

                -- Expected for sumHelper : Int -> Int -> Int
                expectedArgTypes =
                    [ Mono.MInt, Mono.MInt ]

                -- Under stage-aware design, Int -> Int -> Int becomes nested MFunction
                expectedMonoType =
                    Mono.MFunction [ Mono.MInt ] (Mono.MFunction [ Mono.MInt ] Mono.MInt)

                -- Check argument types
                argTypeErrors =
                    if List.length actualArgTypes /= List.length expectedArgTypes then
                        [ "Arg count mismatch: expected "
                            ++ String.fromInt (List.length expectedArgTypes)
                            ++ ", got "
                            ++ String.fromInt (List.length actualArgTypes)
                        ]

                    else
                        List.map2
                            (\actual expected ->
                                if monoTypesMatch actual expected then
                                    Nothing

                                else
                                    Just
                                        ("Arg type mismatch: expected "
                                            ++ monoTypeToString expected
                                            ++ ", got "
                                            ++ monoTypeToString actual
                                        )
                            )
                            actualArgTypes
                            expectedArgTypes
                            |> List.filterMap identity

                -- Check MonoType field (full function type per MONO_004)
                monoTypeError =
                    if monoTypesMatch monoType expectedMonoType then
                        Nothing

                    else
                        Just
                            ("MonoType mismatch: expected "
                                ++ monoTypeToString expectedMonoType
                                ++ ", got "
                                ++ monoTypeToString monoType
                            )

                allErrors =
                    argTypeErrors ++ Maybe.withDefault [] (Maybe.map List.singleton monoTypeError)
            in
            if List.isEmpty allErrors then
                Expect.pass

            else
                Expect.fail (String.join "; " allErrors)


{-| Check that MonoTailFunc has the expected number of arguments.
-}
checkMonoTailFuncArgCount : String -> Int -> Mono.MonoGraph -> Expectation
checkMonoTailFuncArgCount funcName expectedCount (Mono.MonoGraph data) =
    let
        -- Find MonoTailFunc node(s)
        tailFuncNodes =
            Dict.toList compare data.nodes
                |> List.filterMap
                    (\( _, node ) ->
                        case node of
                            Mono.MonoTailFunc args _ _ ->
                                Just (List.length args)

                            _ ->
                                Nothing
                    )
    in
    case tailFuncNodes of
        [] ->
            Expect.fail ("No MonoTailFunc node found for " ++ funcName)

        actualCount :: _ ->
            if actualCount == expectedCount then
                Expect.pass

            else
                Expect.fail
                    ("MonoTailFunc arg count mismatch for "
                        ++ funcName
                        ++ ": expected "
                        ++ String.fromInt expectedCount
                        ++ ", got "
                        ++ String.fromInt actualCount
                        ++ ". This may indicate Bug 1 (pattern types as TVar) or Bug 2 (full func type as return type)"
                    )



-- ============================================================================
-- MONOTYPE UTILITIES
-- ============================================================================


{-| Check if two MonoTypes match structurally.
-}
monoTypesMatch : Mono.MonoType -> Mono.MonoType -> Bool
monoTypesMatch actual expected =
    case ( actual, expected ) of
        ( Mono.MInt, Mono.MInt ) ->
            True

        ( Mono.MFloat, Mono.MFloat ) ->
            True

        ( Mono.MBool, Mono.MBool ) ->
            True

        ( Mono.MChar, Mono.MChar ) ->
            True

        ( Mono.MString, Mono.MString ) ->
            True

        ( Mono.MUnit, Mono.MUnit ) ->
            True

        ( Mono.MList a, Mono.MList b ) ->
            monoTypesMatch a b

        ( Mono.MFunction args1 ret1, Mono.MFunction args2 ret2 ) ->
            List.length args1
                == List.length args2
                && List.all identity (List.map2 monoTypesMatch args1 args2)
                && monoTypesMatch ret1 ret2

        ( Mono.MCustom home1 name1 args1, Mono.MCustom home2 name2 args2 ) ->
            home1 == home2 && name1 == name2 && List.length args1 == List.length args2

        ( Mono.MVar _ _, _ ) ->
            -- MVar indicates unresolved polymorphism - Bug 1
            False

        _ ->
            False


{-| Convert a MonoType to a debug string.
-}
monoTypeToString : Mono.MonoType -> String
monoTypeToString monoType =
    case monoType of
        Mono.MInt ->
            "MInt"

        Mono.MFloat ->
            "MFloat"

        Mono.MBool ->
            "MBool"

        Mono.MChar ->
            "MChar"

        Mono.MString ->
            "MString"

        Mono.MUnit ->
            "MUnit"

        Mono.MList inner ->
            "MList (" ++ monoTypeToString inner ++ ")"

        Mono.MFunction args ret ->
            "MFunction ["
                ++ String.join ", " (List.map monoTypeToString args)
                ++ "] "
                ++ monoTypeToString ret

        Mono.MCustom _ name args ->
            "MCustom " ++ name ++ " [" ++ String.join ", " (List.map monoTypeToString args) ++ "]"

        Mono.MRecord layout ->
            "MRecord {...}"

        Mono.MTuple _ ->
            "MTuple (...)"

        Mono.MVar name _ ->
            "MVar \"" ++ name ++ "\""
