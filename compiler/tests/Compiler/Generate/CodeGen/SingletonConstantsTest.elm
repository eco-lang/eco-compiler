module Compiler.Generate.CodeGen.SingletonConstantsTest exposing (suite)

{-| Test suite for CGEN_019: Singleton Constants invariant.

Well-known singletons (Unit, True, False, Nil, Nothing, EmptyString, EmptyRec)
must always use `eco.constant`, never `eco.construct.custom`.

-}

import Compiler.Generate.CodeGen.SingletonConstants exposing (expectSingletonConstants)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_019: Singleton Constants"
        [ StandardTestSuites.expectSuite expectSingletonConstants "passes singleton constants invariant"
        ]
