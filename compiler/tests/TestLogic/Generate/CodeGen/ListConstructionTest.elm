module TestLogic.Generate.CodeGen.ListConstructionTest exposing (suite)

{-| The eco MLIR dialect has its own operations for lists: `eco.construct.list`
builds a cons cell, and the empty list is an `eco.constant`. These tests look,
across many programs rather than a hand-picked few, for a list constructor
built instead with `eco.construct.custom`, the generic operation for a value of
a custom type.

The fixture is the standard catalogue of `SourceIR` test programs gathered by
`SourceIR.Suite.StandardTestSuites`. Two of its case modules hold fuzz tests,
whose programs can vary from run to run.

What the tests establish:

  - `suite`: for each program in the catalogue, that
    `TestLogic.TestPipeline.runToMlir` succeeds on it and that the MLIR module
    it generates has no `eco.construct.custom` op whose `constructor`
    attribute is `::` or `[]`, as
    `TestLogic.Generate.CodeGen.ListConstruction.expectListConstruction`
    describes.

The catalogue includes, in `SourceIR.CaseCases`, a program that declares its
own `Cons` and `Nil` constructors and puts values built with them in a list
literal, on which the check must not report the program's own constructors.
That the program's `Cons` is built with an `eco.construct.custom` at all, so
that this is not vacuous, is pinned by the unit test
`Compiler.GenerateMlir.OpsUserListCtorTest`.

Among what is not tested:

  - that cons cells are built with `eco.construct.list`, or that the empty
    list is an `eco.constant`;
  - an `eco.construct.custom` op with no `constructor` attribute.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.ListConstruction exposing (expectListConstruction)


{-| The test group that runs the list-construction check on every program in
the standard catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_016: List Construction"
        [ StandardTestSuites.expectSuite expectListConstruction "passes list construction invariant"
        ]
