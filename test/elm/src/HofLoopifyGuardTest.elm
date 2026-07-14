module HofLoopifyGuardTest exposing (main)

{-| H5 loopification guards
(plans/hof-elimination-closure-alloc-reduction.md): shapes that must NOT
loopify and must stay behaviorally correct —

  - `keepBoth` STORES its function param (returned in a tuple alongside the
    mapped list), so the param escapes and the eligibility analysis refuses
    the spec — its lambda keeps allocating;
  - `applyVar`'s foldl lambda IS a literal and legitimately loopifies, but
    it CAPTURES `h` — a multi-use let-bound closure — pinning that a
    captured closure variable survives loopification with correct sharing
    (h is also called directly outside the loop).

Behavioral: keepBoth (\x -> x+10) [1,2] gives mapped [11,12] and g back;
List.sum mapped + g 1 = 23 + 11 = 34. applyVar 5: foldl adds (1+5)+(2+5)+
(3+5) = 21, plus h 100 = 105 -> 126. Total 34 + 126 = 160.

-}

-- CHECK: result: 160


import Html exposing (text)


keepBoth : (Int -> Int) -> List Int -> ( Int -> Int, List Int )
keepBoth f xs =
    case xs of
        [] ->
            ( f, [] )

        x :: rest ->
            let
                ( g, mapped ) =
                    keepBoth f rest
            in
            ( g, f x :: mapped )


applyVar : Int -> Int
applyVar c =
    let
        h =
            \x -> x + c
    in
    List.foldl (\x acc -> acc + h x) 0 [ 1, 2, 3 ] + h 100


main =
    let
        ( g, mapped ) =
            keepBoth (\x -> x + 10) [ 1, 2 ]

        fromTuple =
            List.sum mapped + g 1

        fromVar =
            applyVar 5

        _ =
            Debug.log "result" (fromTuple + fromVar)
    in
    text "done"
