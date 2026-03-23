module TailRecDecoderLoopTest exposing (main)

{-| Tail-recursive decoder loop with nested string case inside constructor case.
Mimics Compiler.LocalOpt.Erased.Port.toDecoder: outer case on type constructors,
inner string dispatch for known type names.
-}

-- CHECK: r1: "decode_int"
-- CHECK: r2: "decode_string"
-- CHECK: r3: "decode_list(decode_int)"
-- CHECK: r4: "decode_custom(Foo)"

import Html exposing (text)


type TypeDesc
    = TPrim String
    | TList TypeDesc
    | TAlias TypeDesc
    | TCustom String


toDecoder : TypeDesc -> String
toDecoder tipe =
    case tipe of
        TAlias inner ->
            toDecoder inner

        TPrim name ->
            case name of
                "Int" ->
                    "decode_int"

                "Float" ->
                    "decode_float"

                "Bool" ->
                    "decode_bool"

                "String" ->
                    "decode_string"

                _ ->
                    "decode_unknown"

        TList inner ->
            "decode_list(" ++ toDecoder inner ++ ")"

        TCustom name ->
            "decode_custom(" ++ name ++ ")"


main =
    let
        _ = Debug.log "r1" (toDecoder (TPrim "Int"))
        _ = Debug.log "r2" (toDecoder (TAlias (TPrim "String")))
        _ = Debug.log "r3" (toDecoder (TList (TPrim "Int")))
        _ = Debug.log "r4" (toDecoder (TCustom "Foo"))
    in
    text "done"
