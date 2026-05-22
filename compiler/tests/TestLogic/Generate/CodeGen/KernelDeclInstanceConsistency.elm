module TestLogic.Generate.CodeGen.KernelDeclInstanceConsistency exposing (expectKernelDeclInstanceConsistency)

{-| Test logic for CGEN\_038: Kernel calls use types matching the func.func declaration.

For every Elm\_Kernel\_\* symbol referenced anywhere in the module, every
referencing eco.call / eco.papCreate / eco.papExtend must have operand and
result MLIR types consistent with the matching func.func is\_kernel=true
declaration's `function_type` attribute.

This test trusts the `_operand_types` attribute as canonical for operand
types.

@docs expectKernelDeclInstanceConsistency

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirAttr(..), MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , extractResultTypes
        , findFuncOps
        , getBoolAttr
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        , walkAllOps
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that every Elm\_Kernel\_\* reference in the module has operand and
result types consistent with the matching kernel func.func declaration.
-}
expectKernelDeclInstanceConsistency : Src.Module -> Expectation
expectKernelDeclInstanceConsistency srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkKernelDeclInstanceConsistency mlirModule)


{-| Type signature of a kernel function declaration.
-}
type alias KernelDeclSig =
    { inputs : List MlirType
    , result : MlirType
    }


checkKernelDeclInstanceConsistency : MlirModule -> List Violation
checkKernelDeclInstanceConsistency mlirModule =
    let
        kernelDeclSigs : Dict String KernelDeclSig
        kernelDeclSigs =
            buildKernelDeclSigs mlirModule

        allOps : List MlirOp
        allOps =
            walkAllOps mlirModule
    in
    List.concatMap (checkOp kernelDeclSigs) allOps


{-| Build a map from kernel sym\_name to its declared (inputs, result) types.

Includes only func.func ops with `is_kernel = true`. Funcs with multiple
result types are skipped (kernel func.funcs always have a single result).

-}
buildKernelDeclSigs : MlirModule -> Dict String KernelDeclSig
buildKernelDeclSigs mlirModule =
    findFuncOps mlirModule
        |> List.filter (\op -> getBoolAttr "is_kernel" op == Just True)
        |> List.foldl
            (\op acc ->
                case ( getStringAttr "sym_name" op, getFunctionType op ) of
                    ( Just symName, Just sig ) ->
                        if isKernelName symName then
                            Dict.insert symName sig acc

                        else
                            acc

                    _ ->
                        acc
            )
            Dict.empty


{-| Extract the function\_type attribute from a func.func, returning a
KernelDeclSig with a single result. Returns Nothing if the function has zero
or multiple results, or no function\_type attribute.
-}
getFunctionType : MlirOp -> Maybe KernelDeclSig
getFunctionType op =
    case Dict.get "function_type" op.attrs of
        Just (TypeAttr (FunctionType { inputs, results })) ->
            case results of
                [ result ] ->
                    Just { inputs = inputs, result = result }

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Dispatch per-op consistency checks for the three kernel-referencing op
kinds.
-}
checkOp : Dict String KernelDeclSig -> MlirOp -> List Violation
checkOp kernelDeclSigs op =
    if op.name == "eco.call" then
        checkCallOp kernelDeclSigs op

    else if op.name == "eco.papCreate" then
        checkPapCreateOp kernelDeclSigs op

    else if op.name == "eco.papExtend" then
        checkPapExtendOp kernelDeclSigs op

    else
        []


{-| eco.call → operand and result types must equal the decl's signature exactly.
-}
checkCallOp : Dict String KernelDeclSig -> MlirOp -> List Violation
checkCallOp kernelDeclSigs op =
    case getKernelCallee op of
        Nothing ->
            []

        Just calleeName ->
            case Dict.get calleeName kernelDeclSigs of
                Nothing ->
                    -- Missing decl is CGEN_057's responsibility.
                    []

                Just sig ->
                    let
                        allOperandTypes =
                            extractOperandTypes op |> Maybe.withDefault []

                        -- Drop appended GC root hints; only the leading
                        -- entries are ABI-relevant call operands.
                        rootCount =
                            Maybe.withDefault 0 (getIntAttr "eco.gc_roots_count" op)

                        operandTypes =
                            List.take (List.length allOperandTypes - rootCount) allOperandTypes

                        resultTypes =
                            extractResultTypes op
                    in
                    inputsViolations op calleeName "eco.call" sig.inputs operandTypes
                        ++ resultViolations op calleeName "eco.call" (Just sig.result) resultTypes


