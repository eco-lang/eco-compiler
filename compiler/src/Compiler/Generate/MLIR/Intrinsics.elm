module Compiler.Generate.MLIR.Intrinsics exposing (intrinsicResultMlirType, unboxArgsForIntrinsic, unboxToType, generateIntrinsicOps)

{-| Emits the MLIR for an _intrinsic_: a kernel call that the back end lowers to
inline operations instead of a call to the kernel function.

Which calls are intrinsics, and which `Intrinsic` each becomes, is decided by
`Compiler.GlobalOpt.KernelIntrinsics`, whose `Intrinsic` docstring says what
each constructor stands for. This module takes that decision as given and
answers three questions about it: what MLIR type the result has, what types
the operands must have, and which operations compute it.

Operands arrive as SSA variables that may be boxed (`!eco.value`) where the
operation wants a primitive (`i64`, `f64`, `i1` or the Char type). The operand
types listed here are what the operation needs, and `unboxArgsForIntrinsic`
inserts an `eco.unbox` for each boxed argument in a primitive slot. It never
boxes; a slot that wants `!eco.value` takes the argument as it is. Strings and
Lists are always `!eco.value` operands.

Most intrinsics are one operation. Three need more: `StringOrderCompare` is a
three-way compare followed by a test of its sign against zero; `ValueEq` with
`negate` (`/=`) is `eco.value.eq` followed by `eco.bool.not`; and `BoolEq`
without `negate` (`==`) is `eco.bool.xor` followed by `eco.bool.not`, since
`eco.bool.xor` already computes `/=`. `generateIntrinsicOps` emits every
intrinsic, these included.

When the argument variables do not fit what an intrinsic takes, operands that
cannot be taken from them are named `%error`, and the emitted MLIR is not
meaningful.

@docs intrinsicResultMlirType, unboxArgsForIntrinsic, unboxToType, generateIntrinsicOps

-}

import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Compiler.GlobalOpt.KernelIntrinsics exposing (CompareKind(..), Intrinsic(..))
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))



-- ====== INTRINSIC TYPE INFO ======


{-| Returns the MLIR type of the value an intrinsic produces.

Comparisons and equality give `i1`; `compare` gives a boxed `Order`. `ArrayGet`
gives the element type it carries, so an element stored unboxed is read
unboxed.

-}
intrinsicResultMlirType : Intrinsic -> MlirType
intrinsicResultMlirType intrinsic =
    case intrinsic of
        UnaryInt _ ->
            Types.ecoInt

        BinaryInt _ ->
            Types.ecoInt

        UnaryFloat _ ->
            Types.ecoFloat

        BinaryFloat _ ->
            Types.ecoFloat

        UnaryBool _ ->
            I1

        BinaryBool _ ->
            I1

        IntToFloat ->
            Types.ecoFloat

        FloatToInt _ ->
            Types.ecoInt

        IntComparison _ ->
            I1

        FloatComparison _ ->
            I1

        CharComparison _ ->
            I1

        FloatClassify _ ->
            I1

        ConstantFloat _ ->
            Types.ecoFloat

        CharToInt ->
            Types.ecoInt

        CharFromInt ->
            Types.ecoChar

        StringFromInt ->
            Types.ecoValue

        StringFromFloat ->
            Types.ecoValue

        ArrayGet { elementMlirType } ->
            elementMlirType

        ArraySet _ ->
            Types.ecoValue

        ArrayLength ->
            Types.ecoInt

        StringLength ->
            Types.ecoInt

        ArrayEmpty ->
            Types.ecoValue

        ArraySingleton _ ->
            Types.ecoValue

        ArrayPush _ ->
            Types.ecoValue

        ArraySlice ->
            Types.ecoValue

        ArrayAppendN ->
            Types.ecoValue

        ConstructList _ ->
            Types.ecoValue

        AppendString ->
            Types.ecoValue

        AppendList ->
            Types.ecoValue

        CompareToOrder _ ->
            Types.ecoValue

        StringOrderCompare _ ->
            I1

        ValueEq _ ->
            I1

        BoolEq _ ->
            I1


