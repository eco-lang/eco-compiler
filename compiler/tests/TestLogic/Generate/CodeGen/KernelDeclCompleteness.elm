module TestLogic.Generate.CodeGen.KernelDeclCompleteness exposing (expectKernelDeclCompleteness)

{-| Checks that the MLIR generated for a module declares the kernel functions
it refers to by `Elm_Kernel_` symbols. A kernel function is one implemented by
the runtime rather than compiled from Elm. Its implementation is not in the
generated module, which instead holds a top-level `func.func` stub for it
carrying the attribute `is_kernel = true`.

The check compiles a source module to an in-memory MLIR module, collects the
names of its top-level `func.func` ops that begin `Elm_Kernel_` and have
`is_kernel` true, and then looks at every op at any depth. One violation is
found for each of these ops that names an `Elm_Kernel_` symbol missing from
that set, and a failing test shows the first of them:

  - an `eco.papCreate` or `eco.papExtend`, by its `function` attribute;
  - an `eco.call`, by its `callee` attribute, with a leading `@` removed.

Among what is not checked: symbols with any other prefix, such as
`Eco_Kernel_`; references held in any other attribute or by any other op; and
whether a declaration's type agrees with the references to it. Generated
`eco.papExtend` ops carry no `function` attribute, so in practice only
`eco.papCreate` and `eco.call` references are checked.

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


{-| Compiles `srcModule` to MLIR and passes when every `Elm_Kernel_` symbol
named by its `eco.papCreate`, `eco.papExtend` and `eco.call` ops is declared as
a kernel, as the module docstring describes. Fails with the message for the
first undeclared reference, or with the test pipeline's error message if
compilation fails.
-}
expectKernelDeclCompleteness : Src.Module -> Expectation
expectKernelDeclCompleteness srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkKernelDeclCompleteness mlirModule)


{-| Returns one violation for each `eco.papCreate`, `eco.papExtend` or
`eco.call` in `mlirModule`, at any depth, that names an `Elm_Kernel_` symbol the
module does not declare as a kernel.
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


{-| Returns the names of the top-level `func.func` ops in `mlirModule` that begin
`Elm_Kernel_` and have `is_kernel` true, as a set.
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


{-| Returns a violation if `op` is an `eco.papCreate`, `eco.papExtend` or
`eco.call` that refers to an `Elm_Kernel_` symbol missing from `kernelDecls`.
Any other op gives `Nothing`.
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


{-| Returns a violation if the `function` attribute of an `eco.papCreate` names
an `Elm_Kernel_` symbol missing from `kernelDecls`. An op with no `function`
attribute gives `Nothing`.
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


{-| Returns a violation if the `function` attribute of an `eco.papExtend` names
an `Elm_Kernel_` symbol missing from `kernelDecls`. An op with no `function`
attribute gives `Nothing`. Generated `eco.papExtend` ops carry no `function`
attribute, so on them this always gives `Nothing`.
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


{-| Returns a violation if the `callee` attribute of an `eco.call`, with a
leading `@` removed, names an `Elm_Kernel_` symbol missing from `kernelDecls`.
An op with no `callee` attribute gives `Nothing`.
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


{-| Tells whether `name` begins `Elm_Kernel_`, which is what this module takes
to mark a kernel symbol.
-}
isKernelName : String -> Bool
isKernelName name =
    String.startsWith "Elm_Kernel_" name
