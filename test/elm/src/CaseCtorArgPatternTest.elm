module CaseCtorArgPatternTest exposing (main)

{-| A single-constructor custom type can be destructured by a pattern in a function parameter, as in `getId (Person id _)`.
-}

-- CHECK: id: 30
-- CHECK: age: 25

import Html exposing (text)


type Person
    = Person Int Int


getId : Person -> Int
getId (Person id _) =
    id


getAge : Person -> Int
getAge (Person _ age) =
    age


main =
    let
        p =
            Person 30 25

        _ =
            Debug.log "id" (getId p)

        _ =
            Debug.log "age" (getAge p)
    in
    text "done"
