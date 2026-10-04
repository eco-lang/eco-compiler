module TestLogic.Generate.CodeGen.KernelDeclAbiPolicy exposing (expectKernelDeclAbiPolicy)

{-| A kernel is a function implemented by the runtime rather than in Elm, and
the generated MLIR declares kernels as top-level `func.func` ops marked
`is_kernel`. This module checks those declarations against the backend
ABI policy that `Compiler.Generate.MLIR.KernelAbi.kernelBackendAbiPolicy`
assigns to each kernel.

`expectKernelDeclAbiPolicy` compiles a source module to MLIR, takes every
top-level `func.func` whose `is_kernel` attribute is true, and reads the
kernel's home module and name from its `sym_name`. A symbol of the form
`Elm_Kernel_<home>_<name>` or `eco_Elm_Kernel_<home>_<name>` is parsed, where
`<home>` runs to the first underscore and `<name>` is the rest. A declaration
with no `sym_name`, or with a symbol in any other form, such as one starting
`Eco_Kernel_`, is skipped.

The policy has the single value `ElmDerived`, and for it this check reports
nothing. So the expectation passes whenever compilation succeeds, and no
declaration's types are examined.

Among what is not tested: the argument and result types of any kernel
declaration.

@docs expectKernelDeclAbiPolicy

-}

import Compiler.AST.Source as Src
import Compiler.Generate.MLIR.KernelAbi exposing (KernelBackendAbiPolicy(..), kernelBackendAbiPolicy)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , getBoolAttr
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR and checks each
top-level kernel declaration whose symbol has the form
`Elm_Kernel_<home>_<name>` or `eco_Elm_Kernel_<home>_<name>` against
`Compiler.Generate.MLIR.KernelAbi.kernelBackendAbiPolicy`. Other kernel
declarations are skipped.

It fails when compilation fails. Otherwise it passes, because the only policy,
`ElmDerived`, imposes nothing this check tests.

-}
expectKernelDeclAbiPolicy : Src.Module -> Expectation
expectKernelDeclAbiPolicy srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkKernelDeclAbiPolicy mlirModule)


{-| Returns the policy violations of the top-level `func.func` ops in
`mlirModule` whose `is_kernel` attribute is true.
-}
checkKernelDeclAbiPolicy : MlirModule -> List Violation
checkKernelDeclAbiPolicy mlirModule =
    let
        funcOps =
            List.filter (\op -> op.name == "func.func") mlirModule.body

        kernelFuncOps =
            List.filter (\op -> getBoolAttr "is_kernel" op == Just True) funcOps
    in
    List.concatMap checkKernelFunc kernelFuncOps


{-| Returns the policy violations of one kernel declaration. This is always the
empty list: a declaration whose `sym_name` is missing or does not parse is
skipped, and the `ElmDerived` policy reports nothing.
-}
checkKernelFunc : MlirOp -> List Violation
checkKernelFunc op =
    case getStringAttr "sym_name" op of
        Nothing ->
            []

        Just symName ->
            case parseKernelName symName of
                Nothing ->
                    []

                Just _ ->
                    case kernelBackendAbiPolicy of
                        ElmDerived ->
                            []


{-| Returns the home module and name of a kernel symbol, so
`Elm_Kernel_Utils_equal` and `eco_Elm_Kernel_Utils_equal` both give
`( "Utils", "equal" )`.

The home is the text up to the first underscore after the prefix, and the name
is everything after it, so any suffix such as `_Int` stays in the name. Returns
`Nothing` for a symbol without one of the two prefixes, or with no underscore
after the home.

-}
parseKernelName : String -> Maybe ( String, String )
parseKernelName symName =
    let
        stripped =
            if String.startsWith "eco_Elm_Kernel_" symName then
                String.dropLeft 15 symName

            else if String.startsWith "Elm_Kernel_" symName then
                String.dropLeft 11 symName

            else
                ""
    in
    case String.split "_" stripped of
        home :: rest ->
            if List.isEmpty rest then
                Nothing

            else
                Just ( home, String.join "_" rest )

        [] ->
            Nothing
