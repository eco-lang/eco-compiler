module ListToArrayFloatRoundtripTest exposing (main)

{-| Converting a `List Float` to an `Array` with `Array.fromList` and back with
`Array.toList` returns a list equal to the original.

The list is `[ 1.5, 2.5, 3.5 ]`. The test logs the round-tripped list and
whether it is `==` to the original.

-}

-- CHECK: result: [1.5,2.5,3.5]
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
