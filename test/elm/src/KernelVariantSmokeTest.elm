module KernelVariantSmokeTest exposing (main)

{-| Smoke test that exercises every migrated kernel at least once per
    primitive type. Acts as a coverage canary — if any per-instance variant
    becomes unreachable through normal Elm code in a future refactor, this
    test still produces correct output (the boxed root is functionally
    identical) but each value flows through the migrated code path.
-}

-- CHECK: cmp_int: LT
-- CHECK: cmp_float: GT
-- CHECK: cmp_char: EQ
-- CHECK: eq_int: True
-- CHECK: ne_float: True
-- CHECK: lt_char: True
-- CHECK: ge_int: True
-- CHECK: cons_int: [42, 1, 2]
-- CHECK: cons_float: [3.14, 1, 2]
-- CHECK: cons_char: ['z', 'a', 'b']
-- CHECK: from_int: "100"
-- CHECK: from_float: "0.5"


import Html exposing (text)


main =
    let
        _ =
            Debug.log "cmp_int" (compare 1 2)

        _ =
            Debug.log "cmp_float" (compare 2.0 1.0)

        _ =
            Debug.log "cmp_char" (compare 'a' 'a')

        _ =
            Debug.log "eq_int" (List.member 3 [ 1, 2, 3 ])

        _ =
            Debug.log "ne_float" (1.5 /= 2.5)

        _ =
            Debug.log "lt_char" (List.foldl (\x acc -> acc || (<) x 'b') False [ 'a' ])

        _ =
            Debug.log "ge_int" (List.foldl (\x acc -> acc || (>=) x 5) False [ 5 ])

        _ =
            Debug.log "cons_int" (42 :: [ 1, 2 ])

        _ =
            Debug.log "cons_float" (3.14 :: [ 1.0, 2.0 ])

        _ =
            Debug.log "cons_char" ('z' :: [ 'a', 'b' ])

        _ =
            Debug.log "from_int" (String.fromInt 100)

        _ =
            Debug.log "from_float" (String.fromFloat 0.5)
    in
    text "done"
