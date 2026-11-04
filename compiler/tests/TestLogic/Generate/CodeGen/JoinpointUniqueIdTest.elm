module TestLogic.Generate.CodeGen.JoinpointUniqueIdTest exposing (suite)

{-| Runs the tail-recursion lowering check,
`TestLogic.Generate.CodeGen.JoinpointUniqueId.expectJoinpointUniqueId`, on every
program of the standard `SourceIR` catalogue.

The code generator lowers every self-tail-recursive function to an `scf.while`
loop, not to the `eco.joinpoint`/`eco.jump` pair the dialect also offers. The
check fails when a tail-recursive function's generated `func.func` holds no
`scf.while` or holds an `eco.jump`, and keeps the old rule that joinpoint ids
are unique within a function for any joinpoint that does appear.

What the tests establish:

  - `suite` compiles each catalogue program with `runToMlir`, and passes for it
    when compilation succeeds and the check finds nothing.

The tail-recursive programs of the catalogue include those of
`SourceIR.TailRecCaseCases`, among them the top-level `sumTo` (an `Int` loop
under an `if`) and `count` (a loop over a list). That every program of that
module holds an `scf.while`, so that the check cannot pass with the recursion
optimised away, is required by
`TestLogic.Generate.CodeGen.UnscopedTailJumpTest`, not here: a program with no
tail-recursive function passes this check.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.JoinpointUniqueId exposing (expectJoinpointUniqueId)


{-| The test group of this module: the standard catalogue's suites, each
applying `expectJoinpointUniqueId` to its programs.
-}
suite : Test
suite =
    Test.describe "CGEN_031: Tail recursion lowering and joinpoint ID uniqueness"
        [ StandardTestSuites.expectSuite expectJoinpointUniqueId "passes joinpoint unique id invariant"
        ]
