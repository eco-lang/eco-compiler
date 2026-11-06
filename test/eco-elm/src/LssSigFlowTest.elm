module LssSigFlowTest exposing (main)

{-| A function that chooses between two function arguments returns the chosen one, and a function that returns its argument on both branches returns it.

  - `a`: `chooseHandler True` picks `\x -> x + 1`, applied to 9: 10.
  - `b`: `chooseHandler False` picks `\x -> x + 2`, applied to 9: 11.
  - `c`: `single True (\x -> x * 2)` is passed to `applyAt 20`: 40.

## eco

Exercises signature set-flow completion (LSS_020 in design_docs/invariants.csv; the
signature flow work, plans/lss-fidelity-3-signature-flow-completion.md). With
`ECO_MONO_LSS_SIG_FLOW=1` the set at the `chooseHandler` call site is the two-member join, so no
devirtualization may run one lambda's code for the other: `b: 11` (not 10) is the guard. `single`
keeps a genuine singleton flowing end to end. The CHECK lines must hold with the flag on and off.

-}

import Html exposing (text)


chooseHandler : Bool -> (Int -> Int) -> (Int -> Int) -> (Int -> Int)
chooseHandler b f g =
    if b then
        f

    else
        g


applyAt : Int -> (Int -> Int) -> Int
applyAt n h =
    h n


single : Bool -> (Int -> Int) -> (Int -> Int)
single b f =
    if b then
        f

    else
        f


main : Html.Html msg
main =
    let
        _ =
            Debug.log "a" (chooseHandler True (\x -> x + 1) (\x -> x + 2) 9)

        _ =
            Debug.log "b" (chooseHandler False (\x -> x + 1) (\x -> x + 2) 9)

        _ =
            Debug.log "c" (applyAt 20 (single True (\x -> x * 2)))
    in
    text "done"



-- CHECK: a: 10
-- CHECK: b: 11
-- CHECK: c: 40
