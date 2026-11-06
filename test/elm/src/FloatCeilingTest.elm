module FloatCeilingTest exposing (main)

{-| `ceiling` rounds a `Float` up towards positive infinity, for positive, whole and negative values.

`ceiling -2.3` and `ceiling -2.7` are both -2.
-}

-- CHECK: ceil1: 3
-- CHECK: ceil2: 2
-- CHECK: ceil3: -2
-- CHECK: ceil4: -2

import Html exposing (text)


main =
    let
        _ = Debug.log "ceil1" (ceiling 2.3)
        _ = Debug.log "ceil2" (ceiling 2.0)
        _ = Debug.log "ceil3" (ceiling -2.3)
        _ = Debug.log "ceil4" (ceiling -2.7)
    in
    text "done"
