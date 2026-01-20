module CaseTreeTest exposing (main)

{-| Test case expression on recursive tree type.
-}

-- CHECK: tree1: 0
-- CHECK: tree2: 1
-- CHECK: tree3: 3

import Html exposing (text)


type Tree
    = Leaf
    | Node Tree Int Tree


countNodes tree =
    case tree of
        Leaf -> 0
        Node left _ right -> 1 + countNodes left + countNodes right


main =
    let
        _ = Debug.log "tree1" (countNodes Leaf)
        _ = Debug.log "tree2" (countNodes (Node Leaf 1 Leaf))
        _ = Debug.log "tree3" (countNodes (Node (Node Leaf 2 Leaf) 1 (Node Leaf 3 Leaf)))
    in
    text "done"
