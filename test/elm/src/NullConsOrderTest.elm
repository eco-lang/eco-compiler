module NullConsOrderTest exposing (main)

{-| Null-cons embedding (HEAP_044): Order values are embedded constants on
BOTH sides — the kernel's compare returns them and compiled Elm constructs
them — so this pins the kernel-vs-compiled single representation END TO END
(the test that would catch the resolveAndCompare word-equality landmine).
-}

-- CHECK: intLt: True
-- CHECK: intEq: True
-- CHECK: intGt: True
-- CHECK: strCmp: "lt"
-- CHECK: floatCmp: "gt"
-- CHECK: listSort: [1, 2, 3]
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
        -- Kernel compare result vs compiled Order ctor: word equality.
        _ =
            Debug.log "intLt" (compare 1 2 == LT)

        _ =
            Debug.log "intEq" (compare 5 5 == EQ)

        _ =
            Debug.log "intGt" (compare 9 2 == GT)

        -- Kernel Order flowing into compiled case dispatch.
        _ =
            Debug.log "strCmp" (showOrder (compare "apple" "banana"))

        _ =
            Debug.log "floatCmp" (showOrder (compare 2.5 1.5))

        -- Comparator-driven kernel sort consuming compiled-code Orders.
        _ =
            Debug.log "listSort"
                (List.sortWith compare [ 3, 1, 2 ])

        _ =
            Debug.log "orderCase" (showOrder (compare ( 1, "a" ) ( 1, "a" )))
    in
    text "done"
