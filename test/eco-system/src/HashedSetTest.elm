module HashedSetTest exposing (main)

{-| `HashedSet` (plans/hashed-values-and-hash-consing.md H6): `find` and `intern` hand back the stored
element, `intern` inserts a missing one, and the rest of the API behaves as `SeqSet` on the unwrapped
elements. A 10,000-node tree interned twice gives one element.

-}

-- CHECK: intern: [True,True,True,True]
-- CHECK: find: [True,True]
-- CHECK: api: [True,True,True,True,True,True,True]
-- CHECK: tree: [True,True]

import Hash exposing (Hashed, hashed, value)
import HashedSet exposing (HashedSet)
import SeqSet
import System
import Task


type Tree
    = Leaf Int
    | Node Tree Tree


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


tree : Int -> Int -> Tree
tree lo hi =
    if lo >= hi then
        Leaf lo

    else
        let
            mid =
                (lo + hi) // 2
        in
        Node (tree lo mid) (tree (mid + 1) hi)


elems : HashedSet a -> List a
elems s =
    List.map value (HashedSet.toList s)


report : () -> ()
report () =
    let
        xs =
            List.range 1 30

        set =
            HashedSet.fromList (List.map hashed xs)

        plain =
            SeqSet.fromList xs

        other =
            HashedSet.fromList (List.map hashed (List.range 20 50))

        plainOther =
            SeqSet.fromList (List.range 20 50)

        ( first, set1 ) =
            HashedSet.intern (hashed [ 1, 2, 3 ]) HashedSet.empty

        ( second, set2 ) =
            HashedSet.intern (hashed (List.range 1 3)) set1

        ( third, set3 ) =
            HashedSet.intern (hashed [ 4 ]) set2

        _ =
            Debug.log "intern"
                [ first == second && HashedSet.size set2 == 1
                , value second == [ 1, 2, 3 ]
                , value third == [ 4 ] && HashedSet.size set3 == 2
                , HashedSet.member (hashed [ 4 ]) set3
                ]

        _ =
            Debug.log "find"
                [ Maybe.map value (HashedSet.find (hashed (List.range 1 3)) set3) == Just [ 1, 2, 3 ]
                , HashedSet.find (hashed [ 9 ]) set3 == Nothing
                ]

        _ =
            Debug.log "api"
                [ elems set == SeqSet.toList plain
                , elems (HashedSet.insert (hashed 99) set) == SeqSet.toList (SeqSet.insert 99 plain)
                , elems (HashedSet.remove (hashed 5) set) == SeqSet.toList (SeqSet.remove 5 plain)
                , elems (HashedSet.union set other) == SeqSet.toList (SeqSet.union plain plainOther)
                    && elems (HashedSet.intersect set other) == SeqSet.toList (SeqSet.intersect plain plainOther)
                    && elems (HashedSet.diff set other) == SeqSet.toList (SeqSet.diff plain plainOther)
                , elems (HashedSet.map (\h -> hashed (modBy 5 (value h))) set) == SeqSet.toList (SeqSet.map (modBy 5) plain)
                , HashedSet.foldl (\h acc -> value h :: acc) [] set == SeqSet.foldl (::) [] plain
                    && HashedSet.foldr (\h acc -> value h :: acc) [] set == SeqSet.foldr (::) [] plain
                , elems (HashedSet.filter (\h -> value h > 10) set) == SeqSet.toList (SeqSet.filter (\x -> x > 10) plain)
                    && Tuple.mapBoth elems elems (HashedSet.partition (\h -> value h > 10) set)
                    == Tuple.mapBoth SeqSet.toList SeqSet.toList (SeqSet.partition (\x -> x > 10) plain)
                    && HashedSet.unorderedEquals set (HashedSet.fromList (List.map hashed (List.reverse xs)))
                    && HashedSet.size set == 30
                    && not (HashedSet.isEmpty (HashedSet.singleton (hashed 1)))
                ]

        ( t1, ts1 ) =
            HashedSet.intern (hashed (tree 1 10000)) HashedSet.empty

        ( t2, ts2 ) =
            HashedSet.intern (hashed (tree 1 10000)) ts1

        _ =
            Debug.log "tree" [ t1 == t2, HashedSet.size ts2 == 1 ]
    in
    ()
