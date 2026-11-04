module Compiler.Canonicalize.DependencySCCTest exposing (suite)

{-| Pins the components the canonicalizer groups each program of
`SourceIR.DependencySCCCases` into.

The canonicalizer groups a module's top-level definitions into the strongly
connected components (SCCs) of their dependency graph. The rules every
grouping must follow (CANON\_005) are checked over the whole standard
catalogue, these programs included, by
`TestLogic.Canonicalize.DependencySCCTest`. Here each program is passed to
`TestLogic.Canonicalize.DependencySCC.expectSCCGroups`, which checks the same
rules and compares the components, in any order, with the expected ones: each
a list of definition names and whether it is a recursive group.

The tests:

  - "independent definitions have separate SCCs": `a`, `b`, `c` and
    `testValue`, four non-recursive components.
  - "linear dependency chain": `a`, `b = a`, `c = b`, `testValue = c`.
  - "dependency written after its use": the same chain in reverse source
    order, so the canonicalizer must reorder the source.
  - "simple function dependency": `helper`, `result = helper 42`,
    `testValue`.
  - "self-recursive function": `loop`, a recursive group of one, and
    `testValue`.
  - "mutually recursive functions": `ping` and `pong`, a recursive group of
    two, then `user` and `testValue`.

-}

import Compiler.Core.Name exposing (Name)
import Compiler.IR.Source as Src
import SourceIR.DependencySCCCases as Cases
import Test exposing (Test)
import TestLogic.Canonicalize.DependencySCC exposing (expectSCCGroups)


{-| The six tests the module docstring lists.
-}
suite : Test
suite =
    Test.describe "Dependency SCC groups of pinned programs (CANON_005)"
        [ pin "independent definitions have separate SCCs"
            Cases.independent
            [ ( [ "a" ], False ), ( [ "b" ], False ), ( [ "c" ], False ), ( [ "testValue" ], False ) ]
        , pin "linear dependency chain"
            Cases.chain
            [ ( [ "a" ], False ), ( [ "b" ], False ), ( [ "c" ], False ), ( [ "testValue" ], False ) ]
        , pin "dependency written after its use"
            Cases.reversed
            [ ( [ "a" ], False ), ( [ "b" ], False ), ( [ "c" ], False ), ( [ "testValue" ], False ) ]
        , pin "simple function dependency"
            Cases.fnDep
            [ ( [ "helper" ], False ), ( [ "result" ], False ), ( [ "testValue" ], False ) ]
        , pin "self-recursive function"
            Cases.selfRec
            [ ( [ "loop" ], True ), ( [ "testValue" ], False ) ]
        , pin "mutually recursive functions"
            Cases.mutualRec
            [ ( [ "ping", "pong" ], True ), ( [ "user" ], False ), ( [ "testValue" ], False ) ]
        ]


{-| The test named `label` that expects `modul` to be grouped into `expected`.
-}
pin : String -> Src.Module -> List ( List Name, Bool ) -> Test
pin label modul expected =
    Test.test label <| \_ -> expectSCCGroups expected modul
