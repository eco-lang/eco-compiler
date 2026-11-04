module TestLogic.Generate.CodeGen.CmpiPredicateAttrTest exposing (suite)

{-| Tests, on the standard catalogue of test programs, that every `arith.cmpi`
in the generated MLIR says which comparison it makes, so that an integer or
character comparison emitted without a valid `predicate` attribute is caught.

Each program `SourceIR.Suite.StandardTestSuites.expectSuite` supplies is given
to `TestLogic.Generate.CodeGen.CmpiPredicateAttr.expectCmpiPredicateAttr`,
which compiles it with `TestLogic.TestPipeline.runToMlir` and fails on an
`arith.cmpi`, at any depth, whose `predicate` is absent, not an integer, or
outside MLIR's numbering 0 (`eq`) to 9 (`uge`). A program with no
`arith.cmpi` passes once it compiles.

The catalogue includes `SourceIR.CharCaseCases`, the character `case`
programs this check was first written for; `Compiler.GenerateMlir.CmpiPredicateAttrTest`
pins how each of those is compiled.

Among what is not tested: whether the predicate is the right comparison, and
the operands and result of an `arith.cmpi`.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CmpiPredicateAttr exposing (expectCmpiPredicateAttr)


{-| `expectCmpiPredicateAttr` over every program of the standard catalogue.
-}
suite : Test
suite =
    Test.describe "arith.cmpi predicate attribute"
        [ StandardTestSuites.expectSuite expectCmpiPredicateAttr "has a valid predicate on every arith.cmpi"
        ]
