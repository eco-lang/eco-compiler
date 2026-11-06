module NullConsNormalUnionTest exposing (main)

{-| A custom type with one constructor that has no arguments and one that
has an argument, `type T = A | B Int`, works for both constructors: values
built by a function are matched by `case`, compared with `==`, stored in a
tuple and printed by `Debug.log`.

`mk` returns `A` for a negative number and `B n` otherwise.

## eco

Exercises null-constructor embedding (HEAP_044 in design_docs/invariants.csv;
plans/null-cons-hpointer-embedding.md) in a union that also has a constructor with arguments, the
shape of `Dict`'s `RBEmpty`. `A` is an embedded constant while `B` stays a heap object, so equality
covers embedded against embedded (word compare), embedded against heap, and heap against heap
(structural), and `inField` reads the embedded constant back from a heap field.

-}

-- CHECK: matchA: "a"
-- CHECK: matchB: 41
-- CHECK: eqAA: True
-- CHECK: eqAB: False
-- CHECK: eqBB: True
-- CHECK: eqB5B7: False
-- CHECK: inField: "a"
-- CHECK: printA: A
-- CHECK: printB: B 7

import Html exposing (text)


type T
    = A
    | B Int


describe : T -> String
describe t =
    case t of
        A ->
            "a"

        B n ->
            "b" ++ String.fromInt n


unwrapOr : Int -> T -> Int
unwrapOr fallback t =
    case t of
        A ->
            fallback

        B n ->
            n


mk : Int -> T
mk n =
    if n < 0 then
        A

    else
        B n


main =
    let
        _ =
            Debug.log "matchA" (describe (mk (negate 1)))

        _ =
            Debug.log "matchB" (unwrapOr 0 (mk 41))

        -- Two `A`s, an `A` and a `B`, and two `B`s with equal and with
        -- different arguments.
        _ =
            Debug.log "eqAA" (mk (negate 1) == A)

        _ =
            Debug.log "eqAB" (mk (negate 1) == B 0)

        _ =
            Debug.log "eqBB" (mk 5 == B 5)

        _ =
            Debug.log "eqB5B7" (mk 5 == B 7)

        -- `A` stored in a tuple and read back.
        _ =
            Debug.log "inField" (describe (Tuple.first ( A, B 1 )))

        _ =
            Debug.log "printA" (mk (negate 1))

        _ =
            Debug.log "printB" (mk 7)
    in
    text "done"
