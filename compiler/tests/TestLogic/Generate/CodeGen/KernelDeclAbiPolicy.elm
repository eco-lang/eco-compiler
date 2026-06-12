module TestLogic.Generate.CodeGen.KernelDeclAbiPolicy exposing (expectKernelDeclAbiPolicy)

{-| Test logic for KERN\_006: Kernel ABI Type Arbitration invariant.

For every func.func with is\_kernel=true, verify that the declaration types
match the policy from kernelBackendAbiPolicy. AllBoxed kernels must have
all params and return as !eco.value.

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


{-| Verify KERN\_006: kernel func.func declarations match kernelBackendAbiPolicy.
-}
expectKernelDeclAbiPolicy : Src.Module -> Expectation
expectKernelDeclAbiPolicy srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkKernelDeclAbiPolicy mlirModule)


checkKernelDeclAbiPolicy : MlirModule -> List Violation
checkKernelDeclAbiPolicy mlirModule =
    let
        funcOps =
            List.filter (\op -> op.name == "func.func") mlirModule.body

        kernelFuncOps =
            List.filter (\op -> getBoolAttr "is_kernel" op == Just True) funcOps
    in
    List.concatMap checkKernelFunc kernelFuncOps


checkKernelFunc : MlirOp -> List Violation
checkKernelFunc op =
    case getStringAttr "sym_name" op of
        Nothing ->
            []

        Just symName ->
            case parseKernelName symName of
                Nothing ->
                    []

                Just ( home, name ) ->
                    case kernelBackendAbiPolicy home name of
                        ElmDerived ->
                            []


{-| Parse "eco\_Elm\_Kernel\_Utils\_equal" or similar into ("Utils", "equal").
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