{-| Returns the MLIR types the operation for an intrinsic needs its operands to
have, in the order of the kernel function's arguments.

For `ConstructList` the list is not used to coerce arguments in practice; it
records the operand shape, with the tail always boxed.

-}
intrinsicOperandTypes : Intrinsic -> List MlirType
intrinsicOperandTypes intrinsic =
    case intrinsic of
        UnaryInt _ ->
            [ I64 ]

        BinaryInt _ ->
            [ I64, I64 ]

        UnaryFloat _ ->
            [ F64 ]

        BinaryFloat _ ->
            [ F64, F64 ]

        UnaryBool _ ->
            [ I1 ]

        BinaryBool _ ->
            [ I1, I1 ]

        IntToFloat ->
            [ I64 ]

        FloatToInt _ ->
            [ F64 ]

        IntComparison _ ->
            [ I64, I64 ]

        FloatComparison _ ->
            [ F64, F64 ]

        CharComparison _ ->
            [ Types.ecoChar, Types.ecoChar ]

        FloatClassify _ ->
            [ F64 ]

        ConstantFloat _ ->
            []

        CharToInt ->
            [ Types.ecoChar ]

        CharFromInt ->
            [ I64 ]

        StringFromInt ->
            [ I64 ]

        StringFromFloat ->
            [ F64 ]

        ArrayGet _ ->
            -- Elm arg order: unsafeGet index array
            [ I64, Types.ecoValue ]

        ArraySet { elementMlirType } ->
            -- Elm arg order: unsafeSet index value array
            [ I64, elementMlirType, Types.ecoValue ]

        ArrayLength ->
            [ Types.ecoValue ]

        StringLength ->
            [ Types.ecoValue ]

        ArrayEmpty ->
            []

        ArraySingleton { elementMlirType } ->
            [ elementMlirType ]

        ArrayPush { elementMlirType } ->
            -- Elm arg order: push value array
            [ elementMlirType, Types.ecoValue ]

        ArraySlice ->
            -- Elm arg order: slice start end array
            [ I64, I64, Types.ecoValue ]

        ArrayAppendN ->
            -- Elm arg order: appendN n dest source
            [ I64, Types.ecoValue, Types.ecoValue ]

        ConstructList { headMlirType } ->
            [ headMlirType, Types.ecoValue ]

        AppendString ->
            [ Types.ecoValue, Types.ecoValue ]

        AppendList ->
            [ Types.ecoValue, Types.ecoValue ]

        CompareToOrder { kind } ->
            case kind of
                CompareIntKind ->
                    [ I64, I64 ]

                CompareFloatKind ->
                    [ F64, F64 ]

                CompareCharKind ->
                    [ Types.ecoChar, Types.ecoChar ]

                CompareStringKind ->
                    [ Types.ecoValue, Types.ecoValue ]

        StringOrderCompare _ ->
            [ Types.ecoValue, Types.ecoValue ]

        ValueEq _ ->
            [ Types.ecoValue, Types.ecoValue ]

        BoolEq _ ->
            [ I1, I1 ]



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


{-| Returns the argument variables to pass to an intrinsic's operation, with the
operations that prepare them.

An argument whose type is `!eco.value` where the intrinsic wants a primitive is
unboxed into a fresh variable; every other argument is passed as it is. Nothing
is boxed. Arguments are paired with the operand types by position, so any
beyond the number of operands the intrinsic takes are dropped.

-}
unboxArgsForIntrinsic : Ctx.Context -> List ( String, MlirType ) -> Intrinsic -> ( List MlirOp, List String, Ctx.Context )
unboxArgsForIntrinsic ctx argsWithTypes intrinsic =
    let
        expectedTypes =
            intrinsicOperandTypes intrinsic

        ( revOps, revVars, finalCtx ) =
            List.foldl
                (\( ( var, actualType ), expectedType ) ( opsAcc, varsAcc, ctxAcc ) ->
                    if Types.isEcoValueType actualType && not (Types.isEcoValueType expectedType) then
                        let
                            ( unboxOps, unboxedVar, newCtx ) =
                                unboxToType ctxAcc var expectedType
                        in
                        ( List.reverse unboxOps ++ opsAcc, unboxedVar :: varsAcc, newCtx )

                    else
                        ( opsAcc, var :: varsAcc, ctxAcc )
                )
                ( [], [], ctx )
                (List.map2 Tuple.pair argsWithTypes expectedTypes)
    in
    ( List.reverse revOps, List.reverse revVars, finalCtx )



-- ====== INTRINSIC OP GENERATION ======


