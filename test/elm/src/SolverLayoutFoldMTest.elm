module SolverLayoutFoldMTest exposing (main)

{-| REPRODUCER for the solver-engine layout-connectivity bug
(plans/solver-layout-connectivity-reconciliation.md): faithful
transplant of System.TypeCheck.IO.foldMGo. Under ECO_MONO_ENGINE=solver
(LSS off) this item records the indirect-call destructure root as the
ERASED `T(R{count:I}, eco)` while its own leaf `b` classifies concrete
`I` and the demand is concrete (b := Int) — the TailDef/TCO-rebuilt
call-node type family is never connected to the demand-seeded
annotation family (verified by tracing, 2026-07-13).

The test is GREEN today only because Patterns.generateMonoPathHelper's
raw-slot reconcile arm masks the disagreement at emission. Verified
reproduction procedure: revert that arm to a boxed-load + unbox and this
test SIGSEGVs in the E2E harness under ECO_MONO_ENGINE=solver (raw i64
slot dereferenced as an HPointer — the original self-compile foldMGo
crash) while passing under subst. It is the regression sentinel for
that arm.
-}

-- CHECK: SolverLayoutFoldM: 10104

import Html exposing (text)


type alias State =
    { count : Int }


foldMGo : (b -> a -> State -> ( State, b )) -> b -> List a -> State -> ( State, b )
foldMGo f acc list s0 =
    case list of
        [] ->
            ( s0, acc )

        a :: rest ->
            let
                ( s1, b ) =
                    f acc a s0
            in
            foldMGo f b rest s1


step : Int -> Int -> State -> ( State, Int )
step total x st =
    ( { count = st.count + 1 }, total + x )


main =
    let
        ( finalState, total ) =
            foldMGo step 0 [ 1, 2, 3, 4 ] { count = 100 }

        _ =
            Debug.log "SolverLayoutFoldM" (total * 1000 + finalState.count)
    in
    text "done"
