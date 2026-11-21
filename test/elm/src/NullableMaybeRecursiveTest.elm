module NullableMaybeRecursiveTest exposing (main)

{-| Recursive types through `Maybe`: a linked `Chain`, a `Node (Maybe Node)` and a
tree with `Maybe` children.

Expected output from elm make + node.

-}

-- CHECK: chain: (Chain "a" (Just (Chain "" (Just (Chain "c" Nothing)))),["a","","c"])
-- CHECK: node: (Node (Just (Node (Just (Node Nothing)))),2)
-- CHECK: tree: (Branch (Just (Branch Nothing "" (Just Leaf))) "m" Nothing,["","m"])

import Html exposing (text)


type Chain
    = Chain String (Maybe Chain)


type Node
    = Node (Maybe Node)


type Tree
    = Leaf
    | Branch (Maybe Tree) String (Maybe Tree)


depth : Node -> Int
depth (Node m) =
    case m of
        Nothing ->
            0

        Just n ->
            1 + depth n


walk : Chain -> List String
walk (Chain s next) =
    s :: (Maybe.map walk next |> Maybe.withDefault [])


flatten : Tree -> List String
flatten t =
    case t of
        Leaf ->
            []

        Branch l s r ->
            (Maybe.map flatten l |> Maybe.withDefault []) ++ [ s ] ++ (Maybe.map flatten r |> Maybe.withDefault [])


main =
    let
        chain =
            Chain "a" (Just (Chain "" (Just (Chain "c" Nothing))))

        node =
            Node (Just (Node (Just (Node Nothing))))

        tree =
            Branch (Just (Branch Nothing "" (Just Leaf))) "m" Nothing

        _ =
            Debug.log "chain" ( chain, walk chain )

        _ =
            Debug.log "node" ( node, depth node )

        _ =
            Debug.log "tree" ( tree, flatten tree )
    in
    text ""
