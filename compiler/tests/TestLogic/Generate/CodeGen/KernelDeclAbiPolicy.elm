module TestLogic.Generate.CodeGen.KernelDeclAbiPolicy exposing (expectKernelDeclAbiPolicy)

{-| A kernel is a function implemented by the runtime rather than in Elm, and
the generated MLIR declares kernels as top-level `func.func` ops marked
`is_kernel`. This module checks the types on those declarations against the
backend ABI policy (KERN\_006).

`Compiler.Generate.MLIR.KernelAbi.kernelBackendAbiPolicy` is `ElmDerived` for
every kernel: each parameter and the result get `Types.monoTypeToAbi` of their
Mono type. That function only ever yields `i64` (Int), `f64` (Float), `i16`
(Char) or `!eco.value` (everything else, Bool included, REP\_ABI\_001). So
`expectKernelDeclAbiPolicy` compiles a source module to MLIR, takes every
top-level `func.func` whose `is_kernel` attribute is true, whatever its symbol
prefix (`Elm_Kernel_` or `Eco_Kernel_`), and reports a declaration

  - that has no `function_type` attribute, or one that is not a function type,
  - whose function type does not have exactly one result,
  - with a parameter or result type outside `i64`, `f64`, `i16` and
    `!eco.value` (an `i1` Bool, for instance), or
  - whose symbol carries one of the per-instance primitive suffixes `_Int`,
    `_Float` or `_Char` that `KernelAbi.kernelInstanceSymbol` adds, but has no
    parameter of the matching primitive type `i64`, `f64` or `i16`. Every
    suffixed instance is chosen because one of its parameters is that
    primitive, and `ElmDerived` must then type that parameter unboxed.

Among what is not tested: which parameter the suffix refers to, that an
unsuffixed kernel's types match the Mono types at its call sites (that is
`KernelDeclInstanceConsistency`), and the LLVM lowering of the declarations.

@docs expectKernelDeclAbiPolicy

-}

import Compiler.AST.Source as Src
import Compiler.Generate.MLIR.KernelAbi exposing (KernelBackendAbiPolicy(..), kernelBackendAbiPolicy)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , getBoolAttr
        , getStringAttr
        , getTypeAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR and checks the
type of each top-level kernel declaration against the `ElmDerived` policy, as
described in the module documentation.

It fails when compilation fails or when any kernel declaration is reported.

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


{-| Returns the policy violations of one kernel declaration. The case on
`kernelBackendAbiPolicy` makes this check revisit its rules if a second policy
is ever added.
-}
checkKernelFunc : MlirOp -> List Violation
checkKernelFunc op =
    let
        symName =
            getStringAttr "sym_name" op |> Maybe.withDefault "<no sym_name>"

        violation msg =
            [ { opId = op.id, opName = op.name, message = symName ++ ": " ++ msg } ]
    in
    case kernelBackendAbiPolicy of
        ElmDerived ->
            case getTypeAttr "function_type" op of
                Just (FunctionType { inputs, results }) ->
                    case results of
                        [ result ] ->
                            let
                                badTypes =
                                    List.filter (not << isElmDerivedAbiType) (inputs ++ [ result ])
                            in
                            if not (List.isEmpty badTypes) then
                                violation
                                    ("kernel ABI type(s) "
                                        ++ String.join ", " (List.map typeToString badTypes)
                                        ++ " are not produced by monoTypeToAbi (expected i64, f64, i16 or !eco.value)"
                                    )

                            else
                                case suffixPrimitive symName of
                                    Just ( suffix, prim ) ->
                                        if List.member prim inputs then
                                            []

                                        else
                                            violation
                                                ("per-instance suffix "
                                                    ++ suffix
                                                    ++ " but no "
                                                    ++ typeToString prim
                                                    ++ " parameter in ("
                                                    ++ String.join ", " (List.map typeToString inputs)
                                                    ++ ")"
                                                )

                                    Nothing ->
                                        []

                        _ ->
                            violation ("expected exactly one result, got " ++ String.fromInt (List.length results))

                Just other ->
                    violation ("function_type is not a function type: " ++ typeToString other)

                Nothing ->
                    violation "missing function_type attribute"


{-| Whether `t` is in the image of `Types.monoTypeToAbi`.
-}
isElmDerivedAbiType : MlirType -> Bool
isElmDerivedAbiType t =
    case t of
        I64 ->
            True

        F64 ->
            True

        I16 ->
            True

        NamedStruct "eco.value" ->
            True

        _ ->
            False


{-| Returns the per-instance primitive suffix of a kernel symbol and the MLIR
type it stands for, so `Elm_Kernel_Utils_compare_Int` gives `( "_Int", I64 )`.
-}
suffixPrimitive : String -> Maybe ( String, MlirType )
suffixPrimitive symName =
    if String.endsWith "_Int" symName then
        Just ( "_Int", I64 )

    else if String.endsWith "_Float" symName then
        Just ( "_Float", F64 )

    else if String.endsWith "_Char" symName then
        Just ( "_Char", I16 )

    else
        Nothing


typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

        I8 ->
            "i8"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct name ->
            "!" ++ name

        FunctionType _ ->
            "function"
