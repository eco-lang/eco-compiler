module CrossSpecChainedReturnsTest exposing (main)

{-| Phase 3.1 end-to-end positive integration test.

Combines three Phase 3.1 features through a single Elm program:

1. **Result-side unboxing (Commit 4):** `bumpPair` returns a tuple
   built via construct.
2. **Call-result fixpoint propagation (Commit 5 + relaxed
   eligibility):** `widenPair` returns whatever `bumpPair` returned
   without rebuilding it — its return is fed by an eligible-callee
   call result, which only specialises if the fixpoint admits the
   call-result-passthrough case.
3. **Param-side unboxing:** `sumPair` projects the tuple at the
   bottom of the chain.

Compiled with `-enable-unboxed-agg`, all three top-level helpers
should get `$unboxed` workers and the chain should call through
workers end-to-end. Behaviour must match the boxed path either way.

Compute: widenPair 3 = bumpPair (3*2) = bumpPair 6 = (6, 7);
sumPair (6, 7) = 13.

-}

-- CHECK: result: 13


import Html exposing (text)


bumpPair : Int -> ( Int, Int )
bumpPair n =
    ( n, n + 1 )


widenPair : Int -> ( Int, Int )
widenPair n =
    bumpPair (n * 2)


sumPair : ( Int, Int ) -> Int
sumPair pair =
    case pair of
        ( a, b ) ->
            a + b


main =
    let
        result =
            sumPair (widenPair 3)

        _ =
            Debug.log "result" result
    in
    text "done"
