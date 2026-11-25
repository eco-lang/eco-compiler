module HashCons exposing (benchHashConsHashed, benchHashConsPlain, benchStructKeysHashed, benchStructKeysPlain, benchTraverseHashed, benchTraversePlain)

{-| eco/system's `Hash.Hashed` against plain keys (plans/hashed-values-and-hash-consing.md H8).

  - `benchHashConsPlain` (hashcons-plain) hash-conses `size` type terms twice over through a
    `SeqDict PTy PTy` table, interning every node bottom-up with `SeqDict.lookup`: each lookup
    hashes the node's whole subtree (definition v5 reads all of it) and a hit compares it with `==`.
  - `benchHashConsHashed` (hashcons-hashed) does the same with `Hashed` children and
    `HashedSet.intern`: each node hashes in O(fields) from its children's stored hashes, and a hit
    compares canonical children by pointer.
  - `benchStructKeysPlain` (seqdict-structkeys) inserts `size` keys `( List Int, String )` (50-element
    lists) into a `SeqDict` and looks each up 20 times: every lookup hashes the 50-element list.
  - `benchStructKeysHashed` (hasheddict-structkeys) does the same with a `HashedDict`, the keys made
    `Hashed` once and every lookup probing with those same objects ("hash once, reuse the key"): no
    lookup walks a key, and a hit compares the probe with the stored key by pointer.
  - `benchTraversePlain` (traverse-plain) builds a balanced binary tree of 2^14 leaves once and sums
    its leaves `size` times over.
  - `benchTraverseHashed` (traverse-hashed) does the same with `Hashed` children, reaching each child
    through `Hash.value`: the cost of traversing a hash-consed structure. The timed part hashes
    nothing, so building it with `ECO_HASH_INTRINSIC=0` changes only `Hash.value` (a kernel call
    instead of an inline load, plans/hashed-values-and-hash-consing.md F4).

Checked: a second hash-consing pass leaves the table's size unchanged and gives equal results; the
lookups find every key, their values summing to 20 times the triangle number; each traversal sums the
leaves to the triangle number of 2^14 - 1.

-}

import Hash exposing (Hashed, hashed, value)
import HashedDict
import HashedSet exposing (HashedSet)
import SeqDict exposing (SeqDict)


type PTy
    = PInt
    | PBool
    | PList PTy
    | PFun PTy PTy


type HTy
    = HInt
    | HBool
    | HList (Hashed HTy)
    | HFun (Hashed HTy) (Hashed HTy)


internPlain : PTy -> SeqDict PTy PTy -> ( PTy, SeqDict PTy PTy )
internPlain ty table =
    case SeqDict.lookup ty table of
        Just ( stored, _ ) ->
            ( stored, table )

        Nothing ->
            ( ty, SeqDict.insert ty ty table )


