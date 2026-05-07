module UtilsEqualityCaptureFloatTest exposing (main)

{-| Higher-order capture of `(==)` and `(/=)` on `Float`.
-}

-- CHECK: eq_count: 2
-- CHECK: ne_count: 3
-- CHECK: eq_filter: [1.5, 1.5]
-- CHECK: ne_filter: [0, 2, 3]


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
        xs : List Float
        xs =
            [ 0.0, 2.0, 3.0, 1.5, 1.5 ]

        _ =
            Debug.log "eq_count" (countWith (==) 1.5 xs)

        _ =
            Debug.log "ne_count" (countWith (/=) 1.5 xs)

        _ =
            Debug.log "eq_filter" (List.filter (\x -> (==) x 1.5) xs)

        _ =
            Debug.log "ne_filter" (List.filter (\x -> (/=) x 1.5) xs)
    in
    text "done"
