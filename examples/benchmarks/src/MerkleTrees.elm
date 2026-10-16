module MerkleTrees exposing (bench, output)

{-| Merkle trees: like binary-trees, but every tree gets a hash computed bottom-up (a leaf's
hash is its value, a node's the sum of its children's) in a separate pass, then checked.
Allocation-heavy: hashing rebuilds each tree with its hashes filled in. Checked in closed form:
every leaf holds 1, so a tree of depth `d` hashes to `2^d`.
-}


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


type alias Report =
    { stretchDepth : Int
    , stretch : Tree
    , maxDepth : Int
    , rows : List { iterations : Int, depth : Int, hashSum : Int }
    , longLived : Tree
    }


{-| Build and hash every tree for maximum depth `n`.
-}
run : Int -> Report
run n =
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

        row d =
            let
                iterations =
                    2 ^ (maxDepth + minDepth - d)
            in
            { iterations = iterations, depth = d, hashSum = hashSum d iterations 0 }

        rows =
            List.range 0 ((stretchDepth - 1 - minDepth) // 2)
                |> List.map (\i -> row (minDepth + 2 * i))
    in
    Report stretchDepth stretch maxDepth rows (calHash longLived)


{-| The benchmark's standard output, for maximum depth `n`.
-}
output : Int -> String
output n =
    let
        r =
            run n

        rowLine x =
            String.fromInt x.iterations
                ++ "\t trees of depth "
                ++ String.fromInt x.depth
                ++ "\t root hash sum: "
                ++ String.fromInt x.hashSum
                ++ "\n"
    in
    ("stretch tree of depth " ++ String.fromInt r.stretchDepth ++ "\t root hash: " ++ String.fromInt (getHash r.stretch) ++ " check: " ++ bool (check r.stretch) ++ "\n")
        ++ String.concat (List.map rowLine r.rows)
        ++ ("long lived tree of depth " ++ String.fromInt n ++ "\t root hash: " ++ String.fromInt (getHash r.longLived) ++ " check: " ++ bool (check r.longLived) ++ "\n")


{-| Every leaf holds 1, so a tree of depth `d` hashes to `2^d`, and every tree must pass `check`.
-}
bench : Int -> Bool
bench n =
    let
        r =
            run n
    in
    getHash r.stretch == 2 ^ r.stretchDepth
        && check r.stretch
        && List.all (\x -> x.hashSum == x.iterations * 2 ^ x.depth) r.rows
        && getHash r.longLived == 2 ^ r.maxDepth
        && check r.longLived
