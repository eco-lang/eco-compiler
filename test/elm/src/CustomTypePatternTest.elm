module CustomTypePatternTest exposing (main)

{-| Functions that take apart a custom-type value with a constructor pattern in
their argument extract the right field.

`getName` and `getAge` each match `Person name age`, ignoring the other field
with `_`; on `Person "Alice" 30` they return `"Alice"` and 30.

-}

-- CHECK: name: "Alice"
-- CHECK: age: 30

import Html exposing (text)


type Person
    = Person String Int


getName (Person name _) = name
getAge (Person _ age) = age


main =
    let
        p = Person "Alice" 30
        _ = Debug.log "name" (getName p)
        _ = Debug.log "age" (getAge p)
    in
    text "done"
