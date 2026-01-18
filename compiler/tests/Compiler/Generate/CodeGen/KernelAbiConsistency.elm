module Compiler.Generate.CodeGen.KernelAbiConsistency exposing
    ( expectKernelAbiConsistency
    , checkKernelAbiConsistency
    )

{-| Test logic for CGEN_038: Kernel ABI Consistency invariant.

All calls to the same kernel function must use identical MLIR argument and
result types.

@docs expectKernelAbiConsistency, checkKernelAbiConsistency

-}

import Compiler.AST.Source as Src
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , extractResultTypes
        , findOpsNamed
        , getStringAttr
        , violationsToExpectation
        )
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType)


{-| Verify that kernel ABI consistency invariants hold for a source module.
-}
expectKernelAbiConsistency : Src.Module -> Expectation
expectKernelAbiConsistency srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkKernelAbiConsistency mlirModule)


{-| Check kernel ABI consistency invariants.
-}
checkKernelAbiConsistency : MlirModule -> List Violation
checkKernelAbiConsistency mlirModule =
    let
        callOps =
            findOpsNamed "eco.call" mlirModule

        callsByCallee =
            List.foldl groupCallByCallee Dict.empty callOps

        violations =
            Dict.foldl checkCalleeConsistency [] callsByCallee
    in
    violations


groupCallByCallee : MlirOp -> Dict String (List MlirOp) -> Dict String (List MlirOp)
groupCallByCallee op dict =
    case getStringAttr "callee" op of
        Nothing ->
            dict

        Just callee ->
            if isKernelFunction callee then
                Dict.update callee
                    (\maybeOps ->
                        case maybeOps of
                            Just ops ->
                                Just (op :: ops)

                            Nothing ->
                                Just [ op ]
                    )
                    dict

            else
                dict


isKernelFunction : String -> Bool
isKernelFunction name =
    String.startsWith "eco_" name
        || String.contains "$kernel$" name
        || String.startsWith "@eco_" name


checkCalleeConsistency : String -> List MlirOp -> List Violation -> List Violation
checkCalleeConsistency callee calls accViolations =
    case calls of
        [] ->
            accViolations

        [ _ ] ->
            accViolations

        first :: rest ->
            let
                firstArgTypes =
                    extractOperandTypes first

                firstResultTypes =
                    extractResultTypes first

                newViolations =
                    List.filterMap (checkAgainstFirst callee first firstArgTypes firstResultTypes) rest
            in
            newViolations ++ accViolations


checkAgainstFirst : String -> MlirOp -> Maybe (List MlirType) -> List MlirType -> MlirOp -> Maybe Violation
checkAgainstFirst callee firstOp firstArgTypes firstResultTypes otherOp =
    let
        otherArgTypes =
            extractOperandTypes otherOp

        otherResultTypes =
            extractResultTypes otherOp
    in
    if firstArgTypes /= otherArgTypes then
        Just
            { opId = otherOp.id
            , opName = otherOp.name
            , message =
                "Kernel '"
                    ++ callee
                    ++ "' call has different arg types than previous call at "
                    ++ firstOp.id
            }

    else if firstResultTypes /= otherResultTypes then
        Just
            { opId = otherOp.id
            , opName = otherOp.name
            , message =
                "Kernel '"
                    ++ callee
                    ++ "' call has different result types than previous call at "
                    ++ firstOp.id
            }

    else
        Nothing
