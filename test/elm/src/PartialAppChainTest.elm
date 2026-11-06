module PartialAppChainTest exposing (main)

{-| Tests a three-argument function partially applied one argument at a time,
`addThree 3`, then `4`, then `3`, against a direct full call.
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
