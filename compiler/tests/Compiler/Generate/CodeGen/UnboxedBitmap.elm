module Compiler.Generate.CodeGen.UnboxedBitmap exposing
    ( expectUnboxedBitmap
    , checkUnboxedBitmap
    )

{-| Test logic for heap and closure boundary representation (CGEN_026, CGEN_027, CGEN_003, CGEN_049).

This tests the HEAP and CLOSURE boundaries, NOT the ABI boundary.
ABI boundary testing (function parameters/returns) is separate.

Per REP_CLOSURE_001 and CGEN_026, at heap/closure boundaries:

  - Only Int (i64), Float (f64), and Char (i16) may be unboxed
  - Bool must be !eco.value (i1 is a violation)
  - All other types must be !eco.value

CGEN_026: For container construct ops, bit N of `unboxed_bitmap` must be set
iff operand N is unboxable (Int, Float, Char). Bool operands must be !eco.value.

CGEN_027: For `eco.construct.list`, `head_unboxed` must be true iff head
operand is unboxable.

CGEN_003: For `eco.papCreate`, bit N of `unboxed_bitmap` must be set iff
captured operand N is unboxable.

CGEN_049: For `eco.papExtend`, bit N of `newargs_unboxed_bitmap` must be set
iff new argument operand N is unboxable.

@docs expectUnboxedBitmap, checkUnboxedBitmap

-}

import Bitwise
import Compiler.AST.Source as Src
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , findOpsNamed
        , getBoolAttr
        , getIntAttr
        , isUnboxable
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))


{-| Verify that unboxed bitmap invariants hold for a source module.
-}
expectUnboxedBitmap : Src.Module -> Expectation
expectUnboxedBitmap srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkUnboxedBitmap mlirModule)


{-| Check unboxed bitmap consistency for containers and PAP ops (CGEN_026/027/003/049).
-}
checkUnboxedBitmap : MlirModule -> List Violation
checkUnboxedBitmap mlirModule =
    let
        -- Container construct ops (CGEN_026)
        tuple2Ops =
            findOpsNamed "eco.construct.tuple2" mlirModule

        tuple3Ops =
            findOpsNamed "eco.construct.tuple3" mlirModule

        recordOps =
            findOpsNamed "eco.construct.record" mlirModule

        customOps =
            findOpsNamed "eco.construct.custom" mlirModule

        targetOps =
            tuple2Ops ++ tuple3Ops ++ recordOps ++ customOps

        containerViolations =
            List.concatMap checkContainerBitmap targetOps

        -- List construct ops (CGEN_027)
        listOps =
            findOpsNamed "eco.construct.list" mlirModule

        listViolations =
            List.filterMap checkListHeadUnboxed listOps

        -- PAP create ops (CGEN_003)
        papCreateOps =
            findOpsNamed "eco.papCreate" mlirModule

        papCreateViolations =
            List.concatMap checkPapCreateBitmap papCreateOps

        -- PAP extend ops (CGEN_049)
        papExtendOps =
            findOpsNamed "eco.papExtend" mlirModule

        papExtendViolations =
            List.concatMap checkPapExtendBitmap papExtendOps
    in
    containerViolations ++ listViolations ++ papCreateViolations ++ papExtendViolations


checkContainerBitmap : MlirOp -> List Violation
checkContainerBitmap op =
    let
        unboxedBitmap =
            getIntAttr "unboxed_bitmap" op |> Maybe.withDefault 0

        maybeOperandTypes =
            extractOperandTypes op
    in
    case maybeOperandTypes of
        Nothing ->
            []

        Just operandTypes ->
            List.indexedMap (checkBitmapBit op unboxedBitmap) operandTypes
                |> List.filterMap identity


checkBitmapBit : MlirOp -> Int -> Int -> MlirType -> Maybe Violation
checkBitmapBit op bitmap index operandType =
    let
        bitIsSet =
            Bitwise.and bitmap (Bitwise.shiftLeftBy index 1) /= 0

        typeIsUnboxable =
            isUnboxable operandType
    in
    -- Bool (i1) is always a violation at heap/closure boundaries
    if operandType == I1 then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "operand "
                    ++ String.fromInt index
                    ++ " is i1 (Bool) but must be !eco.value at heap boundary"
            }

    else if bitIsSet && not typeIsUnboxable then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "unboxed_bitmap bit "
                    ++ String.fromInt index
                    ++ " is set but operand type is "
                    ++ typeToString operandType
                    ++ ", expected unboxable (i64, f64, i16)"
            }

    else if not bitIsSet && typeIsUnboxable then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "unboxed_bitmap bit "
                    ++ String.fromInt index
                    ++ " is clear but operand type is "
                    ++ typeToString operandType
                    ++ ", expected !eco.value"
            }

    else
        Nothing


