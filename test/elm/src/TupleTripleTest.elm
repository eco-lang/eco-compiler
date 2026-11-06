module TupleTripleTest exposing (main)

{-| Checks that 3-tuple literals of `Int`s and of `String`s are built and printed
by `Debug.log` as `(1,2,3)` and `("a","b","c")`.
-}

-- CHECK: triple1: (1,2,3)
-- CHECK: triple2: ("a","b","c")

import Html exposing (text)


main =
    let
        _ = Debug.log "triple1" (1, 2, 3)
        _ = Debug.log "triple2" ("a", "b", "c")
    in
    text "done"
