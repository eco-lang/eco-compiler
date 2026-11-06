module TruncateToIntTest exposing (main)

{-| `truncate` rounds a `Float` towards zero: 2.7 gives 2 and -2.7 gives -2.
-}

-- CHECK: trunc1: 2
-- CHECK: trunc2: -2

import Html exposing (text)


main =
    let
        _ = Debug.log "trunc1" (truncate 2.7)
        _ = Debug.log "trunc2" (truncate -2.7)
    in
    text "done"
