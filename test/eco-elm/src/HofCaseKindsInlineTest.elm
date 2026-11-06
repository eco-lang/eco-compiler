module HofCaseKindsInlineTest exposing (main)

{-| Small functions whose bodies are a `case` on a custom type, on an `Int` and on a `Bool` give the right values when used inside one arithmetic expression.

`pickCtor Two` is 20, `pickInt 3` is 30 and `pickBool True` is 7, so
`pickCtor Two + pickInt 3 * pickBool True` is 20 + 30 * 7 = 230.

## eco

Exercises the HOF-elimination work (plans/hof-elimination-closure-alloc-reduction.md): small
case-bodied helpers are inlined into expression positions across the case
kinds ctor, int and bool, and the inlined cases become value-producing
`eco.case` ops in the middle of a block (CGEN_010 and CGEN_045 in
design_docs/invariants.csv). Each helper is under the default inlining cost
threshold, so this pins the lifted inlining guard itself, independent of the
`hofThreshold` default.

-}

-- CHECK: result: 230


import Html exposing (text)


type Tri
    = One
    | Two
    | Three


pickCtor : Tri -> Int
pickCtor t =
    case t of
        One ->
            10

        Two ->
            20

        Three ->
            30


pickInt : Int -> Int
pickInt n =
    case n of
        1 ->
            10

        3 ->
            30

        _ ->
            99


pickBool : Bool -> Int
pickBool b =
    case b of
        True ->
            7

        False ->
            2


main =
    let
        _ =
            Debug.log "result" (pickCtor Two + pickInt 3 * pickBool True)
    in
    text "done"
