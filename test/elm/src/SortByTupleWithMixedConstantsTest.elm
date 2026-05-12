module SortByTupleWithMixedConstantsTest exposing (main)

{-| `List.sortBy` returning a tuple key where the second field is
deterministically `[]` for some inputs and `[-n]` for others, with both
positive and negative inputs. Stress-tests repeated F2 traversal during
stable_sort comparator calls.

For input `[-2, -1, 0, 1, 2]`:
- -2 → (-2, [2])
- -1 → (-1, [1])
- 0  → ( 0, [0])
- 1  → ( 1, [])
- 2  → ( 2, [])
Sort by `(first, second)` ascending: order of `first` is -2,-1,0,1,2.
→ result = [-2, -1, 0, 1, 2] (identity since `first` strictly orders).
The Nil-vs-heap comparisons fire only as **tiebreakers**; here `first`
is already distinct, so the F2 bug doesn't change the result. This
test exists to catch the case where the comparator's wrong sign on
Nil-vs-heap *avoids* changing the result (a "lucky-pass" regression).
-}

-- CHECK: result: [-2, -1, 0, 1, 2]

import Html exposing (text)


keyOf : Int -> ( Int, List Int )
keyOf n =
    if n > 0 then
        ( n, [] )

    else
        ( n, [ -n ] )


main =
    let
        result : List Int
        result = List.sortBy keyOf [ -2, -1, 0, 1, 2 ]

        _ = Debug.log "result" result
    in
    text "done"
