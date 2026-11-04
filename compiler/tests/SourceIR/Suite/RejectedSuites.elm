module SourceIR.Suite.RejectedSuites exposing (expectSuite)

{-| This module lets a check be run against the whole negative catalogue of
`SourceIR` test programs, the programs the compiler must reject, in one call,
as `SourceIR.Suite.StandardTestSuites` does for the programs it must accept.

The negative catalogue is one case module per rejecting stage, so a case's
module says which stage must reject it. `expectSuite` passes each module's
cases to the caller's expectation together with that stage
(`TestLogic.TestPipeline.Stage`) and the `SourceIR.Suite.Rejection.Rejection`
the case records. The six modules, in the order a build reaches their stages:

  - `SourceIR.CanonicalizeFailsCases`: canonicalization (`Canonicalize`);
  - `SourceIR.LimitFailsCases`: canonicalization's size limits, also
    `Canonicalize`;
  - `SourceIR.TypeCheckFailsCases`: type checking (`TypeCheck`);
  - `SourceIR.PatternFailsCases`: pattern-match checking (`PatternMatch`);
  - `SourceIR.MainFailsCases`: typed optimization's check of `main`
    (`TypedOptimize`);
  - `SourceIR.MonoFailsCases`: the build's steps after `Compiler.Compile`
    (`Monomorphize`).

As with the standard catalogue, what is checked is decided by the caller.

-}

import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import SourceIR.CanonicalizeFailsCases as CanonicalizeFailsCases
import SourceIR.LimitFailsCases as LimitFailsCases
import SourceIR.MainFailsCases as MainFailsCases
import SourceIR.MonoFailsCases as MonoFailsCases
import SourceIR.PatternFailsCases as PatternFailsCases
import SourceIR.Suite.Rejection exposing (Rejection)
import SourceIR.TypeCheckFailsCases as TypeCheckFailsCases
import Test exposing (Test)
import TestLogic.TestPipeline exposing (Stage(..))


{-| Builds one group of tests named `condStr`, holding the `expectRejectedSuite`
of each negative case module, with `expectFn` given the stage of the module
first. `condStr` is passed on to each module, whose own group name ends with
it.
-}
expectSuite : (Stage -> Src.Module -> Rejection -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe condStr
        [ CanonicalizeFailsCases.expectRejectedSuite (expectFn Canonicalize) condStr
        , LimitFailsCases.expectRejectedSuite (expectFn Canonicalize) condStr
        , TypeCheckFailsCases.expectRejectedSuite (expectFn TypeCheck) condStr
        , PatternFailsCases.expectRejectedSuite (expectFn PatternMatch) condStr
        , MainFailsCases.expectRejectedSuite (expectFn TypedOptimize) condStr
        , MonoFailsCases.expectRejectedSuite (expectFn Monomorphize) condStr
        ]
