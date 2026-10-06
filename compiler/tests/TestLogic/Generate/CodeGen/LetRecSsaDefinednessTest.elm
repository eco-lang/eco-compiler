module TestLogic.Generate.CodeGen.LetRecSsaDefinednessTest exposing (suite)

{-| Runs the SSA definedness check over the whole standard catalogue of test
programs, so that generated MLIR in which a function uses a value it never
defines is caught in any of those programs, not only in a few chosen by hand.

In MLIR an SSA value is a name beginning with `%` that one place defines and
any number of operands use. The check is aimed at recursive `let` groups, where
the code generator gives each bound name a placeholder SSA name that sibling
closures can capture, and something must then define that placeholder. The
check, and what counts as a definition and a use, is
`TestLogic.Generate.CodeGen.LetRecSsaDefinedness`; its docstring sets out the
rules.

The programs are the ones `SourceIR.Suite.StandardTestSuites.expectSuite`
gathers from its case modules. Each is compiled to MLIR with
`TestLogic.TestPipeline.runToMlir`, which compiles it the way a default build
does.

  - `suite` passes for a program when it compiles to MLIR and, in every
    top-level `func.func`, each operand beginning with `%` is defined somewhere
    in that function. A program that does not compile fails.

Among what is not tested:

  - That a definition comes before its uses, or is in a scope they can see.
  - MLIR produced by the solver monomorphization engine.
  - Programs of the `SourceIR` case modules that the standard catalogue leaves
    out.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.LetRecSsaDefinedness exposing (expectLetRecSsaDefinedness)


{-| The group of tests that applies the SSA definedness check to every program
of the standard catalogue.
-}
suite : Test
suite =
    Test.describe "SSA Definedness (let-rec placeholder)"
        [ StandardTestSuites.expectSuite expectLetRecSsaDefinedness "passes SSA definedness check"
        ]
