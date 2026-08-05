module Compiler.Generate.MLIR.LogicalTypes exposing
    ( LogicalTypeDesc(..), AggKind(..)
    , addLogicalTypesAttr, addLogicalTypesAttrUnknown
    )

{-| Encode a function's logical Elm parameter/result types as
StringAttr entries for the `eco.logical_param_types` /
`eco.logical_result_types` attributes on `func.func` ops (CGEN\_065).

The encoding pipeline is two-stage:

    MonoType / MlirType  →  LogicalTypeDesc  →  wire-format String

The intermediate `LogicalTypeDesc` ADT carries the structural facts
the cross-spec pass needs (field count for records, ctor tag for
customs, element kinds for aggregates) so the producer side can't
accidentally emit a malformed encoding — every valid `LogicalTypeDesc`
maps to a parseable wire string and vice versa.

Aggregate element types are constrained to a single primitive-kind
character (`i`/`f`/`c`/`v`) by the wire format itself; the `AggKind`
type makes that constraint explicit on the producer side too.

Wire format (one StringAttr per param/result):

  - `"i64"` / `"f64"` / `"i16"` / `"i1"` — primitive ABI types.
  - `"value"` — `!eco.value` (boxed; not aggregate-eligible). Also
    serves as the "unknown / opaque" entry that satisfies CGEN\_065's
    "absent or LUnknown ⇒ non-eligible" clause.
  - `"tuple2:K0:K1"` — 2-tuple. K is single-char element kind.
  - `"tuple3:K0:K1:K2"` — 3-tuple.
  - `"record:N:K0:...:KN-1"` — record with N fields in layout order.
  - `"custom:Tag:N:K0:...:KN-1"` — single-constructor custom with N
    ≤ `customMaxFields` fields. Multi-ctor and oversized customs
    encode as `"value"` so cross-spec leaves them boxed.
  - `"cons:Khead:Ktail"` — list cons cell (tail is always `v`).

@docs LogicalTypeDesc, AggKind
@docs addLogicalTypesAttr, addLogicalTypesAttrUnknown

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.MLIR.Types as Types
import Dict exposing (Dict)
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))


{-| Structural description of one parameter or result's logical type.

Each variant maps 1:1 to a wire-format string but carries the
structural facts in typed form so producers can't accidentally
emit a malformed encoding (e.g. record field count disagreeing
with the kind list).

`LUnknown` is the explicit "logical type unavailable" entry —
distinct from `LValue` (`!eco.value` is a real boxed Elm type)
even though both serialise to `"value"` on the wire. The
distinction matters for diagnostic output and possible future
refinement; cross-spec treats them identically for now.

-}
type LogicalTypeDesc
    = LValue
    | LI64
    | LF64
    | LI16
    | LI1
    | LTuple2 AggKind AggKind
    | LTuple3 AggKind AggKind AggKind
    | LRecord (List AggKind)
    | LCustom { tag : Int, fields : List AggKind }
    | LCons AggKind AggKind
    | LUnknown


{-| Aggregate element kind. Single-character on the wire
(REP\_HEAP\_002): `i`/`f`/`c`/`v` for i64/f64/i16/!eco.value.
-}
type AggKind
    = AKInt
    | AKFloat
    | AKChar
    | AKValue


{-| Compute the logical description of a MonoType, consulting the
ctor registry to recognise single-constructor customs.
-}
monoTypeToLogical : Int -> Mono.LayoutMap (List Mono.CtorShape) -> Mono.MonoType -> LogicalTypeDesc
monoTypeToLogical customMaxFields ctorShapes ty =
    case ty of
        Mono.MInt ->
            LI64

        Mono.MFloat ->
            LF64

        Mono.MChar ->
            LI16

        Mono.MTuple _ [ a, b ] ->
            LTuple2 (kindOf a) (kindOf b)

        Mono.MTuple _ [ a, b, c ] ->
            LTuple3 (kindOf a) (kindOf b) (kindOf c)

        Mono.MRecord _ fields ->
            let
                layout =
                    Types.computeRecordLayout fields
            in
            LRecord (List.map (kindOf << .monoType) layout.fields)

        Mono.MList _ headType ->
            -- Tail is recursive (List a), always boxed at the wire level.
            LCons (kindOf headType) AKValue

        Mono.MCustom _ _ _ _ ->
            customDescFor customMaxFields ctorShapes ty

        _ ->
            LValue


{-| Try to build an `LCustom` for a single-constructor Mono.mCustom with
≤ `customMaxFields` fields; fall back to `LValue` otherwise.
-}
customDescFor : Int -> Mono.LayoutMap (List Mono.CtorShape) -> Mono.MonoType -> LogicalTypeDesc
customDescFor customMaxFields ctorShapes ty =
    case Mono.layoutMapGet ty ctorShapes of
        Just [ singleCtor ] ->
            let
                fieldCount =
                    List.length singleCtor.fieldTypes
            in
            if fieldCount > 0 && fieldCount <= customMaxFields then
                LCustom
                    { tag = singleCtor.tag
                    , fields = List.map kindOf singleCtor.fieldTypes
                    }

            else
                LValue

        _ ->
            LValue


