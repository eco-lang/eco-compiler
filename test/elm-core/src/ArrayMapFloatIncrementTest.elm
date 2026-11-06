module ArrayMapFloatIncrementTest exposing (main)

{-| `Array.map ((+) 0.5)` over an `Array Float` of 1.5 and 2.5 gives exactly 2.0 and 3.0.
-}

-- CHECK: result: [2,3]
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        arr =
            Array.fromList [ 1.5, 2.5 ]

        result =
            Array.toList (Array.map ((+) 0.5) arr)

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == [ 2.0, 3.0 ])
    in
    text "done"
