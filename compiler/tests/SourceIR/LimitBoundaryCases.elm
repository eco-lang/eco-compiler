module SourceIR.LimitBoundaryCases exposing (expectSuite)

{-| Programs whose function, constructor and record are exactly at the
runtime's size limits, which canonicalization must accept: the at-limit
controls of `SourceIR.LimitFailsCases`, whose programs are one over.

  - "a function with 2047 parameters": a top-level `big a0 … a2046 = a0`
    (`Compiler.IR.Runtime.HeapLimits.maxStageArity`).
  - "a constructor with 2040 fields and a record alias with 2047 fields":
    `type Wide = Big Int … Int` (`maxCtorFields`) and
    `type alias BigRecord = { f0 : Int, … }` (`maxRecordFields`).

Each also defines `testValue = 0`, which uses none of the wide definitions.

This module only builds the programs and asserts nothing itself; `expectSuite`
runs a caller's expectation over them in turn, stopping at the first that
fails. It is not part of the standard catalogue
(`SourceIR.Suite.StandardTestSuites`): the checks of that catalogue on a
function of 2047 parameters ran for more than four minutes, and one test worker
grew to about 11 GB, before the run was stopped. Only the oracles that need no
more than canonicalization run it (`TestLogic.Canonicalize.SizeLimitsTest`,
`NameClashesTest`).

-}

import Compiler.AST.SourceBuilder as SB
import Compiler.BulkCheck exposing (bulkCheck)
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import Test exposing (Test)


{-| Builds one test, named "Limit boundary cases " followed by `condStr`, that
applies `expectFn` to every program in this module in turn. It fails with the
label of the first program whose expectation fails, and later programs are not
run.
-}
expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.test ("Limit boundary cases " ++ condStr) <|
        \_ ->
            bulkCheck
                (List.map (\( label, build ) -> { label = label, run = \_ -> expectFn (build ()) }) limitCases)


{-| A function, a constructor and a record exactly at their limits.
-}
limitCases : List ( String, () -> Src.Module )
limitCases =
    [ ( "a function with 2047 parameters"
      , \() ->
            SB.makeModuleWithDefs "Test"
                [ ( "big", List.map (\i -> SB.pVar ("a" ++ String.fromInt i)) (List.range 0 2046), SB.varExpr "a0" )
                , ( "testValue", [], SB.intExpr 0 )
                ]
      )
    , ( "a constructor with 2040 fields and a record alias with 2047 fields"
      , \() ->
            SB.makeModuleWithTypedDefsUnionsAliases "Test"
                [ { name = "testValue", args = [], tipe = SB.tType "Int" [], body = SB.intExpr 0 } ]
                [ { name = "Wide", args = [], ctors = [ { name = "Big", args = List.repeat 2040 (SB.tType "Int" []) } ] } ]
                [ { name = "BigRecord"
                  , args = []
                  , tipe = SB.tRecord (List.map (\i -> ( "f" ++ String.fromInt i, SB.tType "Int" [] )) (List.range 0 2046))
                  }
                ]
      )
    ]
