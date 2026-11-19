module SeqDictEqualityTest exposing (main)

{-| `==` on SeqDicts and SeqSets compares their entries in insertion order, not their insides.

Removing an entry leaves a hole in a SeqDict's insertion-order Array, so a SeqDict that had an entry
removed and one built without it hold the same entries but differ structurally; they must be equal.
The same entries in another order, or different entries, are not equal. SeqDicts nested in other
values, and Dicts and SeqDicts used as keys, compare the same way. Native only: elm/core's
JavaScript `==` compares SeqDicts structurally.

-}

-- SKIP-JS: elm/core's JavaScript `==` compares SeqDicts structurally, holes included; eco's native `==` compares their entries
-- CHECK: hole: True
-- CHECK: holeSet: True
-- CHECK: order: False
-- CHECK: value: False
-- CHECK: nested: True
-- CHECK: dictKey: True
-- CHECK: dictKeyOrder: ["b","a"]
-- CHECK: seqDictKey: Just "s"
-- CHECK: compacted: (True,True)

import Dict
import SeqDict
import SeqSet
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


report : () -> ()
report () =
    let
        withHole =
            SeqDict.fromList [ ( 1, "a" ), ( 2, "b" ), ( 3, "c" ) ] |> SeqDict.remove 2

        withoutHole =
            SeqDict.fromList [ ( 1, "a" ), ( 3, "c" ) ]

        _ =
            Debug.log "hole" (withHole == withoutHole)

        _ =
            Debug.log "holeSet" (SeqSet.remove 2 (SeqSet.fromList [ 1, 2, 3 ]) == SeqSet.fromList [ 1, 3 ])

        _ =
            Debug.log "order" (withoutHole == SeqDict.fromList [ ( 3, "c" ), ( 1, "a" ) ])

        _ =
            Debug.log "value" (withHole == SeqDict.fromList [ ( 1, "a" ), ( 3, "x" ) ])

        _ =
            Debug.log "nested" (Just ( withHole, [ withHole ] ) == Just ( withoutHole, [ withoutHole ] ))

        -- Equal Dicts built in different orders have different trees, so they must also hash alike.
        keyA =
            Dict.fromList [ ( 1, "x" ), ( 2, "y" ), ( 3, "z" ) ]

        keyA2 =
            Dict.fromList [ ( 3, "z" ), ( 1, "x" ), ( 2, "y" ) ]

        byDict =
            SeqDict.fromList [ ( keyA, "a" ) ]

        _ =
            Debug.log "dictKey" (SeqDict.get keyA2 byDict == Just "a")

        _ =
            Debug.log "dictKeyOrder"
                (SeqDict.fromList [ ( Dict.singleton 9 "b", "b" ), ( keyA, "a" ) ]
                    |> SeqDict.insert keyA2 "a"
                    |> SeqDict.values
                )

        -- A SeqDict with a hole, used as a key, must hash as the equal SeqDict without it does.
        _ =
            Debug.log "seqDictKey"
                (SeqDict.get (SeqDict.fromList [ ( 1, "a" ), ( 3, "c" ) ]) (SeqDict.singleton withHole "s"))

        -- Removing most entries compacts the insertion-order Array, leaving some holes; equal anyway.
        compacted =
            List.foldl SeqDict.remove (SeqDict.fromList (List.map (\i -> ( i, i )) (List.range 1 1000))) (List.range 1 900)

        fresh =
            SeqDict.fromList (List.map (\i -> ( i, i )) (List.range 901 1000))

        _ =
            Debug.log "compacted" ( compacted == fresh, SeqSet.fromList (SeqDict.keys compacted) == SeqSet.fromList (List.range 901 1000) )
    in
    ()
