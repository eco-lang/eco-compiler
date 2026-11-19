module SeqDictRandomizedTest exposing (main)

{-| A SeqDict and a SeqSet built by 3000 pseudo-random inserts, updates and removes, with keys of many
kinds (Ints, Strings, tuples, records, lists, Dicts, Chars, constructors), agree with a plain list of
pairs at every step: lookups, size, insertion order, folds, and `==` (SeqDictModel.elm).

## eco

`==` on two SeqDicts compares their entries in insertion order (`seqDictEq` in
elm-kernel-cpp/src/core/Utils.cpp): removing an entry leaves a hole in a SeqDict's insertion-order
Array, so two SeqDicts with the same entries can differ structurally.

-}

-- SKIP-JS: checks `==` on SeqDicts (contentEquality), which needs eco's native SeqDict-aware `==`
-- CHECK: SeqDictRandomized: "PASS"

import SeqDictModel
import System
import Task


main : Platform.Program System.Environment () ()
main =
    System.simpleProgram (\_ -> Task.succeed (report ()))


report : () -> ()
report () =
    let
        _ =
            case SeqDictModel.run { contentEquality = True } of
                [] ->
                    Debug.log "SeqDictRandomized" "PASS"

                errors ->
                    Debug.log "SeqDictRandomized" (String.join "\n" errors)
    in
    ()
