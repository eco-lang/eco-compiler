module DecodeUnboxedSlotsTest exposing (main)

{-| Guard (JsonExports.cpp runDecoder, DEC_LIST and DEC_KEYVALUE): a list head or a
`keyValuePairs` tuple value of type Int, Float or Char is stored unboxed, because compiled code
reads it unboxed, whichever decoder produced it. The kernel used to choose the representation
from the element decoder's top constructor, so only a bare `Decode.int` / `Decode.float` got an
unboxed slot; `Decode.field "v" Decode.int`, `Decode.map f Decode.int` or a Char from
`Decode.map` stayed boxed, and the reader got the box's pointer bits as the number (sums like
3362959422864 for 43).

-}

-- CHECK: list_field_int: 43
-- CHECK: list_map_int: 86
-- CHECK: list_oneof_int: 43
-- CHECK: dict_field_int: 43
-- CHECK: pairs_field_float: 43.5
-- CHECK: pairs_char: "zzz"
-- CHECK: list_field_string: "a,b"
-- CHECK: array_field_int: 43

import Array
import Dict
import Html exposing (text)
import Json.Decode as D


objects : String
objects =
    """[{"v":1},{"v":2},{"v":40}]"""


keyed : String
keyed =
    """{"a":{"v":1},"b":{"v":2.5},"c":{"v":40}}"""


main =
    let
        _ =
            Debug.log "list_field_int" (D.decodeString (D.list (D.field "v" D.int)) objects |> Result.map List.sum |> Result.withDefault -1)

        _ =
            Debug.log "list_map_int" (D.decodeString (D.list (D.map (\x -> x * 2) D.int)) "[1,2,40]" |> Result.map List.sum |> Result.withDefault -1)

        _ =
            Debug.log "list_oneof_int" (D.decodeString (D.list (D.oneOf [ D.field "v" D.int, D.int ])) "[{\"v\":1},2,40]" |> Result.map List.sum |> Result.withDefault -1)

        _ =
            Debug.log "dict_field_int" (D.decodeString (D.dict (D.field "v" D.int)) """{"a":{"v":1},"b":{"v":2},"c":{"v":40}}""" |> Result.map (Dict.foldl (\_ v s -> s + v) 0) |> Result.withDefault -1)

        _ =
            Debug.log "pairs_field_float" (D.decodeString (D.keyValuePairs (D.field "v" D.float)) keyed |> Result.map (List.map Tuple.second >> List.sum) |> Result.withDefault -1)

        _ =
            Debug.log "pairs_char" (D.decodeString (D.keyValuePairs (D.map (\_ -> 'z') D.value)) keyed |> Result.map (List.map Tuple.second >> String.fromList) |> Result.withDefault "failed")

        _ =
            Debug.log "list_field_string" (D.decodeString (D.list (D.field "s" D.string)) """[{"s":"a"},{"s":"b"}]""" |> Result.map (String.join ",") |> Result.withDefault "failed")

        _ =
            Debug.log "array_field_int" (D.decodeString (D.array (D.field "v" D.int)) objects |> Result.map (Array.foldl (+) 0) |> Result.withDefault -1)
    in
    text "done"
