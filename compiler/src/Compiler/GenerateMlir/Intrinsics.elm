module Compiler.GenerateMlir.Intrinsics exposing (operationResultMlirType, unboxOperands, unboxToType, generateOperationOps)

{-| Emits the MLIR for an intrinsic `Operation`: a kernel call that the back
end lowers to inline operations instead of a call to the kernel function.

Which calls are intrinsics, and which `Operation` each becomes, is decided by
`Compiler.IR.Kernel.Intrinsics`, whose `Intrinsic` docstring says what each
constructor stands for. The other kind of intrinsic, `ConstructList`, is
emitted by `Compiler.GenerateMlir.Expr`, because its operands may need boxing.
This module takes the decision as given and answers three questions about an
`Operation`: what MLIR type its result has, how its operands are brought to the
types the operation needs, and which operations compute it.

Operands arrive as SSA variables that may be boxed (`!eco.value`) where the
operation wants a primitive (`i64`, `f64`, `i1` or the Char type).
`unboxOperands` inserts an `eco.unbox` for each boxed operand in a primitive
slot. It never boxes; a slot that wants `!eco.value` takes the operand as it
is. Strings and Lists are always `!eco.value` operands.

Most operations are one MLIR operation. Three need more: `StringOrderCompare`
is a three-way compare followed by a test of its sign against zero; `ValueEq`
with `negate` (`/=`) is `eco.value.eq` followed by `eco.bool.not`; and `BoolEq`
without `negate` (`==`) is `eco.bool.xor` followed by `eco.bool.not`, since
`eco.bool.xor` already computes `/=`. `generateOperationOps` emits every
operation, these included.

@docs operationResultMlirType, unboxOperands, unboxToType, generateOperationOps

-}

import Compiler.GenerateMlir.Context as Ctx
import Compiler.GenerateMlir.Ops as Ops
import Compiler.GenerateMlir.Types as Types
import Compiler.IR.Kernel.Intrinsics exposing (CompareKind(..), Operation(..))
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))



-- ====== INTRINSIC TYPE INFO ======


{-| Returns the MLIR type of the value an operation produces.

Comparisons and equality give `i1`; `compare` gives a boxed `Order`. `ArrayGet`
gives the element type it carries, so an element stored unboxed is read
unboxed.

-}
operationResultMlirType : Operation a -> MlirType
operationResultMlirType operation =
    case operation of
        UnaryInt _ _ ->
            Types.ecoInt

        BinaryInt _ _ _ ->
            Types.ecoInt

        UnaryFloat _ _ ->
            Types.ecoFloat

        BinaryFloat _ _ _ ->
            Types.ecoFloat

        UnaryBool _ _ ->
            I1

        BinaryBool _ _ _ ->
            I1

        IntToFloat _ ->
            Types.ecoFloat

        FloatToInt _ _ ->
            Types.ecoInt

        IntComparison _ _ _ ->
            I1

        FloatComparison _ _ _ ->
            I1

        CharComparison _ _ _ ->
            I1

        FloatClassify _ _ ->
            I1

        CharToInt _ ->
            Types.ecoInt

        CharFromInt _ ->
            Types.ecoChar

        StringFromInt _ ->
            Types.ecoValue

        StringFromFloat _ ->
            Types.ecoValue

        ArrayGet { elementMlirType } _ _ ->
            elementMlirType

        ArraySet _ _ _ _ ->
            Types.ecoValue

        ArrayLength _ ->
            Types.ecoInt

        StringLength _ ->
            Types.ecoInt

        ArraySingleton _ _ ->
            Types.ecoValue

        ArrayPush _ _ _ ->
            Types.ecoValue

        ArraySlice _ _ _ ->
            Types.ecoValue

        ArrayAppendN _ _ _ ->
            Types.ecoValue

        AppendString _ _ ->
            Types.ecoValue

        AppendList _ _ ->
            Types.ecoValue

        CompareToOrder _ _ _ ->
            Types.ecoValue

        StringOrderCompare _ _ _ ->
            I1

        ValueEq _ _ _ ->
            I1

        BoolEq _ _ _ ->
            I1


