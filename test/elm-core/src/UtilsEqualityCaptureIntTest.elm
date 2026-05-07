module UtilsEqualityCaptureIntTest exposing (main)

{-| Higher-order capture of `(==)` and `(/=)` on `Int`, routing through
    `Utils.equal` / `Utils.notEqual` rather than the inline `eco.int.eq`
    intrinsic.
-}

-- CHECK: eq_count: 2
-- CHECK: ne_count: 3
-- CHECK: eq_filter: [5, 5]
-- CHECK: ne_filter: [1, 2, 3]


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