{-| Project a MonoType down to its aggregate-element kind. Non-
primitive types (including nested aggregates) collapse to `AKValue`,
matching the wire format's single-character element encoding.
-}
kindOf : Mono.MonoType -> AggKind
kindOf ty =
    case ty of
        Mono.MInt ->
            AKInt

        Mono.MFloat ->
            AKFloat

        Mono.MChar ->
            AKChar

        _ ->
            AKValue


{-| Derive a logical description from an MLIR ABI type alone (no
MonoType context). Used by `func.func` emitters that don't carry
MonoTypes — kernel decls in particular. Only the four primitive
ABI types map directly; everything else is `LUnknown`.
-}
mlirTypeToLogical : MlirType -> LogicalTypeDesc
mlirTypeToLogical mlirType =
    case mlirType of
        I64 ->
            LI64

        F64 ->
            LF64

        I16 ->
            LI16

        I1 ->
            LI1

        _ ->
            LUnknown


{-| Render a logical description as its wire-format string.

Total over the `LogicalTypeDesc` constructor space; producers can
never emit a malformed encoding by construction.

-}
encodeLogicalType : LogicalTypeDesc -> String
encodeLogicalType desc =
    case desc of
        LValue ->
            "value"

        LI64 ->
            "i64"

        LF64 ->
            "f64"

        LI16 ->
            "i16"

        LI1 ->
            "i1"

        LTuple2 a b ->
            "tuple2:" ++ kindChar a ++ ":" ++ kindChar b

        LTuple3 a b c ->
            "tuple3:" ++ kindChar a ++ ":" ++ kindChar b ++ ":" ++ kindChar c

        LRecord fields ->
            "record:"
                ++ String.fromInt (List.length fields)
                ++ String.concat (List.map (\k -> ":" ++ kindChar k) fields)

        LCustom { tag, fields } ->
            "custom:"
                ++ String.fromInt tag
                ++ ":"
                ++ String.fromInt (List.length fields)
                ++ String.concat (List.map (\k -> ":" ++ kindChar k) fields)

        LCons h t ->
            "cons:" ++ kindChar h ++ ":" ++ kindChar t

        LUnknown ->
            -- LUnknown wire-encodes identically to LValue but stays
            -- distinct in the ADT for diagnostic / future use.
            "value"


{-| Single-character encoding of an aggregate element's primitive kind.
-}
kindChar : AggKind -> String
kindChar k =
    case k of
        AKInt ->
            "i"

        AKFloat ->
            "f"

        AKChar ->
            "c"

        AKValue ->
            "v"


{-| Post-hoc attribute attacher. Adds `eco.logical_param_types` and
`eco.logical_result_types` to a `func.func` op based on its logical
parameter / result MonoTypes. No-op for non-`func.func` ops.

`ctorShapes` comes from `ctx.typeRegistry.ctorShapes` and is needed
for recognising single-constructor customs.

-}
addLogicalTypesAttr : Int -> Mono.LayoutMap (List Mono.CtorShape) -> List Mono.MonoType -> Mono.MonoType -> MlirOp -> MlirOp
addLogicalTypesAttr customMaxFields ctorShapes argTypes resultType op =
    addLogicalDescsAttr
        (List.map (monoTypeToLogical customMaxFields ctorShapes) argTypes)
        (monoTypeToLogical customMaxFields ctorShapes resultType)
        op


{-| Attach `eco.logical_param_types` / `eco.logical_result_types`
using only MLIR ABI types — no MonoType context. Aggregate slots
all become `LUnknown` since the ABI type alone can't recover the
aggregate's shape; cross-spec then conservatively skips the function
(CGEN\_065).
-}
addLogicalTypesAttrUnknown : List MlirType -> MlirType -> MlirOp -> MlirOp
addLogicalTypesAttrUnknown argMlirTypes resultMlirType op =
    addLogicalDescsAttr
        (List.map mlirTypeToLogical argMlirTypes)
        (mlirTypeToLogical resultMlirType)
        op


{-| Shared attribute-attachment core. Both `addLogicalTypesAttr` and
`addLogicalTypesAttrUnknown` funnel through here after converting
their inputs to `LogicalTypeDesc`s.
-}
addLogicalDescsAttr : List LogicalTypeDesc -> LogicalTypeDesc -> MlirOp -> MlirOp
addLogicalDescsAttr argDescs resultDesc op =
    if op.name == "func.func" then
        let
            argEntries =
                List.map (StringAttr << encodeLogicalType) argDescs

            resultEntries =
                [ StringAttr (encodeLogicalType resultDesc) ]
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
