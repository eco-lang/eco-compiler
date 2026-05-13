module SortByTupleWithEmptyStringTest exposing (main)

{-| `List.sortBy` returning a tuple key whose second field can be `""`.
The top-level key (Tuple2) is heap-allocated, so the F3 assert in
`Allocator::resolve` does NOT fire — but the inner field comparison
takes the `compareUnboxableSlot` path which IS special-cased for
EmptyString. Cross between F3 structure and OK regression payload.

For input `[4, 1, 2, 3]`:
- 4 → (0, "")   (even ∧ >2)
- 1 → (1, "x")  (odd ∧ ≤2)
- 2 → (0, "x")  (even ∧ ≤2)
- 3 → (1, "")   (odd ∧ >2)
Sorted by `(parity, suffix)`: (0,""), (0,"x"), (1,""), (1,"x")
                              → 4,         2,      3,      1
-}

-- CHECK: result: [4, 2, 3, 1]

import Html exposing (text)


keyOf : Int -> ( Int, String )
keyOf n =
    let
        suffix =
            if n > 2 then
                ""

            else
                "x"
    in
    ( modBy 2 n, suffix )


main =
    let
        result : List Int
        result = List.sortBy keyOf [ 4, 1, 2, 3 ]

        _ = Debug.log "result" result
    in
    text "done"
