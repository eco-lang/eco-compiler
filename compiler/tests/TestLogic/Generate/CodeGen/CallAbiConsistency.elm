module TestLogic.Generate.CodeGen.CallAbiConsistency exposing (expectCallAbiConsistency)

{-| Checks that each `eco.call` in generated MLIR passes its arguments in the
types the called function declares, so that no value crosses a call boundary in
a representation the callee does not expect, such as a Bool passed as `i1` to a
parameter of type `!eco.value`. Nothing in `Mlir.Mlir` ties a call's operand
types to its callee's signature, so this is checked here.

`expectCallAbiConsistency` compiles a source module with
`TestLogic.TestPipeline.runToMlir` and, for each `eco.call` in the result,
compares two lists of types:

  - The callee's parameter types: the inputs of the `function_type` attribute
    of the module's top-level `func.func` whose `sym_name` is the call's
    `callee`, with any leading `@` removed.
  - The call's operand types: its `_operand_types` attribute, less any GC-root
    hints. A GC-root hint is an operand appended after the arguments that the
    garbage collector treats as a root rather than an argument; the call's
    `eco.gc_roots_count` attribute says how many there are.

The two lists must have the same length and hold equal types, position by
position. A call that fails gets one violation, for the count if the lengths
differ and otherwise for its first mismatched operand.

Among what is not checked:

  - a call whose callee has no top-level `func.func` with a `function_type` in
    the module;
  - an `eco.call` with no `callee` or no `_operand_types` attribute;
  - the types of a call's results.

@docs expectCallAbiConsistency

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , findFuncOps
        , findOpsNamed
        , getIntAttr
        , getStringAttr
        , getTypeAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR and checks each
`eco.call` in it against its callee's parameter types, as the module
documentation describes.

It fails if compilation fails, and otherwise if any checked call has the wrong
number of operands or an operand of the wrong type. Only the first such
violation is reported.

-}
expectCallAbiConsistency : Src.Module -> Expectation
expectCallAbiConsistency srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCallAbiConsistency mlirModule)


{-| Returns a violation for each `eco.call` in `mlirModule` whose operands do
not match its callee's parameter types, at most one per call.
-}
checkCallAbiConsistency : MlirModule -> List Violation
checkCallAbiConsistency mlirModule =
    let
        funcParamTypes =
            buildFuncParamTypesMap mlirModule

        callOps =
            findOpsNamed "eco.call" mlirModule
    in
    List.filterMap (checkCallOp funcParamTypes) callOps


{-| Returns the parameter types of each top-level `func.func` in `mlirModule`,
keyed by its `sym_name`. A function lacking either attribute is left out.
-}
buildFuncParamTypesMap : MlirModule -> Dict String (List MlirType)
buildFuncParamTypesMap mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.foldl addFuncToMap Dict.empty funcOps


{-| Adds `funcOp`'s parameter types to `dict` under its `sym_name`, or returns
`dict` unchanged if `funcOp` has no `sym_name` or no `function_type` holding a
function type.
-}
addFuncToMap : MlirOp -> Dict String (List MlirType) -> Dict String (List MlirType)
addFuncToMap funcOp dict =
    case getStringAttr "sym_name" funcOp of
        Nothing ->
            dict

        Just name ->
            case getTypeAttr "function_type" funcOp of
                Nothing ->
                    dict

                Just funcType ->
                    case extractParamTypes funcType of
                        Nothing ->
                            dict

                        Just paramTypes ->
                            Dict.insert name paramTypes dict


{-| Returns the input types of a function type, or `Nothing` for any other
type.
-}
extractParamTypes : MlirType -> Maybe (List MlirType)
extractParamTypes mlirType =
    case mlirType of
        FunctionType { inputs } ->
            Just inputs

        _ ->
            Nothing


{-| Returns the violation, if any, of one `eco.call`, given the parameter types
of the module's functions by name.

The call is not checked, and `Nothing` is returned, when it has no `callee`,
when the callee is not in `funcParamTypes`, or when it has no `_operand_types`.
Otherwise the last `eco.gc_roots_count` operand types, the GC-root hints, are
dropped before the comparison.

-}
checkCallOp : Dict String (List MlirType) -> MlirOp -> Maybe Violation
checkCallOp funcParamTypes op =
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
            case Dict.get calleeName funcParamTypes of
                Nothing ->
                    Nothing

                Just expectedParamTypes ->
                    case extractOperandTypes op of
                        Nothing ->
                            Nothing

                        Just allOperandTypes ->
                            let
                                rootCount =
                                    Maybe.withDefault 0 (getIntAttr "eco.gc_roots_count" op)

                                actualOperandTypes =
                                    List.take (List.length allOperandTypes - rootCount) allOperandTypes
                            in
                            checkTypesMatch op calleeName expectedParamTypes actualOperandTypes


{-| Returns a violation for `op`'s call to `calleeName` if `actualTypes`
differs in length from `expectedTypes`, or else if any position holds different
types, in which case it names the first such operand.
-}
checkTypesMatch : MlirOp -> String -> List MlirType -> List MlirType -> Maybe Violation
checkTypesMatch op calleeName expectedTypes actualTypes =
    let
        expectedCount =
            List.length expectedTypes

        actualCount =
            List.length actualTypes
    in
    if expectedCount /= actualCount then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "Call to '"
                    ++ calleeName
                    ++ "' has "
                    ++ String.fromInt actualCount
                    ++ " operands but function expects "
                    ++ String.fromInt expectedCount
                    ++ " parameters"
            }

    else
        List.map2 Tuple.pair expectedTypes actualTypes
            |> List.indexedMap (checkSingleType op calleeName)
            |> List.filterMap identity
            |> List.head


{-| Returns a violation naming operand `index`, counted from 0, if `actual` is
not equal to `expected`.
-}
checkSingleType : MlirOp -> String -> Int -> ( MlirType, MlirType ) -> Maybe Violation
checkSingleType op calleeName index ( expected, actual ) =
    if typesMatch expected actual then
        Nothing

    else
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "Call to '"
                    ++ calleeName
                    ++ "' operand "
                    ++ String.fromInt index
                    ++ " has type "
                    ++ typeToString actual
                    ++ " but function parameter expects "
                    ++ typeToString expected
            }


{-| Returns whether two types are equal. There is no normalization: the types
must be identical.
-}
typesMatch : MlirType -> MlirType -> Bool
typesMatch t1 t2 =
    t1 == t2


{-| Returns a type's MLIR spelling for a violation message, except that every
function type is written `function`.
-}
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
