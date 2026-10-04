module TestLogic.Monomorphize.TailFuncSpecializationTest exposing (suite)

{-| Pins the types the monomorphizer gives a tail-recursive top-level function,
so that a specialization whose parameter types or function type disagree with
the function's annotation does not go unnoticed.

The substitution engine, which these tests run, specializes a tail-recursive
top-level function to a `Mono.MonoTailFunc` node. The node carries the
function's parameters, each with its `MonoType`, and one `MonoType` for the
whole function, not only for its result. The first test expects that
whole-function type to be _nested_: one `MFunction` per arrow of the
annotation, each taking one parameter, so `Int -> Int -> Int` is
`MFunction [MInt] (MFunction [MInt] MInt)` rather than the flattened
`MFunction [MInt, MInt] MInt`.

The fixture, `sumHelperModule`, is a module with two annotated definitions:
`sumHelper : Int -> Int -> Int`, which adds `n` down to zero into the
accumulator `acc` and calls itself in tail position, and `testValue`, which
calls `sumHelper 0 10`. It is run through `TestLogic.TestPipeline.runToMono`;
the `TestLogic.TestPipeline` module docstring says how the synthetic `main` it
adds makes `testValue` reachable.

The tests establish:

  - "sumHelper MonoTailFunc has nested ...": the first `MonoTailFunc` node in
    the graph has two parameters, each of type `MInt`, and its function type
    is `MFunction [MInt] (MFunction [MInt] MInt)`. Types are compared by
    `monoTypesMatch`, which ignores lambda-set annotations.
  - "MonoTailFunc arg count matches expected arity": the first `MonoTailFunc`
    node in the graph has two parameters.

Both fail when the pipeline fails or the graph has no `MonoTailFunc` node.

Among what is not tested: that the node checked is `sumHelper`'s, since both
take the first `MonoTailFunc` node whatever its name (`sumHelper` is the
fixture's only tail-recursive definition); the lambda-set annotations on the
arrows; the node's body; a polymorphic tail-recursive function, or one
specialized at more than one type; the solver engine; and the graph after
global optimization.

-}

import Array
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
import Compiler.Data.Id as Id
import Expect exposing (Expectation)
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


{-| The two tail-function specialization tests, described in the module
docstring.
-}
suite : Test
suite =
    Test.describe "MonoTailFunc specialization type invariants (MONO_TAILFUNC_001)"
        [ Test.test "sumHelper MonoTailFunc has nested Mono.mFunction [MInt] (Mono.mFunction [MInt] MInt)" <|
            \_ -> checkSumHelperMono
        , Test.test "MonoTailFunc arg count matches expected arity" <|
            \_ -> checkMonoTailFuncArity
        ]



-- ============================================================================
-- FIXTURE AND TESTS
-- ============================================================================


{-| The fixture: a module named `Test` holding these two definitions.

    sumHelper : Int -> Int -> Int
    sumHelper acc n =
        if n <= 0 then
            acc

        else
            sumHelper (acc + n) (n - 1)

    testValue : Int
    testValue =
        sumHelper 0 10

`testValue` calls `sumHelper` at `Int`, which is what makes `sumHelper`
reachable and so specialized.

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
          , body =
                callExpr (varExpr "sumHelper") [ intExpr 0, intExpr 10 ]
          }
        ]


{-| Runs the fixture to monomorphization and checks its first `MonoTailFunc`
node's parameter and function types with `checkMonoTailFuncType`, failing if
the pipeline fails.
-}
checkSumHelperMono : Expectation
checkSumHelperMono =
    case Pipeline.runToMono sumHelperModule of
        Err msg ->
            Expect.fail ("Pipeline failed: " ++ msg)

        Ok { monoGraph } ->
            checkMonoTailFuncType "sumHelper" monoGraph


