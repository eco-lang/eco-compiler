module UtilsEqualityCaptureIntTest exposing (main)

{-| `(==)` and `(/=)` on `Int` give the same answers when passed as function
values as when applied directly.

On the list `[1, 2, 3, 5, 5]` with target `5`, the operators are passed to the
generic helper `countWith`, giving counts of 2 and 3, and applied in prefix
form inside `List.filter` lambdas, keeping the two matches and the other three
elements.

-}

-- CHECK: eq_count: 2
-- CHECK: ne_count: 3
-- CHECK: eq_filter: [5,5]
-- CHECK: ne_filter: [1,2,3]


import Html exposing (text)


{-| Counts the elements `x` of a list for which `pred x target` holds.
-}
countWith : (a -> a -> Bool) -> a -> List a -> Int
countWith pred target =
    List.foldl
        (\x acc ->
            if pred x target then
                acc + 1

            else
                acc
        )
        0


main =
    let
        xs : List Int
        xs =
            [ 1, 2, 3, 5, 5 ]

        _ =
            Debug.log "eq_count" (countWith (==) 5 xs)

        _ =
            Debug.log "ne_count" (countWith (/=) 5 xs)

        _ =
            Debug.log "eq_filter" (List.filter (\x -> (==) x 5) xs)

        _ =
            Debug.log "ne_filter" (List.filter (\x -> (/=) x 5) xs)
    in
    text "done"
