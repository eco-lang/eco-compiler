module TestLogic.Generate.MonoNumericResolutionTest exposing (suite)

{-| Monomorphization must leave no number variable in the program it hands to
code generation, and must resolve a number type the same way on both sides of
a call. A number variable is an `MVar` with the `CNumber` constraint, and it
stands for an `Int` or a `Float` not yet chosen. This module runs the two
checks in `TestLogic.Generate.MonoNumericResolution` on the programs of the
standard test catalogue, those `SourceIR.Suite.StandardTestSuites.expectSuite`
gathers from its case modules.

  - `noNumericPolymorphismSuite` applies `expectNoNumericPolymorphism`: the
    graph after the post-monomorphization inliner and the global optimizer
    (`TestLogic.TestPipeline.runToGlobalOpt`, what MLIR generation receives)
    holds no number variable in any type, at any depth.
  - `numericTypesResolvedSuite` applies `expectNumericTypesResolved`: in the
    monomorphized graph (`runToMono`), no call passes an `Int` where its
    callee's type says `Float`, or the reverse. It also runs on
    `double n = n + n` used as `double 2` and `double 2.5`, whose two
    specializations must each agree with their calls.

Both use the substitution engine. Among what is not tested: tail calls, the
engine a default build uses, and the `SourceIR` case modules the standard
catalogue leaves out.

-}

import Compiler.AST.SourceBuilder as SB
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.MonoNumericResolution
    exposing
        ( expectNoNumericPolymorphism
        , expectNumericTypesResolved
        )


{-| All the tests of this module: `noNumericPolymorphismSuite` and
`numericTypesResolvedSuite` in one group.
-}
suite : Test
suite =
    Test.describe "Numeric type resolution in monomorphization"
        [ noNumericPolymorphismSuite
        , numericTypesResolvedSuite
        ]


{-| The group that applies `expectNoNumericPolymorphism` to the programs of the
standard catalogue, on the graph MLIR generation receives.
-}
noNumericPolymorphismSuite : Test
noNumericPolymorphismSuite =
    Test.describe "No CNumber MVar at MLIR entry (MONO_002)"
        [ StandardTestSuites.expectSuite expectNoNumericPolymorphism "has no CNumber MVars"
        ]


{-| The group that applies `expectNumericTypesResolved`, which compares call
arguments with their parameters, to the programs of the standard catalogue.
-}
numericTypesResolvedSuite : Test
numericTypesResolvedSuite =
    Test.describe "Numeric types fixed at call sites (MONO_008)"
        [ StandardTestSuites.expectSuite expectNumericTypesResolved "has resolved numeric types"
        , Test.test "a number function used at Int and at Float" <|
            \_ ->
                expectNumericTypesResolved
                    (SB.makeModuleWithDefs "NumBoth"
                        [ ( "double", [ SB.pVar "n" ], SB.binopsExpr [ ( SB.varExpr "n", "+" ) ] (SB.varExpr "n") )
                        , ( "testValue"
                          , []
                          , SB.tupleExpr
                                (SB.callExpr (SB.varExpr "double") [ SB.intExpr 2 ])
                                (SB.callExpr (SB.varExpr "double") [ SB.floatExpr 2.5 ])
                          )
                        ]
                    )
        ]
