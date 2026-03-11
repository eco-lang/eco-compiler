module TestLogic.Generate.CodeGen.KernelDeclAbiPolicy exposing (expectKernelDeclAbiPolicy)

{-| Test logic for KERN\_006: Kernel ABI Type Arbitration invariant.

For every func.func with is\_kernel=true, verify that the declaration types
match the policy from kernelBackendAbiPolicy. AllBoxed kernels must have
all params and return as !eco.value.

@docs expectKernelDeclAbiPolicy

-}

import Compiler.AST.Source as Src
import Compiler.Generate.MLIR.Context exposing (KernelBackendAbiPolicy(..), kernelBackendAbiPolicy)
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirAttr(..), MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , getBoolAttr
        , getStringAttr
        , isEcoValueType
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
                        AllBoxed ->
                            checkAllBoxedTypes symName op

                        ElmDerived ->
                            []


{-| Parse "eco\_Elm\_Kernel\_Utils\_equal" or similar into ("Utils", "equal").
-}
parseKernelName : String -> Maybe ( String, String )
parseKernelName symName =
    let
        stripped =
            if String.startsWith "eco_Elm_Kernel_" symName then
                String.dropLeft (String.length "eco_Elm_Kernel_") symName

            else if String.startsWith "Elm_Kernel_" symName then
                String.dropLeft (String.length "Elm_Kernel_") symName

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


checkAllBoxedTypes : String -> MlirOp -> List Violation
checkAllBoxedTypes symName op =
    case getFunctionTypeAttr op of
        Nothing ->
            []

        Just ( paramTypes, returnTypes ) ->
            let
                paramViolations =
                    List.indexedMap
                        (\i t ->
                            if isEcoValueType t then
                                Nothing

                            else
                                Just
                                    { opId = op.id
                                    , opName = "func.func"
                                    , message =
                                        "AllBoxed kernel '"
                                            ++ symName
                                            ++ "' has non-!eco.value param type at index "
                                            ++ String.fromInt i
                                            ++ ": "
                                            ++ Debug.toString t
                                    }
                        )
                        paramTypes

                returnViolations =
                    List.indexedMap
                        (\i t ->
                            if isEcoValueType t then
                                Nothing

                            else
                                Just
                                    { opId = op.id
                                    , opName = "func.func"
                                    , message =
                                        "AllBoxed kernel '"
                                            ++ symName
                                            ++ "' has non-!eco.value return type at index "
                                            ++ String.fromInt i
                                            ++ ": "
                                            ++ Debug.toString t
                                    }
                        )
                        returnTypes
            in
            List.filterMap identity paramViolations
                ++ List.filterMap identity returnViolations


{-| Extract function type from func.func's function\_type attribute.
The attribute is stored as TypeAttr (FunctionType { inputs, results }).
-}
getFunctionTypeAttr : MlirOp -> Maybe ( List MlirType, List MlirType )
getFunctionTypeAttr op =
    case Dict.get "function_type" op.attrs of
        Just (TypeAttr (FunctionType { inputs, results })) ->
            Just ( inputs, results )

        _ ->
            Nothing
