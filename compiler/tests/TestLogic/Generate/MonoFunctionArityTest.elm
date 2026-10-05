module TestLogic.Generate.MonoFunctionArityTest exposing (suite)

{-| Runs the function arity check over the standard catalogue of test
programs, so that a function whose parameters disagree with the arity of its
type after global optimization is looked for in all of those programs rather
than in a hand-picked few.

The check is `TestLogic.Generate.MonoFunctionArity.expectFunctionArityMatches`.
That module's docstring defines the _stage arity_ (the parameter count of a
function type's outermost stage) and the _flattened arity_ (the parameter
count of all its stages together), and lists the mismatches it reports. It
compiles each program through the global optimizer
(`TestLogic.TestPipeline.runToGlobalOpt`) and fails on a pipeline error or on
any mismatch it finds.

The fixture is the set of programs built by the case modules that
`SourceIR.Suite.StandardTestSuites` includes.

What `suite` establishes, for each program those case modules hand to the
check:

  - that it compiles through the global optimizer without an error;
  - that, in the nodes and expressions the check walks, no closure's parameter
    count differs from the stage arity of its type, no tail function node's
    parameter count differs from the stage arity of its type, and no call
    whose callee's type has a flattened arity above 0 passes more arguments
    than that arity.

Among what is not tested: the parameters of a `MonoTailDef` in a `let`, a call
with fewer arguments than its callee's arity, which is accepted as a partial
application, and nodes other than defines, tail functions and ports.

`tailFuncReturningFunction` adds one program of its own: a tail-recursive
function of two parameters whose type, `Int -> Int -> Int -> Int`, also
returns a function. Its parameters match its first stage once the global
optimizer has split its type, though its flattened arity is 3.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , makeModuleWithTypedDefs
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.MonoFunctionArity exposing (expectFunctionArityMatches)


{-| The test group that applies `expectFunctionArityMatches` to the standard
catalogue of test programs.
-}
suite : Test
suite =
    Test.describe "Function arity matches (MONO_012)"
        [ StandardTestSuites.expectSuite expectFunctionArityMatches "has matching function arity"
        , Test.test "a tail-recursive function that returns a function" <|
            \_ -> expectFunctionArityMatches tailFuncReturningFunction
        ]


{-| `f : Int -> Int -> Int -> Int` defined with two parameters,
`f n acc = if n == 0 then \x -> x + acc else f (n - 1) (acc + 1)`, so its
tail-function node has 2 parameters while its type flattens to 3, and
`testValue = f 3 0 10`.
-}
tailFuncReturningFunction : Src.Module
tailFuncReturningFunction =
    let
        tInt =
            tType "Int" []
    in
    makeModuleWithTypedDefs "TailFn"
        [ { name = "f"
          , args = [ pVar "n", pVar "acc" ]
          , tipe = tLambda tInt (tLambda tInt (tLambda tInt tInt))
          , body =
                ifExpr (binopsExpr [ ( varExpr "n", "==" ) ] (intExpr 0))
                    (lambdaExpr [ pVar "x" ] (binopsExpr [ ( varExpr "x", "+" ) ] (varExpr "acc")))
                    (callExpr (varExpr "f")
                        [ binopsExpr [ ( varExpr "n", "-" ) ] (intExpr 1)
                        , binopsExpr [ ( varExpr "acc", "+" ) ] (intExpr 1)
                        ]
                    )
          }
        , { name = "testValue"
          , args = []
          , tipe = tInt
          , body = callExpr (varExpr "f") [ intExpr 3, intExpr 0, intExpr 10 ]
          }
        ]
