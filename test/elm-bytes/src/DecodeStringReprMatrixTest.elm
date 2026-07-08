module DecodeStringReprMatrixTest exposing (main)

{-| W1: Bytes.Decode.string over ASCII payloads of varying length now yields
UTF-8 forms (leaf < 32 bytes, zero-copy view >= 32). This test is
representation-blind: it asserts round-trip value equality and that String ops
on a decoded (view-backed) string agree with a literal twin.
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

        -- A decoded 40-char string is a zero-copy view; ops must match a twin.
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
