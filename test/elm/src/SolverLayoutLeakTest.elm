module SolverLayoutLeakTest exposing (main)

{-| SENTINEL documenting the solver engine's demand-healing channels
(GREEN under both engines — deliberately).

Inside the tail-recursive `foldGo`, the destructured indirect-call
result carries an ERASED recorded type ( State, eco ) (see
SolverLayoutFoldMTest). This test pins down that the erasure does NOT
leak into `sinkSecond`'s spec demand: passing the call result as a
call ARGUMENT heals the demand through `unifyParamsWithArgExprs` (the
use-site canonical types belong to the connected family), so
`sinkSecond` is specialized concrete (tuple2:v:i, raw slot read) and
the program computes correctly. Verified 2026-07-13: sinkSecond's spec
logical types are concrete under ECO_MONO_ENGINE=solver.

If this test starts failing under the solver engine, a healing channel
regressed (or a new erased-demand channel opened) — see
plans/solver-layout-connectivity-reconciliation.md.

`sinkSecond` is self-recursive (fuel) so the inliner cannot dissolve
the spec boundary. `f` is called twice per element; State is a pure
record and `step` is deterministic, so both calls agree and the
expected output equals the plain fold.
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
