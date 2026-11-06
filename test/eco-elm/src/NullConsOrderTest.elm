module NullConsOrderTest exposing (main)

{-| `Order` values returned by `compare` are the same as the constructors
`LT`, `EQ` and `GT` written in source: they are equal to them under `==` and
are matched by them in a `case`.

The tests compare `Int`s, `String`s, `Float`s and tuples with `compare`, and
sort `[ 3, 1, 2 ]` with `List.sortWith compare`.

## eco

Exercises null-constructor embedding (HEAP_044 in design_docs/invariants.csv;
plans/null-cons-hpointer-embedding.md) across the kernel boundary. `Order` values are embedded
constants on both sides: the kernel `compare` (elm-kernel-cpp/src/core/Utils.cpp) returns them and
compiled Elm constructs them, so word equality and case dispatch only work if both use the same
representation. The sort checks a kernel sort consuming orders from compiled code.

-}

-- CHECK: intLt: True
-- CHECK: intEq: True
-- CHECK: intGt: True
-- CHECK: strCmp: "lt"
-- CHECK: floatCmp: "gt"
-- CHECK: listSort: [1,2,3]
-- CHECK: orderCase: "eq"

import Html exposing (text)


showOrder : Order -> String
showOrder o =
    case o of
        LT ->
            "lt"

        EQ ->
            "eq"

        GT ->
            "gt"


main =
    let
        -- `compare` results tested against `Order` constructors with `==`.
        _ =
            Debug.log "intLt" (compare 1 2 == LT)

        _ =
            Debug.log "intEq" (compare 5 5 == EQ)

        _ =
            Debug.log "intGt" (compare 9 2 == GT)

        -- `compare` results matched by `case`.
        _ =
            Debug.log "strCmp" (showOrder (compare "apple" "banana"))

        _ =
            Debug.log "floatCmp" (showOrder (compare 2.5 1.5))

        _ =
            Debug.log "listSort"
                (List.sortWith compare [ 3, 1, 2 ])

        _ =
            Debug.log "orderCase" (showOrder (compare ( 1, "a" ) ( 1, "a" )))
    in
    text "done"
