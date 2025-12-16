module CustomTypePatternTest exposing (main)

{-| Test pattern matching on custom types with extraction.
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
