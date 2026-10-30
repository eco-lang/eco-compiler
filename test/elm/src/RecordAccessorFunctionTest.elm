module RecordAccessorFunctionTest exposing (main)

{-| Test .field as a function.
-}

-- CHECK: names: ["Alice","Bob"]
-- CHECK: xs: [1,4]

import Html exposing (text)


main =
    let
        people = [ { name = "Alice", age = 30 }, { name = "Bob", age = 25 } ]
        points = [ { x = 1, y = 2 }, { x = 4, y = 5 } ]
        _ = Debug.log "names" (List.map .name people)
        _ = Debug.log "xs" (List.map .x points)
    in
    text "done"
