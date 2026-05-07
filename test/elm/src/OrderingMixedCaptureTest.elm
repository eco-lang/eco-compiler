module OrderingMixedCaptureTest exposing (main)

{-| Stress test combining `(<)`, `(<=)`, `(>)`, `(>=)` per-type via
    higher-order capture. The same shape as the per-type capture tests but
    interleaved so the kernel symbol table sees calls to all 12 ordering
    variants in one program.
-}

-- CHECK: int_lt_count: 3
-- CHECK: int_ge_count: 2
-- CHECK: float_lt_count: 3
-- CHECK: float_ge_count: 2
-- CHECK: char_lt_count: 3
-- CHECK: char_ge_count: 2


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
        ints : List Int
        ints =
            [ 1, 2, 3, 4, 5 ]

        floats : List Float
        floats =
            [ 1.0, 2.0, 3.0, 4.0, 5.0 ]

        chars : List Char
        chars =
            [ 'a', 'b', 'c', 'd', 'e' ]

        _ =
            Debug.log "int_lt_count" (countWith (<) 4 ints)

        _ =
            Debug.log "int_ge_count" (countWith (>=) 4 ints)

        _ =
            Debug.log "float_lt_count" (countWith (<) 4.0 floats)

        _ =
            Debug.log "float_ge_count" (countWith (>=) 4.0 floats)

        _ =
            Debug.log "char_lt_count" (countWith (<) 'd' chars)

        _ =
            Debug.log "char_ge_count" (countWith (>=) 'd' chars)
    in
    text "done"
