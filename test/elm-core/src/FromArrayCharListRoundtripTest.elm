module FromArrayCharListRoundtripTest exposing (main)

{-| Converting `['a', 'b', 'c']` to an `Array` with `Array.fromList` and back with `Array.toList` gives the same list.

The test logs the reconstructed list as well as the result of comparing it with the original.
-}

-- CHECK: result: ['a','b','c']
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        original = ['a', 'b', 'c']
        roundTrip = Array.toList (Array.fromList original)
        _ = Debug.log "result" roundTrip
        _ = Debug.log "match" (roundTrip == original)
    in
    text "done"
