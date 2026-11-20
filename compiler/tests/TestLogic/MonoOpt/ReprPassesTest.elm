module TestLogic.MonoOpt.ReprPassesTest exposing (suite)

{-| Runs every program of the standard `SourceIR` catalogue through the whole
pipeline, to MLIR, with every representation pass of
plans/constructor-representation-levels.md switched on and checked: wrapper
erasure with unboxed fields (E1a, E1b), nullable `Maybe` and Maybe-shaped user
types (N1a, N1b), case of a known constructor (K1) and custom `$sret` results
(S1), under `repr.validate`.

The fixture is the set of programs that
`SourceIR.Suite.StandardTestSuites.expectSuite` hands to an expectation.

What `suite` establishes, for each of those programs, under both the solver
engine (the default) and the substitution engine (bootstrap Stage 5's):

  - the pipeline returns no error, so `Steps.representation` found no MONO_031
    violation and no meet the passes made inconsistent (MONO_029 interior slot
    kinds, MONO_033), and code generation did not crash (for instance on a test
    of `Just` left on a nullable value);
  - MLIR is produced (under the solver engine; under the substitution engine
    the pipeline runs through global optimization only, see
    `expectReprPassesToGlobalOpt`).

Among what is not tested: running the programs, which the E2E fixtures
`test/elm/src/EraseWrapper*Test.elm`, `Nullable*Test.elm`,
`KnownCtorCaseTest.elm` and `SretCtorTest.elm` do.

-}

import Compiler.Config as Config
import Compiler.IR.Source as Src
import Expect exposing (Expectation)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


allOn : Config.EcoConfig -> Config.EcoConfig
allOn cfg =
    let
        repr =
            cfg.repr
    in
    { cfg
        | sretResults = True
        , repr =
            { repr
                | eraseWrappers = True
                , eraseUnboxed = True
                , nullableMaybe = True
                , nullableUser = True
                , knownCtorCase = True
                , sretCtors = True
                , validate = True
            }
    }


expectReprPasses : Config.EcoConfig -> Src.Module -> Expectation
expectReprPasses cfg srcModule =
    case Pipeline.runToMlirWith (allOn cfg) srcModule of
        Ok _ ->
            Expect.pass

        Err msg ->
            Expect.fail ("Compilation failed with every representation pass on: " ++ msg)


{-| As `expectReprPasses`, through global optimization only: MLIR generation
under the substitution engine crashes on two catalogue programs with or
without the representation passes ("cannot coerce i64 to f64", Mono refine
coverage and Number through a compound field), which is not this suite's
concern.
-}
expectReprPassesToGlobalOpt : Config.EcoConfig -> Src.Module -> Expectation
expectReprPassesToGlobalOpt cfg srcModule =
    case Pipeline.runToGlobalOptWith (allOn cfg) srcModule of
        Ok _ ->
            Expect.pass

        Err msg ->
            Expect.fail ("Compilation failed with every representation pass on: " ++ msg)


{-| The test group that compiles every program of the standard `SourceIR`
catalogue with every representation pass on, under both engines.
-}
suite : Test
suite =
    Test.describe "Representation passes (plans/constructor-representation-levels.md)"
        [ StandardTestSuites.expectSuite (expectReprPasses Pipeline.productionConfig) "compiles with every representation pass on (solver)"
        , StandardTestSuites.expectSuite (expectReprPassesToGlobalOpt Pipeline.stage5Config) "compiles with every representation pass on (subst)"
        ]
