module TuplePairFuncTest exposing (main)

{-| Test Tuple.pair function.
-}

-- CHECK: pair1: (1,2)
-- CHECK: pair2: ("a","b")

import Html exposing (text)


main =
    let
        _ = Debug.log "pair1" (Tuple.pair 1 2)
        _ = Debug.log "pair2" (Tuple.pair "a" "b")
    in
    text "done"
