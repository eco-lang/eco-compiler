module FromArrayCharListEqualityTest exposing (main)

{-| Converting a `List Char` to an `Array` with `Array.fromList` and back with `Array.toList` gives a list equal to the original.

Only the `==` comparison is logged; `FromArrayCharListRoundtripTest` also logs the list itself.
-}

-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        original = ['a', 'b', 'c']
        roundTrip = Array.toList (Array.fromList original)
        _ = Debug.log "match" (roundTrip == original)
    in
    text "done"
