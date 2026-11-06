module SolverLayoutLeakTest exposing (main)

{-| A tuple returned by a function parameter inside a polymorphic fold can be passed straight to another polymorphic function, which reads its second element correctly.

`foldGo` is a tail-recursive monadic fold like the one in `SolverLayoutFoldMTest`,
except that it calls `f acc a s0` twice per element. The first result is
destructured for the new state. The second is passed, as a tuple, to
`sinkSecond`, which recurses once on a fuel counter and then returns the tuple's
second element as the new accumulator. `step` is a pure function, so both calls
give the same result. Folding `[ 1, 2, 3, 4 ]` from 0 with `count = 100` gives a
total of 10 and a count of 104, printed as `total * 1000 + count`, which is
10104.

## eco

A sentinel for the solver engine's demand-healing channels; it passes under
both engines on purpose. Inside `foldGo` the destructured indirect-call result
carries an erased recorded type, as in test/eco-elm/src/SolverLayoutFoldMTest.elm.
Passing that result as a call argument heals the demand through
`unifyParamsWithArgExprs` (compiler/src/Compiler/Monomorphize/Solver/Translate.elm),
so `sinkSecond` is specialized concretely with a raw slot read. If this fails
under the solver engine, a healing channel regressed or a new erased-demand
channel opened (plans/solver-layout-connectivity-reconciliation.md).

`sinkSecond` recurses on fuel so the inliner cannot dissolve the spec boundary.

-}

-- CHECK: SolverLayoutLeak: 10104

import Html exposing (text)


type alias State =
    { count : Int }


sinkSecond : Int -> ( State, x ) -> x
sinkSecond fuel ( s, x ) =
    if fuel > 0 then
        sinkSecond (fuel - 1) ( s, x )

    else
        x


foldGo : (b -> a -> State -> ( State, b )) -> b -> List a -> State -> ( State, b )
foldGo f acc list s0 =
    case list of
        [] ->
            ( s0, acc )

        a :: rest ->
            let
                ( s1, _ ) =
                    f acc a s0
            in
            foldGo f (sinkSecond 1 (f acc a s0)) rest s1


step : Int -> Int -> State -> ( State, Int )
step total x st =
    ( { count = st.count + 1 }, total + x )


main =
    let
        ( finalState, total ) =
            foldGo step 0 [ 1, 2, 3, 4 ] { count = 100 }

        _ =
            Debug.log "SolverLayoutLeak" (total * 1000 + finalState.count)
    in
    text "done"
