module LetNumberDualUseTest exposing (main)

{-| Let-bound `number` values used at both `Int` and `Float` in one body, which
the solver engine's per-use copies (`translateNumberMultiLet`) must tell
apart. Each case is its own top-level value so that one cannot hide another.
The scalar case is the simplest: `n = 5` with `n + 0` an `Int` and `n * 1.5` a
`Float`. Then the value goes through a global (`List.sum`, `Tuple.first`), a
tuple destructured by `case`, a list destructured by `case` at its head and at
its tail, and a `number` computed by such a `case` and then used at both
types.

Before the fix every case but the global one stopped the native build (a
`mul_Float` kernel signature mismatch, or `eco.float.mul` given an `i64`), and
an intermediate fix printed 0 for the tail case: the tail was read from the
`Int` instance as `Float`s (plans/dead-code-report.md, NumList2).

-}

-- CHECK: scalar: 9
-- CHECK: listSum: 15
-- CHECK: tupleFirst: 3
-- CHECK: tupleCase: 5
-- CHECK: listHead: 3
-- CHECK: listTail: 5
-- CHECK: caseProduct: 5

import Html exposing (text)


scalar : Int
scalar =
    let
        n =
            5
    in
    round (toFloat (n + 0) + n * 0.8)


listSum : Int
listSum =
    let
        xs =
            [ 1, 2, 3 ]
    in
    round (toFloat (List.sum xs + 0) + List.sum xs * 1.5)


tupleFirst : Int
tupleFirst =
    let
        p =
            ( 1, 2 )
    in
    round (toFloat (Tuple.first p + 0) + Tuple.first p * 1.5)


tupleCase : Int
tupleCase =
    let
        t =
            ( 1, 2 )

        prod =
            case t of
                ( a, b ) ->
                    a * b
    in
    round (toFloat (prod + 0) + prod * 1.5)


listHead : Int
listHead =
    let
        xs =
            [ 1, 2, 3 ]

        h =
            case xs of
                a :: _ ->
                    a

                _ ->
                    0
    in
    round (toFloat (h + 0) + h * 1.5)


listTail : Int
listTail =
    let
        xs =
            [ 1, 2, 3 ]

        prod =
            case xs of
                a :: b :: _ ->
                    a * b

                _ ->
                    0
    in
    round (toFloat (prod + 0) + prod * 1.5)


caseProduct : Int
caseProduct =
    let
        prod =
            case [ 1, 2, 3 ] of
                a :: b :: _ ->
                    a * b

                _ ->
                    0
    in
    round (toFloat (prod + 0) + prod * 1.5)


main =
    let
        _ =
            Debug.log "scalar" scalar

        _ =
            Debug.log "listSum" listSum

        _ =
            Debug.log "tupleFirst" tupleFirst

        _ =
            Debug.log "tupleCase" tupleCase

        _ =
            Debug.log "listHead" listHead

        _ =
            Debug.log "listTail" listTail

        _ =
            Debug.log "caseProduct" caseProduct
    in
    text "done"
