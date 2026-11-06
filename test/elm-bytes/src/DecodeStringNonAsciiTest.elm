module DecodeStringNonAsciiTest exposing (main)

{-| Bytes.Decode.string round-trips non-ASCII text, and the decoded strings have the
right `String.length`.

Four strings are encoded to UTF-8 and decoded back using the encoded width:
`"café"` (with a 2-byte character), `"中"` (3 bytes), `"😀"` (4 bytes, outside the
Basic Multilingual Plane), and `"A😀Bé"`. The string literals are written
with `\u{...}` escapes.

  - `NonAscii.values` is `True` when every decoded string equals its original.
  - `NonAscii.lengths` is `True` when `String.length` of the decoded strings is
    4, 1, 2 and 5. Elm counts string length in UTF-16 code units, so a
    character outside the Basic Multilingual Plane counts as 2.

-}

-- CHECK: NonAscii.values: True
-- CHECK: NonAscii.lengths: True

import Bytes
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


roundTrip : String -> String
roundTrip s =
    let
        b =
            E.encode (E.string s)
    in
    D.decode (D.string (Bytes.width b)) b
        |> Maybe.withDefault "FAIL"


main : Html.Html msg
main =
    let
        -- é (2-byte), 中 (3-byte), 😀 (astral, surrogate pair), mixed.
        cafe =
            "caf\u{00E9}"

        zhong =
            "\u{4E2D}"

        grin =
            "\u{1F600}"

        mixed =
            "A\u{1F600}B\u{00E9}"

        valuesOk =
            (roundTrip cafe == cafe)
                && (roundTrip zhong == zhong)
                && (roundTrip grin == grin)
                && (roundTrip mixed == mixed)

        -- UTF-16 unit counts: café=4, 中=1, 😀=2, "A😀Bé"=1+2+1+1=5
        lengthsOk =
            (String.length (roundTrip cafe) == 4)
                && (String.length (roundTrip zhong) == 1)
                && (String.length (roundTrip grin) == 2)
                && (String.length (roundTrip mixed) == 5)

        _ =
            Debug.log "NonAscii.values" valuesOk

        _ =
            Debug.log "NonAscii.lengths" lengthsOk
    in
    text ""
