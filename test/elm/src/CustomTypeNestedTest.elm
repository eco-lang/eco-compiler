module CustomTypeNestedTest exposing (main)

{-| Test nested custom types.
-}

-- CHECK: nested

import Html exposing (text)


type Tree a
    = Leaf a
    | Node (Tree a) (Tree a)


main =
    let
        tree = Node (Leaf 1) (Node (Leaf 2) (Leaf 3))
        _ = Debug.log "nested" tree
    in
    text "done"
