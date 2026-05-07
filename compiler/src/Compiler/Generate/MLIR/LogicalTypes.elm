module Compiler.Generate.MLIR.LogicalTypes exposing
    ( encodeLogicalType
    , addLogicalTypesAttr
    )

{-| Encode a function's logical Elm parameter/result types as
StringAttr entries for the `eco.logical_param_types` /
`eco.logical_result_types` attributes on `func.func` ops (CGEN_065).

The encoding is a small DSL parsed by the C++ cross-spec pass
(`EcoUnboxedAggCrossSpec`) to drive Phase 3 worker/wrapper
specialization.

Encoding (one StringAttr per param/result):

  - `"i64"` / `"f64"` / `"i16"` / `"i1"` — primitive ABI types.
  - `"value"` — `!eco.value` (boxed; not aggregate-eligible).
  - `"tuple2:K0:K1"` — 2-tuple. K is single-char element kind:
    `i` = i64, `f` = f64, `c` = i16, `v` = !eco.value.
  - `"tuple3:K0:K1:K2"` — 3-tuple.
  - `"record:N:K0:...:KN-1"` — record with N fields in layout order
    (sorted unboxed-first then alphabetical, matching
    `Types.computeRecordLayout`).
  - Custom and List shapes are encoded as `"value"` in v1 (skipped
    by cross-spec); only tuples and records are eligible for Phase 3
    rewriting.

Absent attribute is interpreted by the C++ pass as "no logical type
info", which conservatively disables cross-spec on that function.

@docs encodeLogicalType, addLogicalTypesAttr

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.MLIR.Types as Types
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirType(..))


{-| Encode a single logical MonoType as a string for the cross-spec DSL.
-}
encodeLogicalType : Mono.MonoType -> String
encodeLogicalType ty =
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

        _ ->
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
-}
addLogicalTypesAttr : List Mono.MonoType -> Mono.MonoType -> MlirOp -> MlirOp
addLogicalTypesAttr argTypes resultType op =
    if op.name == "func.func" then
        let
            argEntries =
                List.map (StringAttr << encodeLogicalType) argTypes

            resultEntries =
                [ StringAttr (encodeLogicalType resultType) ]
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
