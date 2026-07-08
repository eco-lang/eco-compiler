module StringOpChainSurvivalTest exposing (main)

{-| A chain of String ops over a decoded/created ASCII string must produce the
same values as the same chain over literals — regardless of representation.
This exercises the W4 conservative-widening arms (toUpper/split/join/++/filter/
reverse/repeat/pad) through compiled code. Value-blind (the "stays UTF-8"
property is checked by the C++ representation tests + the W5 counter run).
-}

-- CHECK: Chain.upper: True
-- CHECK: Chain.splitjoin: True
-- CHECK: Chain.mix: True

import Char
import Html exposing (text)


main : Html.Html msg
main =
    let
        base =
            String.fromInt 1234 ++ "-abcDEF-" ++ String.repeat 3 "xy"

        -- base == "1234-abcDEF-xyxyxy"
        upperOk =
            String.toUpper base == "1234-ABCDEF-XYXYXY"

        parts =
            String.split "-" base

        splitJoinOk =
            (parts == [ "1234", "abcDEF", "xyxyxy" ])
                && (String.join "/" parts == "1234/abcDEF/xyxyxy")

        mixOk =
            (String.reverse "abc" == "cba")
                && (String.filter Char.isDigit base == "1234")
                && (String.padLeft 6 '0' "42" == "000042")
                && (String.toLower "ABC" ++ String.fromInt 9 == "abc9")

        _ =
            Debug.log "Chain.upper" upperOk

        _ =
            Debug.log "Chain.splitjoin" splitJoinOk

        _ =
            Debug.log "Chain.mix" mixOk
    in
    text ""
