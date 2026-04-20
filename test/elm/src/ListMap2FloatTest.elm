module ListMap2FloatTest exposing (main)

{-| `List.map2` / `List.map3` on lists of `Float`.

    The `Elm_Kernel_List_map2..map5` kernels re-box each unboxed list head
    as an `Elm Int` before calling the user mapper. With a `List Float` the
    mapper should receive the float values unchanged, so the sums below must
    match IEEE addition.
-}

-- CHECK: map2Add: [11, 22, 33]
-- CHECK: map2Mul: [3, 5]
-- CHECK: map2Decimals: [4.5, 6.5]
-- CHECK: map3: [111, 222]

import Html exposing (text)


main =
    let
        _ = Debug.log "map2Add" (List.map2 (+) [1.0, 2.0, 3.0] [10.0, 20.0, 30.0])
        _ = Debug.log "map2Mul" (List.map2 (*) [1.5, 2.5] [2.0, 2.0])
        _ = Debug.log "map2Decimals" (List.map2 (+) [1.5, 2.5] [3.0, 4.0])
        _ = Debug.log "map3" (List.map3 (\a b c -> a + b + c) [1.0, 2.0] [10.0, 20.0] [100.0, 200.0])
    in
    text "done"
