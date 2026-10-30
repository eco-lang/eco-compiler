module CharSimpleCaseTest exposing (main)

{-| eco's Char and String case mapping (plans/char-simple-case-mapping.md,
design\_docs/char-case-mapping.md): the Unicode simple case mapping (UnicodeData.txt fields
12/13), one code point in and one out, so a Char is always exactly one code point.

  - `Char.toUpper` / `toLower` map through the simple tables; `toLocaleUpper` / `toLocaleLower`
    are the same.
  - `String.toUpper` / `toLower` map every code point the same way, with no Final\_Sigma rule,
    so they equal `String.map Char.toUpper` / `toLower` and never change a String's length.
  - Chars compare and are equal as code points.

Where Elm-on-JS uses full case mapping instead (`'ß'` to `"SS"`), eco differs on purpose; the
recorded Elm behaviour is in test/elm-conformance (CaseMappingDivergenceTest). Inputs are Int code
points mapped through functions, so nothing is folded at compile time. Code points are logged as
upper-case hex.

-}

-- CHECK: up DF: "DF"
-- CHECK: up DF len: "1"
-- CHECK: up FB01: "FB01"
-- CHECK: up 1F80: "1F88"
-- CHECK: up 1FB3: "1FBC"
-- CHECK: up 1FBC: "1FBC"
-- CHECK: lo 130: "69"
-- CHECK: up 130: "130"
-- CHECK: up E9: "C9"
-- CHECK: lo 416: "436"
-- CHECK: up 10428: "10400"
-- CHECK: lo 3A3: "3C3"
-- CHECK: up 17F: "53"
-- CHECK: lo 212A: "6B"
-- CHECK: uplo 1E9E: "DF"
-- CHECK: loc: "DF 49 130 DF 69 69"
-- CHECK: str up: "53 54 52 41 DF 45"
-- CHECK: str lo sigma: "3BF 3B4 3BF 3C3"
-- CHECK: str up fi: "FB01 58"
-- CHECK: str lo istanbul: "69 73 74 61 6E 62 75 6C"
-- CHECK: str up deseret: "10400 58"
-- CHECK: str up deseret len: "3"
-- CHECK: str up lone: "D800 41"
-- CHECK: str ascii: "SI"
-- CHECK: equiv: "True True True True True True True True True True"
-- CHECK: cmp: "GT LT LT"
-- CHECK: eq: "True"
-- CHECK: set: "1"
-- CHECK: show: "27 DF 27"

import Html exposing (text)
import Set


