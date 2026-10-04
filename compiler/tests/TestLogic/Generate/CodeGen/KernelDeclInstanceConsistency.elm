module TestLogic.Generate.CodeGen.KernelDeclInstanceConsistency exposing (expectKernelDeclInstanceConsistency)

{-| A kernel is a function the runtime implements rather than Elm code. The
generated MLIR declares each kernel it uses as a `func.func` and refers to it
by symbol from calls and closures, so a use whose MLIR types differ from the
declaration's makes the module disagree with itself at the kernel boundary.
Nothing in the types of `Mlir.Mlir` prevents that. This module checks, for one
program, that the uses of its declared `Elm_Kernel_` kernels described below
agree with their declarations.

`expectKernelDeclInstanceConsistency` compiles the source module it is given to
an `MlirModule` with `TestLogic.TestPipeline.runToMlir`, and fails if that does
not compile. It then finds the _kernel declarations_: the module's top-level
`func.func` ops whose `is_kernel` attribute is true, whose `sym_name` starts
with `Elm_Kernel_`, and whose `function_type` has exactly one result. The
inputs and the result of that function type are the _declared signature_.
An op's operand types are read from its `_operand_types` attribute.

Every op in the module, at any depth, is checked against the declared
signatures:

  - An `eco.call` whose `callee` names a declared kernel must have operand
    types, less the trailing GC root hints that `eco.gc_roots_count` counts,
    equal to the declared inputs, in number and position by position, and
    exactly one result, of the declared result type. A call with no
    `_operand_types` is compared as having no operands.
  - An `eco.papCreate` whose `function` names a declared kernel must record
    exactly `num_captured` operand types, `num_captured` must not exceed the
    number of declared inputs, and each recorded type must equal the declared
    input at the same position. Its result is not compared.
  - An `eco.papExtend` whose `function` names a declared kernel must have, less
    the GC root hints, no more operand types than there are declared inputs,
    each equal to the declared input at the same position. The first operand,
    the closure being extended, is compared against the first input. When it is
    saturated, meaning `remaining_arity` is 0, or is absent and the operand
    types are as many as the inputs, it must also have exactly one result, of
    the declared result type.

Among what is not tested:

  - A use of a kernel that has no declaration, which is skipped here.
  - Kernels whose symbol starts with `Eco_Kernel_`, and declarations whose
    function type has other than one result.
  - Whether `_operand_types` matches the types of the values the op is actually
    given; the recorded types are trusted.
  - Any op other than the three above.
  - An `eco.papCreate` or `eco.papExtend` with no `function` attribute, which
    is skipped.

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


{-| Compiles `srcModule` to MLIR and passes if every `eco.call`,
`eco.papCreate` and `eco.papExtend` naming a declared `Elm_Kernel_` kernel
agrees with that kernel's declared signature, as the module docstring sets out.
Fails with the pipeline's message if the module does not compile to MLIR.
-}
expectKernelDeclInstanceConsistency : Src.Module -> Expectation
expectKernelDeclInstanceConsistency srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkKernelDeclInstanceConsistency mlirModule)


{-| The MLIR signature a kernel declaration states: the types of its inputs, in
order, and of its one result.
-}
type alias KernelDeclSig =
    { inputs : List MlirType
    , result : MlirType
    }


{-| Returns the violations of every `eco.call`, `eco.papCreate` and
`eco.papExtend` in `mlirModule`, at any depth, against the declared signatures
of the module's kernel declarations, by the rules the module docstring sets
out.
-}
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


