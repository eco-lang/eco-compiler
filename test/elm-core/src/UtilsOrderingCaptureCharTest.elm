module UtilsOrderingCaptureCharTest exposing (main)

{-| `(<)`, `(<=)`, `(>)` and `(>=)` on `Char` give the right answers when
passed as function values or applied in prefix form.

On the list `['a','b','c','d','e']` with pivot `'c'`, each operator is applied
in prefix form inside a `List.filter` lambda, and `(<)` and `(>=)` are also passed to the
generic helper `countWith`, counting 2 and 3 elements.

-}

-- CHECK: lt_filter: ['a','b']
-- CHECK: le_filter: ['a','b','c']
-- CHECK: gt_filter: ['d','e']
-- CHECK: ge_filter: ['c','d','e']
-- CHECK: count_lt: 2
-- CHECK: count_ge: 3


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
            [ 'a', 'b', 'c', 'd', 'e' ]

        _ =
            Debug.log "lt_filter" (List.filter (\x -> (<) x 'c') xs)

        _ =
            Debug.log "le_filter" (List.filter (\x -> (<=) x 'c') xs)

        _ =
            Debug.log "gt_filter" (List.filter (\x -> (>) x 'c') xs)

        _ =
            Debug.log "ge_filter" (List.filter (\x -> (>=) x 'c') xs)

        _ =
            Debug.log "count_lt" (countWith (<) 'c' xs)

        _ =
            Debug.log "count_ge" (countWith (>=) 'c' xs)
    in
    text "done"
