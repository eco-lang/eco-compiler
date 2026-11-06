module TupleFirstTest exposing (main)

{-| `Tuple.first` returns the first component of an `Int` pair and of a `String` pair.
-}

-- CHECK: first1: 1
-- CHECK: first2: "hello"

import Html exposing (text)


main =
    let
        _ = Debug.log "first1" (Tuple.first (1, 2))
        _ = Debug.log "first2" (Tuple.first ("hello", "world"))
    in
    text "done"
