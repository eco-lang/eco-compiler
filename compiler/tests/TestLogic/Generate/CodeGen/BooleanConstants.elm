module TestLogic.Generate.CodeGen.BooleanConstants exposing (expectBooleanConstants, checkBooleanConstants)

{-| Test logic for CGEN\_009: Boolean Constants invariant.

Boolean constants (True, False) must use !eco.value representation except
in control-flow contexts. i1 values may only appear as eco.case scrutinees
with case\_kind="bool".

@docs expectBooleanConstants, checkBooleanConstants

-}

import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , extractResultTypes
        , findOpsNamed
        , getStringAttr
        , isEcoValueType
        , violationsToExpectation
        , walkAllOps
        )


{-| Verify that boolean constant invariants hold for a source module.
-}
expectBooleanConstants : Src.Module -> Expectation
expectBooleanConstants srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkBooleanConstants mlirModule)


{-| Check boolean constant representation.

CGEN\_009: Bool constants must produce !eco.value; i1 only in case scrutinee.

-}
checkBooleanConstants : MlirModule -> List Violation
checkBooleanConstants mlirModule =
    let
        constantOps =
            findOpsNamed "eco.constant" mlirModule

        boolConstants =
            List.filter isBoolConstant constantOps

        -- Check all Bool constants produce !eco.value
        constantViolations =
            List.filterMap checkBoolConstantType boolConstants

        -- Check i1 only used appropriately (in eco.unbox results for case scrutinee)
        i1Violations =
            checkI1Usage mlirModule
    in
    constantViolations ++ i1Violations


{-| Check if an eco.constant op is a Bool constant.
-}
isBoolConstant : MlirOp -> Bool
isBoolConstant op =
    case getStringAttr "value" op of
        Just "True" ->
            True

        Just "False" ->
            True

        _ ->
            False


{-| Check that Bool constants produce !eco.value, not i1.
-}
checkBoolConstantType : MlirOp -> Maybe Violation
checkBoolConstantType op =
    case extractResultTypes op of
        [ resultType ] ->
            if not (isEcoValueType resultType) then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "Bool constant must produce !eco.value, got "
                            ++ typeToString resultType
                    }

            else
                Nothing

        _ ->
            Nothing


{-| Check that i1 values are only used appropriately.

i1 is valid as:

  - Result of eco.unbox (for Bool case scrutinee)
  - Operand of eco.case with case\_kind="bool"

i1 is NOT valid in:

  - eco.construct.\* operands (heap storage)
  - eco.papCreate/papExtend operands (closure capture)
  - eco.call operands (function arguments at ABI boundary)

-}
checkI1Usage : MlirModule -> List Violation
checkI1Usage mlirModule =
    let
        allOps =
            walkAllOps mlirModule

        -- Check construct ops don't have i1 operands
        constructOps =
            List.filter isConstructOp allOps

        constructViolations =
            List.concatMap checkNoI1Operands constructOps

        -- Check PAP ops don't have i1 in captured values
        papCreateOps =
            List.filter (\op -> op.name == "eco.papCreate") allOps

        papViolations =
            List.concatMap checkNoI1Operands papCreateOps
    in
    constructViolations ++ papViolations


isConstructOp : MlirOp -> Bool
isConstructOp op =
    String.startsWith "eco.construct." op.name


{-| Check that an op has no i1 operands.
-}
checkNoI1Operands : MlirOp -> List Violation
checkNoI1Operands op =
    case extractOperandTypes op of
        Just operandTypes ->
            List.indexedMap (checkNotI1 op) operandTypes
                |> List.filterMap identity

        Nothing ->
            []


checkNotI1 : MlirOp -> Int -> MlirType -> Maybe Violation
checkNotI1 op index operandType =
    if operandType == I1 then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "operand "
                    ++ String.fromInt index
                    ++ " is i1 (Bool) but must be !eco.value at heap/closure boundary"
            }

    else
        Nothing


typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

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
