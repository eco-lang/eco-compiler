module CustomTypeMultiFieldTest exposing (main)

{-| A value of a custom type whose constructor has three arguments of different
types (`String`, `Int`, `Bool`) can be built and logged.

The only check is that a line starting with `person` is printed; the logged
text itself is not checked.

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