{-| Returns the declared signature of each kernel declared in `mlirModule`,
keyed by symbol name. Only a top-level `func.func` with `is_kernel` true, a
`sym_name` starting with `Elm_Kernel_`, and a `function_type` with exactly one
result is included.
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


{-| Returns the inputs and the single result of the function type in `op`'s
`function_type` attribute, or `Nothing` if the attribute is absent, holds
something else, or has other than one result.
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


{-| Returns the violations of `op` against the declared signatures when it is
an `eco.call`, `eco.papCreate` or `eco.papExtend`, and none for any other op.
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


{-| Returns the violations of an `eco.call` whose callee is a declared kernel.
Its operand types, less the trailing GC root hints that `eco.gc_roots_count`
counts, must equal the declared inputs, and it must have exactly one result, of
the declared result type. A call to anything else, including a kernel with no
declaration, gives none.
-}
checkCallOp : Dict String KernelDeclSig -> MlirOp -> List Violation
checkCallOp kernelDeclSigs op =
    case getKernelCallee op of
        Nothing ->
            []

        Just calleeName ->
            case Dict.get calleeName kernelDeclSigs of
                Nothing ->
                    []

                Just sig ->
                    let
                        allOperandTypes =
                            extractOperandTypes op |> Maybe.withDefault []

                        rootCount =
                            Maybe.withDefault 0 (getIntAttr "eco.gc_roots_count" op)

                        operandTypes =
                            List.take (List.length allOperandTypes - rootCount) allOperandTypes

                        resultTypes =
                            extractResultTypes op
                    in
                    inputsViolations op calleeName "eco.call" sig.inputs operandTypes
                        ++ resultViolations op calleeName "eco.call" (Just sig.result) resultTypes


{-| Returns the violations of an `eco.papCreate` whose `function` is a
declared kernel. It must record exactly `num_captured` operand types,
`num_captured` must not exceed the declared inputs, and each recorded type must
equal the declared input at the same position. Without `num_captured`, every
recorded type is taken as captured. The result, a closure, is not compared.
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


{-| Returns the violations of an `eco.papExtend` whose `function` is a
declared kernel. Its operand types, less the trailing GC root hints, must be no
more than the declared inputs and must equal them position by position,
starting from the first input. When it is saturated, meaning `remaining_arity`
is 0, or is absent and the operand types are as many as the inputs, it must
also have exactly one result, of the declared result type.

The first operand of an `eco.papExtend` is the closure being extended, and it
is compared against the kernel's first input like the rest.

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

                            rootCount =
                                Maybe.withDefault 0 (getIntAttr "eco.gc_roots_count" op)

                            operandTypes =
                                List.take (List.length allOperandTypes - rootCount) allOperandTypes

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


{-| Returns the violations of the `observed` operand types against the
`expected` ones: one if their counts differ, and otherwise one for each
position where they differ. `symName` and `opLabel` name the kernel and the op
in each message.
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


{-| Returns the violations of the `observed` operand types against the first
`prefixLen` of `declInputs`: one if `prefixLen` exceeds the number of inputs,
otherwise one if `observed` does not have `prefixLen` entries, and otherwise one
for each position where they differ.
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


{-| Returns a violation for each position, numbered from 0, where `expected`
and `observed` hold different types. Positions past the end of the shorter list
are not compared.
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


{-| Returns the violations of an op's `observed` result types against
`expectedMaybe`: none when it is `Nothing`, and otherwise one if there is not
exactly one result or that result is not the expected type.
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


{-| Returns `s` without its leading `@`, if it has one. The `@` belongs to the
printed form of a symbol reference, not to the symbol's name. Only the callee
of an `eco.call` is passed through this; the `function` of a closure op is
compared as read.
-}
stripLeadingAt : String -> String
stripLeadingAt s =
    if String.startsWith "@" s then
        String.dropLeft 1 s

    else
        s


{-| Returns the `callee` of an `eco.call`, without a leading `@`, when it is
an `Elm_Kernel_` symbol, and `Nothing` otherwise.
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


{-| Returns whether `name` starts with `Elm_Kernel_`. A kernel symbol starting
with `Eco_Kernel_` does not count.
-}
isKernelName : String -> Bool
isKernelName name =
    String.startsWith "Elm_Kernel_" name
