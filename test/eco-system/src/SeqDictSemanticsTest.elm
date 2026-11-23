module SeqDictSemanticsTest exposing (main)

{-| Which key object and value SeqDict keeps, and in which order, when keys are equal under `==` but
distinguishable: `0` and `-0` are equal Floats, told apart by `1 / k` (`Infinity` against
`-Infinity`). Pins the rules of plans/seq-data-structures-performance.md §3.1: inserting a present
key keeps its place and stores the new key object; `update` and `updateIfExists` store the argument
key; `fromList` keeps the first position and the last key and value; `union` takes the first dict's
key and value at the second dict's position and appends the first dict's other keys; `intersect` and
`diff` keep the first dict's keys, values and order; `merge` after removals; `filter`, `filterMap`
and `partition` on dicts with holes; `SeqSet.map` collapsing images; `NaN` keys are never found.

-}

-- ENV: ECO_SEQDICT_VALIDATE=1
-- CHECK: insertPresent: [(-Infinity,"z"),(1,"b")]
-- CHECK: update: [(-Infinity,"ua"),(1,"b")]
-- CHECK: updateIfExists: [(-Infinity,"va"),(1,"b")]
-- CHECK: fromListDuplicates: [(-Infinity,3),(1,2)]
-- CHECK: union: [(0.5,"two"),(-Infinity,"t1"),(0.2,"five")]
-- CHECK: intersect: [[(-Infinity,"t1")],[(Infinity,"t2")]]
-- CHECK: diff: [(0.2,"five")]
-- CHECK: mergeAfterRemovals: ["L1","B3:c:x","R5"]
-- CHECK: filterHoles: [2,4,6,8,10]
-- CHECK: filterMapHoles: [(6,60),(8,80),(9,90),(10,100)]
-- CHECK: partitionHoles: ([1,2,4],[5,6,8,9,10])
-- CHECK: seqSetMap: [1,Infinity]
-- CHECK: nan: (2,Nothing,2)

import SeqDict exposing (SeqDict)
import SeqSet
import System
import Task


negZero : Float
negZero =
    -0.0


inverse : List ( Float, v ) -> List ( Float, v )
inverse =
    List.map (\( k, v ) -> ( 1 / k, v ))


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


report : () -> ()
report () =
    let
        d =
            SeqDict.fromList [ ( 0.0, "a" ), ( 1.0, "b" ) ]

        _ =
            Debug.log "insertPresent" (inverse (SeqDict.toList (SeqDict.insert negZero "z" d)))

        _ =
            Debug.log "update" (inverse (SeqDict.toList (SeqDict.update negZero (Maybe.map ((++) "u")) d)))

        _ =
            Debug.log "updateIfExists" (inverse (SeqDict.toList (SeqDict.updateIfExists negZero ((++) "v") d)))

        _ =
            Debug.log "fromListDuplicates" (inverse (SeqDict.toList (SeqDict.fromList [ ( 0.0, 1 ), ( 1.0, 2 ), ( negZero, 3 ) ])))

        t1 =
            SeqDict.fromList [ ( negZero, "t1" ), ( 5.0, "five" ) ]

        t2 =
            SeqDict.fromList [ ( 2.0, "two" ), ( 0.0, "t2" ) ]

        _ =
            Debug.log "union" (inverse (SeqDict.toList (SeqDict.union t1 t2)))

        _ =
            Debug.log "intersect" [ inverse (SeqDict.toList (SeqDict.intersect t1 t2)), inverse (SeqDict.toList (SeqDict.intersect t2 t1)) ]

        _ =
            Debug.log "diff" (inverse (SeqDict.toList (SeqDict.diff t1 t2)))

        left =
            SeqDict.fromList [ ( 1, "a" ), ( 2, "b" ), ( 3, "c" ) ] |> SeqDict.remove 2

        right =
            SeqDict.fromList [ ( 3, "x" ), ( 4, "y" ) ] |> SeqDict.remove 4 |> SeqDict.insert 5 "z"

        _ =
            Debug.log "mergeAfterRemovals"
                (SeqDict.merge
                    (\k _ acc -> acc ++ [ "L" ++ String.fromInt k ])
                    (\k a b acc -> acc ++ [ "B" ++ String.fromInt k ++ ":" ++ a ++ ":" ++ b ])
                    (\k _ acc -> acc ++ [ "R" ++ String.fromInt k ])
                    left
                    right
                    []
                )

        holes =
            SeqDict.fromList (List.map (\i -> ( i, i )) (List.range 1 10)) |> SeqDict.remove 3 |> SeqDict.remove 7

        _ =
            Debug.log "filterHoles" (SeqDict.keys (SeqDict.filter (\k _ -> modBy 2 k == 0) holes))

        _ =
            Debug.log "filterMapHoles"
                (SeqDict.toList
                    (SeqDict.filterMap
                        (\k v ->
                            if k > 5 then
                                Just (v * 10)

                            else
                                Nothing
                        )
                        holes
                    )
                )

        _ =
            Debug.log "partitionHoles" (Tuple.mapBoth SeqDict.keys SeqDict.keys (SeqDict.partition (\k _ -> k < 5) holes))

        _ =
            Debug.log "seqSetMap"
                (SeqSet.fromList [ 1.0, 2.0, 3.0 ]
                    |> SeqSet.map
                        (\x ->
                            if x == 2 then
                                negZero

                            else if x == 3 then
                                0.0

                            else
                                x
                        )
                    |> SeqSet.toList
                    |> List.map (\k -> 1 / k)
                )

        nan =
            0 / 0

        withNan =
            SeqDict.empty |> SeqDict.insert nan 1 |> SeqDict.insert nan 2

        _ =
            Debug.log "nan" ( SeqDict.size withNan, SeqDict.get nan withNan, SeqDict.size (SeqDict.remove nan withNan) )
    in
    ()