{-| Returns the MLIR type of the two operands of a `compare` of `kind`.
-}
compareOperandType : CompareKind -> MlirType
compareOperandType kind =
    case kind of
        CompareIntKind ->
            I64

        CompareFloatKind ->
            F64

        CompareCharKind ->
            Types.ecoChar

        CompareStringKind ->
            Types.ecoValue



-- ====== UNBOXING HELPERS ======


{-| Returns one `eco.unbox` that reads the boxed `var` as a value of
`targetType`, together with the fresh variable holding the result.
-}
unboxToType : Ctx.Context -> String -> MlirType -> ( List MlirOp, String, Ctx.Context )
unboxToType ctx var targetType =
    let
        ( unboxedVar, ctx1 ) =
            Ctx.freshVar ctx

        attrs =
            Dict.singleton "_operand_types" (ArrayAttr Nothing [ TypeAttr Types.ecoValue ])

        ( ctx2, unboxOp ) =
            Ops.mlirOp ctx1 "eco.unbox"
                |> Ops.opBuilder.withOperands [ var ]
                |> Ops.opBuilder.withResults [ ( unboxedVar, targetType ) ]
                |> Ops.opBuilder.withAttrs attrs
                |> Ops.opBuilder.build
    in
    ( [ unboxOp ], unboxedVar, ctx2 )


{-| Returns the operation with each operand, a variable and its SSA type,
replaced by the variable to pass to the MLIR operation, with the operations
that prepare them, in operand order.

An operand whose type is `!eco.value` where the operation wants a primitive is
unboxed into a fresh variable; every other operand is passed as it is. Nothing
is boxed.

-}
unboxOperands : Ctx.Context -> Operation ( String, MlirType ) -> ( List MlirOp, Operation String, Ctx.Context )
unboxOperands ctx operation =
    case operation of
        UnaryInt r a ->
            unbox1 ctx (UnaryInt r) ( a, I64 )

        BinaryInt r a b ->
            unbox2 ctx (BinaryInt r) ( a, I64 ) ( b, I64 )

        UnaryFloat r a ->
            unbox1 ctx (UnaryFloat r) ( a, F64 )

        BinaryFloat r a b ->
            unbox2 ctx (BinaryFloat r) ( a, F64 ) ( b, F64 )

        UnaryBool r a ->
            unbox1 ctx (UnaryBool r) ( a, I1 )

        BinaryBool r a b ->
            unbox2 ctx (BinaryBool r) ( a, I1 ) ( b, I1 )

        IntToFloat a ->
            unbox1 ctx IntToFloat ( a, I64 )

        FloatToInt r a ->
            unbox1 ctx (FloatToInt r) ( a, F64 )

        IntComparison r a b ->
            unbox2 ctx (IntComparison r) ( a, I64 ) ( b, I64 )

        FloatComparison r a b ->
            unbox2 ctx (FloatComparison r) ( a, F64 ) ( b, F64 )

        CharComparison r a b ->
            unbox2 ctx (CharComparison r) ( a, Types.ecoChar ) ( b, Types.ecoChar )

        FloatClassify r a ->
            unbox1 ctx (FloatClassify r) ( a, F64 )

        CharToInt a ->
            unbox1 ctx CharToInt ( a, Types.ecoChar )

        CharFromInt a ->
            unbox1 ctx CharFromInt ( a, I64 )

        StringFromInt a ->
            unbox1 ctx StringFromInt ( a, I64 )

        StringFromFloat a ->
            unbox1 ctx StringFromFloat ( a, F64 )

        ArrayGet r index array ->
            unbox2 ctx (ArrayGet r) ( index, I64 ) ( array, Types.ecoValue )

        ArraySet r index value array ->
            unbox3 ctx (ArraySet r) ( index, I64 ) ( value, r.elementMlirType ) ( array, Types.ecoValue )

        ArrayLength array ->
            unbox1 ctx ArrayLength ( array, Types.ecoValue )

        StringLength string ->
            unbox1 ctx StringLength ( string, Types.ecoValue )

        ArraySingleton r value ->
            unbox1 ctx (ArraySingleton r) ( value, r.elementMlirType )

        ArrayPush r value array ->
            unbox2 ctx (ArrayPush r) ( value, r.elementMlirType ) ( array, Types.ecoValue )

        ArraySlice start end array ->
            unbox3 ctx ArraySlice ( start, I64 ) ( end, I64 ) ( array, Types.ecoValue )

        ArrayAppendN n dest source ->
            unbox3 ctx ArrayAppendN ( n, I64 ) ( dest, Types.ecoValue ) ( source, Types.ecoValue )

        AppendString a b ->
            unbox2 ctx AppendString ( a, Types.ecoValue ) ( b, Types.ecoValue )

        AppendList a b ->
            unbox2 ctx AppendList ( a, Types.ecoValue ) ( b, Types.ecoValue )

        CompareToOrder r a b ->
            unbox2 ctx (CompareToOrder r) ( a, compareOperandType r.kind ) ( b, compareOperandType r.kind )

        StringOrderCompare r a b ->
            unbox2 ctx (StringOrderCompare r) ( a, Types.ecoValue ) ( b, Types.ecoValue )

        ValueEq r a b ->
            unbox2 ctx (ValueEq r) ( a, Types.ecoValue ) ( b, Types.ecoValue )

        BoolEq r a b ->
            unbox2 ctx (BoolEq r) ( a, I1 ) ( b, I1 )


