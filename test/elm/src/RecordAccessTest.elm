module RecordAccessTest exposing (main)

{-| Test record field access.
-}

-- CHECK: x: 1
-- CHECK: y: 2
-- CHECK: name: "Alice"

import Html exposing (text)


main =
    let
        point = { x = 1, y = 2 }
        person = { name = "Alice", age = 30 }
        _ = Debug.log "x" point.x
        _ = Debug.log "y" point.y
        _ = Debug.log "name" person.name
    in
    text "done"
