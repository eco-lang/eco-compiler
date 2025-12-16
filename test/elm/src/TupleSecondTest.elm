module TupleSecondTest exposing (main)

{-| Test Tuple.second.
-}

-- CHECK: second1: 2
-- CHECK: second2: "world"

import Html exposing (text)


main =
    let
        _ = Debug.log "second1" (Tuple.second (1, 2))
        _ = Debug.log "second2" (Tuple.second ("hello", "world"))
    in
    text "done"
