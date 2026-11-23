module SeqDictChurnTest exposing (main)

{-| SeqDicts with tens of thousands of entries, built while the program allocates (so collections run
during the builds), and heavy removal churn, which compacts the insertion-order Array
(`rebuildOnOverflow`): every lookup stays right, insertion order survives compaction, a compacted
SeqDict holds the entries of one built fresh (its `==` is in SeqDictEqualityTest), and new keys still
go to the end.

-}

-- ENV: ECO_SEQDICT_VALIDATE=1
-- CHECK: built: (50000,True)
-- CHECK: stringKeys: (20000,True)
-- CHECK: afterRemovingOdds: (25000,True,True)
-- CHECK: orderAfterCompaction: True
-- CHECK: firstAndLast: ([2,4,6],[49996,49998,50000])
-- CHECK: sameAsFresh: True
-- CHECK: appendAfterCompaction: [49998,50000,1]
-- CHECK: churnToEmpty: (0,True,[7])
-- CHECK: setChurn: (1000,True)

import SeqDict exposing (SeqDict)
import SeqSet
import System
import Task


n : Int
n =
    50000


ints : SeqDict Int Int
ints =
    List.foldl (\i acc -> SeqDict.insert i (i * 2) acc) SeqDict.empty (List.range 1 n)


lastThree : List a -> List a
lastThree xs =
    List.drop (List.length xs - 3) xs


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


report : () -> ()
report () =
    let
        _ =
            Debug.log "built"
                ( SeqDict.size ints, List.all (\i -> SeqDict.get i ints == Just (i * 2)) (List.range 1 n) )

        strs =
            List.foldl (\i acc -> SeqDict.insert ("key-" ++ String.fromInt i) i acc) SeqDict.empty (List.range 1 20000)

        _ =
            Debug.log "stringKeys"
                ( SeqDict.size strs, List.all (\i -> SeqDict.get ("key-" ++ String.fromInt i) strs == Just i) (List.range 1 20000) )

        -- Removing half the entries one at a time leaves holes until remove compacts the Array.
        evens =
            List.foldl
                (\i acc ->
                    if modBy 2 i == 1 then
                        SeqDict.remove i acc

                    else
                        acc
                )
                ints
                (List.range 1 n)

        _ =
            Debug.log "afterRemovingOdds"
                ( SeqDict.size evens
                , List.all (\i -> SeqDict.get i evens == Just (i * 2)) (List.range 1 (n // 2) |> List.map ((*) 2))
                , List.all (\i -> not (SeqDict.member i evens)) (List.range 0 (n // 2 - 1) |> List.map (\k -> 2 * k + 1))
                )

        evenKeys =
            SeqDict.keys evens

        _ =
            Debug.log "orderAfterCompaction" (evenKeys == List.map ((*) 2) (List.range 1 (n // 2)))

        _ =
            Debug.log "firstAndLast" ( List.take 3 evenKeys, lastThree evenKeys )

        fresh =
            SeqDict.fromList (List.map (\i -> ( 2 * i, 4 * i )) (List.range 1 (n // 2)))

        _ =
            Debug.log "sameAsFresh" (SeqDict.toList evens == SeqDict.toList fresh)

        _ =
            Debug.log "appendAfterCompaction" (lastThree (SeqDict.keys (SeqDict.insert 1 2 evens)))

        -- Insert and remove so many keys that the Array is rebuilt many times over.
        churned =
            List.foldl (\i acc -> acc |> SeqDict.insert i i |> SeqDict.remove (i - 1)) SeqDict.empty (List.range 1 30000)
                |> SeqDict.remove 30000

        _ =
            Debug.log "churnToEmpty"
                ( SeqDict.size churned, SeqDict.isEmpty churned, SeqDict.keys (SeqDict.insert 7 7 churned) )

        set =
            List.foldl (\i acc -> SeqSet.remove (i - 1000) (SeqSet.insert i acc)) SeqSet.empty (List.range 1 2000)

        _ =
            Debug.log "setChurn" ( SeqSet.size set, SeqSet.toList set == List.range 1001 2000 )
    in
    ()
