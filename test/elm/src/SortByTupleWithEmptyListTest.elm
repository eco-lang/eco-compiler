module SortByTupleWithEmptyListTest exposing (main)

{-| `List.sortBy` returning a tuple key whose second field can be `[]`.
F3 structure with F2 payload: the top-level key is a heap Tuple2 (so
sortBy's `Allocator::resolve` is fine), but the inner field comparison
hits the F2 bug — `compareUnboxableSlot` falls through to the raw
constant-byte ordering for Nil-vs-heap, returning the wrong sign.
Expected to FAIL today via a permutation that differs from the correct
order.

For input `[4, 1, 2, 3]`:
- 4 → (0, [])   (even ∧ >2)
- 1 → (1, [1])  (odd ∧ ≤2)
- 2 → (0, [2])  (even ∧ ≤2)
- 3 → (1, [])   (odd ∧ >2)
Sorted by `(parity, suffix)` with correct list ordering ([] < [_]):
  (0,[]), (0,[2]), (1,[]), (1,[1])
  → 4,       2,      3,      1
-}

-- CHECK: result: [4, 2, 3, 1]

import Html exposing (text)


keyOf : Int -> ( Int, List Int )
keyOf n =
    let
        suffix =
            if n > 2 then
                []

            else
                [ n ]
    in
    ( modBy 2 n, suffix )


main =
    let
        result : List Int
        result = List.sortBy keyOf [ 4, 1, 2, 3 ]

        _ = Debug.log "result" result
    in
    text "done"
