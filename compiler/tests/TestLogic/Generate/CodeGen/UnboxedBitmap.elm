module TestLogic.Generate.CodeGen.UnboxedBitmap exposing (expectUnboxedBitmap)

{-| Checks that the unboxed bitmaps in generated MLIR agree with the operand
types of the ops that carry them, so that a heap object or closure whose bitmap
misdescribes the values stored in it is caught in the MLIR the code generator
produces.

The tuple, record and custom construct ops and the closure ops `eco.papCreate`
and `eco.papExtend` record which of their operands are stored unboxed in an
integer attribute, their _unboxed bitmap_. The bitmap holds one 2-bit
_slot kind_ per operand position, slot N in bits 2N and 2N+1: 0 for a boxed
value (`!eco.value`), 1 for an Int (`i64`), 2 for a Float (`f64`) and 3 for a
Char (`i16`). The operand types compared against it are the ones the op records
in its `_operand_types` attribute, read with
`TestLogic.Generate.CodeGen.Invariants.extractOperandTypes`.

A Bool is `!eco.value` when it is stored in a heap object or captured by a
closure, so an `i1` in any operand position that is compared (for a list cons,
the head) is a violation whatever the bitmap or flag says.

`expectUnboxedBitmap` compiles the given module to MLIR and checks, at any
nesting depth:

  - `eco.construct.tuple2`, `eco.construct.tuple3`, `eco.construct.record` and
    `eco.construct.custom`: slot N of `unboxed_bitmap` holds the kind of
    operand N, for every recorded operand, trailing GC root hints included.
  - `eco.papCreate`: the same, over its captured operands.
  - `eco.papExtend`: slot N of `newargs_unboxed_bitmap` holds the kind of
    operand N+1. Operand 0 is the closure being extended, and the trailing
    operands that `eco.gc_roots_count` counts are GC root hints, so neither is
    compared.
  - `eco.construct.list`: the boolean `head_unboxed` is true exactly when the
    head operand is `i64`, `f64` or `i16`.

A missing bitmap reads as 0 (every slot boxed) and a missing `head_unboxed` as
false. An op with no `_operand_types` attribute is not checked. On the
JavaScript back end, where `Bitwise` is 32-bit, only slots 0 to 15 are read
correctly; a slot N past 15 is read as slot N modulo 16.

Among what is not tested: the `head_kind` attribute of `eco.construct.list`,
`eco.papCreateGroup` ops, the types of function parameters and results, and
whether a recorded operand type matches the type of the SSA value actually
passed.

@docs expectUnboxedBitmap

-}

import Bitwise
import Compiler.AST.Source as Src
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , findOpsNamed
        , getBoolAttr
        , getIntAttr
        , isUnboxable
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that passes when `srcModule` compiles to MLIR and
every op the module docstring lists has an unboxed bitmap, or for a list cons a
`head_unboxed` flag, that agrees with its operand types under the rules set out
there.

A compilation failure fails with its message. Otherwise the expectation fails
with the first violation found, as
`TestLogic.Generate.CodeGen.Invariants.violationsToExpectation` describes.

-}
expectUnboxedBitmap : Src.Module -> Expectation
expectUnboxedBitmap srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkUnboxedBitmap mlirModule)


{-| Returns every violation in `mlirModule`: those of the tuple, record and
custom construct ops, then of the list cons ops, then of `eco.papCreate`, then
of `eco.papExtend`.
-}
checkUnboxedBitmap : MlirModule -> List Violation
checkUnboxedBitmap mlirModule =
    let
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

        listOps =
            findOpsNamed "eco.construct.list" mlirModule

        listViolations =
            List.filterMap checkListHeadUnboxed listOps

        papCreateOps =
            findOpsNamed "eco.papCreate" mlirModule

        papCreateViolations =
            List.concatMap checkPapCreateBitmap papCreateOps

        papExtendOps =
            findOpsNamed "eco.papExtend" mlirModule

        papExtendViolations =
            List.concatMap checkPapExtendBitmap papExtendOps
    in
    containerViolations ++ listViolations ++ papCreateViolations ++ papExtendViolations


{-| Returns the violations in the `unboxed_bitmap` of a tuple, record or custom
construct op, comparing slot N with operand N. A missing bitmap reads as 0, and
an op with no recorded operand types gives none.
-}
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


{-| Returns the violation, if any, for operand `index` of a construct op, as
`checkBitmapKind` decides it.
-}
checkBitmapBit : MlirOp -> Int -> Int -> MlirType -> Maybe Violation
checkBitmapBit op bitmap index operandType =
    checkBitmapKind op bitmap index operandType "unboxed_bitmap" "operand"


