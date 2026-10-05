module TestLogic.Canonicalize.LimitErrorsTest exposing (suite)

{-| Eco limits a closure's stage arity to 2047 (`HEAP_078`): a function or
lambda with more parameters, or a lambda whose parameters plus captured
variables exceed it, must be rejected by canonicalization with a located
`TooLarge` error (bug B18, decision D5 and §S.9 of
`plans/wide-object-tail-kind-words.md`), not fail late in the backend. These
tests check that each such shape is reported as the right `TooLarge` variant,
that a function at exactly the limit is accepted, and that the report names the
function and the limit.

Each test builds a small source module with `Compiler.AST.SourceBuilder`,
whose parameter lists are built with `List.range`, and hands it to an
expectation from `TestLogic.Canonicalize.LimitErrors`, which canonicalizes it
and looks only at the errors, matching the `TooLarge` constructor and its
`TooLargeWhat`, actual count and limit.

The tests establish:

  - a top-level function with 2048 parameters is one `TooLarge` with
    `TooManyParams "big"`, 2048 and 2047;
  - the same function defined in a `let` is the same error;
  - a lambda with 2048 parameters is a `TooLarge` with `TooManyLambdaParams`;
  - a lambda with 2000 parameters capturing 48 locals is a `TooLarge` with
    `TooManyClosureSlots Nothing`, 2048 and 2047;
  - a function with 2047 parameters is accepted;
  - the report of the 2048-parameter error is titled `TOO MANY PARAMETERS`
    and names `big` and the limit 2047.

Among what is not tested: the region the error carries, record and constructor
field limits (added by Phase 3D), and compiler-generated arity.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as SB
import Compiler.Reporting.Error.Canonicalize as CanError
import Test exposing (Test)
import TestLogic.Canonicalize.LimitErrors
    exposing
        ( expectCanonicalizes
        , expectFirstReportContains
        , expectTooLarge
        )


{-| The whole suite.
-}
suite : Test
suite =
    Test.describe "Front-end limit diagnostics (B18, D5)"
        [ Test.test "a top-level function with 2048 parameters is TooLarge TooManyParams" <|
            \_ ->
                expectTooLarge (CanError.TooManyParams "big") 2048 2047 (topLevelBig 2048)
        , Test.test "a let-defined function with 2048 parameters is TooLarge TooManyParams" <|
            \_ ->
                expectTooLarge (CanError.TooManyParams "big") 2048 2047 (letBig 2048)
        , Test.test "a lambda with 2048 parameters is TooLarge TooManyLambdaParams" <|
            \_ ->
                expectTooLarge CanError.TooManyLambdaParams 2048 2047 (lambdaOf 2048)
        , Test.test "a lambda with 2000 parameters capturing 48 locals is TooLarge TooManyClosureSlots" <|
            \_ ->
                expectTooLarge (CanError.TooManyClosureSlots Nothing) 2048 2047 (capturingLambda 48 2000)
        , Test.test "a function with 2047 parameters is accepted" <|
            \_ ->
                expectCanonicalizes (topLevelBig 2047)
        , Test.test "the TooLarge report names the function and the limit" <|
            \_ ->
                expectFirstReportContains [ "TOO MANY PARAMETERS", "big", "2047" ] (topLevelBig 2048)
        ]


{-| Returns the variable patterns `prefix0` to `prefix(n-1)`.
-}
params : String -> Int -> List Src.Pattern
params prefix n =
    List.map (\i -> SB.pVar (prefix ++ String.fromInt i)) (List.range 0 (n - 1))


{-| A module whose top-level function `big a0 … a(n-1) = a0` takes `n`
parameters.
-}
topLevelBig : Int -> Src.Module
topLevelBig n =
    SB.makeModuleWithDefs "Test"
        [ ( "big", params "a" n, SB.varExpr "a0" ) ]


{-| A module whose value `testValue` defines `big a0 … a(n-1) = a0` in a
`let` and returns it.
-}
letBig : Int -> Src.Module
letBig n =
    SB.makeModuleWithDefs "Test"
        [ ( "testValue"
          , []
          , SB.letExpr [ SB.define "big" (params "a" n) (SB.varExpr "a0") ] (SB.varExpr "big")
          )
        ]


{-| A module whose value `f = \a0 … a(n-1) -> a0` is a lambda of `n`
parameters.
-}
lambdaOf : Int -> Src.Module
lambdaOf n =
    SB.makeModuleWithDefs "Test"
        [ ( "f", [], SB.lambdaExpr (params "a" n) (SB.varExpr "a0") ) ]


{-| A module whose function `mk c0 … c(captured-1)` returns the lambda
`\a0 … a(arity-1) -> c0 + … + c(captured-1) + a0`, which captures every `c`.
-}
capturingLambda : Int -> Int -> Src.Module
capturingLambda captured arity =
    let
        capturedTerms =
            List.map (\i -> ( SB.varExpr ("c" ++ String.fromInt i), "+" )) (List.range 0 (captured - 1))
    in
    SB.makeModuleWithDefs "Test"
        [ ( "mk"
          , params "c" captured
          , SB.lambdaExpr (params "a" arity) (SB.binopsExpr capturedTerms (SB.varExpr "a0"))
          )
        ]
