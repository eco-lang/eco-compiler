module SolverLayoutErasedThreadTest exposing (main)

{-| Solver layout probe: the type var `a` appears ONLY in tuple-element
position of `threadN`'s signature — the MONO_003 layout-erasure shape
where a spec may legitimately stay erased (boxed element). The caller
supplies a concrete Int witness (42) and builds the tuple itself: if the
caller's constructed layout (raw i64 slot) and the callee's possibly
erased view (boxed slot) disagree, the destructure inside `threadN`
misreads the slot.
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
