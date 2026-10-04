module TestLogic.Generate.CodeGen.TypeTableUniqueness exposing (expectTypeTableUniqueness)

{-| The code generator emits a program's type table, the `eco.type_table` op
that records the program's types, as a top-level op of the MLIR module. A
second one in the same module would be a code generation fault, and this module
holds the check for it.

The check is `expectTypeTableUniqueness`. It takes the fixture from its caller:
a source module, which it compiles with `TestLogic.TestPipeline.runToMlir`.

What the check establishes:

  - The source module compiles as far as `runToMlir` takes it; an `Err` fails
    the expectation with the test pipeline's error message.
  - The top-level ops of the generated MLIR module include at most one named
    `eco.type_table`. Zero passes.

Among what is not tested: ops nested inside other ops' regions are not
searched; that a type table is present at all, or what it contains; and the
MLIR the build emits, since `runToMlir` generates its module with
`Compiler.Generate.MLIR.Backend.generateMlirModule` rather than the build's
streaming writers.

@docs expectTypeTableUniqueness

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that `srcModule` compiles to an MLIR module with at
most one `eco.type_table` op among its top-level ops.

A compilation failure fails the expectation with a message that starts
`Compilation failed` and gives the test pipeline's error message. A module with
several type tables fails with a message that gives their count.

-}
expectTypeTableUniqueness : Src.Module -> Expectation
expectTypeTableUniqueness srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkTypeTableUniqueness mlirModule)


{-| Returns one violation, giving the count, when the top-level ops of
`mlirModule` include more than one `eco.type_table`, and no violations
otherwise.
-}
checkTypeTableUniqueness : MlirModule -> List Violation
checkTypeTableUniqueness mlirModule =
    let
        typeTableOps =
            List.filter (\op -> op.name == "eco.type_table") mlirModule.body

        typeTableCount =
            List.length typeTableOps
    in
    if typeTableCount > 1 then
        [ { opId = "module"
          , opName = "module"
          , message =
                "Module has "
                    ++ String.fromInt typeTableCount
                    ++ " eco.type_table ops, expected at most 1"
          }
        ]

    else
        []
