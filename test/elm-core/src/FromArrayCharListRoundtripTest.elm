module FromArrayCharListRoundtripTest exposing (main)

{-| Round-trip identity for `List Char → Array Char → List Char`. Complements
    the equality variant by inspecting the reconstructed list directly.
-}

-- CHECK: result: ['a', 'b', 'c']
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
