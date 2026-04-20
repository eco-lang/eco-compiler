module FromArrayCharListEqualityTest exposing (main)

{-| Build `Array Char` via `Array.fromList`, convert back to `List Char` via
    `Array.toList`, and assert equality with the original list.

    `Char` is unboxed as `u16`, so this exercises the same round-trip path
    as the Float equivalent but with a different primitive width.
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
