module JsArrayBasicsTest exposing (main)

-- CHECK: toList: [1, 2, 3]
-- CHECK: length: 3
-- CHECK: isEmpty_empty: True
-- CHECK: isEmpty_nonempty: False
-- CHECK: empty_toList: []

import Array
import Html exposing (text)

main =
    let
        arr = Array.fromList [1, 2, 3]
        _ = Debug.log "toList" (Array.toList arr)
        _ = Debug.log "length" (Array.length arr)
        _ = Debug.log "isEmpty_empty" (Array.isEmpty Array.empty)
        _ = Debug.log "isEmpty_nonempty" (Array.isEmpty arr)
        _ = Debug.log "empty_toList" (Array.toList (Array.empty))
    in
    text "done"
