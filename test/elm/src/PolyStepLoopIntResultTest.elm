module PolyStepLoopIntResultTest exposing (main)

{-| Reproduces the stage-6 MLIR parse failure seen compiling
    `System.TypeCheck.IO.loop` with `a = Int`.

    A polymorphic `Step state a = Loop state | Done a` is specialized so
    `a` is a primitive `Int`. The tail-recursive `loop` pattern matches
    on the `Step` and, in the `Done` branch, returns a tuple
    `(newIOState, a)` whose second field is unboxed.

    In the bad codegen path, `eco.project.custom` for the `Done` field
    is emitted with result type `!eco.value`, but the enclosing
    `eco.construct.tuple2` declares field 1 as unboxed `i64`. MLIR
    rejects this with:

      error: use of value '%N' expects different type than prior uses:
             'i64' vs '!eco.value'

-}

-- CHECK: result: 42
-- CHECK: state: 15

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


countdown : Int -> IO (Step Int Int)
countdown n s =
    if n == 0 then
        ( s + n, Done 42 )

    else
        ( s + n, Loop (n - 1) )


main =
    let
        ( finalState, result ) =
            loop countdown 5 0

        _ =
            Debug.log "result" result

        _ =
            Debug.log "state" finalState
    in
    text "done"
