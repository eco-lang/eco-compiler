module Compiler.Generate.MLIR.LogicalTypes exposing
    ( encodeLogicalType
    , addLogicalTypesAttr
    , addLogicalTypesAttrUnknown
    , customMaxFields
    )

{-| Encode a function's logical Elm parameter/result types as
StringAttr entries for the `eco.logical_param_types` /
`eco.logical_result_types` attributes on `func.func` ops (CGEN_065).

The encoding is a small DSL parsed by the C++ cross-spec pass
(`EcoUnboxedAggCrossSpec`) to drive Phase 3 worker/wrapper
specialization.

Encoding (one StringAttr per param/result):

  - `"i64"` / `"f64"` / `"i16"` / `"i1"` — primitive ABI types.
  - `"value"` — `!eco.value` (boxed; not aggregate-eligible). This
    also serves as the "unknown / opaque" entry that satisfies
    CGEN_065's "absent or LUnknown ⇒ non-eligible" clause when an
    explicit encoding can't be computed.
  - `"tuple2:K0:K1"` — 2-tuple. K is single-char element kind:
    `i` = i64, `f` = f64, `c` = i16, `v` = !eco.value.
  - `"tuple3:K0:K1:K2"` — 3-tuple.
  - `"record:N:K0:...:KN-1"` — record with N fields in layout order
    (sorted unboxed-first then alphabetical, matching
    `Types.computeRecordLayout`).
  - `"custom:Tag:N:K0:...:KN-1"` — single-constructor custom ADT
    with N ≤ `customMaxFields` fields. Emitted only when ctor count
    is exactly 1; multi-ctor customs encode as `"value"` so cross-
    spec leaves them boxed (Q3: case-flow conservatism).
  - `"cons:Khead:Ktail"` — list cons cell. Tail is always boxed
    (`v`) since `List a` is recursive; head's element kind comes
    from the list element type. Kept for round-trip / future use
    (Phase 3.1 maps this to `AggKind::None` per Q4).

Absent attribute is interpreted by the C++ pass as "no logical type
info", which conservatively disables cross-spec on that function.
Per CGEN_065, both absent and all-`"value"` shapes are treated as
non-eligible.

@docs encodeLogicalType, addLogicalTypesAttr, addLogicalTypesAttrUnknown, customMaxFields

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.MLIR.Types as Types
import Dict exposing (Dict)
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))


{-| Field-count limit above which a single-constructor custom is
demoted to `"value"`. Mirrors the C++ side's `kCustomMaxFields`
constant in `EcoUnboxedAggCrossSpec`.
-}
customMaxFields : Int
customMaxFields =
    3


{-| Encode a single logical MonoType as a string for the cross-spec DSL.

The `ctorShapes` argument is the per-type constructor table from
`Ctx.Context.typeRegistry.ctorShapes` (`Dict (comparable monoType key)
(List CtorShape)`), used to recognise single-constructor customs.

-}
encodeLogicalType : Dict String (List Mono.CtorShape) -> Mono.MonoType -> String
encodeLogicalType ctorShapes ty =
    case ty of
        Mono.MInt ->
            "i64"

        Mono.MFloat ->
            "f64"

        Mono.MChar ->
            "i16"

        Mono.MTuple [ a, b ] ->
            "tuple2:" ++ kindCharOf a ++ ":" ++ kindCharOf b

        Mono.MTuple [ a, b, c ] ->
            "tuple3:" ++ kindCharOf a ++ ":" ++ kindCharOf b ++ ":" ++ kindCharOf c

        Mono.MRecord fields ->
            let
                layout =
                    Types.computeRecordLayout fields

                fieldKinds =
                    List.map (kindCharOf << .monoType) layout.fields
            in
            "record:"
                ++ String.fromInt layout.fieldCount
                ++ ":"
                ++ String.join ":" fieldKinds

        Mono.MList headType ->
            -- Cons cell: head kind from element type, tail always boxed
            -- (List is self-recursive).
            "cons:" ++ kindCharOf headType ++ ":v"

        Mono.MCustom _ _ _ ->
            encodeCustom ctorShapes ty

        _ ->
            "value"


