module LssGroundStandaloneTest exposing (main)

{-| A polymorphic function and a custom-type constructor are each passed as function values at both `Int` and `Float` and give the right results.

`myId` is passed to `applyI` at `Int -> Int` and to `applyF` at `Float -> Float`. `Box` is passed
to `applyBI` at `Int -> Box Int` and to `applyBF` at `Float -> Box Float`. Each `apply` function
counts its second argument down to zero recursively before calling the function once.

  - `sum` is `myId 4 + round (myId 5.0)`, which is 9.
  - `box` is `7 + round 2.5 - 3`, which is 7, since `round` takes 2.5 up to 3.

## eco

Exercises standalone-member grounding (LSS_019 in design_docs/invariants.csv; the
standalone-member grounding work, plans/lss-fidelity-2-standalone-member-grounding.md). One
polymorphic global (`myId`) and one constructor (`Box`) each flow as function values at two
layouts (Int and Float). With grounding on, each flow's provisional global or constructor member
is grounded per arrow layout, so the two layouts get distinct member ids instead of sharing one.

The `apply` helpers recurse so their dispatch sites survive inlining. The CHECK lines pin LSS_005
(design_docs/invariants.csv): grounding may change annotations, specialization counts and dispatch
tiers, never output. The unit-level test is
compiler/tests/Compiler/Monomorphize/Solver/LssGroundingTest.elm.

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
