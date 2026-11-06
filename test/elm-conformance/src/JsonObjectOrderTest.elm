module JsonObjectOrderTest exposing (main)

{-| `Json.Encode` and `Json.Decode` keep an object's keys in JavaScript's order: insertion order,
except that array-index keys come first in ascending numeric order.

An array-index key is a canonical decimal integer from "0" to "4294967294"; "02", "-1", "1.5"
and "4294967295" are ordinary keys. A key added twice keeps its first position and takes its last
value. The tests encode objects built with `Json.Encode.object` (flat, nested, and indented by 4),
encode a `Dict` (whose keys come out in the `Dict`'s own order), decode objects with
`keyValuePairs` and `Json.Decode.dict`, and decode objects as a `Value` and encode them again.

-}

-- CHECK: object: "{\"b\":0,\"a\":1}"
-- CHECK: object many: "{\"zeta\":0,\"alpha\":1,\"mid\":2,\"beta\":3,\"_\":4,\"Z\":5}"
-- CHECK: object duplicate: "{\"b\":2,\"a\":1,\"c\":3}"
-- CHECK: object index keys: "{\"0\":9,\"2\":3,\"10\":1,\"4294967294\":7,\"b\":0,\"a\":2,\"02\":4,\"-1\":5,\"1.5\":6,\"4294967295\":8}"
-- CHECK: object nested: "{\"y\":{\"q\":null,\"p\":[1]},\"x\":true}"
-- CHECK: object indent 4: "{\n    \"b\": 1,\n    \"a\": {\n        \"d\": 2,\n        \"c\": 3\n    }\n}"
-- CHECK: dict: "{\"3\":3,\"a\":2,\"b\":1}"
-- CHECK: round trip: "{\"2\":3,\"b\":1,\"a\":2,\"c\":{\"z\":0,\"y\":1}}"
-- CHECK: round trip duplicate: "{\"b\":3,\"a\":2}"
-- CHECK: keyValuePairs: "[(\"9\",4),(\"10\",3),(\"b\",1),(\"a\",2)]"
-- CHECK: dict decode: "Ok [(\"a\",2),(\"b\",1)]"
-- CHECK: decodeValue object: "{\"b\":1,\"a\":2}"

import ConformanceHelp exposing (logAll, worker)
import Dict
import Json.Decode as D
import Json.Encode as E


{-| Encodes an object with `keys` in that order, each mapped to its position in the list.
-}
encodeKeys : List String -> String
encodeKeys keys =
    E.encode 0 (E.object (List.indexedMap (\i k -> ( k, E.int i )) keys))


{-| Decodes `text` as a `Value` and encodes it again without indentation.
-}
roundTrip : String -> String
roundTrip text =
    case D.decodeString D.value text of
        Ok v ->
            E.encode 0 v

        Err e ->
            D.errorToString e


{-| Decodes `text` with `keyValuePairs` and prints the resulting list.
-}
pairs : String -> String
pairs text =
    case D.decodeString (D.keyValuePairs D.int) text of
        Ok kvs ->
            Debug.toString kvs

        Err e ->
            D.errorToString e


report : ()
report =
    logAll
        [ ( "object", String.concat (List.map encodeKeys [ [ "b", "a" ] ]) )
        , ( "object many", encodeKeys [ "zeta", "alpha", "mid", "beta", "_", "Z" ] )
        , ( "object duplicate", encodeKeys [ "b", "a", "b", "c" ] )
        , ( "object index keys", encodeKeys [ "b", "10", "a", "2", "02", "-1", "1.5", "4294967294", "4294967295", "0" ] )
        , ( "object nested", E.encode 0 (E.object [ ( "y", E.object [ ( "q", E.null ), ( "p", E.list E.int [ 1 ] ) ] ), ( "x", E.bool True ) ]) )
        , ( "object indent 4", E.encode 4 (E.object [ ( "b", E.int 1 ), ( "a", E.object [ ( "d", E.int 2 ), ( "c", E.int 3 ) ] ) ]) )
        , ( "dict", E.encode 0 (E.dict identity E.int (Dict.fromList [ ( "b", 1 ), ( "a", 2 ), ( "3", 3 ) ])) )
        , ( "round trip", roundTrip "{\"b\":1,\"a\":2,\"2\":3,\"c\":{\"z\":0,\"y\":1}}" )
        , ( "round trip duplicate", roundTrip "{\"b\":1,\"a\":2,\"b\":3}" )
        , ( "keyValuePairs", pairs "{\"b\":1,\"a\":2,\"10\":3,\"9\":4}" )
        , ( "dict decode", Debug.toString (Result.map Dict.toList (D.decodeString (D.dict D.int) "{\"b\":1,\"a\":2}")) )
        , ( "decodeValue object", Result.withDefault "err" (Result.map (E.encode 0) (D.decodeValue D.value (E.object [ ( "b", E.int 1 ), ( "a", E.int 2 ) ]))) )
        ]


main : Program () () ()
main =
    worker report
