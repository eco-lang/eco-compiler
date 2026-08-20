module LssGroundStandaloneTest exposing (main)

{-| LSS_019 standalone-member grounding (GAP-1,
`plans/lss-fidelity-2-standalone-member-grounding.md` §6 G2).

ONE polymorphic global (`myId`) and ONE box ctor (`Box`) each flow as
function values at TWO layouts (Int and Float) into recursion-protected
HOFs (recursion keeps the dispatch sites alive against inlining, the
CtorDevirt pattern). Flag-on, each flow's provisional `g|`/`c|` member
grounds per-arrow-layout at zonk — the ids diverge where they used to
share one family id. The CHECKs pin LSS_005: the answers must be identical
to a flag-off build; the grounding may change annotations, spec counts and
dispatch tiers, never observable behavior.

Unit-level pin: compiler/tests/TestLogic/Monomorphize/LssGroundingTest.elm.

-}

-- CHECK: sum: 9
-- CHECK: box: 7

import Html exposing (text)


type Box a
    = Box a


myId : a -> a
myId x =
    x


applyI : (Int -> Int) -> Int -> Int
applyI f n =
    if n <= 0 then
        f 4

    else
        applyI f (n - 1)


applyF : (Float -> Float) -> Float -> Float
applyF f n =
    if n <= 0 then
        f 5.0

    else
        applyF f (n - 1.0)


applyBI : (Int -> Box Int) -> Int -> Box Int
applyBI f n =
    if n <= 0 then
        f 7

    else
        applyBI f (n - 1)


applyBF : (Float -> Box Float) -> Float -> Box Float
applyBF f n =
    if n <= 0 then
        f 2.5

    else
        applyBF f (n - 1.0)


unBox : Box a -> a
unBox (Box x) =
    x


main =
    let
        a =
            applyI myId 2

        b =
            applyF myId 2.0

        sum =
            a + round b

        _ =
            Debug.log "sum" sum

        boxed =
            unBox (applyBI Box 2) + round (unBox (applyBF Box 2.0)) - 3

        _ =
            Debug.log "box" boxed
    in
    text "done"
