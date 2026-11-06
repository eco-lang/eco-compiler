module ListToArrayCharRoundtripTest exposing (main)

{-| Converting a `List Char` to an array with `Array.fromList` and back with `Array.toList` gives the original list.

The test prints the round-tripped list and whether it is `==` to the original `['a','b','c']`.

-}

-- CHECK: result: ['a','b','c']
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        xs =
            [ 'a', 'b', 'c' ]

        result =
            Array.toList (Array.fromList xs)

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == xs)
    in
    text "done"
