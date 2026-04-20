module FromArrayFloatListRoundtripTest exposing (main)

{-| Round-trip identity for `List Float → Array Float → List Float` via
    `Array.fromList` and `Array.toList`. Complements
    `FromArrayFloatListEqualityTest` by also inspecting the reconstructed
    list value directly so a corrupted round-trip is visible in the output.
-}

-- CHECK: result: [1.5, 2.5, 3.5]
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
