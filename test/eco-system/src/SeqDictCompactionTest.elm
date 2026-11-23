module SeqDictCompactionTest exposing (main)

{-| SeqDict compacts its insertion-order array when, before a removal, fewer than half of its slots
are live. A 10-entry dict compacts at its 7th removal (4 of 10 live). These checks cross that point
through `remove`, through `update` to `Nothing` and inside `diff`, remove absent keys (before and
after compaction), and then read the dict every way: order, lookups, size, equality with a freshly
built dict, and appending after compaction.

-}

-- ENV: ECO_SEQDICT_VALIDATE=1
-- CHECK: remove: [[1,2,3,4,5,6,7,8,9,10],[2,3,4,5,6,7,8,9,10],[3,4,5,6,7,8,9,10],[4,5,6,7,8,9,10],[5,6,7,8,9,10],[6,7,8,9,10],[7,8,9,10],[8,9,10],[9,10]]
-- CHECK: removeReads: [True,True,True,True]
-- CHECK: updateToNothing: [8,9,10]
-- CHECK: updateReads: [True,True,True]
-- CHECK: diff: [1,3,5,7,9]
-- CHECK: diffReads: [True,True,True]
-- CHECK: absent: [True,True,True]
-- CHECK: diffIncremental: (92,True,True)

import SeqDict exposing (SeqDict)
import System
import Task


ten : SeqDict Int Int
ten =
    SeqDict.fromList (List.map (\i -> ( i, i * 10 )) (List.range 1 10))


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


reads : SeqDict Int Int -> List Int -> List Bool
reads d live =
    [ SeqDict.keys d == live
    , List.all (\k -> SeqDict.get k d == Just (k * 10)) live
    , SeqDict.size d == List.length live
    , d == SeqDict.fromList (List.map (\k -> ( k, k * 10 )) live)
    ]


report : () -> ()
report () =
    let
        steps =
            List.foldl (\k acc -> SeqDict.remove k (Maybe.withDefault ten (List.head acc)) :: acc) [ ten ] (List.range 1 8)
                |> List.reverse

        _ =
            Debug.log "remove" (List.map SeqDict.keys steps)

        afterEight =
            Maybe.withDefault ten (List.head (List.reverse steps))

        appended =
            SeqDict.insert 99 990 afterEight

        _ =
            Debug.log "removeReads"
                [ reads afterEight (List.range 9 10) == [ True, True, True, True ]
                , SeqDict.keys appended == List.range 9 10 ++ [ 99 ]
                , SeqDict.get 99 appended == Just 990
                , List.all (\k -> SeqDict.get k afterEight == Nothing) (List.range 1 8)
                ]

        viaUpdate =
            List.foldl (\k d -> SeqDict.update k (\_ -> Nothing) d) ten (List.range 1 7)

        _ =
            Debug.log "updateToNothing" (SeqDict.keys viaUpdate)

        _ =
            Debug.log "updateReads" (List.take 3 (reads viaUpdate (List.range 8 10)))

        evens =
            SeqDict.fromList (List.map (\i -> ( i * 2, () )) (List.range 1 5))

        viaDiff =
            SeqDict.diff ten evens

        _ =
            Debug.log "diff" (SeqDict.keys viaDiff)

        _ =
            Debug.log "diffReads" (List.take 3 (reads viaDiff [ 1, 3, 5, 7, 9 ]))

        -- 200 entries, 95 removed (no compaction yet: 105 of 200 live), then a diff by 13 keys, small
        -- enough to go one key at a time, which crosses the half-live point on the way
        holed =
            List.foldl SeqDict.remove (SeqDict.fromList (List.map (\i -> ( i, i * 10 )) (List.range 1 200))) (List.range 1 95)

        diffedOneByOne =
            SeqDict.diff holed (SeqDict.fromList (List.map (\i -> ( i, () )) (List.range 96 108)))

        _ =
            Debug.log "diffIncremental"
                ( SeqDict.size diffedOneByOne
                , SeqDict.keys diffedOneByOne == List.range 109 200
                , diffedOneByOne == SeqDict.fromList (List.map (\i -> ( i, i * 10 )) (List.range 109 200))
                )

        _ =
            Debug.log "absent"
                [ SeqDict.remove 99 ten == ten
                , SeqDict.keys (SeqDict.remove 99 afterEight) == List.range 9 10
                , SeqDict.update 42 (\_ -> Nothing) ten == ten
                ]
    in
    ()
