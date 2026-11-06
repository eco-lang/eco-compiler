module PolyStepLoopFoldMIntTest exposing (main)

{-| A monadic fold, `foldM`, built on a polymorphic `Step`-driven state loop, sums
a list of `Int`s and threads its state correctly.

`IO a` is a function from an `Int` state to a pair of the new state and a
result. `foldM` runs `loop` over a `( List a, b )` pair whose `Done` value is
the accumulator `b`, here an `Int`. `addM` adds each element to the accumulator
and increments the state, so folding `[ 1, 2, 3, 4, 5 ]` from state 99 gives a
sum of 15 and a final state of 104.

-}

-- CHECK: sum: 15
-- CHECK: final: 104

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


foldM : (b -> a -> IO b) -> b -> List a -> IO b
foldM f b list =
    loop (foldMHelp f) ( list, b )


foldMHelp : (b -> a -> IO b) -> ( List a, b ) -> IO (Step ( List a, b ) b)
foldMHelp callback ( list, result ) =
    case list of
        [] ->
            \s -> ( s, Done result )

        x :: rest ->
            \s ->
                let
                    ( s2, newAcc ) =
                        callback result x s
                in
                ( s2, Loop ( rest, newAcc ) )


addM : Int -> Int -> IO Int
addM acc x s =
    ( s + 1, acc + x )


main =
    let
        ( final, sum ) =
            foldM addM 0 [ 1, 2, 3, 4, 5 ] 99

        _ =
            Debug.log "sum" sum

        _ =
            Debug.log "final" final
    in
    text "done"
