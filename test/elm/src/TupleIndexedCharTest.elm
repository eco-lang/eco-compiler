module TupleIndexedCharTest exposing (main)

{-| `List.indexedMap Tuple.pair` over the characters of `"Hello"` builds `( Int, Char )` pairs, and the first one is `(0,'H')`.
-}

-- CHECK: first: (0,'H')

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
