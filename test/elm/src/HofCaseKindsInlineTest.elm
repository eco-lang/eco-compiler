module HofCaseKindsInlineTest exposing (main)

{-| H2.0 (plans/hof-elimination-closure-alloc-reduction.md): small
case-bodied helpers inline into EXPRESSION positions across the case_kind
spectrum — ctor, int, bool — and the inlined cases land mid-block as
value-producing eco.case ops (CGEN_010/CGEN_045). Each helper is under the
default cost threshold, so this pins the guard lift itself, independent of
the hofThreshold default.

Behavioral: pickCtor (Two) = 20; pickInt 3 = 30; pickBool True = 7.
Sum in expression position: 20 + 30 * 7 = 230.

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