{-| Runs the fixture to monomorphization and checks that its first
`MonoTailFunc` node has two parameters, failing if the pipeline fails.
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


{-| Passes when the first `MonoTailFunc` node in the graph has the types of
`sumHelper : Int -> Int -> Int`: exactly two parameters, each matching `MInt`,
and a function type matching `MFunction [MInt] (MFunction [MInt] MInt)`.
Otherwise it fails with every mismatch found, and a wrong parameter count
skips the comparison of parameter types.

The expected types are fixed here, not derived from an argument, and the node
is the first `MonoTailFunc` in node order whatever its name: `funcName` is used
only in the message when the graph has no such node. Types are compared with
`monoTypesMatch`, so lambda-set annotations are ignored.

-}
checkMonoTailFuncType : String -> Mono.MonoGraph -> Expectation
checkMonoTailFuncType funcName (Mono.MonoGraph data) =
    let
        tailFuncNodes =
            Array.toList data.nodes
                |> List.filterMap
                    (\maybeNode ->
                        case maybeNode of
                            Just (Mono.MonoTailFunc args _ monoType) ->
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

                expectedArgTypes =
                    [ Mono.MInt, Mono.MInt ]

                expectedMonoType =
                    Mono.mFunction Mono.topLegacy [ Mono.MInt ] (Mono.mFunction Mono.topLegacy [ Mono.MInt ] Mono.MInt)

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

                -- The node's type is the whole function's type, not its result type.
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


{-| Passes when the first `MonoTailFunc` node in the graph has `expectedCount`
parameters, and fails when it has another number or the graph has no such
node.

The node is the first `MonoTailFunc` in node order whatever its name:
`funcName` is used only in the failure messages.

-}
checkMonoTailFuncArgCount : String -> Int -> Mono.MonoGraph -> Expectation
checkMonoTailFuncArgCount funcName expectedCount (Mono.MonoGraph data) =
    let
        tailFuncNodes =
            Array.toList data.nodes
                |> List.filterMap
                    (\maybeNode ->
                        case maybeNode of
                            Just (Mono.MonoTailFunc args _ _) ->
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


{-| Reports whether two `MonoType`s match, comparing the primitive types by
constructor and lists and functions structurally, with lambda-set annotations
ignored.

Two custom types match when their home, name and number of arguments agree,
whatever the arguments are. Tuples, records and type variables never match
anything, not even themselves.

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

        ( Mono.MList _ a, Mono.MList _ b ) ->
            monoTypesMatch a b

        ( Mono.MFunction _ _ args1 ret1, Mono.MFunction _ _ args2 ret2 ) ->
            List.length args1
                == List.length args2
                && List.all identity (List.map2 monoTypesMatch args1 args2)
                && monoTypesMatch ret1 ret2

        ( Mono.MCustom _ home1 name1 args1, Mono.MCustom _ home2 name2 args2 ) ->
            home1 == home2 && name1 == name2 && List.length args1 == List.length args2

        ( Mono.MVar _ _, _ ) ->
            -- A type variable left in a specialized type is a mismatch,
            -- even against itself.
            False

        _ ->
            False


{-| Renders a `MonoType` for a failure message. Lambda-set annotations are
left out, and record and tuple types are shown without their contents.
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

        Mono.MList _ inner ->
            "Mono.mList (" ++ monoTypeToString inner ++ ")"

        Mono.MFunction _ _ args ret ->
            "Mono.mFunction ["
                ++ String.join ", " (List.map monoTypeToString args)
                ++ "] "
                ++ monoTypeToString ret

        Mono.MCustom _ _ name args ->
            "Mono.mCustom " ++ name ++ " [" ++ String.join ", " (List.map monoTypeToString args) ++ "]"

        Mono.MRecord _ _ ->
            "Mono.mRecord {...}"

        Mono.MTuple _ _ ->
            "Mono.mTuple (...)"

        Mono.MVar mvarId _ ->
            "MVar \"" ++ String.fromInt (Id.toComparable mvarId) ++ "\""
