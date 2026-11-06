module StagedResultTest exposing (main)

{-| A recursive function whose annotated result is itself a function, `mk : Int -> (Int -> Int)`, can be applied to two arguments at once.

`mk a` returns `\b -> b + 1000` when `a <= 0`, `\b -> a + b` when `a` is even
and positive, and otherwise recurses on `a - 1`. `use n` applies it as
`mk n (n * 10)`:

  - `use 4` is `4 + 40 = 44`.
  - `use 3` recurses to `mk 2`, giving `2 + 30 = 32`.
  - `use 0` is `0 + 1000 = 1000`.

## eco

Written as the reproducer for the staged-result type-flattening bug
(plans/hof-elimination-closure-alloc-reduction.md). `mk n (n * 10)` is a
two-stage application. Monomorphization flattened the spec type of `mk` to
`(i64) -> (i64)`, dropping the middle arrow, so when `SaturatedPapToCallPattern`
in runtime/src/codegen/Passes/EcoPAPSimplify.cpp emitted a direct call to that
spec, LLVM translation failed with `result type mismatch: ptr != i64`. The fix
belongs in the producer-side spec typing (`peelCallResult` in
compiler/src/Compiler/Monomorphize/Subst/Specialize.elm).

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
