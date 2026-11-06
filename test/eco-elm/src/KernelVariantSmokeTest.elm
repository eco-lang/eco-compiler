module KernelVariantSmokeTest exposing (main)

{-| Checks comparison, equality, list cons and number-to-string conversion on Int, Float and Char values.

`compare` is applied to two Ints, two Floats and two Chars. `List.member`,
`/=`, and `<` and `>=` applied in prefix form inside a `List.foldl` callback cover
equality and ordering. `::` conses an Int, a Float and a Char onto a list, and
`String.fromInt` and `String.fromFloat` convert one number each.

## eco

A coverage canary for the per-primitive kernel variants: it reaches each
migrated kernel at least once for Int, Float and Char. If a variant became
unreachable from ordinary Elm code, the output would still be correct (the
boxed generic kernel behaves the same), so this test only guarantees that the
values flow through the migrated per-type code paths while they are used.

-}

-- CHECK: cmp_int: LT
-- CHECK: cmp_float: GT
-- CHECK: cmp_char: EQ
-- CHECK: eq_int: True
-- CHECK: ne_float: True
-- CHECK: lt_char: True
-- CHECK: ge_int: True
-- CHECK: cons_int: [42,1,2]
-- CHECK: cons_float: [3.14,1,2]
-- CHECK: cons_char: ['z','a','b']
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
