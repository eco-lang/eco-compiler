module PolyStepLoopFloatResultTest exposing (main)

{-| Float-result variant of the `Step state a` / `loop` bug.

    Same shape as `PolyStepLoopIntResultTest`, but the `a` specialization
    is `Float`. Exercises the same `project.custom` / `construct.tuple2`
    mismatch on a different unboxable primitive — catches a fix that
    only handles `Int`.

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
