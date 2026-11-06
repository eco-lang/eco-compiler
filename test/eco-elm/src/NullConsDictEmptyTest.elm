module NullConsDictEmptyTest exposing (main)

{-| `Dict` operations that produce or meet the empty dictionary give the
right answers.

The tests check that:

  - a singleton with its only key removed equals `Dict.empty`, and is
    reported empty by `Dict.isEmpty`;
  - removing all three keys of a three-entry dictionary leaves size 0, and
    `Dict.get` on the result returns `Nothing`;
  - `Dict.foldl` sums the values of a three-entry dictionary to 6;
  - two dictionaries built from the same entries in different orders are
    equal under `==`;
  - `Dict.empty` is not equal to a singleton.

## eco

Exercises null-constructor embedding (HEAP_044 in design_docs/invariants.csv;
plans/null-cons-hpointer-embedding.md). `RBEmpty` is an embedded constant word carrying its
declaration index, not a heap object, so tree slots hold the embedded constant. The test covers
equality walking a tree down to embedded empty leaves, shrinking a dictionary back to empty, folds
over such trees, and dictionaries built by kernel code.

-}

-- CHECK: emptyEq: True
-- CHECK: removeToEmpty: True
-- CHECK: sizeAfterShrink: 0
-- CHECK: getMissing: Nothing
-- CHECK: foldSum: 6
-- CHECK: contentEq: True
-- CHECK: neqNonEmpty: False

import Dict
import Html exposing (text)


main =
    let
        _ =
            Debug.log "emptyEq" (Dict.empty == Dict.remove "k" (Dict.singleton "k" 1))

        _ =
            Debug.log "removeToEmpty"
                (Dict.isEmpty (Dict.remove 1 (Dict.singleton 1 "v")))

        shrunk =
            List.foldl Dict.remove
                (Dict.fromList [ ( 1, "a" ), ( 2, "b" ), ( 3, "c" ) ])
                [ 1, 2, 3 ]

        _ =
            Debug.log "sizeAfterShrink" (Dict.size shrunk)

        _ =
            Debug.log "getMissing" (Dict.get 9 shrunk)

        _ =
            Debug.log "foldSum"
                (Dict.foldl (\_ v acc -> v + acc)
                    0
                    (Dict.fromList [ ( "x", 1 ), ( "y", 2 ), ( "z", 3 ) ])
                )

        -- `==` compares contents, so the insertion order does not matter.
        d1 =
            Dict.fromList [ ( 1, "a" ), ( 2, "b" ), ( 3, "c" ) ]

        d2 =
            Dict.fromList [ ( 3, "c" ), ( 1, "a" ), ( 2, "b" ) ]

        _ =
            Debug.log "contentEq" (d1 == d2)

        _ =
            Debug.log "neqNonEmpty" (Dict.empty == Dict.singleton 1 "v")
    in
    text "done"
