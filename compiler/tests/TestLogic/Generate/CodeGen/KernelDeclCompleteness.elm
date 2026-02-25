module TestLogic.Generate.CodeGen.KernelDeclCompleteness exposing (expectKernelDeclCompleteness)

{-| Test logic for CGEN\_057: Kernel Declaration Completeness invariant.

Every kernel function symbol (Elm\_Kernel\_\*) that appears in a papCreate,
papExtend, or eco.call operation must have a corresponding func.func
declaration with is\_kernel=true.

@docs expectKernelDeclCompleteness

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getBoolAttr
        , getStringAttr
        , violationsToExpectation
        , walkAllOps
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that kernel declaration completeness invariants hold for a source module.
-}
expectKernelDeclCompleteness : Src.Module -> Expectation
expectKernelDeclCompleteness srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkKernelDeclCompleteness mlirModule)


{-| Check kernel declaration completeness invariants.

Builds a set of func.func declarations marked is\_kernel=true, then checks
every papCreate, papExtend, and eco.call that references an Elm\_Kernel\_\*
symbol has a matching declaration.

-}
checkKernelDeclCompleteness : MlirModule -> List Violation
checkKernelDeclCompleteness mlirModule =
    let
        kernelDecls =
            buildKernelDeclSet mlirModule

        allOps =
            walkAllOps mlirModule
    in
    List.filterMap (checkOp kernelDecls) allOps


{-| Build a set of kernel function names that have func.func declarations.

Only includes functions with is\_kernel=true attribute.

-}
buildKernelDeclSet : MlirModule -> Dict String ()
buildKernelDeclSet mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.foldl
        (\op acc ->
            case getStringAttr "sym_name" op of
                Nothing ->
                    acc

                Just symName ->
                    if isKernelName symName && getBoolAttr "is_kernel" op == Just True then
                        Dict.insert symName () acc

                    else
                        acc
        )
        Dict.empty
        funcOps


{-| Check a single op for kernel declaration completeness.
-}
checkOp : Dict String () -> MlirOp -> Maybe Violation
checkOp kernelDecls op =
    if op.name == "eco.papCreate" then
        checkPapCreateOp kernelDecls op

    else if op.name == "eco.papExtend" then
        checkPapExtendOp kernelDecls op

    else if op.name == "eco.call" then
        checkCallOp kernelDecls op

    else
        Nothing


{-| Check a papCreate op: its "function" attr must reference a declared kernel.
-}
checkPapCreateOp : Dict String () -> MlirOp -> Maybe Violation
checkPapCreateOp kernelDecls op =
    case getStringAttr "function" op of
        Nothing ->
            Nothing

        Just funcName ->
            if isKernelName funcName && not (Dict.member funcName kernelDecls) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.papCreate references kernel '"
                            ++ funcName
                            ++ "' which has no func.func is_kernel=true declaration (CGEN_057)"
                    }

            else
                Nothing


{-| Check a papExtend op: its "function" attr (if present) must reference a declared kernel.

Note: papExtend may not always have a direct function attr if extending from a
papCreate chain, but when it does reference a kernel directly, the declaration
must exist.

-}
checkPapExtendOp : Dict String () -> MlirOp -> Maybe Violation
checkPapExtendOp kernelDecls op =
    case getStringAttr "function" op of
        Nothing ->
            Nothing

        Just funcName ->
            if isKernelName funcName && not (Dict.member funcName kernelDecls) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.papExtend references kernel '"
                            ++ funcName
                            ++ "' which has no func.func is_kernel=true declaration (CGEN_057)"
                    }

            else
                Nothing


{-| Check an eco.call op: its "callee" attr must reference a declared kernel.
-}
checkCallOp : Dict String () -> MlirOp -> Maybe Violation
checkCallOp kernelDecls op =
    case getStringAttr "callee" op of
        Nothing ->
            Nothing

        Just callee ->
            let
                calleeName =
                    if String.startsWith "@" callee then
                        String.dropLeft 1 callee

                    else
                        callee
            in
            if isKernelName calleeName && not (Dict.member calleeName kernelDecls) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.call references kernel '"
                            ++ calleeName
                            ++ "' which has no func.func is_kernel=true declaration (CGEN_057)"
                    }

            else
                Nothing


{-| Check if a function name is an Elm kernel function.
-}
isKernelName : String -> Bool
isKernelName name =
    String.startsWith "Elm_Kernel_" name
