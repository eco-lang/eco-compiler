module DecodeUnboxedSlotsTest exposing (main)

{-| Collection decoders whose element decoder is not a bare primitive decoder still yield `Int`,
`Float` and `Char` elements that arithmetic and string functions use correctly.

Each line decodes a collection and folds it to one value, so a wrong element shows up as a
wrong sum or string:

  - `list_field_int`, `list_map_int`, `list_oneof_int`: `list` over `field "v" int`, over
    `map (\x -> x * 2) int`, and over a `oneOf` mixing `field "v" int` with `int`.
  - `dict_field_int`: `dict` over `field "v" int`.
  - `pairs_field_float`: `keyValuePairs` over `field "v" float`, summing 1, 2.5 and 40.
  - `pairs_char`: `keyValuePairs` over a decoder that maps every value to the `Char` `'z'`.
  - `list_field_string`: `list` over `field "s" string`, joined with commas.
  - `array_field_int`: `array` over `field "v" int`.

## eco

Exercises the slot representation chosen by `runDecoder` in
elm-kernel-cpp/src/json/JsonExports.cpp (the `DEC_LIST` and `DEC_KEYVALUE` cases). Compiled code
reads a list head or a `keyValuePairs` tuple value of type `Int`, `Float` or `Char` as an
unboxed slot (REP_HEAP_002 in design_docs/invariants.csv), whichever decoder produced it.

The kernel once chose the representation from the element decoder's top constructor, so only a
bare `int` / `float` got an unboxed slot; `field "v" int`, `map f int` or a `Char` from `map`
stayed boxed, and the reader took the box's pointer bits as the number (sums like 3362959422864
for 43). Each line therefore wraps the primitive decoder in a different combinator.

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
