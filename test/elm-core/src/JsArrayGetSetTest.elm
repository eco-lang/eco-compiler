module JsArrayGetSetTest exposing (main)

-- CHECK: get_first: Just 10
-- CHECK: get_last: Just 30
-- CHECK: get_oob: Nothing
-- CHECK: get_neg: Nothing
-- CHECK: set_mid: [10,99,30]
-- CHECK: set_oob: [10,20,30]

import Array
import Html exposing (text)

main =
    let
        arr = Array.fromList [10, 20, 30]
        _ = Debug.log "get_first" (Array.get 0 arr)
        _ = Debug.log "get_last" (Array.get 2 arr)
        _ = Debug.log "get_oob" (Array.get 5 arr)
        _ = Debug.log "get_neg" (Array.get -1 arr)
        _ = Debug.log "set_mid" (Array.toList (Array.set 1 99 arr))
        _ = Debug.log "set_oob" (Array.toList (Array.set 5 99 arr))
    in
    text "done"
