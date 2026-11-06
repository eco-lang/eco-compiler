module LssGapLambdaStages exposing (main)

{-| Functions whose results are themselves functions can be partially applied,
passed on, and called with their remaining arguments.

  - `stageFragment`: `mkAdd3v` is a two-parameter lambda returning a
    one-parameter lambda. `mkAdd3v 1` is passed to `useStage`, which applies
    it to 2 and then 10, printing 1 + 2 + 10 = 13.
  - `blockedCell`: `pick` returns `double` for a positive argument and
    `\y -> y - x` otherwise. `pickyWrap` receives `\x -> pick x` and applies
    it to a seed and then 7: seed 3 gives 7 * 2 = 14 and seed -4 gives
    7 + 4 = 11, printing 25.

## eco

A lambda-set specialization (LSS) probe isolating three lambda-stage shapes
from the var-chain roots work (plans/lss-var-chain-roots.md). Read with
`ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1`, grep `^pos|`.

`mkAdd3v` is an arity-2 lambda whose result is itself a closure. Spine injection
(LSS_013 in design_docs/invariants.csv) writes the lambda's own member on arrows
1 and 2 and must stop there: arrow 3 belongs to the returned inner closure. The
type alone cannot tell this from an arity-3 lambda; only the parameter count
anchors the boundary. `useStage` receives the stage-1 value `mkAdd3v 1` across
a definition boundary: `/a0` should name the stage of `mkAdd3v`, and `/a0/r`
must be the inner lambda, not `mkAdd3v`. `pickyWrap` receives an arity-1 lambda
whose result comes from `pick`, which branches between a global and a local
closure, so the honest result set has two members.

At probe scale all three shapes come back fully and soundly covered, and the
emitted MLIR lowers every site to direct `eco.call` and `eco.papCreate` with no
generic apply; the corpus residue appears only when these shapes are split
across item boundaries.

-}

import Html exposing (text)


{-| Adds three Ints, written as a two-parameter lambda returning a
one-parameter lambda.
-}
mkAdd3v : Int -> Int -> (Int -> Int)
mkAdd3v =
    \a b -> \c -> a + b + c


{-| Applies `f` to `n` and then applies the resulting function to 10.
-}
useStage : (Int -> (Int -> Int)) -> Int -> Int
useStage f n =
    (f n) 10


{-| Doubles an Int.
-}
double : Int -> Int
double n =
    n * 2


pick : Int -> (Int -> Int)
pick x =
    if x > 0 then
        double

    else
        \y -> y - x


{-| Applies `g` to `seed` and then applies the resulting function to 7.
-}
pickyWrap : (Int -> (Int -> Int)) -> Int -> Int
pickyWrap g seed =
    (g seed) 7


main =
    let
        _ =
            Debug.log "stageFragment" (useStage (mkAdd3v 1) 2)

        _ =
            Debug.log "blockedCell" (pickyWrap (\x -> pick x) 3 + pickyWrap (\x -> pick x) (negate 4))
    in
    text "hello"



-- CHECK: stageFragment: 13
-- CHECK: blockedCell: 25
