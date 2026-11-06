module HofLoopifyGuardTest exposing (main)

{-| A function parameter returned inside a tuple from a recursive mapping function, and a let-bound closure used both inside a `List.foldl` lambda and directly, both behave correctly.

`keepBoth f xs` maps `f` over `xs` and also returns `f` itself. Called with
`\x -> x + 10` and `[ 1, 2 ]` it gives `[ 11, 12 ]`, summing to 23, and the
returned function applied to 1 gives 11, for 34.

`applyVar 5` binds `h = \x -> x + 5`, calls it from the lambda passed to
`List.foldl` over `[ 1, 2, 3 ]` (6 + 7 + 8 = 21), and calls it again directly
as `h 100` (105), for 126.

The logged total is 34 + 126 = 160.

## eco

Exercises the loopification guards of the HOF-elimination work
(plans/hof-elimination-closure-alloc-reduction.md) with shapes that must stay correct:

`keepBoth` stores its function parameter (returns it in the tuple), so the
parameter escapes and the eligibility analysis refuses to specialize it; its
lambda keeps allocating.

`applyVar`'s `List.foldl` lambda is a literal and is loopified, but it
captures `h`, a let-bound closure used more than once (also called directly as
`h 100`), so a captured closure variable must survive loopification with
correct sharing.

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
