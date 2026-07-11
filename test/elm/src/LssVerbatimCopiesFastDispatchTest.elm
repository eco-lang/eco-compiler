module LssVerbatimCopiesFastDispatchTest exposing (main)

{-| LSS M3.5 (LSS_009): `runWith` is polymorphic in a parameter the lambda
never touches, so its two specializations each contain a VERBATIM copy of
the capturing lambda — same `srcLambda`, identical capture/param/return
layout, distinct `lambdaId`s. The shared `applyN` specialization's
internal `f acc` site sees a singleton set with TWO instances: declined
under M3's literal uniqueness, upgraded under M3.5's interchangeability
rule with either copy as representative. Capture VALUES differ per object
(start = 1 vs 10); the fast clone loads them from the object, so outputs
must be identical with LSS on or off.
-}

-- CHECK: first: 4
-- CHECK: second: 40

import Html exposing (text)


applyN : (Int -> Int) -> Int -> Int -> Int
applyN f n acc =
    if n <= 0 then
        acc

    else
        applyN f (n - 1) (f acc)


runWith : a -> Int -> Int
runWith _ start =
    applyN (\x -> x + start) 3 start


main =
    let
        _ =
            Debug.log "first" (runWith "one" 1)

        _ =
            Debug.log "second" (runWith 2.0 10)
    in
    text "done"
