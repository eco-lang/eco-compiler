module MerkleTrees exposing (bench, output)

{-| Merkle trees: like binary-trees, but every tree gets a hash computed bottom-up (a leaf's
hash is its value, a node's the sum of its children's) in a separate pass, then checked.
Allocation-heavy: hashing rebuilds each tree with its hashes filled in.
-}

import Output


type Tree
    = Leaf Int (Maybe Int)
    | Node (Maybe Int) Tree Tree


make : Int -> Tree
make d =
    if d > 0 then
        Node Nothing (make (d - 1)) (make (d - 1))

    else
        Leaf 1 Nothing


calHash : Tree -> Tree
calHash tree =
    case tree of
        Leaf value Nothing ->
            Leaf value (Just value)

        Node Nothing left right ->
            let
                l =
                    calHash left

                r =
                    calHash right
            in
            Node (Just (getHash l + getHash r)) l r

        _ ->
            tree


getHash : Tree -> Int
getHash tree =
    case tree of
        Leaf _ hash ->
            Maybe.withDefault -1 hash

        Node hash _ _ ->
            Maybe.withDefault -1 hash


check : Tree -> Bool
check tree =
    case tree of
        Leaf _ (Just _) ->
            True

        Node (Just _) left right ->
            check left && check right

        _ ->
            False


bool : Bool -> String
bool b =
    if b then
        "true"

    else
        "false"


hashSum : Int -> Int -> Int -> Int
hashSum d iterations acc =
    if iterations <= 0 then
        acc

    else
        hashSum d (iterations - 1) (acc + getHash (calHash (make d)))


{-| The benchmark's standard output, for maximum depth `n`.
-}
output : Int -> String
output n =
    let
        minDepth =
            4

        maxDepth =
            max (minDepth + 2) n

        stretchDepth =
            maxDepth + 1

        stretch =
            calHash (make stretchDepth)

        longLived =
            make maxDepth

        depthLine d =
            let
                iterations =
                    2 ^ (maxDepth + minDepth - d)
            in
            String.fromInt iterations
                ++ "\t trees of depth "
                ++ String.fromInt d
                ++ "\t root hash sum: "
                ++ String.fromInt (hashSum d iterations 0)
                ++ "\n"

        depthLines =
            List.range 0 ((stretchDepth - 1 - minDepth) // 2)
                |> List.map (\i -> depthLine (minDepth + 2 * i))
                |> String.concat

        hashedLongLived =
            calHash longLived
    in
    ("stretch tree of depth " ++ String.fromInt stretchDepth ++ "\t root hash: " ++ String.fromInt (getHash stretch) ++ " check: " ++ bool (check stretch) ++ "\n")
        ++ depthLines
        ++ ("long lived tree of depth " ++ String.fromInt n ++ "\t root hash: " ++ String.fromInt (getHash hashedLongLived) ++ " check: " ++ bool (check hashedLongLived) ++ "\n")


bench : Int -> Int
bench n =
    Output.checksum (output n)
