module RecordCreateTest exposing (main)

{-| Test record creation.
-}

-- CHECK: record1: { x = 1, y = 2 }
-- CHECK: record2: { age = 30, name = "Alice" }

import Html exposing (text)


main =
    let
        _ = Debug.log "record1" { x = 1, y = 2 }
        _ = Debug.log "record2" { name = "Alice", age = 30 }
    in
    text "done"
