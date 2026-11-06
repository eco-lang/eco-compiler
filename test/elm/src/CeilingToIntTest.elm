module CeilingToIntTest exposing (main)

{-| `ceiling` rounds a `Float` up to an `Int`: `ceiling 2.3` is 3 and
`ceiling -2.7` is -2.
-}

-- CHECK: ceil1: 3
-- CHECK: ceil2: -2

import Html exposing (text)


main =
    let
        _ = Debug.log "ceil1" (ceiling 2.3)
        _ = Debug.log "ceil2" (ceiling -2.7)
    in
    text "done"
