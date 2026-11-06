module RecordCreateTest exposing (main)

{-| Record literals with `Int` and `String` fields print correctly through `Debug.log`.

`Debug.toString` lists a record's fields by field name, so `record2` prints `age`
before `name` although the literal gives `name` first.
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
