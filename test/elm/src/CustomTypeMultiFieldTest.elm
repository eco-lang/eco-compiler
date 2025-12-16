module CustomTypeMultiFieldTest exposing (main)

{-| Test custom types with multiple fields.
-}

-- CHECK: person

import Html exposing (text)


type Person
    = Person String Int Bool


main =
    let
        p = Person "Alice" 30 True
        _ = Debug.log "person" p
    in
    text "done"
