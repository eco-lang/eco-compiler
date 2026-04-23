module PolyStepLoopFoldMIntTest exposing (main)

{-| Closer reproduction of the `System.TypeCheck.IO.foldM` / `loop`
    call shape that fails to lower at stage 6 of the bootstrap.

    `foldM` builds a `Step (List a, b) b` machine driven by `loop`.
    Specializing with `b = Int` instantiates `Done b` as `Done Int`, so
    the `a` slot of `Step` is unboxed. The faulty codegen path emits
    `eco.project.custom` for the `Done` field as `!eco.value` but
    constructs the final `(newIOState, b)` tuple with `bitmap` claiming
    field 1 is unboxed `i64`.

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
