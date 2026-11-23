module SeqDictOrderTest exposing (main)

{-| The SeqDict API keeps insertion order as documented (eco/system's `SeqDict`, from
lamdera/containers): inserting an existing key replaces its value in place, a removed and re-inserted
key goes to the end, `union` keeps the second dictionary's order and the first one's values,
`intersect` and `diff` keep the first one's order, and `merge` visits the left keys in order and then
the right-only keys.

-}

-- ENV: ECO_SEQDICT_VALIDATE=1
-- CHECK: insertKeepsPosition: [("a",10),("b",2),("c",3)]
-- CHECK: reinsertAppends: [("b",2),("c",3),("a",1)]
-- CHECK: fromListDuplicate: [("x",3),("y",2)]
-- CHECK: update: [("b",20),("c",3),("d",4)]
-- CHECK: updateIfExists: [("a",1),("b",2),("c",-3)]
-- CHECK: get: [Just 2,Nothing]
-- CHECK: member: [True,False]
-- CHECK: size: [3,0,1]
-- CHECK: isEmpty: [False,True]
-- CHECK: keys: ["a","b","c"]
-- CHECK: values: [1,2,3]
-- CHECK: foldl: ["c","b","a"]
-- CHECK: foldr: ["a","b","c"]
-- CHECK: map: ["a1","b2","c3"]
-- CHECK: filter: [("a",1),("c",3)]
-- CHECK: filterMap: [("b",4),("c",9)]
-- CHECK: partition: ([("a",1),("c",3)],[("b",2)])
-- CHECK: union: [("b",2),("c",30),("a",1)]
-- CHECK: intersect: [("c",3),("b",2)]
-- CHECK: diff: [("c",3),("b",2)]
-- CHECK: merge: ["Lx","By","Lz","Rw","Rv"]
-- CHECK: unorderedEquals: [True,False,False]
-- CHECK: orderedEq: [False,True]
-- CHECK: singleton: [(1,"one")]

import SeqDict exposing (SeqDict)
import System
import Task


base : SeqDict String Int
base =
    SeqDict.fromList [ ( "a", 1 ), ( "b", 2 ), ( "c", 3 ) ]


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


report : () -> ()
report () =
    let
        _ =
            Debug.log "insertKeepsPosition" (SeqDict.toList (SeqDict.insert "a" 10 base))

        _ =
            Debug.log "reinsertAppends" (base |> SeqDict.remove "a" |> SeqDict.insert "a" 1 |> SeqDict.toList)

        _ =
            Debug.log "fromListDuplicate" (SeqDict.toList (SeqDict.fromList [ ( "x", 1 ), ( "y", 2 ), ( "x", 3 ) ]))

        _ =
            Debug.log "update"
                (base
                    |> SeqDict.update "b" (Maybe.map ((*) 10))
                    |> SeqDict.update "d" (\_ -> Just 4)
                    |> SeqDict.update "a" (\_ -> Nothing)
                    |> SeqDict.toList
                )

        _ =
            Debug.log "updateIfExists"
                (base |> SeqDict.updateIfExists "c" negate |> SeqDict.updateIfExists "z" negate |> SeqDict.toList)

        _ =
            Debug.log "get" [ SeqDict.get "b" base, SeqDict.get "z" base ]

        _ =
            Debug.log "member" [ SeqDict.member "c" base, SeqDict.member "z" base ]

        _ =
            Debug.log "size" [ SeqDict.size base, SeqDict.size SeqDict.empty, SeqDict.size (SeqDict.remove "a" (SeqDict.remove "b" base)) ]

        _ =
            Debug.log "isEmpty" [ SeqDict.isEmpty base, SeqDict.isEmpty (SeqDict.remove "x" (SeqDict.singleton "x" 0)) ]

        _ =
            Debug.log "keys" (SeqDict.keys base)

        _ =
            Debug.log "values" (SeqDict.values base)

        _ =
            Debug.log "foldl" (SeqDict.foldl (\k _ acc -> k :: acc) [] base)

        _ =
            Debug.log "foldr" (SeqDict.foldr (\k _ acc -> k :: acc) [] base)

        _ =
            Debug.log "map" (SeqDict.values (SeqDict.map (\k v -> k ++ String.fromInt v) base))

        _ =
            Debug.log "filter" (SeqDict.toList (SeqDict.filter (\_ v -> v /= 2) base))

        _ =
            Debug.log "filterMap"
                (SeqDict.toList
                    (SeqDict.filterMap
                        (\_ v ->
                            if v > 1 then
                                Just (v * v)

                            else
                                Nothing
                        )
                        base
                    )
                )

        _ =
            Debug.log "partition"
                (SeqDict.partition (\_ v -> modBy 2 v == 1) base |> Tuple.mapBoth SeqDict.toList SeqDict.toList)

        _ =
            Debug.log "union"
                (SeqDict.union (SeqDict.fromList [ ( "a", 1 ), ( "b", 2 ) ]) (SeqDict.fromList [ ( "b", 20 ), ( "c", 30 ) ])
                    |> SeqDict.toList
                )

        _ =
            Debug.log "intersect"
                (SeqDict.intersect (SeqDict.fromList [ ( "c", 3 ), ( "a", 1 ), ( "b", 2 ) ]) (SeqDict.fromList [ ( "b", () ), ( "c", () ) ])
                    |> SeqDict.toList
                )

        _ =
            Debug.log "diff"
                (SeqDict.diff (SeqDict.fromList [ ( "c", 3 ), ( "a", 1 ), ( "b", 2 ) ]) (SeqDict.fromList [ ( "a", True ) ])
                    |> SeqDict.toList
                )

        _ =
            Debug.log "merge"
                (SeqDict.merge
                    (\k _ acc -> acc ++ [ "L" ++ k ])
                    (\k _ _ acc -> acc ++ [ "B" ++ k ])
                    (\k _ acc -> acc ++ [ "R" ++ k ])
                    (SeqDict.fromList [ ( "x", 1 ), ( "y", 2 ), ( "z", 3 ) ])
                    (SeqDict.fromList [ ( "w", 0 ), ( "y", 0 ), ( "v", 0 ) ])
                    []
                )

        ab =
            SeqDict.fromList [ ( "A", 1 ), ( "B", 2 ) ]

        ba =
            SeqDict.fromList [ ( "B", 2 ), ( "A", 1 ) ]

        _ =
            Debug.log "unorderedEquals"
                [ SeqDict.unorderedEquals ab ba
                , SeqDict.unorderedEquals ab (SeqDict.fromList [ ( "B", 2 ), ( "A", 9 ) ])
                , SeqDict.unorderedEquals ab (SeqDict.insert "C" 3 ba)
                ]

        _ =
            Debug.log "orderedEq" [ ab == ba, ab == SeqDict.insert "B" 2 (SeqDict.singleton "A" 1) ]

        _ =
            Debug.log "singleton" (SeqDict.toList (SeqDict.singleton 1 "one"))
    in
    ()
