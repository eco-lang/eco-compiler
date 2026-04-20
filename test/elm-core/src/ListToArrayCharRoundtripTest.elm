module ListToArrayCharRoundtripTest exposing (main)

{-| `List Char → Array Char → List Char` round-trip. Asserts the
    reconstructed list equals the original literal.

    Exercises the unsafe kernel paths with unboxed `Char` (u16) heads.
-}

-- CHECK: result: ['a', 'b', 'c']
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        xs =
            [ 'a', 'b', 'c' ]

        result =
            Array.toList (Array.fromList xs)

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == xs)
    in
    text "done"