checkListHeadUnboxed : MlirOp -> Maybe Violation
checkListHeadUnboxed op =
    let
        headUnboxed =
            getBoolAttr "head_unboxed" op |> Maybe.withDefault False

        maybeOperandTypes =
            extractOperandTypes op
    in
    case maybeOperandTypes of
        Nothing ->
            Nothing

        Just [] ->
            Nothing

        Just (headType :: _) ->
            let
                headIsUnboxable =
                    isUnboxable headType
            in
            -- Bool (i1) is always a violation at heap/closure boundaries
            if headType == I1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "list head is i1 (Bool) but must be !eco.value at heap boundary"
                    }

            else if headUnboxed && not headIsUnboxable then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "head_unboxed=true but head type is "
                            ++ typeToString headType
                            ++ ", expected unboxable (i64, f64, i16)"
                    }

            else if not headUnboxed && headIsUnboxable then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "head_unboxed=false but head type is "
                            ++ typeToString headType
                            ++ ", expected !eco.value"
                    }

            else
                Nothing


{-| Check eco.papCreate unboxed\_bitmap against captured operand types (CGEN\_003).

For papCreate, all operands are captured values and unboxed\_bitmap applies to all of them.

-}
checkPapCreateBitmap : MlirOp -> List Violation
checkPapCreateBitmap op =
    let
        unboxedBitmap =
            getIntAttr "unboxed_bitmap" op |> Maybe.withDefault 0

        maybeOperandTypes =
            extractOperandTypes op
    in
    case maybeOperandTypes of
        Nothing ->
            []

        Just operandTypes ->
            List.indexedMap (checkPapCreateBit op unboxedBitmap) operandTypes
                |> List.filterMap identity


checkPapCreateBit : MlirOp -> Int -> Int -> MlirType -> Maybe Violation
checkPapCreateBit op bitmap index operandType =
    let
        bitIsSet =
            Bitwise.and bitmap (Bitwise.shiftLeftBy index 1) /= 0

        typeIsUnboxable =
            isUnboxable operandType
    in
    -- Bool (i1) is always a violation at closure boundaries
    if operandType == I1 then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "captured operand "
                    ++ String.fromInt index
                    ++ " is i1 (Bool) but must be !eco.value at closure boundary"
            }

    else if bitIsSet && not typeIsUnboxable then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "unboxed_bitmap bit "
                    ++ String.fromInt index
                    ++ " is set but captured operand type is "
                    ++ typeToString operandType
                    ++ ", expected unboxable (i64, f64, i16)"
            }

    else if not bitIsSet && typeIsUnboxable then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "unboxed_bitmap bit "
                    ++ String.fromInt index
                    ++ " is clear but captured operand type is "
                    ++ typeToString operandType
                    ++ ", expected !eco.value"
            }

    else
        Nothing


{-| Check eco.papExtend newargs\_unboxed\_bitmap against new argument operand types (CGEN\_049).

For papExtend, operand 0 is the PAP being extended, and operands 1+ are the new arguments.
The newargs\_unboxed\_bitmap applies to operands starting at index 1.

-}
checkPapExtendBitmap : MlirOp -> List Violation
checkPapExtendBitmap op =
    let
        newargsBitmap =
            getIntAttr "newargs_unboxed_bitmap" op |> Maybe.withDefault 0

        maybeOperandTypes =
            extractOperandTypes op
    in
    case maybeOperandTypes of
        Nothing ->
            []

        Just operandTypes ->
            -- Skip operand 0 (the PAP), check operands 1+ as new args
            case List.tail operandTypes of
                Nothing ->
                    []

                Just newArgTypes ->
                    List.indexedMap (checkPapExtendBit op newargsBitmap) newArgTypes
                        |> List.filterMap identity


checkPapExtendBit : MlirOp -> Int -> Int -> MlirType -> Maybe Violation
checkPapExtendBit op bitmap index operandType =
    let
        bitIsSet =
            Bitwise.and bitmap (Bitwise.shiftLeftBy index 1) /= 0

        typeIsUnboxable =
            isUnboxable operandType
    in
    -- Bool (i1) is always a violation at closure boundaries
    if operandType == I1 then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "new arg operand "
                    ++ String.fromInt index
                    ++ " is i1 (Bool) but must be !eco.value at closure boundary"
            }

    else if bitIsSet && not typeIsUnboxable then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "newargs_unboxed_bitmap bit "
                    ++ String.fromInt index
                    ++ " is set but new arg operand type is "
                    ++ typeToString operandType
                    ++ ", expected unboxable (i64, f64, i16)"
            }

    else if not bitIsSet && typeIsUnboxable then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "newargs_unboxed_bitmap bit "
                    ++ String.fromInt index
                    ++ " is clear but new arg operand type is "
                    ++ typeToString operandType
                    ++ ", expected !eco.value"
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
            name

        FunctionType _ ->
            "function"
