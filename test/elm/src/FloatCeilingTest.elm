module FloatCeilingTest exposing (main)

{-| Test ceiling function.
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
