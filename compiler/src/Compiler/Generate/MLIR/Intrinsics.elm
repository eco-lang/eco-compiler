module Compiler.Generate.MLIR.Intrinsics exposing (Intrinsic(..), CompareKind(..), kernelIntrinsic, intrinsicResultMlirType, unboxArgsForIntrinsic, unboxToType, generateIntrinsicOp)

{-| Intrinsic operations for the MLIR backend.

This module defines intrinsics for core Elm operations that can be
directly lowered to efficient MLIR operations without kernel calls.

@docs Intrinsic, CompareKind, kernelIntrinsic, intrinsicResultMlirType, unboxArgsForIntrinsic, unboxToType, generateIntrinsicOp

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Types as Types
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))



-- ====== INTRINSIC TYPE ======


{-| Intrinsic operation type representing operations that can be lowered directly to MLIR.
-}
type Intrinsic
    = UnaryInt { op : String }
    | BinaryInt { op : String }
    | UnaryFloat { op : String }
    | BinaryFloat { op : String }
    | UnaryBool { op : String }
    | BinaryBool { op : String }
    | IntToFloat
    | FloatToInt { op : String }
    | IntComparison { op : String }
    | FloatComparison { op : String }
    | CharComparison { op : String }
    | FloatClassify { op : String }
    | ConstantFloat { value : Float }
    | CharToInt
    | CharFromInt
    | StringFromInt
    | StringFromFloat
    | StringLength
    | ArrayGet { elementMlirType : MlirType }
    | ArraySet { elementMlirType : MlirType }
    | ArrayLength
    | ArrayEmpty
    | ArraySingleton { elementMlirType : MlirType }
    | ArrayPush { elementMlirType : MlirType }
    | ArraySlice
    | ArrayAppendN
    | ConstructList { headMlirType : MlirType }
    | AppendString
    | AppendList
    | CompareToOrder { kind : CompareKind }


{-| Operand kind selector for the `Utils.compare` intrinsic.
-}
type CompareKind
    = CompareIntKind
    | CompareFloatKind
    | CompareCharKind
    | CompareStringKind



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



-- ====== INTRINSIC LOOKUP ======


{-| Look up an intrinsic for a kernel function call.
-}
kernelIntrinsic : Name.Name -> Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
kernelIntrinsic home name argTypes resultType =
    case home of
        "Basics" ->
            basicsIntrinsic name argTypes resultType

        "Bitwise" ->
            bitwiseIntrinsic name argTypes resultType

        "Utils" ->
            utilsIntrinsic name argTypes resultType

        "JsArray" ->
            jsArrayIntrinsic name argTypes resultType

        "List" ->
            listIntrinsic name argTypes resultType

        "Char" ->
            charIntrinsic name argTypes resultType

        "String" ->
            stringIntrinsic name argTypes resultType

        _ ->
            Nothing


basicsIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
basicsIntrinsic name argTypes resultType =
    -- Note: We match primarily on argument types because the result type from
    -- the MonoCall might be a type variable (MVar) when the call is used in a
    -- polymorphic context (e.g., `Debug.log "x" (negate 5)` where the result type
    -- inherits from Debug.log's `a` parameter). For functions where the return type
    -- is the same as the argument type, we use wildcard matching on resultType.
    case ( name, argTypes ) of
        ( "pi", [] ) ->
            if resultType == Mono.MFloat || Ctx.isTypeVar resultType then
                Just (ConstantFloat { value = 3.141592653589793 })

            else
                Nothing

        ( "e", [] ) ->
            if resultType == Mono.MFloat || Ctx.isTypeVar resultType then
                Just (ConstantFloat { value = 2.718281828459045 })

            else
                Nothing

        ( "add", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.add" })

        ( "sub", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.sub" })

        ( "mul", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.mul" })

        ( "idiv", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.div" })

        ( "modBy", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.modby" })

        ( "remainderBy", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.remainderby" })

        ( "negate", [ Mono.MInt ] ) ->
            Just (UnaryInt { op = "eco.int.negate" })

        ( "abs", [ Mono.MInt ] ) ->
            Just (UnaryInt { op = "eco.int.abs" })

        ( "pow", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.pow" })

        ( "add", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.add" })

        ( "sub", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.sub" })

        ( "mul", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.mul" })

        ( "fdiv", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.div" })

        ( "negate", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.negate" })

        ( "abs", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.abs" })

        ( "pow", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.pow" })

        ( "sqrt", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.sqrt" })

        ( "sin", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.sin" })

        ( "cos", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.cos" })

        ( "tan", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.tan" })

        ( "asin", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.asin" })

        ( "acos", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.acos" })

        ( "atan", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.atan" })

        ( "atan2", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.atan2" })

        ( "logBase", [ Mono.MFloat, Mono.MFloat ] ) ->
            Nothing

        ( "log", [ Mono.MFloat ] ) ->
            Just (UnaryFloat { op = "eco.float.log" })

        ( "isNaN", [ Mono.MFloat ] ) ->
            Just (FloatClassify { op = "eco.float.isNaN" })

        ( "isInfinite", [ Mono.MFloat ] ) ->
            Just (FloatClassify { op = "eco.float.isInfinite" })

        ( "toFloat", [ Mono.MInt ] ) ->
            Just IntToFloat

        ( "round", [ Mono.MFloat ] ) ->
            Just (FloatToInt { op = "eco.float.round" })

        ( "floor", [ Mono.MFloat ] ) ->
            Just (FloatToInt { op = "eco.float.floor" })

        ( "ceiling", [ Mono.MFloat ] ) ->
            Just (FloatToInt { op = "eco.float.ceiling" })

        ( "truncate", [ Mono.MFloat ] ) ->
            Just (FloatToInt { op = "eco.float.truncate" })

        ( "min", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.min" })

        ( "max", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.max" })

        ( "min", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.min" })

        ( "max", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (BinaryFloat { op = "eco.float.max" })

        ( "lt", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.lt" })

        ( "le", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.le" })

        ( "gt", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.gt" })

        ( "ge", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.ge" })

        ( "eq", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.eq" })

        ( "neq", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.ne" })

        ( "lt", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.lt" })

        ( "le", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.le" })

        ( "gt", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.gt" })

        ( "ge", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.ge" })

        ( "eq", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.eq" })

        ( "neq", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.ne" })

        -- Boolean operations.
        --
        -- `eco.bool.and` / `eco.bool.or` are strict in both arguments; they are
        -- only reached for first-class references to Basics.and / Basics.or
        -- (e.g. `(&&)` passed as a value). Short-circuit semantics for the
        -- (&&) / (||) operators are implemented earlier in TypedOptimized by
        -- rewriting Binop to If, and do not flow through this path.
        ( "not", [ Mono.MBool ] ) ->
            Just (UnaryBool { op = "eco.bool.not" })

        ( "and", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BinaryBool { op = "eco.bool.and" })

        ( "or", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BinaryBool { op = "eco.bool.or" })

        ( "xor", [ Mono.MBool, Mono.MBool ] ) ->
            Just (BinaryBool { op = "eco.bool.xor" })

        _ ->
            Nothing


bitwiseIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
bitwiseIntrinsic name argTypes _ =
    case ( name, argTypes ) of
        ( "and", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.and" })

        ( "or", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.or" })

        ( "xor", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.xor" })

        ( "complement", [ Mono.MInt ] ) ->
            Just (UnaryInt { op = "eco.int.complement" })

        ( "shiftLeftBy", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.shl" })

        ( "shiftRightBy", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.shr" })

        ( "shiftRightZfBy", [ Mono.MInt, Mono.MInt ] ) ->
            Just (BinaryInt { op = "eco.int.shru" })

        _ ->
            Nothing


utilsIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
utilsIntrinsic name argTypes _ =
    case ( name, argTypes ) of
        -- Int comparisons
        ( "equal", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.eq" })

        ( "notEqual", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.ne" })

        ( "lt", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.lt" })

        ( "le", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.le" })

        ( "gt", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.gt" })

        ( "ge", [ Mono.MInt, Mono.MInt ] ) ->
            Just (IntComparison { op = "eco.int.ge" })

        -- Float comparisons
        ( "equal", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.eq" })

        ( "notEqual", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.ne" })

        ( "lt", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.lt" })

        ( "le", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.le" })

        ( "gt", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.gt" })

        ( "ge", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (FloatComparison { op = "eco.float.ge" })

        -- Char comparisons (i16 unboxed). Equality is signedness-agnostic;
        -- ordering uses unsigned predicates because Char is a Unicode code
        -- point.
        ( "equal", [ Mono.MChar, Mono.MChar ] ) ->
            Just (CharComparison { op = "eco.char.eq" })

        ( "notEqual", [ Mono.MChar, Mono.MChar ] ) ->
            Just (CharComparison { op = "eco.char.ne" })

        ( "lt", [ Mono.MChar, Mono.MChar ] ) ->
            Just (CharComparison { op = "eco.char.lt" })

        ( "le", [ Mono.MChar, Mono.MChar ] ) ->
            Just (CharComparison { op = "eco.char.le" })

        ( "gt", [ Mono.MChar, Mono.MChar ] ) ->
            Just (CharComparison { op = "eco.char.gt" })

        ( "ge", [ Mono.MChar, Mono.MChar ] ) ->
            Just (CharComparison { op = "eco.char.ge" })

        -- Compare-to-Order intrinsics: return one of the three pre-allocated
        -- Order singletons. Boxed-key compares (Strings, lists, tuples,
        -- records, user comparables) keep falling through to the kernel call.
        ( "compare", [ Mono.MInt, Mono.MInt ] ) ->
            Just (CompareToOrder { kind = CompareIntKind })

        ( "compare", [ Mono.MFloat, Mono.MFloat ] ) ->
            Just (CompareToOrder { kind = CompareFloatKind })

        ( "compare", [ Mono.MChar, Mono.MChar ] ) ->
            Just (CompareToOrder { kind = CompareCharKind })

        -- String compares leave the boxed kernel root (Elm_Kernel_Utils_compare)
        -- for a typed op; the remaining boxed-key compares (lists, tuples,
        -- records, user comparables) still fall through to the kernel call.
        ( "compare", [ Mono.MString, Mono.MString ] ) ->
            Just (CompareToOrder { kind = CompareStringKind })

        -- ++ on statically-known String / List (kernel-opt-05). The residue --
        -- ANY MVar operand -- falls through to `_ -> Nothing` below and keeps
        -- emitting eco.call @Elm_Kernel_Utils_append verbatim. The config gate
        -- is applied by Expr.gateIntrinsic, so this module stays config-free.
        ( "append", [ Mono.MString, Mono.MString ] ) ->
            Just AppendString

        ( "append", [ Mono.MList _ _, Mono.MList _ _ ] ) ->
            Just AppendList

        -- Defensive: a mixed String/List pair violates `appendable a => a -> a
        -- -> a`. These arms keep such a pair on the polymorphic kernel, which
        -- still routes by runtime tag, rather than mis-dispatching it.
        ( "append", [ Mono.MString, Mono.MList _ _ ] ) ->
            Nothing

        ( "append", [ Mono.MList _ _, Mono.MString ] ) ->
            Nothing

        _ ->
            Nothing


charIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
charIntrinsic name argTypes _ =
    case ( name, argTypes ) of
        ( "toCode", [ Mono.MChar ] ) ->
            Just CharToInt

        ( "fromCode", [ Mono.MInt ] ) ->
            Just CharFromInt

        _ ->
            Nothing


stringIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
stringIntrinsic name argTypes _ =
    case ( name, argTypes ) of
        ( "fromNumber", [ Mono.MInt ] ) ->
            Just StringFromInt

        ( "fromNumber", [ Mono.MFloat ] ) ->
            Just StringFromFloat

        -- kernel-opt-04. Requires the SATURATED shape: argTypes = [ MString ].
        -- A bare `Elm.Kernel.String.length` reference reaches generateVarKernel
        -- with argTypes = [] (Expr.elm:775) and therefore still falls through to
        -- the papCreate/kernel-decl path -- whitelist discipline, unlisted forms
        -- keep today's behaviour. The `stringLengthOp` config gate is applied by
        -- Expr.gateIntrinsic, so this module stays config-free.
        ( "length", [ Mono.MString ] ) ->
            Just StringLength

        _ ->
            Nothing


arrayElementType : Mono.MonoType -> Maybe Mono.MonoType
arrayElementType ty =
    case ty of
        Mono.MCustom _ _ "Array" [ elt ] ->
            Just elt

        _ ->
            Nothing


jsArrayIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
jsArrayIntrinsic name argTypes resultType =
    case name of
        "empty" ->
            -- JsArray.empty : Array a — element kind is recovered later when
            -- the array is first written. No element-type attribute on the op.
            case argTypes of
                [] ->
                    Just ArrayEmpty

                _ ->
                    Nothing

        "singleton" ->
            -- JsArray.singleton : a -> Array a — element kind from the result
            -- (resultType = MCustom _ "Array" [elt]); robust when the value
            -- arg type is a polymorphic var.
            case ( argTypes, arrayElementType resultType ) of
                ( [ _ ], Just elt ) ->
                    Just (ArraySingleton { elementMlirType = Types.monoTypeToAbi elt })

                _ ->
                    Nothing

        "push" ->
            -- JsArray.push : a -> Array a -> Array a
            case argTypes of
                [ elt, _ ] ->
                    Just (ArrayPush { elementMlirType = Types.monoTypeToAbi elt })

                _ ->
                    Nothing

        "slice" ->
            -- JsArray.slice : Int -> Int -> Array a -> Array a
            case argTypes of
                [ Mono.MInt, Mono.MInt, _ ] ->
                    Just ArraySlice

                _ ->
                    Nothing

        "appendN" ->
            -- JsArray.appendN : Int -> Array a -> Array a -> Array a
            case argTypes of
                [ Mono.MInt, _, _ ] ->
                    Just ArrayAppendN

                _ ->
                    Nothing

        "length" ->
            -- JsArray.length : Array a -> Int
            case resultType of
                Mono.MInt ->
                    Just ArrayLength

                _ ->
                    Nothing

        "unsafeGet" ->
            -- JsArray.unsafeGet : Int -> Array a -> a
            -- argTypes = [ MInt, MCustom _ "Array" [elt] ], resultType = elt
            case argTypes of
                [ Mono.MInt, _ ] ->
                    Just (ArrayGet { elementMlirType = Types.monoTypeToAbi resultType })

                _ ->
                    Nothing

        "unsafeSet" ->
            -- JsArray.unsafeSet : Int -> a -> Array a -> Array a
            -- argTypes = [ MInt, elt, MCustom _ "Array" [elt] ]
            case argTypes of
                [ Mono.MInt, elt, _ ] ->
                    Just (ArraySet { elementMlirType = Types.monoTypeToAbi elt })

                _ ->
                    Nothing

        _ ->
            Nothing


{-| `List.cons` (`::`) -> `eco.construct.list` (kernel-opt-01). The head slot's
2-bit kind is a HEAP layout decision (REP\_BOUNDARY\_002, invariants.csv:24) and must
reproduce the axis `kernelInstanceSymbol` uses for the `_Int`/`_Float`/`_Char` C
variants (Generate/MLIR/KernelAbi.elm:310-317). Anything outside that axis — an
unsettled `CNumber` head, a scalar tail/result (the `kernelDevirtShapeOk` hazard,
MonoSolver/Translate.elm:1869-1892), a non-binary application — DECLINES and keeps
today's kernel call (whitelist discipline).

The `Config`-level flag is applied by `Expr.consIntrinsicFor`, not here: this module
takes no `EcoConfig`, and the SSA-type admissibility test needs Expr's view anyway.

-}
listIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
listIntrinsic name argTypes resultType =
    case ( name, argTypes ) of
        ( "cons", [ headTy, tailTy ] ) ->
            case consHeadAbi headTy of
                Just headMlirType ->
                    if boxedSlot tailTy && boxedSlot resultType then
                        Just (ConstructList { headMlirType = headMlirType })

                    else
                        Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| The head's ABI type, or `Nothing` when the numeric axis is not settled.
`MVar _ CNumber` maps to `i64` under `monoTypeToAbi` (Types.elm:170-172) but does
NOT match the `_Int` suffix arm, so today's site calls the BOXED root symbol with an
i64 head — an unsettled shape this intrinsic must not freeze into a heap layout.
-}
consHeadAbi : Mono.MonoType -> Maybe MlirType
consHeadAbi headTy =
    case headTy of
        Mono.MInt ->
            Just Types.ecoInt

        Mono.MFloat ->
            Just Types.ecoFloat

        Mono.MChar ->
            Just Types.ecoChar

        Mono.MVar _ Mono.CNumber ->
            Nothing

        _ ->
            if Types.isEcoValueType (Types.monoTypeToAbi headTy) then
                Just Types.ecoValue

            else
                Nothing


boxedSlot : Mono.MonoType -> Bool
boxedSlot t =
    Types.isEcoValueType (Types.monoTypeToAbi t)



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
