module FromArrayFloatListRoundtripTest exposing (main)

{-| Converting `[1.5, 2.5, 3.5]` to an `Array` with `Array.fromList` and back with `Array.toList` gives the same list.

The test logs the reconstructed list as well as the result of comparing it with the original.
-}

-- CHECK: result: [1.5,2.5,3.5]
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        original = [1.5, 2.5, 3.5]
        roundTrip = Array.toList (Array.fromList original)
        _ = Debug.log "result" roundTrip
        _ = Debug.log "match" (roundTrip == original)
    in
    text "done"
