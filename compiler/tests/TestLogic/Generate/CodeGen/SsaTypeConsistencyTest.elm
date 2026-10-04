module TestLogic.Generate.CodeGen.SsaTypeConsistencyTest exposing (suite)

{-| Within one function, generated MLIR must not give an SSA name two different
types. These tests look for such a conflict in the MLIR compiled from the
standard catalogue of test programs, so that a code-generation change that
breaks the rule on one of those programs is reported.

An _SSA name_ is the name of a value that is defined once, as a block argument
or as the result of an operation, and then read by name. Two functions may use
the same names, so the rule is checked one function at a time.

The programs are those of `SourceIR.Suite.StandardTestSuites`, each given in
turn to `TestLogic.Generate.CodeGen.SsaTypeConsistency.expectSsaTypeConsistency`.

  - `suite` compiles each program to MLIR and checks every top-level
    `func.func`: each block argument and operation result inside it, at any
    depth of nesting and in sibling regions alike, is recorded under its name,
    and a name recorded with two different types fails the test. A program that
    does not compile to MLIR also fails.

Among what is not tested:

  - The types at which values are read. Only definitions are compared.
  - Whether a name is defined more than once. A repeated definition with the
    same type passes.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.SsaTypeConsistency exposing (expectSsaTypeConsistency)


{-| The group of tests that checks SSA type consistency in the MLIR compiled
from each program of the standard catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_0B1: SSA Type Consistency"
        [ StandardTestSuites.expectSuite expectSsaTypeConsistency "passes SSA type consistency invariant"
        ]
