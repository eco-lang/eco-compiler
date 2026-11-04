module Compiler.GenerateMlir.CmpiPredicateAttrTest exposing (suite)

{-| Pins how code generation compiles the two character `case` programs of
`SourceIR.CharCaseCases`, so that the `arith.cmpi` predicate check those
programs were written for has a character comparison to look at.

A `case` with one character literal and a catch-all branch becomes a single
test that compares the character with an `arith.cmpi`; a `case` with several
character literals and a catch-all branch becomes a fan-out, one `eco.case` on
the character with `case_kind` `"chr"`, with no `arith.cmpi` for its literals.
The predicate check itself runs over the whole standard catalogue, these
programs included, as `TestLogic.Generate.CodeGen.CmpiPredicateAttrTest`.

The tests:

  - "Simple char case emits arith.cmpi with predicate" checks
    `simpleCharCase` with `expectCmpiPresentWithPredicate`: at least one
    `arith.cmpi` must be generated, and every one must have a valid predicate.
  - "Multi-branch char case compiles to a chr eco.case" checks
    `multiBranchCharCase`: the MLIR must hold an `eco.case` with `case_kind`
    `"chr"`.

-}

import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import SourceIR.CharCaseCases as CharCaseCases
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CmpiPredicateAttr exposing (expectCmpiPresentWithPredicate)
import TestLogic.Generate.CodeGen.Invariants exposing (findOpsNamed, getStringAttr)
import TestLogic.TestPipeline exposing (runToMlir)


{-| The two tests the module docstring describes.
-}
suite : Test
suite =
    Test.describe "arith.cmpi predicate attribute: char case pins"
        [ Test.test "Simple char case emits arith.cmpi with predicate" <|
            \_ -> expectCmpiPresentWithPredicate CharCaseCases.simpleCharCase
        , Test.test "Multi-branch char case compiles to a chr eco.case" <|
            \_ -> expectChrCase CharCaseCases.multiBranchCharCase
        ]


{-| Passes when `srcModule` compiles to MLIR holding an `eco.case` whose
`case_kind` is `"chr"`.
-}
expectChrCase : Src.Module -> Expectation
expectChrCase srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            findOpsNamed "eco.case" mlirModule
                |> List.any (\op -> getStringAttr "case_kind" op == Just "chr")
                |> Expect.equal True
                |> Expect.onFail "Expected an eco.case with case_kind \"chr\""