hex : Int -> String
hex n =
    let
        digit d =
            String.slice d (d + 1) "0123456789ABCDEF"

        go k acc =
            if k < 16 then
                digit k ++ acc

            else
                go (k // 16) (digit (modBy 16 k) ++ acc)
    in
    go n ""


cps : String -> String
cps s =
    String.toList s
        |> List.map (\c -> hex (Char.toCode c))
        |> String.join " "


up : Int -> String
up n =
    cps (String.fromChar (Char.toUpper (Char.fromCode n)))


lo : Int -> String
lo n =
    cps (String.fromChar (Char.toLower (Char.fromCode n)))


ord : Order -> String
ord o =
    case o of
        LT ->
            "LT"

        EQ ->
            "EQ"

        GT ->
            "GT"


bool : Bool -> String
bool b =
    if b then
        "True"

    else
        "False"


fromCodes : List Int -> String
fromCodes ns =
    String.fromList (List.map Char.fromCode ns)


equivOk : String -> Bool
equivOk s =
    String.toUpper s == String.map Char.toUpper s && String.toLower s == String.map Char.toLower s


sharpS : Int
sharpS =
    0xDF


rows : List ( String, String )
rows =
    [ ( "up DF", up sharpS )
    , ( "up DF len", String.fromInt (String.length (String.fromChar (Char.toUpper (Char.fromCode sharpS)))) )
    , ( "up FB01", up 0xFB01 )
    , ( "up 1F80", up 0x1F80 )
    , ( "up 1FB3", up 0x1FB3 )
    , ( "up 1FBC", up 0x1FBC )
    , ( "lo 130", lo 0x0130 )
    , ( "up 130", up 0x0130 )
    , ( "up E9", up 0xE9 )
    , ( "lo 416", lo 0x0416 )
    , ( "up 10428", up 0x00010428 )
    , ( "lo 3A3", lo 0x03A3 )
    , ( "up 17F", up 0x017F )
    , ( "lo 212A", lo 0x212A )
    , ( "uplo 1E9E", cps (String.fromChar (Char.toUpper (Char.toLower (Char.fromCode 0x1E9E)))) )
    , ( "loc"
      , String.join " "
            (List.map (\n -> cps (String.fromChar (Char.toLocaleUpper (Char.fromCode n)))) [ sharpS, 0x69, 0x0130 ]
                ++ List.map (\n -> cps (String.fromChar (Char.toLocaleLower (Char.fromCode n)))) [ sharpS, 0x69, 0x0130 ]
            )
      )
    , ( "str up", cps (String.toUpper (fromCodes [ 0x73, 0x74, 0x72, 0x61, sharpS, 0x65 ])) )
    , ( "str lo sigma", cps (String.toLower (fromCodes [ 0x039F, 0x0394, 0x039F, 0x03A3 ])) )
    , ( "str up fi", cps (String.toUpper (fromCodes [ 0xFB01, 0x78 ])) )
    , ( "str lo istanbul", cps (String.toLower (fromCodes [ 0x0130, 0x73, 0x74, 0x61, 0x6E, 0x62, 0x75, 0x6C ])) )
    , ( "str up deseret", cps (String.toUpper (fromCodes [ 0x00010428, 0x78 ])) )
    , ( "str up deseret len", String.fromInt (String.length (String.toUpper (fromCodes [ 0x00010428, 0x78 ]))) )
    , ( "str up lone", cps (String.toUpper (fromCodes [ 0xD800, 0x61 ])) )
    , ( "str ascii", String.toUpper (fromCodes [ 0x017F, 0x0131 ]) )
    , ( "equiv"
      , String.join " "
            (List.map (\s -> bool (equivOk s))
                [ fromCodes [ 0x73, 0x74, 0x72, 0x61, sharpS, 0x65 ]
                , fromCodes [ 0x039F, 0x0394, 0x039F, 0x03A3, 0x20, 0x0391, 0x03A3 ]
                , fromCodes [ 0xFB01, 0x20, 0xFB02, 0x20, 0xFB00 ]
                , fromCodes [ 0x1F80, 0x1FB3, 0x1FF3 ]
                , fromCodes [ 0x0130, 0x0131, 0x69, 0x49 ]
                , fromCodes [ 0x00010428, 0x00010429, 0x78 ]
                , fromCodes [ 0x01C4, 0x01C5, 0x01C6 ]
                , fromCodes [ 0x1E9E, sharpS ]
                , "abc"
                , ""
                ]
            )
      )
    , ( "cmp"
      , String.join " "
            [ ord (compare (Char.toUpper (Char.fromCode sharpS)) (Char.fromCode 0x54))
            , ord (compare (Char.fromCode sharpS) (Char.fromCode 0x1E9E))
            , ord (compare (Char.fromCode 0x61) (Char.fromCode 0x62))
            ]
      )
    , ( "eq", bool (Char.fromCode sharpS == Char.toUpper (Char.fromCode sharpS)) )
    , ( "set", String.fromInt (Set.size (Set.fromList (List.map Char.toUpper (String.toList (fromCodes [ sharpS, sharpS ]))))) )
    , ( "show", cps (Debug.toString (Char.toUpper (Char.fromCode sharpS))) )
    ]


main =
    let
        _ =
            List.foldl (\( label, value ) () -> always () (Debug.log label value)) () rows
    in
    text "done"
