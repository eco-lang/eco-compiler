module TuplePairTest exposing (main)

{-| Tuple literals of `Int`, `String` and `Bool` components are built and printed correctly.
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
