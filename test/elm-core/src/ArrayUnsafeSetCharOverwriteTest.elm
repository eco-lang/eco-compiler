module ArrayUnsafeSetCharOverwriteTest exposing (main)

{-| `Array.set 0 'b'` on a one-element `Array Char` holding `'a'` replaces it, so `Array.get 0`
then returns `Just 'b'`.
-}

-- CHECK: result: Just 'b'
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        arr1 =
            Array.fromList [ 'a' ]

        arr2 =
            Array.set 0 'b' arr1

        result =
            Array.get 0 arr2

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == Just 'b')
    in
    text "done"
