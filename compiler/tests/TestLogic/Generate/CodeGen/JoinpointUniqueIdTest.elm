module TestLogic.Generate.CodeGen.JoinpointUniqueIdTest exposing (suite)

{-| An `eco.jump` names the joinpoint it transfers control to by an integer, so
two joinpoints with the same integer in one function would make the jump
ambiguous. This module runs the check for that on every program of the standard
`SourceIR` catalogue, rather than on a few chosen programs.

A _joinpoint_ is an `eco.joinpoint` op, identified within its function by its
integer `id` attribute. The check itself, `expectJoinpointUniqueId`, is
described in `TestLogic.Generate.CodeGen.JoinpointUniqueId`.

The programs are those that `SourceIR.Suite.StandardTestSuites.expectSuite`
gathers from its case modules. Two of those modules hold fuzz tests, whose
programs vary from run to run.

What the tests establish:

  - `suite` compiles each program to MLIR with `runToMlir`, and passes for it
    when compilation succeeds and no top-level `func.func` holds a joinpoint
    without an integer `id`, or two joinpoints with the same `id`.

The code generator builds no `eco.joinpoint` op, so on these programs the check
finds no joinpoint, and a test here fails only when compilation fails.

Among what is not tested: whether each `eco.jump` names a joinpoint that exists.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.JoinpointUniqueId exposing (expectJoinpointUniqueId)


{-| The test group of this module: the standard catalogue's suites, each
applying `expectJoinpointUniqueId` to its programs.
-}
suite : Test
suite =
    Test.describe "CGEN_031: Joinpoint ID Uniqueness"
        [ StandardTestSuites.expectSuite expectJoinpointUniqueId "passes joinpoint unique id invariant"
        ]
