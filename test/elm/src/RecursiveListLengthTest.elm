module RecursiveListLengthTest exposing (main)

{-| Test recursive list traversal.
-}

-- CHECK: len0: 0
-- CHECK: len3: 3
-- CHECK: len5: 5

import Html exposing (text)


myLength list =
    case list of
        [] -> 0
        _ :: rest -> 1 + myLength rest


main =
    let
        _ = Debug.log "len0" (myLength [])
        _ = Debug.log "len3" (myLength [1, 2, 3])
        _ = Debug.log "len5" (myLength [1, 2, 3, 4, 5])
    in
    text "done"
