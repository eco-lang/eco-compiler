module CaseTreeTest exposing (main)

{-| A case expression on a recursive custom type, a binary tree, drives a
recursive function that counts the tree's nodes.

The test counts an empty tree (`Leaf`, 0), a single node (1) and a node with
two children (3).

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
