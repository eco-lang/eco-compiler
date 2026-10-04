module TestLogic.Generate.CodeGen.KernelDeclCompletenessTest exposing (suite)

{-| Runs the kernel declaration completeness check on every program in the
standard catalogue of `SourceIR` test programs, so that generated MLIR that
refers to a kernel without declaring it is caught on many programs rather than
on a hand-picked few.

A kernel is a function implemented by the runtime rather than compiled from
Elm. Its implementation is not in the generated module, which instead holds a
top-level `func.func` stub for it marked `is_kernel`. The check, as
`TestLogic.Generate.CodeGen.KernelDeclCompleteness` describes, looks for
references to `Elm_Kernel_` symbols that have no such declaration.

The programs are those that `SourceIR.Suite.StandardTestSuites.expectSuite`
supplies.

What the tests establish:

  - For each program, `expectKernelDeclCompleteness` passes: the program
    compiles to MLIR, and every `Elm_Kernel_` symbol named by the `function`
    attribute of an `eco.papCreate` or `eco.papExtend`, or by the `callee` of
    an `eco.call`, is the `sym_name` of a top-level `func.func` with
    `is_kernel` true.

Among what is not tested: kernel symbols with any other prefix, such as
`Eco_Kernel_`; whether a declaration's type agrees with the references to it;
and programs outside the standard catalogue.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.KernelDeclCompleteness exposing (expectKernelDeclCompleteness)


{-| The test group that applies `expectKernelDeclCompleteness` to every
program in the standard catalogue.
-}
suite : Test
suite =
    Test.describe "CGEN_057: Kernel Declaration Completeness"
        [ StandardTestSuites.expectSuite expectKernelDeclCompleteness "passes kernel declaration completeness invariant"
        ]
