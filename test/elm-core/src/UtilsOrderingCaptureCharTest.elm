module UtilsOrderingCaptureCharTest exposing (main)

{-| Higher-order capture of `(<)`, `(<=)`, `(>)`, `(>=)` on `Char`.
-}

-- CHECK: lt_filter: ['a', 'b']
-- CHECK: le_filter: ['a', 'b', 'c']
-- CHECK: gt_filter: ['d', 'e']
-- CHECK: ge_filter: ['c', 'd', 'e']
-- CHECK: count_lt: 2
-- CHECK: count_ge: 3


import Html exposing (text)


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