{-| Try to emit a `"custom:Tag:N:..."` encoding when `ty` is a
single-constructor MCustom with ≤ `customMaxFields` fields.
Otherwise fall back to `"value"`.
-}
encodeCustom : Dict String (List Mono.CtorShape) -> Mono.MonoType -> String
encodeCustom ctorShapes ty =
    let
        key =
            Mono.toComparableMonoType ty
    in
    case Dict.get key ctorShapes of
        Just shapes ->
            case shapes of
                [ singleCtor ] ->
                    let
                        fieldCount =
                            List.length singleCtor.fieldTypes
                    in
                    if fieldCount > 0 && fieldCount <= customMaxFields then
                        let
                            kinds =
                                List.map kindCharOf singleCtor.fieldTypes
                        in
                        "custom:"
                            ++ String.fromInt singleCtor.tag
                            ++ ":"
                            ++ String.fromInt fieldCount
                            ++ ":"
                            ++ String.join ":" kinds

                    else
                        "value"

                _ ->
                    "value"

        Nothing ->
            "value"


{-| Single-character encoding of an aggregate element's primitive kind.
Mirrors the runtime 2-bit-per-slot bitmap (REP_HEAP_002).
-}
kindCharOf : Mono.MonoType -> String
kindCharOf ty =
    case ty of
        Mono.MInt ->
            "i"

        Mono.MFloat ->
            "f"

        Mono.MChar ->
            "c"

        _ ->
            "v"


{-| Post-hoc attribute attacher. Adds `eco.logical_param_types` and
`eco.logical_result_types` to a `func.func` op based on its logical
parameter / result MonoTypes. No-op for non-`func.func` ops.

`ctorShapes` is `ctx.typeRegistry.ctorShapes` and is required for
recognising single-constructor customs. Pass `Dict.empty` if you
only need primitive / tuple / record encodings.

-}
addLogicalTypesAttr : Dict String (List Mono.CtorShape) -> List Mono.MonoType -> Mono.MonoType -> MlirOp -> MlirOp
addLogicalTypesAttr ctorShapes argTypes resultType op =
    if op.name == "func.func" then
        let
            argEntries =
                List.map (StringAttr << encodeLogicalType ctorShapes) argTypes

            resultEntries =
                [ StringAttr (encodeLogicalType ctorShapes resultType) ]
        in
        { op
            | attrs =
                op.attrs
                    |> Dict.insert "eco.logical_param_types"
                        (ArrayAttr Nothing argEntries)
                    |> Dict.insert "eco.logical_result_types"
                        (ArrayAttr Nothing resultEntries)
        }

    else
        op


{-| Attach `eco.logical_param_types` / `eco.logical_result_types` to
a `func.func` op using only the MLIR ABI types — no MonoType
context available. Each entry is derived from the MLIR type alone:
primitive types become `"i64"`/`"f64"`/`"i16"`/`"i1"`, everything
else (notably `!eco.value`) becomes `"value"`.

Used by `func.func` emitters that don't carry Mono types (kernel
decls, extern stubs); guarantees that CGEN_065's "absent or all-
LUnknown ⇒ non-eligible" invariant holds explicitly rather than
implicitly via attribute absence.

-}
addLogicalTypesAttrUnknown : List MlirType -> MlirType -> MlirOp -> MlirOp
addLogicalTypesAttrUnknown argMlirTypes resultMlirType op =
    if op.name == "func.func" then
        let
            argEntries =
                List.map (StringAttr << encodeMlirAbi) argMlirTypes

            resultEntries =
                [ StringAttr (encodeMlirAbi resultMlirType) ]
        in
        { op
            | attrs =
                op.attrs
                    |> Dict.insert "eco.logical_param_types"
                        (ArrayAttr Nothing argEntries)
                    |> Dict.insert "eco.logical_result_types"
                        (ArrayAttr Nothing resultEntries)
        }

    else
        op


{-| MLIR ABI type → logical-type DSL string fallback. Only the four
primitive types map directly; everything else is opaque (`"value"`).
-}
encodeMlirAbi : MlirType -> String
encodeMlirAbi mlirType =
    case mlirType of
        I64 ->
            "i64"

        F64 ->
            "f64"

        I16 ->
            "i16"

        I1 ->
            "i1"

        _ ->
            "value"
