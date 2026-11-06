module SolverLayoutFoldMTest exposing (main)

{-| A polymorphic, tail-recursive monadic fold threads a state record and an `Int` accumulator correctly.

`foldMGo` calls the step function `f`, which is a parameter, with the
accumulator, the current element and the state, destructures the
`( State, b )` it returns, and recurses on the rest of the list. `step` adds the
element to the accumulator and increments `count`. Folding `[ 1, 2, 3, 4 ]` from
0 with `count = 100` gives a total of 10 and a count of 104, printed as
`total * 1000 + count`, which is 10104.

## eco

A transplant of the compiler's own `foldMGo` and the reproducer for the
solver-engine layout-connectivity bug (plans/solver-layout-connectivity-reconciliation.md).
Under the solver engine, with lambda-set specialization off, the destructure
root of the indirect call `f acc a s0` was recorded as the erased
`( State, eco.value )` while its leaf `b` and the demand were concrete `Int`:
the tail-call-rebuilt call-node types were never connected to the demand-seeded
annotation types.

The test passes because the raw-slot reconcile arm of `generateMonoPathHelper`
in compiler/src/Compiler/GenerateMlir/Patterns.elm masks the disagreement at
emission. Reverting that arm to a boxed load plus unbox makes it crash (a raw
`i64` slot dereferenced as a heap pointer, the original self-compile crash), so
this is the regression sentinel for that arm.

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
