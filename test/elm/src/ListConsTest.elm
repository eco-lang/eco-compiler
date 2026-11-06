module ListConsTest exposing (main)

{-| The cons operator `::` builds one-, two- and three-element lists onto `[]`.
-}

-- CHECK: cons1: [1]
-- CHECK: cons2: [1,2]
-- CHECK: cons3: [1,2,3]

import Html exposing (text)


main =
    let
        _ = Debug.log "cons1" (1 :: [])
        _ = Debug.log "cons2" (1 :: 2 :: [])
        _ = Debug.log "cons3" (1 :: 2 :: 3 :: [])
    in
    text "done"
