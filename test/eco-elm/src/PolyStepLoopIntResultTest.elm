module PolyStepLoopIntResultTest exposing (main)

{-| A polymorphic state-threading loop, driven by a `Step state a` custom type,
returns an `Int` result and the threaded state correctly.

`IO a` is a function from an `Int` state to a pair of the new state and a
result. `loop` calls its callback until it returns `Done`, then returns the
final state paired with the value carried by `Done`. `countdown` counts from 5
down to 0, adding each count to the state, and finishes with `Done 42`, so the
result is 42 and the state 5 + 4 + 3 + 2 + 1 + 0 = 15.

## eco

Reproduces a stage-6 MLIR parse failure from compiling
`System.TypeCheck.IO.loop` with `a = Int`. With `Step` specialized so `a` is an
unboxed `Int`, the `Done` branch builds a tuple whose second field is unboxed.
Codegen emitted `eco.project.custom` for the `Done` field with result type
`!eco.value` while the enclosing `eco.construct.tuple2` declared that field
`i64`, and MLIR rejected the use with "expects different type than prior
uses: 'i64' vs '!eco.value'". The fix lives in `generateDestruct`
(compiler/src/Compiler/GenerateMlir/Expr.elm) and the tail-recursion path
(compiler/src/Compiler/GenerateMlir/TailRec.elm).

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