{-| The `i`-th term, interned bottom-up: a small expression over earlier choices, deterministic in `i`.
-}
buildPlain : Int -> SeqDict PTy PTy -> ( PTy, SeqDict PTy PTy )
buildPlain i table =
    case modBy 4 i of
        0 ->
            internPlain PInt table

        1 ->
            internPlain PBool table

        2 ->
            let
                ( e, t1 ) =
                    buildPlain (i // 3) table
            in
            internPlain (PList e) t1

        _ ->
            let
                ( a, t1 ) =
                    buildPlain (i // 2) table

                ( b, t2 ) =
                    buildPlain (i // 5) t1
            in
            internPlain (PFun a b) t2


buildHashed : Int -> HashedSet HTy -> ( Hashed HTy, HashedSet HTy )
buildHashed i table =
    case modBy 4 i of
        0 ->
            HashedSet.intern (hashed HInt) table

        1 ->
            HashedSet.intern (hashed HBool) table

        2 ->
            let
                ( e, t1 ) =
                    buildHashed (i // 3) table
            in
            HashedSet.intern (hashed (HList e)) t1

        _ ->
            let
                ( a, t1 ) =
                    buildHashed (i // 2) table

                ( b, t2 ) =
                    buildHashed (i // 5) t1
            in
            HashedSet.intern (hashed (HFun a b)) t2


passPlain : Int -> SeqDict PTy PTy -> ( List PTy, SeqDict PTy PTy )
passPlain n table =
    List.foldl
        (\i ( acc, t ) ->
            let
                ( ty, t1 ) =
                    buildPlain i t
            in
            ( ty :: acc, t1 )
        )
        ( [], table )
        (List.range 1 n)


passHashed : Int -> HashedSet HTy -> ( List (Hashed HTy), HashedSet HTy )
passHashed n table =
    List.foldl
        (\i ( acc, t ) ->
            let
                ( ty, t1 ) =
                    buildHashed i t
            in
            ( ty :: acc, t1 )
        )
        ( [], table )
        (List.range 1 n)


benchHashConsPlain : Int -> Bool
benchHashConsPlain size =
    let
        ( first, t1 ) =
            passPlain size SeqDict.empty

        ( second, t2 ) =
            passPlain size t1
    in
    SeqDict.size t1 == SeqDict.size t2 && SeqDict.size t1 > 0 && first == second


benchHashConsHashed : Int -> Bool
benchHashConsHashed size =
    let
        ( first, t1 ) =
            passHashed size HashedSet.empty

        ( second, t2 ) =
            passHashed size t1
    in
    HashedSet.size t1 == HashedSet.size t2 && HashedSet.size t1 > 0 && first == second


structKey : Int -> ( List Int, String )
structKey i =
    ( List.range i (i + 49), "k" ++ String.fromInt (modBy 97 i) )


lookupRounds : Int
lookupRounds =
    20


triangle : Int -> Int
triangle n =
    n * (n + 1) // 2


benchStructKeysPlain : Int -> Bool
benchStructKeysPlain size =
    let
        keys =
            List.map structKey (List.range 1 size)

        dict =
            List.foldl (\( k, i ) d -> SeqDict.insert k i d) SeqDict.empty (List.map2 Tuple.pair keys (List.range 1 size))

        total =
            List.foldl
                (\_ acc -> List.foldl (\k a -> a + Maybe.withDefault 0 (SeqDict.get k dict)) acc keys)
                0
                (List.range 1 lookupRounds)
    in
    total == lookupRounds * triangle size


benchStructKeysHashed : Int -> Bool
benchStructKeysHashed size =
    let
        keys =
            List.map (structKey >> hashed) (List.range 1 size)

        dict =
            List.foldl (\( k, i ) d -> HashedDict.insert k i d) HashedDict.empty (List.map2 Tuple.pair keys (List.range 1 size))

        total =
            List.foldl
                (\_ acc -> List.foldl (\k a -> a + Maybe.withDefault 0 (HashedDict.get k dict)) acc keys)
                0
                (List.range 1 lookupRounds)
    in
    total == lookupRounds * triangle size


type PTree
    = PLeaf Int
    | PNode PTree PTree


type HTree
    = HLeaf Int
    | HNode (Hashed HTree) (Hashed HTree)


{-| The depth of the traversed trees: 2^14 leaves, numbered from 0.
-}
treeDepth : Int
treeDepth =
    14


buildPlainTree : Int -> Int -> PTree
buildPlainTree depth first =
    if depth == 0 then
        PLeaf first

    else
        PNode (buildPlainTree (depth - 1) first) (buildPlainTree (depth - 1) (first + 2 ^ (depth - 1)))


buildHashedTree : Int -> Int -> HTree
buildHashedTree depth first =
    if depth == 0 then
        HLeaf first

    else
        HNode (hashed (buildHashedTree (depth - 1) first)) (hashed (buildHashedTree (depth - 1) (first + 2 ^ (depth - 1))))


sumPlain : PTree -> Int
sumPlain tree =
    case tree of
        PLeaf n ->
            n

        PNode l r ->
            sumPlain l + sumPlain r


sumHashed : HTree -> Int
sumHashed tree =
    case tree of
        HLeaf n ->
            n

        HNode l r ->
            sumHashed (value l) + sumHashed (value r)


benchTraversePlain : Int -> Bool
benchTraversePlain size =
    let
        tree =
            buildPlainTree treeDepth 0
    in
    List.all (\_ -> sumPlain tree == triangle (2 ^ treeDepth - 1)) (List.range 1 size)


benchTraverseHashed : Int -> Bool
benchTraverseHashed size =
    let
        tree =
            buildHashedTree treeDepth 0
    in
    List.all (\_ -> sumHashed tree == triangle (2 ^ treeDepth - 1)) (List.range 1 size)
