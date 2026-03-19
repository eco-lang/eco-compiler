module RecursiveMutualTypeTest exposing (main)

{-| Test mutually recursive types (Forest/RoseTree). -}

-- CHECK: nodes: 4

import Html exposing (text)


type Forest a
    = Forest (List (RoseTree a))


type RoseTree a
    = RoseNode a (Forest a)


countNodes : RoseTree a -> Int
countNodes (RoseNode _ (Forest children)) =
    1 + List.foldl (\child acc -> acc + countNodes child) 0 children


main =
    let
        tree = RoseNode 1 (Forest
            [ RoseNode 2 (Forest [])
            , RoseNode 3 (Forest [ RoseNode 4 (Forest []) ])
            ])
        _ = Debug.log "nodes" (countNodes tree)
    in
    text "done"
