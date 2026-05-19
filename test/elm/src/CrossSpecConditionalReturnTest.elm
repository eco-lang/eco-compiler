module CrossSpecConditionalReturnTest exposing (main)

{-| Phase 3.4 #1 end-to-end fixture: `pick` returns a 2-tuple chosen by
`if … then … else …`. The Elm front-end lowers the `if` to `eco.case`
with `case_kind = "bool"` and two alternatives each yielding an
`eco.construct.tuple2`. Pre-Phase 3.4 the return operand was the
case's result and couldn't be promoted. Phase 3.4 walks both
alternatives, retypes the join chain, and emits `pick$unboxed`
returning a tuple of scalars; the wrapper rebuilds and re-boxes.

-}

-- CHECK: result: 11


import Html exposing (text)


pick : Bool -> Int -> Int -> ( Int, Int )
pick c a b =
    if c then
        ( a, b )

    else
        ( b, a )


main =
    let
        ( x, y ) =
            pick True 7 4

        _ =
            Debug.log "result" (x + y)
    in
    text "done"
