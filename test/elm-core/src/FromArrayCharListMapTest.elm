module FromArrayCharListMapTest exposing (main)

{-| Array.fromList → Array.toList → List.map Char.toUpper. Verifies that
    Char element codes survive the Array → List conversion intact so that
    `Char.toUpper` receives proper Char values rather than re-boxed Ints.
-}

-- CHECK: result: ['A', 'B']
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
