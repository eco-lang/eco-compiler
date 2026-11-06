module ArrayUnsafeGetCharElementTest exposing (main)

{-| `Array.get 1` on an `Array Char` of `'x'` and `'y'` returns `Just 'y'`.
-}

-- CHECK: result: Just 'y'
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        arr =
            Array.fromList [ 'x', 'y' ]

        result =
            Array.get 1 arr

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == Just 'y')
    in
    text "done"
