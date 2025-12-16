module PartialAppChainTest exposing (main)

{-| Test chained partial application.
-}

-- CHECK: chain1: 10
-- CHECK: chain2: 6

import Html exposing (text)


addThree a b c = a + b + c


main =
    let
        addTo3 = addThree 3
        addTo3And4 = addTo3 4
        _ = Debug.log "chain1" (addTo3And4 3)
        _ = Debug.log "chain2" (addThree 1 2 3)
    in
    text "done"
