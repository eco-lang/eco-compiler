module LetNumberDualUseTest exposing (main)

{-| An unannotated let-bound `number` value can be used as an `Int` and as a
`Float` in the same expression, because Elm generalizes the type of a `let`
binding and each use picks its own type.

Each case is a separate top-level value that computes
`round (toFloat (x + 0) + x * k)`: the `toFloat (x + 0)` use makes `x` an `Int`
and the `x * k` use, with `k` a `Float` literal, makes it a `Float`.

  - `scalar` uses `n = 5` directly: 5 + 4.0 logs 9.
  - `listSum` uses `List.sum` of `[ 1, 2, 3 ]`: 6 + 9.0 logs 15.
  - `tupleFirst` uses `Tuple.first` of `( 1, 2 )`: 1 + 1.5 rounds to 3.
  - `tupleCase` uses the product of a `( 1, 2 )` tuple destructured by `case`:
    2 + 3.0 logs 5.
  - `listHead` uses the head of `[ 1, 2, 3 ]` taken by a `case`: 1 + 1.5 rounds
    to 3.
  - `listTail` uses the product of the first two elements of a let-bound
    `[ 1, 2, 3 ]`, read by a `case` that matches past the head: 2 + 3.0 logs 5.
  - `caseProduct` is the same product with the list literal written directly as
    the `case` subject: it logs 5.

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
