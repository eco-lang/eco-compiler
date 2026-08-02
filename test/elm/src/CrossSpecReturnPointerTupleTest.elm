module CrossSpecReturnPointerTupleTest exposing (main)

{-| Phase 3.3 end-to-end fixture: a helper returns a tuple containing
an `!eco.value`-shaped element. Under `-enable-unboxed-agg` (HISTORICAL — pass deleted 2026-06; kept as behavioral coverage, see plans/opt-tier1-aggregate-promotion.md U-T1.3), the
EcoUnboxedAggCrossSpec pass classifies the result as Sret (mixed-kind
aggregate with at least one heap pointer), promotes the helper to
`makePair$unboxed` with a leading `!llvm.ptr` outparam, and emits the
wrapper that allocates the slot before calling into the worker. The
behaviour must match the pre-promotion heap path: rebuilding the
tuple and projecting it back out yields the original elements.

-}

-- CHECK: result: 11


import Html exposing (text)


{-| Tuple of `(Int, List Int)`. The `List Int` element is boxed
(`!eco.value`), so the result aggregate hits the sret ABI.
-}
makePair : Int -> List Int -> ( Int, List Int )
makePair n xs =
    ( n, xs )


sumHead : ( Int, List Int ) -> Int
sumHead pair =
    case pair of
        ( a, x :: _ ) ->
            a + x

        ( a, [] ) ->
            a


main =
    let
        _ =
            Debug.log "result" (sumHead (makePair 7 [ 4, 5, 6 ]))
    in
    text "done"