{-| Returns the single operation that computes an intrinsic into `resultVar`
from `argVars`, which must already have the operand types the intrinsic needs.

This is correct only for intrinsics that are one operation. For
`StringOrderCompare` it emits a placeholder over `%error` operands, and for
`ValueEq` and `BoolEq` it ignores `negate`: `ValueEq` always gives `==` and
`BoolEq` always gives `/=`. `generateIntrinsicOps` handles those three itself.

-}
generateIntrinsicOp : Ctx.Context -> Intrinsic -> String -> List String -> ( Ctx.Context, MlirOp )
generateIntrinsicOp ctx intrinsic resultVar argVars =
    case intrinsic of
        UnaryInt { op } ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            Ops.ecoUnaryOp ctx op resultVar ( operand, I64 ) I64

        BinaryInt { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    Ops.ecoBinaryOp ctx op resultVar ( lhs, I64 ) ( rhs, I64 ) I64

                _ ->
                    Ops.ecoUnaryOp ctx op resultVar ( "%error", I64 ) I64

        UnaryFloat { op } ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            Ops.ecoUnaryOp ctx op resultVar ( operand, F64 ) F64

        BinaryFloat { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    Ops.ecoBinaryOp ctx op resultVar ( lhs, F64 ) ( rhs, F64 ) F64

                _ ->
                    Ops.ecoUnaryOp ctx op resultVar ( "%error", F64 ) F64

        UnaryBool { op } ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            Ops.ecoUnaryOp ctx op resultVar ( operand, I1 ) I1

        BinaryBool { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    Ops.ecoBinaryOp ctx op resultVar ( lhs, I1 ) ( rhs, I1 ) I1

                _ ->
                    Ops.ecoUnaryOp ctx op resultVar ( "%error", I1 ) I1

        IntToFloat ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            Ops.ecoUnaryOp ctx "eco.int.toFloat" resultVar ( operand, I64 ) F64

        FloatToInt { op } ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            Ops.ecoUnaryOp ctx op resultVar ( operand, F64 ) I64

        IntComparison { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    Ops.ecoBinaryOp ctx op resultVar ( lhs, I64 ) ( rhs, I64 ) I1

                _ ->
                    Ops.ecoBinaryOp ctx op resultVar ( "%error", I64 ) ( "%error", I64 ) I1

        FloatComparison { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    Ops.ecoBinaryOp ctx op resultVar ( lhs, F64 ) ( rhs, F64 ) I1

                _ ->
                    Ops.ecoBinaryOp ctx op resultVar ( "%error", F64 ) ( "%error", F64 ) I1

        FloatClassify { op } ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            Ops.ecoUnaryOp ctx op resultVar ( operand, F64 ) I1

        ConstantFloat { value } ->
            Ops.arithConstantFloat ctx resultVar value

        ArrayGet { elementMlirType } ->
            -- Elm arg order: unsafeGet index array
            case argVars of
                [ indexVar, arrayVar ] ->
                    Ops.ecoArrayGet ctx resultVar arrayVar indexVar elementMlirType

                _ ->
                    Ops.ecoArrayGet ctx resultVar "%error" "%error" elementMlirType

        ArraySet { elementMlirType } ->
            -- Elm arg order: unsafeSet index value array
            case argVars of
                [ indexVar, valueVar, arrayVar ] ->
                    Ops.ecoArraySet ctx resultVar arrayVar indexVar valueVar elementMlirType

                _ ->
                    Ops.ecoArraySet ctx resultVar "%error" "%error" "%error" elementMlirType

        ArrayLength ->
            case argVars of
                [ arrayVar ] ->
                    Ops.ecoArrayLength ctx resultVar arrayVar

                _ ->
                    Ops.ecoArrayLength ctx resultVar "%error"

        CharComparison { op } ->
            case argVars of
                [ lhs, rhs ] ->
                    Ops.ecoBinaryOp ctx op resultVar ( lhs, Types.ecoChar ) ( rhs, Types.ecoChar ) I1

                _ ->
                    Ops.ecoBinaryOp ctx op resultVar ( "%error", Types.ecoChar ) ( "%error", Types.ecoChar ) I1

        CharToInt ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            Ops.ecoUnaryOp ctx "eco.char.toInt" resultVar ( operand, Types.ecoChar ) Types.ecoInt

        CharFromInt ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            Ops.ecoUnaryOp ctx "eco.char.fromInt" resultVar ( operand, I64 ) Types.ecoChar

        StringFromInt ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            Ops.ecoUnaryOp ctx "eco.string.from_int" resultVar ( operand, I64 ) Types.ecoValue

        StringLength ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            Ops.ecoUnaryOp ctx "eco.string.length" resultVar ( operand, Types.ecoValue ) Types.ecoInt

        StringFromFloat ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            Ops.ecoUnaryOp ctx "eco.string.from_float" resultVar ( operand, F64 ) Types.ecoValue

        ArrayEmpty ->
            Ops.ecoNullaryOp ctx "eco.array.empty" resultVar Types.ecoValue

        ArraySingleton { elementMlirType } ->
            let
                operand =
                    List.head argVars |> Maybe.withDefault "%error"
            in
            Ops.ecoUnaryOp ctx "eco.array.singleton" resultVar ( operand, elementMlirType ) Types.ecoValue

        ArrayPush { elementMlirType } ->
            -- Elm arg order: push value array
            case argVars of
                [ valueVar, arrayVar ] ->
                    Ops.ecoBinaryOp ctx "eco.array.push" resultVar ( valueVar, elementMlirType ) ( arrayVar, Types.ecoValue ) Types.ecoValue

                _ ->
                    Ops.ecoBinaryOp ctx "eco.array.push" resultVar ( "%error", elementMlirType ) ( "%error", Types.ecoValue ) Types.ecoValue

        ArraySlice ->
            -- Elm arg order: slice start end array
            case argVars of
                [ startVar, endVar, arrayVar ] ->
                    Ops.ecoTernaryOp ctx "eco.array.slice" resultVar ( startVar, I64 ) ( endVar, I64 ) ( arrayVar, Types.ecoValue ) Types.ecoValue

                _ ->
                    Ops.ecoTernaryOp ctx "eco.array.slice" resultVar ( "%error", I64 ) ( "%error", I64 ) ( "%error", Types.ecoValue ) Types.ecoValue

        ArrayAppendN ->
            -- Elm arg order: appendN n dest source
            case argVars of
                [ nVar, destVar, sourceVar ] ->
                    Ops.ecoTernaryOp ctx "eco.array.append_n" resultVar ( nVar, I64 ) ( destVar, Types.ecoValue ) ( sourceVar, Types.ecoValue ) Types.ecoValue

                _ ->
                    Ops.ecoTernaryOp ctx "eco.array.append_n" resultVar ( "%error", I64 ) ( "%error", Types.ecoValue ) ( "%error", Types.ecoValue ) Types.ecoValue

        ConstructList { headMlirType } ->
            case argVars of
                [ headVar, tailVar ] ->
                    Ops.ecoConstructList ctx
                        resultVar
                        ( headVar, headMlirType )
                        ( tailVar, Types.ecoValue )
                        (Types.isUnboxable headMlirType)

                _ ->
                    Ops.ecoConstructList ctx
                        resultVar
                        ( "%error", headMlirType )
                        ( "%error", Types.ecoValue )
                        (Types.isUnboxable headMlirType)

        AppendString ->
            case argVars of
                [ lhs, rhs ] ->
                    Ops.ecoBinaryOp ctx "eco.string.append" resultVar ( lhs, Types.ecoValue ) ( rhs, Types.ecoValue ) Types.ecoValue

                _ ->
                    Ops.ecoBinaryOp ctx "eco.string.append" resultVar ( "%error", Types.ecoValue ) ( "%error", Types.ecoValue ) Types.ecoValue

        AppendList ->
            case argVars of
                [ lhs, rhs ] ->
                    Ops.ecoBinaryOp ctx "eco.list.append" resultVar ( lhs, Types.ecoValue ) ( rhs, Types.ecoValue ) Types.ecoValue

                _ ->
                    Ops.ecoBinaryOp ctx "eco.list.append" resultVar ( "%error", Types.ecoValue ) ( "%error", Types.ecoValue ) Types.ecoValue

        CompareToOrder { kind } ->
            let
                ( opName, lhsType, rhsType ) =
                    case kind of
                        CompareIntKind ->
                            ( "eco.int.cmp_order", I64, I64 )

                        CompareFloatKind ->
                            ( "eco.float.cmp_order", F64, F64 )

                        CompareCharKind ->
                            ( "eco.char.cmp_order", Types.ecoChar, Types.ecoChar )

                        CompareStringKind ->
                            ( "eco.string.cmp_order", Types.ecoValue, Types.ecoValue )
            in
            case argVars of
                [ lhs, rhs ] ->
                    Ops.ecoBinaryOp ctx opName resultVar ( lhs, lhsType ) ( rhs, rhsType ) Types.ecoValue

                _ ->
                    Ops.ecoBinaryOp ctx opName resultVar ( "%error", lhsType ) ( "%error", rhsType ) Types.ecoValue

        StringOrderCompare { op } ->
            Ops.ecoBinaryOp ctx op resultVar ( "%error", Types.ecoInt ) ( "%error", Types.ecoInt ) I1

        ValueEq _ ->
            case argVars of
                [ lhs, rhs ] ->
                    Ops.ecoBinaryOp ctx "eco.value.eq" resultVar ( lhs, Types.ecoValue ) ( rhs, Types.ecoValue ) I1

                _ ->
                    Ops.ecoBinaryOp ctx "eco.value.eq" resultVar ( "%error", Types.ecoValue ) ( "%error", Types.ecoValue ) I1

        BoolEq _ ->
            case argVars of
                [ lhs, rhs ] ->
                    Ops.ecoBinaryOp ctx "eco.bool.xor" resultVar ( lhs, I1 ) ( rhs, I1 ) I1

                _ ->
                    Ops.ecoBinaryOp ctx "eco.bool.xor" resultVar ( "%error", I1 ) ( "%error", I1 ) I1


{-| Returns the operations that compute an intrinsic into `resultVar` from
`argVars`, which must already have the operand types the intrinsic needs.

Most intrinsics are one operation. `StringOrderCompare` is three: an
`eco.string.cmp3` giving a signed Int, a zero constant, and the comparison
`op` between the two. `ValueEq` and `BoolEq` with `negate` set are the equality
into a fresh variable followed by `eco.bool.not`. Two Bools are compared with
`eco.bool.xor`, which is true when they differ, so `BoolEq` without `negate` is
the one that gets the `eco.bool.not`.

-}
generateIntrinsicOps : Ctx.Context -> Intrinsic -> String -> List String -> ( Ctx.Context, List MlirOp )
generateIntrinsicOps ctx intrinsic resultVar argVars =
    case intrinsic of
        StringOrderCompare { op } ->
            let
                ( lhs, rhs ) =
                    case argVars of
                        [ a, b ] ->
                            ( a, b )

                        _ ->
                            ( "%error", "%error" )

                ( signVar, ctx1 ) =
                    Ctx.freshVar ctx

                ( ctx2, cmp3Op ) =
                    Ops.ecoBinaryOp ctx1 "eco.string.cmp3" signVar ( lhs, Types.ecoValue ) ( rhs, Types.ecoValue ) Types.ecoInt

                ( zeroVar, ctx3 ) =
                    Ctx.freshVar ctx2

                ( ctx4, zeroOp ) =
                    Ops.arithConstantInt ctx3 zeroVar 0

                ( ctx5, testOp ) =
                    Ops.ecoBinaryOp ctx4 op resultVar ( signVar, Types.ecoInt ) ( zeroVar, Types.ecoInt ) I1
            in
            ( ctx5, [ cmp3Op, zeroOp, testOp ] )

        ValueEq { negate } ->
            emitEqMaybeNegated ctx "eco.value.eq" Types.ecoValue negate resultVar argVars

        BoolEq { negate } ->
            emitEqMaybeNegated ctx "eco.bool.xor" I1 (not negate) resultVar argVars

        _ ->
            generateIntrinsicOp ctx intrinsic resultVar argVars
                |> Tuple.mapSecond List.singleton


{-| Returns the two-operand operation `opName` into `resultVar`, or, when
`negate` is set, that operation into a fresh variable followed by an
`eco.bool.not` into `resultVar`. Either way `resultVar` holds the final value.
-}
emitEqMaybeNegated : Ctx.Context -> String -> MlirType -> Bool -> String -> List String -> ( Ctx.Context, List MlirOp )
emitEqMaybeNegated ctx opName operandTy negate resultVar argVars =
    let
        ( lhs, rhs ) =
            case argVars of
                [ a, b ] ->
                    ( a, b )

                _ ->
                    ( "%error", "%error" )
    in
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
            |> Tuple.mapSecond List.singleton
