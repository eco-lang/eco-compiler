module UtilsEqualityCaptureCharTest exposing (main)

{-| Higher-order capture of `(==)` and `(/=)` on `Char`.
-}

-- CHECK: eq_count: 2
-- CHECK: ne_count: 3
-- CHECK: eq_filter: ['x', 'x']
-- CHECK: ne_filter: ['a', 'b', 'c']


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
