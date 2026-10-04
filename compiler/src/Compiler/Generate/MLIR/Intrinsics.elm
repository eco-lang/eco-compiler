module Compiler.Generate.MLIR.Intrinsics exposing (intrinsicResultMlirType, unboxArgsForIntrinsic, unboxToType, generateIntrinsicOps)

{-| Intrinsic operations for the MLIR backend.

This module emits the MLIR for the intrinsics that
`Compiler.GlobalOpt.KernelIntrinsics` selects: core Elm operations that are
lowered directly to MLIR operations instead of kernel calls.

@docs intrinsicResultMlirType, unboxArgsForIntrinsic, unboxToType, generateIntrinsicOps

-}

import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Compiler.GlobalOpt.KernelIntrinsics exposing (CompareKind(..), Intrinsic(..))
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))



-- ====== INTRINSIC TYPE INFO ======


{-| Get the MLIR result type for an intrinsic operation.
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


{-| Get the expected operand types for an intrinsic operation.
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
            -- array : !eco.value
            [ Types.ecoValue ]

        StringLength ->
            -- REP_ABI_001: String crosses every ABI as !eco.value; never unbox.
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
            -- Elm arg order: cons head tail. Tail is ALWAYS boxed (Ops.td:636-642).
            -- Never actually consulted: Expr.coerceIntrinsicArgs intercepts this
            -- ctor before unboxArgsForIntrinsic (its only caller). Present for
            -- exhaustiveness and as documentation of the operand shape.
            [ headMlirType, Types.ecoValue ]

        -- REP_ABI_001: String and List cross every ABI as !eco.value. Never
        -- unbox; unboxArgsForIntrinsic no-ops for boxed-expected slots.
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

                -- REP_ABI_001: String crosses every ABI as !eco.value. Never
                -- unbox; unboxArgsForIntrinsic no-ops for boxed-expected slots.
                CompareStringKind ->
                    [ Types.ecoValue, Types.ecoValue ]

        StringOrderCompare _ ->
            -- REP_ABI_001: String crosses every ABI as !eco.value; never unbox.
            -- unboxArgsForIntrinsic no-ops on boxed-expected slots.
            [ Types.ecoValue, Types.ecoValue ]

        ValueEq _ ->
            [ Types.ecoValue, Types.ecoValue ]

        BoolEq _ ->
            [ I1, I1 ]



-- ====== UNBOXING HELPERS ======


{-| Unbox a value from !eco.value to a target primitive type.
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


{-| Unbox arguments to match the expected operand types for an intrinsic.
If an argument has !eco.value type but the intrinsic expects a primitive type,
an unbox operation is inserted.
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
                        -- Need to unbox: actual is !eco.value, expected is primitive
                        let
                            ( unboxOps, unboxedVar, newCtx ) =
                                unboxToType ctxAcc var expectedType
                        in
                        ( List.reverse unboxOps ++ opsAcc, unboxedVar :: varsAcc, newCtx )

                    else
                        -- No unboxing needed
                        ( opsAcc, var :: varsAcc, ctxAcc )
                )
                ( [], [], ctx )
                (List.map2 Tuple.pair argsWithTypes expectedTypes)
    in
    ( List.reverse revOps, List.reverse revVars, finalCtx )



-- ====== INTRINSIC OP GENERATION ======


{-| Generate an MLIR operation for an intrinsic.
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
            -- Elm arg order: cons head tail. HINT-FREE by construction
            -- (kernel-opt-01 Phase 1): EcoGCPrepare recomputes and UNIONS the real
            -- root set at this carrier (EcoGCPrepare.cpp:249-305), and
            -- EcoListTemplate only absorbs hint-free links (EcoListTemplate.cpp:148-150).
            case argVars of
                [ headVar, tailVar ] ->
                    Ops.ecoConstructList ctx
                        []
                        resultVar
                        ( headVar, headMlirType )
                        ( tailVar, Types.ecoValue )
                        (Types.isUnboxable headMlirType)

                _ ->
                    Ops.ecoConstructList ctx
                        []
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
            -- Multi-op intrinsic: both emission sites route through
            -- generateIntrinsicOps. Kept only for case totality.
            Ops.ecoBinaryOp ctx op resultVar ( "%error", Types.ecoInt ) ( "%error", Types.ecoInt ) I1

        ValueEq _ ->
            -- Non-negated form; the negated one is multi-op and goes through
            -- generateIntrinsicOps.
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


{-| Emit an intrinsic that needs MORE THAN ONE op.

`generateIntrinsicOp` returns a single `MlirOp`; `StringOrderCompare` needs
three (the cmp3, the zero constant, the signed test). Rather than churn the
existing single-op arms, this wraps them: anything that is not multi-op is
delegated and wrapped in a singleton list, so both emission sites in `Expr.elm`
can call this uniformly.

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
            -- xor IS notEqual, so the polarity is inverted relative to ValueEq.
            emitEqMaybeNegated ctx "eco.bool.xor" I1 (not negate) resultVar argVars

        _ ->
            generateIntrinsicOp ctx intrinsic resultVar argVars
                |> Tuple.mapSecond List.singleton


{-| Emit a two-operand equality op, optionally followed by `eco.bool.not`.

`notEqual` is emission-side negation -- there is deliberately no second MLIR op
def for it. `eco.bool.not` lowers to `arith.xori %x, true`. When negating, the
equality lands in a fresh temp and the NOT writes `resultVar`, so the caller's
result variable always holds the final value.

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