{-| Returns the variable to pass for `operand` in a slot of type
`expectedType`: unboxed into a fresh variable when it is `!eco.value` and the
slot is a primitive, and as it is otherwise.
-}
unboxOperand : Ctx.Context -> ( ( String, MlirType ), MlirType ) -> ( List MlirOp, String, Ctx.Context )
unboxOperand ctx ( ( var, actualType ), expectedType ) =
    if Types.isEcoValueType actualType && not (Types.isEcoValueType expectedType) then
        unboxToType ctx var expectedType

    else
        ( [], var, ctx )


{-| `unboxOperands` for an operation of one operand, rebuilt with `make`.
-}
unbox1 : Ctx.Context -> (String -> b) -> ( ( String, MlirType ), MlirType ) -> ( List MlirOp, b, Ctx.Context )
unbox1 ctx make a =
    let
        ( opsA, varA, ctxA ) =
            unboxOperand ctx a
    in
    ( opsA, make varA, ctxA )


{-| `unboxOperands` for an operation of two operands, rebuilt with `make`.
-}
unbox2 : Ctx.Context -> (String -> String -> b) -> ( ( String, MlirType ), MlirType ) -> ( ( String, MlirType ), MlirType ) -> ( List MlirOp, b, Ctx.Context )
unbox2 ctx make a b =
    let
        ( opsA, varA, ctxA ) =
            unboxOperand ctx a

        ( opsB, varB, ctxB ) =
            unboxOperand ctxA b
    in
    ( opsA ++ opsB, make varA varB, ctxB )


{-| `unboxOperands` for an operation of three operands, rebuilt with `make`.
-}
unbox3 :
    Ctx.Context
    -> (String -> String -> String -> b)
    -> ( ( String, MlirType ), MlirType )
    -> ( ( String, MlirType ), MlirType )
    -> ( ( String, MlirType ), MlirType )
    -> ( List MlirOp, b, Ctx.Context )
unbox3 ctx make a b c =
    let
        ( opsA, varA, ctxA ) =
            unboxOperand ctx a

        ( opsB, varB, ctxB ) =
            unboxOperand ctxA b

        ( opsC, varC, ctxC ) =
            unboxOperand ctxB c
    in
    ( opsA ++ opsB ++ opsC, make varA varB varC, ctxC )



-- ====== INTRINSIC OP GENERATION ======


