module SolverLayoutErasedThreadTest exposing (main)

{-| A polymorphic recursive function that threads a tuple `( State, a )` returns the caller's `Int` unchanged in the tuple's second position.

`threadN` uses the type variable `a` only as the second element of the tuple it
takes and returns. It destructures the tuple, increments the record's `count`
and recurses, `n` times. `main` calls it with `n = 3` and `( { count = 0 }, 42 )`
and prints `v * 1000 + count`, so the expected 42003 means the value 42 came
back intact and `count` reached 3.

## eco

A layout probe for the solver monomorphization engine
(compiler/src/Compiler/Monomorphize/Solver/Translate.elm). `a` appears only in
tuple-element position, the layout-erasure shape allowed by MONO_003 in
design_docs/invariants.csv, so a spec of `threadN` may legitimately keep that
slot erased (boxed).

The caller builds the tuple itself with a concrete `Int` (a raw `i64` slot). If
the caller's layout and the callee's possibly erased view disagree, the
destructure inside `threadN` misreads the slot.

-}

-- CHECK: SolverLayoutErasedThread: 42003

import Html exposing (text)


type alias State =
    { count : Int }


threadN : Int -> ( State, a ) -> ( State, a )
threadN n pair =
    if n <= 0 then
        pair

    else
        let
            ( s, x ) =
                pair
        in
        threadN (n - 1) ( { count = s.count + 1 }, x )


main =
    let
        ( finalState, v ) =
            threadN 3 ( { count = 0 }, 42 )

        _ =
            Debug.log "SolverLayoutErasedThread" (v * 1000 + finalState.count)
    in
    text "done"
