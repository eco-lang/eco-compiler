module SeqDictHashOnceTest exposing (main)

{-| SeqDict and SeqSet operations that use one key several times in one function
give the same results whether or not the compiler hashes the key once
(plans/seqdict-hash-once-per-function.md): natively, the SeqDict and SeqSet
wrappers are inlined and the hash mode of `Compiler.MonoOpt.Cse` merges the
repeated hashes of one key in a function, seeing through the inliner's `let`
aliases. A wrong merge would give a key another key's hash: a missed lookup, a
duplicate entry, or a trie the validator rejects (`ECO_SEQDICT_VALIDATE=1`).

Every key shape is covered, since tuple and record keys are hashed by typed
chains that the merge must handle before they are generated: custom-type trees,
`( String, Int )` tuples with long Strings, records with a long String field,
Strings, and three Strings that share a hash (as in SeqDictCollisionTest).

  - `probe`: `get`, then `insert` on a miss, of one key in one function; each
    list holds every key twice, so the second pass finds every key.
  - `inAll`: `member k d1 && member k d2 && member k d3`.
  - `addThenHas`: `SeqSet.insert` then `SeqSet.member` of one key.

The checks are semantic only: that the merge happened is shown by the unit test
`compiler/tests/Compiler/MonoOpt/CseTest.elm` and by the CSE report on the
benchmarks. `-- ENV:` reaches only the run, not the compile, so an `off` twin of
this test could not switch the merge off, and `CHECK-MLIR-NOT` is global over
the module, where the SeqDict internals hash keys of the same types too.

-}

-- ENV: ECO_SEQDICT_VALIDATE=1
-- CHECK: trees: (50,1225)
-- CHECK: tuples: (10,45)
-- CHECK: records: (7,21)
-- CHECK: strings: (5,11)
-- CHECK: inAll: [0,30]
-- CHECK: sets: [True,True,True,True,True,True,True]
-- CHECK: absent: False

import SeqDict exposing (SeqDict)
import SeqSet
import System
import Task


type Tree
    = Leaf Int
    | Node Tree Tree


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


{-| `get` then, on a miss, `insert` of one key: two hashes of `k` in one function.
-}
probe : k -> Int -> SeqDict k Int -> SeqDict k Int
probe k v d =
    case SeqDict.get k d of
        Just _ ->
            d

        Nothing ->
            SeqDict.insert k v d


{-| Each key of `keys` probed in turn, with its index as the value; returns the
size and the sum of the values kept (each key keeps its first index).
-}
probeAll : List k -> ( Int, Int )
probeAll keys =
    let
        d =
            List.foldl (\( i, k ) acc -> probe k i acc) SeqDict.empty (List.indexedMap Tuple.pair keys)
    in
    ( SeqDict.size d, SeqDict.foldl (\_ v s -> s + v) 0 d )


inAll : k -> SeqDict k Int -> SeqDict k Int -> SeqDict k Int -> Bool
inAll k d1 d2 d3 =
    SeqDict.member k d1 && SeqDict.member k d2 && SeqDict.member k d3


addThenHas : comparable -> Bool
addThenHas k =
    SeqSet.member k (SeqSet.insert k SeqSet.empty)


tree : Int -> Tree
tree i =
    Node (Leaf i) (Node (Leaf (i * 2)) (Leaf 7))


long : String
long =
    String.repeat 3000 "x"


report : () -> ()
report () =
    let
        trees =
            List.map tree (List.range 0 49)

        -- 60 keys, 10 distinct (both parts follow i mod 10)
        tuples =
            List.map (\i -> ( long ++ String.fromInt (modBy 10 i), modBy 5 i )) (List.range 0 59)

        records =
            List.map (\i -> { name = long ++ String.fromInt (modBy 7 i), n = modBy 7 i }) (List.range 0 34)

        strings =
            [ "collisio", "klsygdlo", "fskwtmhm", "a", "collisio", "b", "fskwtmhm" ]

        subset m =
            List.foldl
                (\( i, k ) acc ->
                    if modBy m i == 0 then
                        SeqDict.insert k i acc

                    else
                        acc
                )
                SeqDict.empty
                (List.indexedMap Tuple.pair trees)

        d2 =
            subset 2

        d3 =
            subset 3

        d5 =
            subset 5

        _ =
            Debug.log "trees" (probeAll (trees ++ trees))

        _ =
            Debug.log "tuples" (probeAll tuples)

        _ =
            Debug.log "records" (probeAll records)

        _ =
            Debug.log "strings" (probeAll strings)

        _ =
            Debug.log "inAll"
                (List.filterMap
                    (\( i, k ) ->
                        if inAll k d2 d3 d5 then
                            Just i

                        else
                            Nothing
                    )
                    (List.indexedMap Tuple.pair trees)
                )

        _ =
            Debug.log "sets" (List.map addThenHas strings)

        _ =
            Debug.log "absent" (SeqSet.member "zzz" (SeqSet.insert "collisio" SeqSet.empty))
    in
    ()
