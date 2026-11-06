module RecordChainedUpdateTest exposing (main)

{-| A record update can set several fields at once, and updates can be chained through let bindings.

`multi` sets `x` and `z` in one update and keeps `y`; `chain` updates `x`, then updates `y`
of that result.
-}

-- CHECK: multi: { x = 100, y = 20, z = 300 }
-- CHECK: chain: { x = 10, y = 20 }

import Html exposing (text)


main =
    let
        r =
            { x = 1, y = 20, z = 3 }

        multi =
            { r | x = 100, z = 300 }

        s =
            { x = 1, y = 2 }

        s2 =
            { s | x = 10 }

        chain =
            { s2 | y = 20 }

        _ =
            Debug.log "multi" multi

        _ =
            Debug.log "chain" chain
    in
    text "done"
