module TestLogic.Generate.CodeGen.JoinpointUniqueIdTest exposing (suite)

{-| Runs the tail-recursion lowering check,
`TestLogic.Generate.CodeGen.JoinpointUniqueId.expectJoinpointUniqueId`, on every
program of the standard `SourceIR` catalogue and on two tail-recursive programs
built here.

The code generator lowers every self-tail-recursive function to an `scf.while`
loop, not to the `eco.joinpoint`/`eco.jump` pair the dialect also offers. The
check fails when a tail-recursive function's generated `func.func` holds no
`scf.while` or holds an `eco.jump`, and keeps the old rule that joinpoint ids
are unique within a function for any joinpoint that does appear.

What the tests establish:

  - `suite` compiles each catalogue program with `runToMlir`, and passes for it
    when compilation succeeds and the check finds nothing.
  - `focusedTests` compiles `sumTo n acc = if n <= 0 then acc else sumTo (n - 1) (acc + n)`
    (an `Int` loop) and `count xs acc = case xs of [] -> acc; _ :: rest -> count rest (acc + 1)`
    (a loop over a list), and additionally requires that the MLIR holds an
    `scf.while`, so the tests cannot pass with the recursion optimised away.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as SB
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.Invariants exposing (findOpsNamed)
import TestLogic.Generate.CodeGen.JoinpointUniqueId exposing (expectJoinpointUniqueId)
import TestLogic.TestPipeline exposing (runToMlir)


{-| The test group of this module: the standard catalogue's suites, each
applying `expectJoinpointUniqueId` to its programs.
-}
suite : Test
suite =
    Test.describe "CGEN_031: Tail recursion lowering and joinpoint ID uniqueness"
        [ StandardTestSuites.expectSuite expectJoinpointUniqueId "passes joinpoint unique id invariant"
        , focusedTests
        ]


{-| `expectJoinpointUniqueId` on `modul`, plus the requirement that its MLIR
holds an `scf.while`.
-}
expectTailLoop : Src.Module -> Expect.Expectation
expectTailLoop modul =
    Expect.all
        [ expectJoinpointUniqueId
        , \m ->
            case runToMlir m of
                Err err ->
                    Expect.fail ("Compilation failed: " ++ err)

                Ok { mlirModule } ->
                    findOpsNamed "scf.while" mlirModule
                        |> List.isEmpty
                        |> Expect.equal False
                        |> Expect.onFail "Expected an scf.while for the tail-recursive function"
        ]
        modul


{-| The two tail-recursive programs the module docstring describes.
-}
focusedTests : Test
focusedTests =
    let
        int =
            SB.tType "Int" []

        sumToDef =
            { name = "sumTo"
            , args = [ SB.pVar "n", SB.pVar "acc" ]
            , tipe = SB.tLambda int (SB.tLambda int int)
            , body =
                SB.ifExpr (SB.binopsExpr [ ( SB.varExpr "n", "<=" ) ] (SB.intExpr 0))
                    (SB.varExpr "acc")
                    (SB.callExpr (SB.varExpr "sumTo")
                        [ SB.parensExpr (SB.binopsExpr [ ( SB.varExpr "n", "-" ) ] (SB.intExpr 1))
                        , SB.parensExpr (SB.binopsExpr [ ( SB.varExpr "acc", "+" ) ] (SB.varExpr "n"))
                        ]
                    )
            }

        countDef =
            { name = "count"
            , args = [ SB.pVar "xs", SB.pVar "acc" ]
            , tipe = SB.tLambda (SB.tType "List" [ int ]) (SB.tLambda int int)
            , body =
                SB.caseExpr (SB.varExpr "xs")
                    [ ( SB.pList [], SB.varExpr "acc" )
                    , ( SB.pCons SB.pAnything (SB.pVar "rest")
                      , SB.callExpr (SB.varExpr "count")
                            [ SB.varExpr "rest"
                            , SB.parensExpr (SB.binopsExpr [ ( SB.varExpr "acc", "+" ) ] (SB.intExpr 1))
                            ]
                      )
                    ]
            }

        testValue body =
            { name = "testValue", args = [], tipe = int, body = body }
    in
    Test.describe "Tail-recursive functions"
        [ Test.test "Int accumulator loop is an scf.while" <|
            \_ ->
                SB.makeModuleWithTypedDefs "Test"
                    [ sumToDef, testValue (SB.callExpr (SB.varExpr "sumTo") [ SB.intExpr 10, SB.intExpr 0 ]) ]
                    |> expectTailLoop
        , Test.test "list-walking loop is an scf.while" <|
            \_ ->
                SB.makeModuleWithTypedDefs "Test"
                    [ countDef, testValue (SB.callExpr (SB.varExpr "count") [ SB.listExpr [ SB.intExpr 1, SB.intExpr 2 ], SB.intExpr 0 ]) ]
                    |> expectTailLoop
        ]