{-| Returns the operations that compute an operation into `resultVar` from its
operands, which must already have the types the operation needs (see
`unboxOperands`).

Most operations are one MLIR operation. `StringOrderCompare` is three: an
`eco.string.cmp3` giving a signed Int, a zero constant, and the comparison
`op` between the two. `ValueEq` and `BoolEq` with `negate` set are the equality
into a fresh variable followed by `eco.bool.not`. Two Bools are compared with
`eco.bool.xor`, which is true when they differ, so `BoolEq` without `negate` is
the one that gets the `eco.bool.not`.

-}
generateOperationOps : Ctx.Context -> Operation String -> String -> ( Ctx.Context, List MlirOp )
generateOperationOps ctx operation resultVar =
    case operation of
        UnaryInt { op } a ->
            single (Ops.ecoUnaryOp ctx op resultVar ( a, I64 ) I64)

        BinaryInt { op } a b ->
            single (Ops.ecoBinaryOp ctx op resultVar ( a, I64 ) ( b, I64 ) I64)

        UnaryFloat { op } a ->
            single (Ops.ecoUnaryOp ctx op resultVar ( a, F64 ) F64)

        BinaryFloat { op } a b ->
            single (Ops.ecoBinaryOp ctx op resultVar ( a, F64 ) ( b, F64 ) F64)

        UnaryBool { op } a ->
            single (Ops.ecoUnaryOp ctx op resultVar ( a, I1 ) I1)

        BinaryBool { op } a b ->
            single (Ops.ecoBinaryOp ctx op resultVar ( a, I1 ) ( b, I1 ) I1)

        IntToFloat a ->
            single (Ops.ecoUnaryOp ctx "eco.int.toFloat" resultVar ( a, I64 ) F64)

        FloatToInt { op } a ->
            single (Ops.ecoUnaryOp ctx op resultVar ( a, F64 ) I64)

        IntComparison { op } a b ->
            single (Ops.ecoBinaryOp ctx op resultVar ( a, I64 ) ( b, I64 ) I1)

        FloatComparison { op } a b ->
            single (Ops.ecoBinaryOp ctx op resultVar ( a, F64 ) ( b, F64 ) I1)

        FloatClassify { op } a ->
            single (Ops.ecoUnaryOp ctx op resultVar ( a, F64 ) I1)

        ArrayGet { elementMlirType } index array ->
            single (Ops.ecoArrayGet ctx resultVar array index elementMlirType)

        ArraySet { elementMlirType } index value array ->
            single (Ops.ecoArraySet ctx resultVar array index value elementMlirType)

        ArrayLength array ->
            single (Ops.ecoArrayLength ctx resultVar array)

        CharComparison { op } a b ->
            single (Ops.ecoBinaryOp ctx op resultVar ( a, Types.ecoChar ) ( b, Types.ecoChar ) I1)

        CharToInt a ->
            single (Ops.ecoUnaryOp ctx "eco.char.toInt" resultVar ( a, Types.ecoChar ) Types.ecoInt)

        CharFromInt a ->
            single (Ops.ecoUnaryOp ctx "eco.char.fromInt" resultVar ( a, I64 ) Types.ecoChar)

        StringFromInt a ->
            single (Ops.ecoUnaryOp ctx "eco.string.from_int" resultVar ( a, I64 ) Types.ecoValue)

        StringLength string ->
            single (Ops.ecoUnaryOp ctx "eco.string.length" resultVar ( string, Types.ecoValue ) Types.ecoInt)

        StringFromFloat a ->
            single (Ops.ecoUnaryOp ctx "eco.string.from_float" resultVar ( a, F64 ) Types.ecoValue)

        ArraySingleton { elementMlirType } value ->
            single (Ops.ecoUnaryOp ctx "eco.array.singleton" resultVar ( value, elementMlirType ) Types.ecoValue)

        ArrayPush { elementMlirType } value array ->
            single (Ops.ecoBinaryOp ctx "eco.array.push" resultVar ( value, elementMlirType ) ( array, Types.ecoValue ) Types.ecoValue)

        ArraySlice start end array ->
            single (Ops.ecoTernaryOp ctx "eco.array.slice" resultVar ( start, I64 ) ( end, I64 ) ( array, Types.ecoValue ) Types.ecoValue)

        ArrayAppendN n dest source ->
            single (Ops.ecoTernaryOp ctx "eco.array.append_n" resultVar ( n, I64 ) ( dest, Types.ecoValue ) ( source, Types.ecoValue ) Types.ecoValue)

        AppendString a b ->
            single (Ops.ecoBinaryOp ctx "eco.string.append" resultVar ( a, Types.ecoValue ) ( b, Types.ecoValue ) Types.ecoValue)

        AppendList a b ->
            single (Ops.ecoBinaryOp ctx "eco.list.append" resultVar ( a, Types.ecoValue ) ( b, Types.ecoValue ) Types.ecoValue)

        CompareToOrder { kind } a b ->
            let
                opName =
                    case kind of
                        CompareIntKind ->
                            "eco.int.cmp_order"

                        CompareFloatKind ->
                            "eco.float.cmp_order"

                        CompareCharKind ->
                            "eco.char.cmp_order"

                        CompareStringKind ->
                            "eco.string.cmp_order"

                operandType =
                    compareOperandType kind
            in
            single (Ops.ecoBinaryOp ctx opName resultVar ( a, operandType ) ( b, operandType ) Types.ecoValue)

        StringOrderCompare { op } a b ->
            let
                ( signVar, ctx1 ) =
                    Ctx.freshVar ctx

                ( ctx2, cmp3Op ) =
                    Ops.ecoBinaryOp ctx1 "eco.string.cmp3" signVar ( a, Types.ecoValue ) ( b, Types.ecoValue ) Types.ecoInt

                ( zeroVar, ctx3 ) =
                    Ctx.freshVar ctx2

                ( ctx4, zeroOp ) =
                    Ops.arithConstantInt ctx3 zeroVar 0

                ( ctx5, testOp ) =
                    Ops.ecoBinaryOp ctx4 op resultVar ( signVar, Types.ecoInt ) ( zeroVar, Types.ecoInt ) I1
            in
            ( ctx5, [ cmp3Op, zeroOp, testOp ] )

        ValueEq { negate } a b ->
            emitEqMaybeNegated ctx "eco.value.eq" Types.ecoValue negate resultVar a b

        BoolEq { negate } a b ->
            emitEqMaybeNegated ctx "eco.bool.xor" I1 (not negate) resultVar a b


