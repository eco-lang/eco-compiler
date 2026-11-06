module ArrayIndexedMapFloatAddIndexTest exposing (main)

{-| `Array.indexedMap` over an `Array Float` passes each element's index, here added to the
element to turn `[ 10, 20, 30 ]` into `[ 10, 21, 32 ]`.
-}

-- CHECK: result: [10,21,32]
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        arr =
            Array.fromList [ 10.0, 20.0, 30.0 ]

        result =
            Array.toList (Array.indexedMap (\i x -> x + toFloat i) arr)

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == [ 10.0, 21.0, 32.0 ])
    in
    text "done"
