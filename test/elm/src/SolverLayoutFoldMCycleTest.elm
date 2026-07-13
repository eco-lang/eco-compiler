module SolverLayoutFoldMCycleTest exposing (main)

{-| Like SolverLayoutFoldMTest but the fold is a MUTUAL-RECURSION pair, so
specialization takes the solver's cycle path (specializeCycleFuncDef /
_M$ group) — the real foldMGo lives in a large SCC in System.TypeCheck.IO.
Carries the same recorded-type inconsistency (verified: erased destructure
root vs concrete leaf, reconcile arm fires) and the same verified
reproduction: with the Patterns.elm raw-slot arm reverted to a boxed
load, this test SIGSEGVs under ECO_MONO_ENGINE=solver while passing
under subst (harness-verified 2026-07-13).
-}

-- CHECK: SolverLayoutFoldMCycle: 10104

import Html exposing (text)


type alias State =
    { count : Int }


goA : (b -> a -> State -> ( State, b )) -> b -> List a -> State -> ( State, b )
goA f acc list s0 =
    case list of
        [] ->
            ( s0, acc )

        a :: rest ->
            let
                ( s1, b ) =
                    f acc a s0
            in
            goB f b rest s1


goB : (b -> a -> State -> ( State, b )) -> b -> List a -> State -> ( State, b )
goB f acc list s0 =
    case list of
        [] ->
            ( s0, acc )

        a :: rest ->
            let
                ( s1, b ) =
                    f acc a s0
            in
            goA f b rest s1


step : Int -> Int -> State -> ( State, Int )
step total x st =
    ( { count = st.count + 1 }, total + x )


main =
    let
        ( finalState, total ) =
            goA step 0 [ 1, 2, 3, 4 ] { count = 100 }

        _ =
            Debug.log "SolverLayoutFoldMCycle" (total * 1000 + finalState.count)
    in
    text "done"
