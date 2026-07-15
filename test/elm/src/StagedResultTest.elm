module StagedResultTest exposing (main)

{-| Repro for the staged-result type-flattening bug (plan
`hof-elimination-closure-alloc-reduction.md`, H6.2 Layer 2 — OPEN).

`mk : Int -> (Int -> Int)` is a recursive STAGED-RESULT function: applying it
to one `Int` returns a closure `Int -> Int`, so `mk n (n * 10)` is a two-stage
application. Monomorphization flattens the spec type of `mk` to `(i64) -> (i64)`,
dropping the middle arrow — it types the spec as returning a plain `Int` when the
body actually returns a closure (a `ptr`). When P1 (`SaturatedPapToCallPattern`,
EcoPAPSimplify) emits a direct call to that spec, LLVM translation fails with
`result type mismatch: ptr != i64`, so this program does not compile/run
correctly until the producer-side spec typing (`peelCallResult` /
demand-flattening in `Specialize.elm`) is fixed.

Expected once fixed: (use 4, use 3, use 0) == (44, 32, 1000).
-}

-- CHECK: use4: 44
-- CHECK: use3: 32
-- CHECK: use0: 1000

import Html exposing (text)


mk : Int -> (Int -> Int)
mk a =
    if a <= 0 then
        \b -> b + 1000

    else if modBy 2 a == 0 then
        \b -> a + b

    else
        mk (a - 1)


use : Int -> Int
use n =
    mk n (n * 10)


main =
    let
        _ =
            Debug.log "use4" (use 4)

        _ =
            Debug.log "use3" (use 3)

        _ =
            Debug.log "use0" (use 0)
    in
    text "done"
