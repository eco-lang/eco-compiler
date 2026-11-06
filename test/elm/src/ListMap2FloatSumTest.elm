module ListMap2FloatSumTest exposing (main)

{-| `List.map2 (+)` on two `List Float`s adds the elements pairwise; `[ 1.5, 2.5 ]`
and `[ 10.5, 20.5 ]` give `[12,23]` and the result equals `[ 12.0, 23.0 ]`.

`Debug.log` prints a whole-number Float without a decimal point.

-}

-- CHECK: result: [12,23]
-- CHECK: match: True

import Html exposing (text)


main =
    let
        result =
            List.map2 (+) [ 1.5, 2.5 ] [ 10.5, 20.5 ]

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == [ 12.0, 23.0 ])
    in
    text "done"
