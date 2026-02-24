module StringToListFromListTest exposing (main)

-- CHECK: toList1: ['h', 'e', 'l', 'l', 'o']
-- CHECK: fromList1: "hello"
-- CHECK: roundtrip: "abc"
-- CHECK: empty_toList: []
-- CHECK: empty_fromList: ""

import Html exposing (text)

main =
    let
        _ = Debug.log "toList1" (String.toList "hello")
        _ = Debug.log "fromList1" (String.fromList ['h', 'e', 'l', 'l', 'o'])
        _ = Debug.log "roundtrip" (String.fromList (String.toList "abc"))
        _ = Debug.log "empty_toList" (String.toList "")
        _ = Debug.log "empty_fromList" (String.fromList [])
    in
    text "done"
