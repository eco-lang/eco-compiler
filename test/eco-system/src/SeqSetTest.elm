module SeqSetTest exposing (main)

{-| The SeqSet API keeps insertion order (eco/system's `SeqSet`, a SeqDict of `True`s): duplicates
keep their first position, a removed and re-inserted value goes to the end, `union` keeps the second
set's order, `map` keeps the first position of values that collapse, and `==` compares insertion
order while `unorderedEquals` does not.

-}

-- CHECK: fromList: [3,1,2]
-- CHECK: insertKeepsPosition: [3,1,2]
-- CHECK: reinsertAppends: [1,2,3]
-- CHECK: member: [True,False]
-- CHECK: size: [3,0]
-- CHECK: union: [2,3,1]
-- CHECK: intersect: [3,1]
-- CHECK: diff: [3,2]
-- CHECK: mapCollapses: [1,0]
-- CHECK: filter: [3,1]
-- CHECK: partition: ([3,1],[2])
-- CHECK: folds: ([2,1,3],[3,1,2])
-- CHECK: equality: [False,True,True]
-- CHECK: anyKey: [True,True,False]

import SeqSet exposing (SeqSet)
import System
import Task


s : SeqSet Int
s =
    SeqSet.fromList [ 3, 1, 2, 1 ]


type Shape
    = Circle Float
    | Rect { w : Int, h : Int }


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


report : () -> ()
report () =
    let
        _ =
            Debug.log "fromList" (SeqSet.toList s)

        _ =
            Debug.log "insertKeepsPosition" (SeqSet.toList (SeqSet.insert 3 s))

        _ =
            Debug.log "reinsertAppends" (s |> SeqSet.remove 3 |> SeqSet.insert 3 |> SeqSet.toList)

        _ =
            Debug.log "member" [ SeqSet.member 2 s, SeqSet.member 5 s ]

        _ =
            Debug.log "size" [ SeqSet.size s, SeqSet.size (SeqSet.remove 7 (SeqSet.singleton 7)) ]

        _ =
            Debug.log "union" (SeqSet.toList (SeqSet.union (SeqSet.fromList [ 1, 2 ]) (SeqSet.fromList [ 2, 3 ])))

        _ =
            Debug.log "intersect" (SeqSet.toList (SeqSet.intersect s (SeqSet.fromList [ 1, 3, 9 ])))

        _ =
            Debug.log "diff" (SeqSet.toList (SeqSet.diff s (SeqSet.fromList [ 1 ])))

        _ =
            Debug.log "mapCollapses" (SeqSet.toList (SeqSet.map (modBy 2) (SeqSet.fromList [ 3, 1, 2, 4 ])))

        _ =
            Debug.log "filter" (SeqSet.toList (SeqSet.filter (\x -> x /= 2) s))

        _ =
            Debug.log "partition" (SeqSet.partition (\x -> x /= 2) s |> Tuple.mapBoth SeqSet.toList SeqSet.toList)

        _ =
            Debug.log "folds" ( SeqSet.foldl (::) [] s, SeqSet.foldr (::) [] s )

        _ =
            Debug.log "equality"
                [ SeqSet.fromList [ 1, 2 ] == SeqSet.fromList [ 2, 1 ]
                , SeqSet.unorderedEquals (SeqSet.fromList [ 1, 2 ]) (SeqSet.fromList [ 2, 1 ])
                , SeqSet.fromList [ 1, 2 ] == SeqSet.insert 2 (SeqSet.singleton 1)
                ]

        -- Values that are not `comparable`: a custom type holding a record.
        shapes =
            SeqSet.fromList [ Circle 1.5, Rect { w = 2, h = 3 } ]

        _ =
            Debug.log "anyKey"
                [ SeqSet.member (Rect { h = 3, w = 2 }) shapes
                , SeqSet.member (Circle (3 / 2)) shapes
                , SeqSet.member (Rect { w = 3, h = 2 }) shapes
                ]
    in
    ()
