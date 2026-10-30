module TupleTripleTest exposing (main)

{-| Test triple creation.
-}

-- CHECK: triple1: (1,2,3)
-- CHECK: triple2: ("a","b","c")

import Html exposing (text)


main =
    let
        _ = Debug.log "triple1" (1, 2, 3)
        _ = Debug.log "triple2" ("a", "b", "c")
    in
    text "done"
