module LssSigFlowTest exposing (main)

{-| LSS_020 — signature set-flow completion
(plans/lss-fidelity-3-signature-flow-completion.md §B.6 E2E fixture).

A lambda-passing caller routed through a `chooseHandler`-style def. The
behavior CHECKs below must hold in BOTH flag states (the suite's default is
flag-off; the plan's B.7 battery re-runs it with ECO_MONO_LSS_SIG_FLOW=1):
under sigFlow the call site's set is the honest 2-member join, so no
false-singleton devirt may stamp one lambda's code for the other — `b: 11`
(not 10) IS the anti-miscompile pin at runtime. The single-lambda variant
(`c:`) keeps a genuine singleton flowing end-to-end.

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
