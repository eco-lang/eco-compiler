module ListToArrayFloatRoundtripTest exposing (main)

{-| `List Float → Array Float → List Float` round-trip. Asserts the
    reconstructed list equals the original literal.

    Exercises the unsafe kernel paths through `Array.fromList` and
    `Array.toList` (which internally reach `JsArray.foldr` / `List.toArray`)
    on unboxed `Float` heads.
-}

-- CHECK: result: [1.5, 2.5, 3.5]
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        xs =
            [ 1.5, 2.5, 3.5 ]

        result =
            Array.toList (Array.fromList xs)

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == xs)
    in
    text "done"
