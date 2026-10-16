module JsonEncode exposing (bench)

{-| `Json.Encode` output: a generated tree of `n` objects (nested objects and arrays of ints,
plain strings, bools and nulls) encoded with `Encode.encode 0` and `Encode.encode 4`. Text
building and indentation.

Elm defines the encoding as JavaScript's `JSON.stringify`, so both texts' lengths can be computed
from the value alone: the compact text's length from the items it prints, and the indented one's
from the compact one plus, for every non-empty array or object at depth `d`, a newline and
`4 (d + 1)` spaces before each element, a newline and `4 d` spaces before the closing bracket, and
one space after every key's colon. Both lengths must match at every size, and both texts must
decode back to the value, compared with every object's fields sorted by key: eco's native
`Encode.object` writes the fields in key order where Elm (JavaScript) keeps the order given
(`plans/benchmark-suite-expansion.md`, Status), which changes neither length.

-}

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode


type Value
    = VInt Int
    | VString String
    | VBool Bool
    | VNull
    | VList (List Value)
    | VObject (List ( String, Value ))


{-| Object `k`, with nested arrays and objects two levels deep.
-}
item : Int -> Value
item k =
    VObject
        [ ( "id", VInt (k * 7919) )
        , ( "name", VString ("item " ++ String.fromInt k) )
        , ( "active", VBool (modBy 3 k == 0) )
        , ( "parent"
          , if modBy 4 k == 0 then
                VNull

            else
                VInt (k - 1)
          )
        , ( "tags", VList (List.map (\i -> VString ("t" ++ String.fromInt i)) (List.range 0 (modBy 4 k))) )
        , ( "dims", VObject [ ( "w", VInt (modBy 100 k) ), ( "h", VInt (modBy 37 k) ), ( "list", VList (List.map VInt (List.range 0 (modBy 3 k))) ) ] )
        , ( "empty", VList [] )
        ]


encode : Value -> Encode.Value
encode v =
    case v of
        VInt i ->
            Encode.int i

        VString s ->
            Encode.string s

        VBool b ->
            Encode.bool b

        VNull ->
            Encode.null

        VList xs ->
            Encode.list encode xs

        VObject fields ->
            Encode.object (List.map (Tuple.mapSecond encode) fields)


decoder : Decoder Value
decoder =
    Decode.oneOf
        [ Decode.map VInt Decode.int
        , Decode.map VString Decode.string
        , Decode.map VBool Decode.bool
        , Decode.null VNull
        , Decode.map VList (Decode.list (Decode.lazy (\_ -> decoder)))
        , Decode.map VObject (Decode.keyValuePairs (Decode.lazy (\_ -> decoder)))
        ]


{-| Length of the compact text. Strings here never need escapes.
-}
compactLength : Value -> Int
compactLength v =
    let
        commas count =
            max 0 (count - 1)
    in
    case v of
        VInt i ->
            String.length (String.fromInt i)

        VString s ->
            String.length s + 2

        VBool b ->
            if b then
                4

            else
                5

        VNull ->
            4

        VList xs ->
            2 + commas (List.length xs) + List.sum (List.map compactLength xs)

        VObject fields ->
            2 + commas (List.length fields) + List.sum (List.map (\( k, x ) -> String.length k + 3 + compactLength x) fields)


{-| The whitespace `Encode.encode 4` adds for `v` at depth `d`.
-}
indentExtra : Int -> Value -> Int
indentExtra d v =
    let
        container children keys =
            if children == [] then
                0

            else
                List.length children * (1 + 4 * (d + 1)) + (1 + 4 * d) + keys + List.sum (List.map (indentExtra (d + 1)) children)
    in
    case v of
        VList xs ->
            container xs 0

        VObject fields ->
            container (List.map Tuple.second fields) (List.length fields)

        _ ->
            0


{-| Every object's fields sorted by key, all the way down.
-}
normalise : Value -> Value
normalise v =
    case v of
        VList xs ->
            VList (List.map normalise xs)

        VObject fields ->
            VObject (List.sortBy Tuple.first (List.map (Tuple.mapSecond normalise) fields))

        _ ->
            v


bench : Int -> Bool
bench n =
    let
        value =
            VList (List.map item (List.range 1 n))

        compact =
            Encode.encode 0 (encode value)

        indented =
            Encode.encode 4 (encode value)
    in
    String.length compact
        == compactLength value
        && String.length indented
        == compactLength value
        + indentExtra 0 value
        && Result.map normalise (Decode.decodeString decoder compact)
        == Ok (normalise value)
        && Result.map normalise (Decode.decodeString decoder indented)
        == Ok (normalise value)