{-| eco.papCreate → captured-slot types must equal the matching prefix of
the decl's inputs. Result is always !eco.value (the closure HPointer), so
we don't compare it against the decl's result.
-}
checkPapCreateOp : Dict String KernelDeclSig -> MlirOp -> List Violation
checkPapCreateOp kernelDeclSigs op =
    case getStringAttr "function" op of
        Nothing ->
            []

        Just funcName ->
            if not (isKernelName funcName) then
                []

            else
                case Dict.get funcName kernelDeclSigs of
                    Nothing ->
                        []

                    Just sig ->
                        let
                            captureTypes =
                                extractOperandTypes op |> Maybe.withDefault []

                            numCaptured =
                                getIntAttr "num_captured" op |> Maybe.withDefault (List.length captureTypes)
                        in
                        prefixViolations op funcName "eco.papCreate" sig.inputs captureTypes numCaptured


{-| eco.papExtend → operand types must be a length-bounded prefix of the
decl's inputs. Saturated form (remaining\_arity = 0 or absent with
operandCount == arity) additionally compares the result type against the
decl's result.

Current codegen rarely sets the `function` attribute on papExtend, but this
defensive check covers any future path that does.

-}
checkPapExtendOp : Dict String KernelDeclSig -> MlirOp -> List Violation
checkPapExtendOp kernelDeclSigs op =
    case getStringAttr "function" op of
        Nothing ->
            []

        Just funcName ->
            if not (isKernelName funcName) then
                []

            else
                case Dict.get funcName kernelDeclSigs of
                    Nothing ->
                        []

                    Just sig ->
                        let
                            allOperandTypes =
                                extractOperandTypes op |> Maybe.withDefault []

                            -- Drop appended GC root hints; only the leading
                            -- entries are ABI-relevant (closure + new args).
                            rootCount =
                                Maybe.withDefault 0 (getIntAttr "eco.gc_roots_count" op)

                            operandTypes =
                                List.take (List.length allOperandTypes - rootCount) allOperandTypes

                            -- Partial check: operand types must be a valid
                            -- prefix of the decl's inputs. We use the
                            -- length of operandTypes as the bound.
                            prefixOk =
                                prefixViolations op funcName "eco.papExtend" sig.inputs operandTypes (List.length operandTypes)

                            isSaturated =
                                case getIntAttr "remaining_arity" op of
                                    Just 0 ->
                                        True

                                    Just _ ->
                                        False

                                    Nothing ->
                                        List.length operandTypes == List.length sig.inputs

                            resultOk =
                                if isSaturated then
                                    resultViolations op funcName "eco.papExtend" (Just sig.result) (extractResultTypes op)

                                else
                                    []
                        in
                        prefixOk ++ resultOk


{-| Compare a list of observed operand types against the expected list.

Reports both length and per-slot mismatches.

-}
inputsViolations : MlirOp -> String -> String -> List MlirType -> List MlirType -> List Violation
inputsViolations op symName opLabel expected observed =
    let
        expectedLen =
            List.length expected

        observedLen =
            List.length observed
    in
    if expectedLen /= observedLen then
        [ { opId = op.id
          , opName = opLabel
          , message =
                opLabel
                    ++ " on kernel '"
                    ++ symName
                    ++ "' has "
                    ++ String.fromInt observedLen
                    ++ " operands but the decl declares "
                    ++ String.fromInt expectedLen
                    ++ " (CGEN_038)"
          }
        ]

    else
        slotViolations op symName opLabel expected observed


