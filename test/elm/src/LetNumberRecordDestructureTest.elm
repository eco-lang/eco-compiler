module LetNumberRecordDestructureTest exposing (main)

{-| Probe: `number` fields bound by a record DESTRUCTURE pattern (`{ lo, hi } = …`)
rather than `.field` access, both used at `Float`. Correct: 30*1.5 + 40*1.5 = 105.
-}

-- CHECK: recdestr: 105

import Html exposing (text)


main =
    let
        { lo, hi } =
            { lo = 30, hi = 40 }

        result =
            round (lo * 1.5) + round (hi * 1.5)

        _ =
            Debug.log "recdestr" result
    in
    text "done"
