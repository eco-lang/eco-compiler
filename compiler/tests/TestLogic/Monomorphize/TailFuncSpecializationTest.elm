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

  - "sumHelper MonoTailFunc has nested ...": the registry lists exactly one
    `MonoTailFunc` node for `sumHelper`; it has two parameters, each of type
    `MInt`, and its function type is `MFunction [MInt] (MFunction [MInt] MInt)`.
    Types are compared by `monoTypesMatch` (`Mono.eqKeyLayout`), which
    ignores lambda-set annotations.
  - "MonoTailFunc arg count matches expected arity": `sumHelper`'s
    `MonoTailFunc` node has two parameters.

Both fail when the pipeline fails or the registry lists no `MonoTailFunc` node
for `sumHelper`.

Among what is not tested: the lambda-set annotations on the arrows; the node's body; a polymorphic tail-recursive function, or one
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


{-| Returns the parameters and type of every `MonoTailFunc` node that the
registry lists for a global named `funcName`.
-}
tailFuncNodesOf : String -> Mono.MonoGraph -> List ( List ( String, Mono.MonoType ), Mono.MonoType )
tailFuncNodesOf funcName (Mono.MonoGraph data) =
    List.filterMap
        (\( specId, entry ) ->
            case ( entry, Array.get specId data.nodes ) of
                ( Just ( Mono.Global _ name, _ ), Just (Just (Mono.MonoTailFunc args _ monoType)) ) ->
                    if name == funcName then
                        Just ( args, monoType )

                    else
                        Nothing

                _ ->
                    Nothing
        )
        (Array.toIndexedList data.registry.reverseMapping)


{-| Tells whether two `MonoType`s are equal ignoring their lambda-set
annotations.
-}
monoTypesMatch : Mono.MonoType -> Mono.MonoType -> Bool
monoTypesMatch =
    Mono.eqKeyLayout


{-| Renders a `MonoType` for a failure message.
-}
monoTypeToString : Mono.MonoType -> String
monoTypeToString =
    Mono.monoTypeToDebugString


{-| Passes when the graph has exactly one `MonoTailFunc` node registered for
`funcName` and it has the types of `sumHelper : Int -> Int -> Int`: exactly two
parameters, each `MInt`, and the function type
`MFunction [MInt] (MFunction [MInt] MInt)`. Otherwise it fails with every
mismatch found, and a wrong parameter count skips the comparison of parameter
types.

The expected types are fixed here, not derived from an argument. Types are
compared with `monoTypesMatch`, so lambda-set annotations are ignored.

-}
checkMonoTailFuncType : String -> Mono.MonoGraph -> Expectation
checkMonoTailFuncType funcName graph =
    case tailFuncNodesOf funcName graph of
        [] ->
            Expect.fail ("No MonoTailFunc node found for " ++ funcName)

        _ :: _ :: _ ->
            Expect.fail ("More than one MonoTailFunc node for " ++ funcName)

        [ ( args, monoType ) ] ->
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


{-| Passes when the first `MonoTailFunc` node registered for `funcName` has
`expectedCount` parameters, and fails when it has another number or the graph
has no such node.
-}
checkMonoTailFuncArgCount : String -> Int -> Mono.MonoGraph -> Expectation
checkMonoTailFuncArgCount funcName expectedCount graph =
    case List.map (Tuple.first >> List.length) (tailFuncNodesOf funcName graph) of
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