{-| Same as `inputsViolations`, but bounded to the first `n` decl inputs.
Used for partial application sites where only a prefix of the decl's inputs
is observed (eco.papCreate captures, partial eco.papExtend operands).
-}
prefixViolations : MlirOp -> String -> String -> List MlirType -> List MlirType -> Int -> List Violation
prefixViolations op symName opLabel declInputs observed prefixLen =
    if prefixLen > List.length declInputs then
        [ { opId = op.id
          , opName = opLabel
          , message =
                opLabel
                    ++ " on kernel '"
                    ++ symName
                    ++ "' has "
                    ++ String.fromInt prefixLen
                    ++ " operand types but the decl declares only "
                    ++ String.fromInt (List.length declInputs)
                    ++ " inputs (CGEN_038)"
          }
        ]

    else if List.length observed /= prefixLen then
        [ { opId = op.id
          , opName = opLabel
          , message =
                opLabel
                    ++ " on kernel '"
                    ++ symName
                    ++ "' declares prefix length "
                    ++ String.fromInt prefixLen
                    ++ " but _operand_types has "
                    ++ String.fromInt (List.length observed)
                    ++ " entries (CGEN_038)"
          }
        ]

    else
        slotViolations op symName opLabel (List.take prefixLen declInputs) observed


{-| Per-slot equality check on two equally-sized type lists.
-}
slotViolations : MlirOp -> String -> String -> List MlirType -> List MlirType -> List Violation
slotViolations op symName opLabel expected observed =
    List.indexedMap
        (\i ( e, o ) ->
            if e == o then
                Nothing

            else
                Just
                    { opId = op.id
                    , opName = opLabel
                    , message =
                        opLabel
                            ++ " on kernel '"
                            ++ symName
                            ++ "' operand "
                            ++ String.fromInt i
                            ++ ": expected "
                            ++ Debug.toString e
                            ++ " from decl, observed "
                            ++ Debug.toString o
                            ++ " in _operand_types (CGEN_038)"
                    }
        )
        (List.map2 Tuple.pair expected observed)
        |> List.filterMap identity


{-| Compare the observed result types of an op against the decl's single
result type. eco.call has exactly one result; the decl always has one.
-}
resultViolations : MlirOp -> String -> String -> Maybe MlirType -> List MlirType -> List Violation
resultViolations op symName opLabel expectedMaybe observed =
    case ( expectedMaybe, observed ) of
        ( Just expected, [ actual ] ) ->
            if expected == actual then
                []

            else
                [ { opId = op.id
                  , opName = opLabel
                  , message =
                        opLabel
                            ++ " on kernel '"
                            ++ symName
                            ++ "' result type: expected "
                            ++ Debug.toString expected
                            ++ " from decl, observed "
                            ++ Debug.toString actual
                            ++ " (CGEN_038)"
                  }
                ]

        ( Just _, _ ) ->
            [ { opId = op.id
              , opName = opLabel
              , message =
                    opLabel
                        ++ " on kernel '"
                        ++ symName
                        ++ "' has "
                        ++ String.fromInt (List.length observed)
                        ++ " result types but exactly one was expected (CGEN_038)"
              }
            ]

        ( Nothing, _ ) ->
            []


{-| Strip a leading "@" from a callee/function symbol reference, if present.
The MLIR text printer renders SymbolRefAttr with a leading "@", but the
attribute extractor returns the bare string. Defensive normalisation.
-}
stripLeadingAt : String -> String
stripLeadingAt s =
    if String.startsWith "@" s then
        String.dropLeft 1 s

    else
        s


{-| Read the kernel callee from an eco.call, returning Nothing if it is not
a kernel reference.
-}
getKernelCallee : MlirOp -> Maybe String
getKernelCallee op =
    case getStringAttr "callee" op of
        Nothing ->
            Nothing

        Just rawCallee ->
            let
                callee =
                    stripLeadingAt rawCallee
            in
            if isKernelName callee then
                Just callee

            else
                Nothing


{-| Predicate: is this an Elm kernel symbol name?
-}
isKernelName : String -> Bool
isKernelName name =
    String.startsWith "Elm_Kernel_" name
