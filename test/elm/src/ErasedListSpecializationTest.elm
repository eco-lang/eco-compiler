module ErasedListSpecializationTest exposing (main)

{-| A polymorphic self-recursive `count : List a -> Int` gives the right length when called both on `List Int` values and on `[]`, whose element type nothing constrains.

`count [ 1, 2 ] + count []` is 2 and `count [ 1, 2, 3 ] + count [] + count []` is 3.
-}

-- CHECK: n: 2
-- CHECK: m: 3

import Html exposing (text)


count : List a -> Int
count xs =
    case xs of
        [] ->
            0

        _ :: rest ->
            1 + count rest


main =
    let
        _ =
            Debug.log "n" (count [ 1, 2 ] + count [])

        _ =
            Debug.log "m" (count [ 1, 2, 3 ] + count [] + count [])
    in
    text "done"
