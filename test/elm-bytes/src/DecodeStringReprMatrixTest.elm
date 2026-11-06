module DecodeStringReprMatrixTest exposing (main)

{-| Bytes.Decode.string round-trips ASCII strings of several lengths, and String
operations on a decoded string agree with the same operations on a literal.

  - `ReprMatrix.roundtrip` is `True` when each of `"x"`, `"hello"` and strings of
    31, 32, 33 and 200 repeated characters decodes to a string equal to the
    original.
  - `ReprMatrix.ops` is `True` when a decoded string of 40 `x` characters has
    length 40, has `"xxxxx"` as its first five characters, contains `"xx"`,
    equals a literal-built string of 40 `x` characters, and still equals it
    after `"!"` is appended to both.

-}

-- CHECK: ReprMatrix.roundtrip: True
-- CHECK: ReprMatrix.ops: True

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
        strs =
            [ "x"
            , "hello"
            , String.repeat 31 "a"
            , String.repeat 32 "b"
            , String.repeat 33 "c"
            , String.repeat 200 "d"
            ]

        allRoundTrip =
            List.all (\s -> roundTrip s == s) strs

        decoded =
            roundTrip (String.repeat 40 "x")

        twin =
            String.repeat 40 "x"

        opsOk =
            (String.length decoded == 40)
                && (String.slice 0 5 decoded == "xxxxx")
                && String.contains "xx" decoded
                && (decoded == twin)
                && ((decoded ++ "!") == (twin ++ "!"))

        _ =
            Debug.log "ReprMatrix.roundtrip" allRoundTrip

        _ =
            Debug.log "ReprMatrix.ops" opsOk
    in
    text ""
