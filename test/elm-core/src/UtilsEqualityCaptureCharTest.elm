module UtilsEqualityCaptureCharTest exposing (main)

{-| `(==)` and `(/=)` on `Char` give the same answers when passed as function
values as when applied directly.

On the list `['a','b','c','x','x']` with target `'x'`, the operators are passed
to the generic helper `countWith`, giving counts of 2 and 3, and applied in prefix
form inside `List.filter` lambdas, keeping the two matches and the other three
elements.

-}

-- CHECK: eq_count: 2
-- CHECK: ne_count: 3
-- CHECK: eq_filter: ['x','x']
-- CHECK: ne_filter: ['a','b','c']


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
        xs : List Char
        xs =
            [ 'a', 'b', 'c', 'x', 'x' ]

        _ =
            Debug.log "eq_count" (countWith (==) 'x' xs)

        _ =
            Debug.log "ne_count" (countWith (/=) 'x' xs)

        _ =
            Debug.log "eq_filter" (List.filter (\x -> (==) x 'x') xs)

        _ =
            Debug.log "ne_filter" (List.filter (\x -> (/=) x 'x') xs)
    in
    text "done"