{-| Wraps the one operation of a single-operation intrinsic as a list.
-}
single : ( Ctx.Context, MlirOp ) -> ( Ctx.Context, List MlirOp )
single =
    Tuple.mapSecond List.singleton


{-| Returns the two-operand operation `opName` on `lhs` and `rhs` into
`resultVar`, or, when `negate` is set, that operation into a fresh variable
followed by an `eco.bool.not` into `resultVar`. Either way `resultVar` holds
the final value.
-}
emitEqMaybeNegated : Ctx.Context -> String -> MlirType -> Bool -> String -> String -> String -> ( Ctx.Context, List MlirOp )
emitEqMaybeNegated ctx opName operandTy negate resultVar lhs rhs =
    if negate then
        let
            ( tmp, ctx1 ) =
                Ctx.freshVar ctx

            ( ctx2, eqOp ) =
                Ops.ecoBinaryOp ctx1 opName tmp ( lhs, operandTy ) ( rhs, operandTy ) I1

            ( ctx3, notOp ) =
                Ops.ecoUnaryOp ctx2 "eco.bool.not" resultVar ( tmp, I1 ) I1
        in
        ( ctx3, [ eqOp, notOp ] )

    else
        Ops.ecoBinaryOp ctx opName resultVar ( lhs, operandTy ) ( rhs, operandTy ) I1
            |> single
