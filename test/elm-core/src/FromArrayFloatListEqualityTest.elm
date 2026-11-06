module FromArrayFloatListEqualityTest exposing (main)

{-| Converting a `List Float` to an `Array` with `Array.fromList` and back with `Array.toList` gives a list equal to the original.

The values are `[1.5, 2.5, 3.5]`. Only the `==` comparison is logged; `FromArrayFloatListRoundtripTest` also logs the list itself.
-}

-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        original = [1.5, 2.5, 3.5]
        roundTrip = Array.toList (Array.fromList original)
        _ = Debug.log "match" (roundTrip == original)
    in
    text "done"
