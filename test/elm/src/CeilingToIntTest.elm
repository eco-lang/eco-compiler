module CeilingToIntTest exposing (main)

{-| Test ceiling for Float to Int conversion.
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
