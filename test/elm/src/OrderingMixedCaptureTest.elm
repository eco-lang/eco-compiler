module OrderingMixedCaptureTest exposing (main)

{-| Tests `(<)` and `(>=)` passed as arguments to one polymorphic counting
helper, used at `Int`, `Float` and `Char` in the same program.

`countWith` counts the list elements `x` for which `pred x target` holds. Each
type uses a five-element list (`1` to `5`, `1.0` to `5.0`, `'a'` to `'e'`) and
a target fourth in that list, so `(<)` counts 3 and `(>=)` counts 2.

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
