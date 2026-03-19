module TypeClassConstraintTest exposing (main)

{-| Test number, comparable, and appendable type-class constraints. -}

-- CHECK: absInt: 5
-- CHECK: absFloat: 3.14
-- CHECK: minInt: 3
-- CHECK: concatStr: "hello world"

import Html exposing (text)


zabs : number -> number
zabs n =
    if n < 0 then
        -n

    else
        n


zmin : comparable -> comparable -> comparable
zmin a b =
    if a < b then
        a

    else
        b


zconcat : appendable -> appendable -> appendable
zconcat a b =
    a ++ b


main =
    let
        _ =
            Debug.log "absInt" (zabs -5)

        _ =
            Debug.log "absFloat" (zabs -3.14)

        _ =
            Debug.log "minInt" (zmin 3 5)

        _ =
            Debug.log "concatStr" (zconcat "hello " "world")
    in
    text "done"
