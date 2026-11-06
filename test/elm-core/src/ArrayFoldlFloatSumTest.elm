module ArrayFoldlFloatSumTest exposing (main)

{-| `Array.foldl (+) 0.0` sums an `Array Float` of 1.5, 2.5 and 3.0 to exactly 7.0.

The sum is logged as `7`, and compared with `7.0` to check it is the exact value.

-}

-- CHECK: result: 7
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        result =
            Array.foldl (+) 0.0 (Array.fromList [ 1.5, 2.5, 3.0 ])

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == 7.0)
    in
    text "done"