{-| Returns the slot kind held in slot `index` of `bitmap`.

On the JavaScript back end, `Bitwise` works on 32-bit values and wraps shift
counts at 32, so only slots 0 to 15 are read correctly there. For a higher
`index` it returns the kind in slot `index` modulo 16.

-}
slotKind : Int -> Int -> Int
slotKind bitmap index =
    Bitwise.and (Bitwise.shiftRightZfBy (2 * index) bitmap) 3


{-| Returns the slot kind an operand of type `ty` requires: 1 for `i64`, 2 for
`f64`, 3 for `i16`, and 0 for every other type, `i1` included.
-}
typeToKind : MlirType -> Int
typeToKind ty =
    case ty of
        I64 ->
            1

        F64 ->
            2

        I16 ->
            3

        _ ->
            0


{-| Returns the violation, if any, for operand `index` of `op`, whose type is
`operandType`, against slot `index` of `bitmap`.

An `i1` operand is reported whatever the slot holds. Otherwise the operand is
reported when the slot's kind differs from the kind its type requires.
`bitmapName` and `operandLabel` only word the message.

-}
checkBitmapKind : MlirOp -> Int -> Int -> MlirType -> String -> String -> Maybe Violation
checkBitmapKind op bitmap index operandType bitmapName operandLabel =
    let
        kindFromBitmap =
            slotKind bitmap index

        kindFromType =
            typeToKind operandType
    in
    if operandType == I1 then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                operandLabel
                    ++ " "
                    ++ String.fromInt index
                    ++ " is i1 (Bool) but must be !eco.value at heap boundary"
            }

    else if kindFromBitmap /= kindFromType then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                bitmapName
                    ++ " slot "
                    ++ String.fromInt index
                    ++ " encodes kind "
                    ++ String.fromInt kindFromBitmap
                    ++ " but "
                    ++ operandLabel
                    ++ " type "
                    ++ typeToString operandType
                    ++ " requires kind "
                    ++ String.fromInt kindFromType
            }

    else
        Nothing


{-| Returns the violation, if any, in the `head_unboxed` flag of a list cons op.

The head is the first recorded operand. An `i1` head is reported, and so is a
flag that is true for a head that is not `i64`, `f64` or `i16`, or false for
one that is. A missing flag reads as false. An op with no recorded operand
types gives none.

-}
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


{-| Returns the violations in the `unboxed_bitmap` of an `eco.papCreate`,
comparing slot N with operand N. Every operand is a captured value. A missing
bitmap reads as 0, and an op with no recorded operand types gives none.
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


{-| Returns the violation, if any, for captured operand `index` of an
`eco.papCreate`, as `checkBitmapKind` decides it.
-}
checkPapCreateBit : MlirOp -> Int -> Int -> MlirType -> Maybe Violation
checkPapCreateBit op bitmap index operandType =
    checkBitmapKind op bitmap index operandType "unboxed_bitmap" "captured operand"


{-| Returns the violations in the `newargs_unboxed_bitmap` of an
`eco.papExtend`, comparing slot N with operand N+1.

Operand 0 is the closure being extended and is not compared. The last
`eco.gc_roots_count` operands are GC root hints and are dropped first; a
missing count drops none. A missing bitmap reads as 0, and an op with no
recorded operand types gives none.

-}
checkPapExtendBitmap : MlirOp -> List Violation
checkPapExtendBitmap op =
    let
        newargsBitmap =
            getIntAttr "newargs_unboxed_bitmap" op |> Maybe.withDefault 0

        maybeOperandTypes =
            extractOperandTypes op

        rootCount =
            Maybe.withDefault 0 (getIntAttr "eco.gc_roots_count" op)
    in
    case maybeOperandTypes of
        Nothing ->
            []

        Just allOperandTypes ->
            let
                operandTypes =
                    List.take (List.length allOperandTypes - rootCount) allOperandTypes
            in
            case List.tail operandTypes of
                Nothing ->
                    []

                Just newArgTypes ->
                    List.indexedMap (checkPapExtendBit op newargsBitmap) newArgTypes
                        |> List.filterMap identity


{-| Returns the violation, if any, for new argument `index` of an
`eco.papExtend`, as `checkBitmapKind` decides it.
-}
checkPapExtendBit : MlirOp -> Int -> Int -> MlirType -> Maybe Violation
checkPapExtendBit op bitmap index operandType =
    checkBitmapKind op bitmap index operandType "newargs_unboxed_bitmap" "new arg operand"


{-| Returns how `t` is written in a violation message. A named struct gives its
bare name, so `!eco.value` reads as `eco.value`, and any function type reads as
`function`.
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
            name

        FunctionType _ ->
            "function"
