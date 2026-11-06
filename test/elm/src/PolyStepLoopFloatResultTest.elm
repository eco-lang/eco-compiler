module PolyStepLoopFloatResultTest exposing (main)

{-| A polymorphic state-threading loop, driven by a `Step state a` custom type,
returns a `Float` result and the threaded state correctly.

`IO a` is a function from an `Int` state to a pair of the new state and a
result. `loop` calls its callback until it returns `Done`, passing the state
along. `countdown` counts 3, 2, 1, 0, adding each count to the state, and
finishes with `Done 3.14`, so the result is 3.14 and the state 0 + 3 + 2 + 1 + 0
= 6. `PolyStepLoopIntResultTest` is the same program with an `Int` result.

-}

-- CHECK: result: 3.14
-- CHECK: state: 6

import Html exposing (text)


type Step state a
    = Loop state
    | Done a


type alias IO a =
    Int -> ( Int, a )


loop : (state -> IO (Step state a)) -> state -> IO a
loop callback loopState ioState =
    case callback loopState ioState of
        ( newIOState, Loop newLoopState ) ->
            loop callback newLoopState newIOState

        ( newIOState, Done a ) ->
            ( newIOState, a )


countdown : Int -> IO (Step Int Float)
countdown n s =
    if n == 0 then
        ( s + n, Done 3.14 )

    else
        ( s + n, Loop (n - 1) )


main =
    let
        ( finalState, result ) =
            loop countdown 3 0

        _ =
            Debug.log "result" result

        _ =
            Debug.log "state" finalState
    in
    text "done"
