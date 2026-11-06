module FromArrayCharListMapTest exposing (main)

{-| `List.map Char.toUpper` works on a `List Char` taken out of an `Array` with `Array.toList`.

`['a', 'b']` goes through `Array.fromList` and `Array.toList` and is upper-cased to `['A', 'B']`.
-}

-- CHECK: result: ['A','B']
-- CHECK: match: True

import Array
import Char
import Html exposing (text)


main =
    let
        arr = Array.fromList [ 'a', 'b' ]
        result = List.map Char.toUpper (Array.toList arr)
        _ = Debug.log "result" result
        _ = Debug.log "match" (result == [ 'A', 'B' ])
    in
    text "done"
