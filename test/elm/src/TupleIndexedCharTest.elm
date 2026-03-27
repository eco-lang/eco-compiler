module TupleIndexedCharTest exposing (main)

{-| Test (Int, Char) tuple construction from List.indexedMap,
the exact pattern that triggers the bootstrap Stage 6 failure.

-}

-- CHECK: first: (0, 'H')

import Html exposing (text)


main =
    let
        indexed =
            List.indexedMap Tuple.pair (String.toList "Hello")

        first =
            Maybe.withDefault ( -1, 'x' ) (List.head indexed)

        _ =
            Debug.log "first" first
    in
    text "done"
