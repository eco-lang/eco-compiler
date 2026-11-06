module LetDestructRecordTest exposing (main)

{-| Record patterns in `let` bindings: a single field, two fields, a subset of a
record's fields (`{ p, r }` from a record that also has `q`), and a record pattern
nested inside a tuple pattern.
-}

-- CHECK: single: 42
-- CHECK: multi: 3
-- CHECK: partial: 4
-- CHECK: mixed: 3

import Html exposing (text)


main =
    let
        { x } = { x = 42 }
        { a, b } = { a = 1, b = 2 }
        { p, r } = { p = 1, q = 2, r = 3 }
        ({ s }, t) = ({ s = 1 }, 2)
        _ = Debug.log "single" x
        _ = Debug.log "multi" (a + b)
        _ = Debug.log "partial" (p + r)
        _ = Debug.log "mixed" (s + t)
    in
    text "done"
