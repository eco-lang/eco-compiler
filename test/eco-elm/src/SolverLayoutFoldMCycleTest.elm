module SolverLayoutFoldMCycleTest exposing (main)

{-| A monadic fold written as a pair of mutually recursive functions threads a state record and an `Int` accumulator correctly.

`goA` and `goB` each handle one element: they call the step function `f` with
the accumulator, the element and the state, destructure the `( State, b )` it
returns, and pass the rest of the list to the other function. `step` adds the
element to the accumulator and increments `count`. Folding `[ 1, 2, 3, 4 ]` from
0 with `count = 100` gives a total of 10 and a count of 104, printed as
`total * 1000 + count`, which is 10104.

## eco

The mutual-recursion twin of test/eco-elm/src/SolverLayoutFoldMTest.elm:
specialization takes the solver's cycle path (`specializeCycleFuncDef` in
compiler/src/Compiler/Monomorphize/Solver/Translate.elm), as the compiler's own
`foldMGo` does inside a large SCC.

It carries the same recorded-type inconsistency (an erased destructure root
against a concrete leaf), which the raw-slot reconcile arm of
`generateMonoPathHelper` in compiler/src/Compiler/GenerateMlir/Patterns.elm
masks. With that arm reverted to a boxed load, this test crashed under the
solver engine while passing under subst (plans/solver-layout-connectivity-reconciliation.md).

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
