module ArrayUnsafeGetFloatElementTest exposing (main)

{-| `Array.get 0` on an `Array Float` of 1.5 and 2.5 returns `Just 1.5`.
-}

-- CHECK: result: Just 1.5
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        arr =
            Array.fromList [ 1.5, 2.5 ]

        result =
            Array.get 0 arr

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == Just 1.5)
    in
    text "done"
