module TuplePairTest exposing (main)

{-| Test tuple pair creation.
-}

-- CHECK: pair1: (1,2)
-- CHECK: pair2: ("a","b")
-- CHECK: pair3: (True,False)

import Html exposing (text)


main =
    let
        _ = Debug.log "pair1" (1, 2)
        _ = Debug.log "pair2" ("a", "b")
        _ = Debug.log "pair3" (True, False)
    in
    text "done"
