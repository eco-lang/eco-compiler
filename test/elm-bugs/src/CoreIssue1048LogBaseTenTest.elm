module CoreIssue1048LogBaseTenTest exposing (main)

{-| `logBase 10 1000` is not 3.

<https://github.com/elm/core/issues/1048>

Elm 0.19.1 computes `log 1000 / log 10` = `2.9999999999999996`, so `floor (logBase 10 1000)` is 2.
The result should be exactly 3 (as JavaScript's `Math.log10` gives).

-}

-- CHECK: logBase 10 1000: 3
-- CHECK: floor: 3

import Html exposing (text)


main =
    let
        _ =
            Debug.log "logBase 10 1000" (logBase 10 1000)

        _ =
            Debug.log "floor" (floor (logBase 10 1000))
    in
    text "done"
