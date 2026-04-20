module FromArrayFloatListEqualityTest exposing (main)

{-| Build `Array Float` via `Array.fromList`, convert back to `List Float`
    via `Array.toList` (the user-facing equivalent of the internal
    `List.fromArray` kernel), and assert equality with the original list.

    Exercises the round-trip path through `Elm_Kernel_JsArray_foldr` (used
    internally by `Array.toList`) on unboxed `Float` leaf slots.
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
