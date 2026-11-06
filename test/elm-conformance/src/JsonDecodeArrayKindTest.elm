module JsonDecodeArrayKindTest exposing (main)

{-| `Json.Decode.array` with an element decoder built by `map` or `field` gives an Array of Ints,
Floats or Chars that later Array operations read correctly.

  - `map int get`, `map int sum`, `map int set`, `map int push`: `[7,8,9]` decoded with
    `D.map identity D.int` supports `Array.get`, `Array.foldl (+)`, `Array.set` and
    `Array.push`.
  - `field int`: `D.field "v" D.int` over an array of objects gives `[1,2]`.
  - `map float` and `map float get`: `D.map (\x -> x * 2) D.float` over `[1.5,2.25]` gives
    `[3,4.5]`.
  - `map char`: `D.map firstChar D.string` over `["ab","c"]` gives the characters `a` and `c`,
    logged by their codes.
  - `plain int`: plain `D.int` gives `[1,2]`, for comparison.

Each result is logged with `Debug.toString`, as a `Maybe` that is `Nothing` if decoding fails.
-}

-- CHECK: map int get: "Just 8"
-- CHECK: map int sum: "Just 24"
-- CHECK: map int set: "Just [70,8,9]"
-- CHECK: map int push: "Just [7,8,9,10]"
-- CHECK: field int: "Just [1,2]"
-- CHECK: map float: "Just [3,4.5]"
-- CHECK: map float get: "Just 3"
-- CHECK: map char: "Just [97,99]"
-- CHECK: plain int: "Just [1,2]"

import Array exposing (Array)
import ConformanceHelp exposing (logAll, worker)
import Json.Decode as D


{-| Decodes `text` as a JSON array of `decoder` elements, or gives `Nothing`.
-}
decode : D.Decoder a -> String -> Maybe (Array a)
decode decoder text =
    Result.toMaybe (D.decodeString (D.array decoder) text)


{-| Returns the first character of `s`, or `'?'` for the empty string.
-}
firstChar : String -> Char
firstChar s =
    Maybe.withDefault '?' (Maybe.map Tuple.first (String.uncons s))


report : ()
report =
    let
        ints =
            decode (D.map identity D.int) "[7,8,9]"

        fields =
            decode (D.field "v" D.int) "[{\"v\":1},{\"v\":2}]"

        floats =
            decode (D.map (\x -> x * 2) D.float) "[1.5,2.25]"

        chars =
            decode (D.map firstChar D.string) "[\"ab\",\"c\"]"
    in
    logAll
        [ ( "map int get", Debug.toString (Maybe.andThen (Array.get 1) ints) )
        , ( "map int sum", Debug.toString (Maybe.map (Array.foldl (+) 0) ints) )
        , ( "map int set", Debug.toString (Maybe.map (Array.toList << Array.set 0 70) ints) )
        , ( "map int push", Debug.toString (Maybe.map (Array.toList << Array.push 10) ints) )
        , ( "field int", Debug.toString (Maybe.map Array.toList fields) )
        , ( "map float", Debug.toString (Maybe.map Array.toList floats) )
        , ( "map float get", Debug.toString (Maybe.andThen (Array.get 0) floats) )
        , ( "map char", Debug.toString (Maybe.map (Array.toList >> List.map Char.toCode) chars) )
        , ( "plain int", Debug.toString (Maybe.map Array.toList (decode D.int "[1,2]")) )
        ]


main : Program () () ()
main =
    worker report
