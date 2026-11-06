module CrossSpecTupleEscapesTest exposing (main)

{-| A function that puts its tuple argument into a list, rather than taking it
apart, returns a list whose element is that tuple.

`boxPair ( 7, 23 )` returns `[ ( 7, 23 ) ]`; matching the head of the list and
then its first component gives the expected result, 7.

## eco

Negative case: the tuple parameter flows into `List.singleton`, an escaping use that is not a projection, so `boxPair` must not be specialised. The CHECK-NOT line asserts that no `boxPair$unboxed` worker appears.

The cross-function aggregate unboxing pass that this fixture was written for (`EcoUnboxedAggCrossSpec`, enabled by `-enable-unboxed-agg`) was deleted in 2026-06; the test is kept as behavioural coverage for the aggregate promotion work (plans/opt-tier1-aggregate-promotion.md). Whatever ABI the back end picks, the result must match the boxed heap path.

-}

-- CHECK: result: 7
-- CHECK-NOT: boxPair$unboxed


import Html exposing (text)


boxPair : ( Int, Int ) -> List ( Int, Int )
boxPair pair =
    [ pair ]


main =
    let
        result =
            case boxPair ( 7, 23 ) of
                p :: _ ->
                    case p of
                        ( a, _ ) ->
                            a

                [] ->
                    0

        _ =
            Debug.log "result" result
    in
    text "done"
