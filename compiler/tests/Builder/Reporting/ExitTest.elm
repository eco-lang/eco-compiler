module Builder.Reporting.ExitTest exposing (suite)

{-| Regression tests for `Exit.toGenerateReport` on monomorphization errors that
are conditions of the program, not faults of the compiler: none of their
reports may tell the user "This is likely a compiler bug".

  - "STAGE ARITY LIMIT": a program whose closure exceeds the stage arity limit
    is thrown by `Builder.Generate.validateStageArityLimit` as
    `GenerateMonomorphizationError` with a message starting "STAGE ARITY
    LIMIT", built exactly as `Compiler.Pipeline.Steps.checkStageArity` builds
    it. `toGenerateReport` once spared only messages starting
    "specialization ", so this report called it a likely compiler bug; it now
    gets a STAGE ARITY LIMIT report.
  - Polymorphic recursion: the solver engine rejects a recursion whose types
    grow without bound with a message starting "polymorphic recursion cannot
    be monomorphized: " (`Compiler.Monomorphize.Solver.Engine.polymorphicRecursionMessage`).
  - An unsupported construct: a GLSL shader, which the native backend cannot
    compile, fails with a message starting "MonoSolver.unsupported: "
    (`Engine.renderFailure` of an `Unsupported` failure).

The last two were found by the negative catalogue's rejection check
(`SourceIR.MonoFailsCases`, plans/sourceir-catalogue-test-logic.md).

-}

import Builder.Reporting.Exit as Exit
import Builder.Reporting.Exit.Help as Help
import Compiler.Reporting.Doc as D
import Expect
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "monomorphization errors of the program are not reported as compiler bugs"
        [ notACompilerBug "STAGE ARITY LIMIT is not reported as a likely compiler bug"
            ("STAGE ARITY LIMIT\n" ++ "Main.f: closure stage needs 2100 slots")
        , notACompilerBug "polymorphic recursion is not reported as a likely compiler bug"
            ("polymorphic recursion cannot be monomorphized: Main.depth\n"
                ++ "  it calls itself, directly or through other definitions, at ever larger types"
            )
        , notACompilerBug "an unsupported shader is not reported as a likely compiler bug"
            "MonoSolver.unsupported: shader (M6)"
        ]


{-| A test that the report for a `GenerateMonomorphizationError` carrying
`message` does not mention a compiler bug.
-}
notACompilerBug : String -> String -> Test
notACompilerBug label message =
    test label <|
        \_ ->
            Exit.makeToReport (Exit.MakeBadGenerate (Exit.GenerateMonomorphizationError message))
                |> Help.reportToDoc
                |> D.toString
                |> String.contains "compiler bug"
                |> Expect.equal False
                |> Expect.onFail ("a program condition is reported as a likely compiler bug: " ++ message)
