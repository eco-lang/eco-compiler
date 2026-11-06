module LetNumberRecordDestructureTest exposing (main)

{-| Integer-literal record fields bound by a let destructuring pattern are used as
`Float`s: `{ lo, hi } = { lo = 30, hi = 40 }` followed by
`round (lo * 1.5) + round (hi * 1.5)` logs 105.
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
