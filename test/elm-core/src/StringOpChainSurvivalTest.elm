module StringOpChainSurvivalTest exposing (main)

{-| Checks that `String` functions give the same results on a string built at run time as they would on the equivalent literal.

The string `base` is assembled from `String.fromInt 1234`, a literal and
`String.repeat 3 "xy"`, giving `"1234-abcDEF-xyxyxy"`. Each logged line is a
`Bool` that is `True` only if every comparison in it holds:

  - `Chain.upper` compares `String.toUpper base` with `"1234-ABCDEF-XYXYXY"`.
  - `Chain.splitjoin` checks that `String.split "-" base` gives the three
    expected pieces and that `String.join "/"` on them gives
    `"1234/abcDEF/xyxyxy"`.
  - `Chain.mix` checks `String.reverse`, `String.filter Char.isDigit` on
    `base`, `String.padLeft` and `String.toLower` followed by `++`; only the
    filter uses `base`, the others use literals.

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
