module DecodeStringNonAsciiTest exposing (main)

{-| W1: non-ASCII payloads must keep the legacy UTF-16 path (the ASCII gate
rejects them), so decoded values and UTF-16 length semantics are unchanged.
The source file itself stays ASCII (chars written as \u escapes).
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

        -- UTF-16 unit counts: café=4, 中=1, 😀=2, "A😀B é"=1+2+1+1=5
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
