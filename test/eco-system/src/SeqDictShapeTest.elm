module SeqDictShapeTest exposing (main)

{-| The same set of keys reached by different sequences of operations: inserting only, inserting
extra keys and removing them again, `fromList`, and after a compaction (removals past the 80 % point),
`filter`, `union` and `diff`. With ECO_SEQDICT_VALIDATE=1 every `==` below checks both dicts' structure,
including the canonical form of the trie (plans/seq-data-structures-performance.md §4.2 T2/T3), which
makes the trie's shape depend only on the keys. Every comparison must be `True`.

-}

-- ENV: ECO_SEQDICT_VALIDATE=1
-- CHECK: sameKeys: [True,True,True,True,True,True]
-- CHECK: unordered: [True,True,True,True,True,True]
-- CHECK: sizes: [500,500,500,500,500,500]

import SeqDict exposing (SeqDict)
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


keys : List Int
keys =
    List.range 1 500


pairs : List ( Int, Int )
pairs =
    List.map (\k -> ( k, k * 3 )) keys


extras : List Int
extras =
    List.range 1000 2499


report : () -> ()
report () =
    let
        inserted =
            List.foldl (\( k, v ) d -> SeqDict.insert k v d) SeqDict.empty pairs

        -- the extra keys go in between, then all leave again (which compacts the order array)
        withExtras =
            List.foldl (\( k, v ) d -> SeqDict.insert (k + 999) 0 (SeqDict.insert k v d)) SeqDict.empty pairs
                |> (\d -> List.foldl SeqDict.remove d extras)
                |> (\d -> List.foldl SeqDict.remove d (List.range 1500 2499))

        fromList =
            SeqDict.fromList pairs

        filtered =
            SeqDict.fromList (pairs ++ List.map (\k -> ( k, 0 )) extras)
                |> SeqDict.filter (\k _ -> k <= 500)

        unioned =
            SeqDict.union (SeqDict.fromList (List.drop 250 pairs)) (SeqDict.fromList (List.take 250 pairs))

        diffed =
            SeqDict.diff (SeqDict.fromList (pairs ++ List.map (\k -> ( k, 0 )) extras)) (SeqDict.fromList (List.map (\k -> ( k, () )) extras))

        all =
            [ inserted, withExtras, fromList, filtered, unioned, diffed ]

        _ =
            Debug.log "sameKeys" (List.map (\d -> d == inserted) all)

        _ =
            Debug.log "unordered" (List.map (\d -> SeqDict.unorderedEquals d inserted) all)

        _ =
            Debug.log "sizes" (List.map SeqDict.size all)
    in
    ()
