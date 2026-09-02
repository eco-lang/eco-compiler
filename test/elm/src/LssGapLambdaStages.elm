module LssGapLambdaStages exposing (main)

{-| LSS gap probe — the THREE lambda-stage shapes that closed M2 unbuilt
(plans/lss-var-chain-roots.md §9.13/§9.14), isolated as small code.

Read the analysis outcome with:
ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1 ... 2>&1 | grep '^pos|'

**(1) `mkAdd3` — the ANCHORING KILLER: an arity-2 lambda body whose result
is ITSELF a closure.** The literal `\a b -> \c -> a + b + c` has params
[a,b] and a THREE-arrow type `Int -> Int -> (Int -> Int)`. LSS_013 spine
injection writes the lambda's OWN mid on arrows 1..2 (its stages: "a PAP
of m is still m") and MUST STOP there — arrow 3 is inhabited by the
returned `\c` closure (`q`), a different value with its own `l|` mid. The
type alone CANNOT distinguish this from an arity-3 lambda; only the
param count anchors the boundary, and only at the lambda's own
translation (stage 0 by construction). Any settle-time pass reading a
row FRAGMENT — say the stage-1 value's type `Int -> (Int -> Int)` —
cannot tell "one more stage of m" from "q's arrow": filling it with m
would be a FALSE member. This is why the own-mid hole-fill died.

**(2) `useStage` — the STAGE FRAGMENT: a PAP of the multi-param lambda
crossing a definition boundary.** `mkAdd3v 1` constructs the stage-1
value; `useStage` receives it at type `Int -> (Int -> Int)`. Whatever
`useStage`'s row shows at `/a0` and `/a0/r` documents how well the
stage identity travels: `/a0` head should carry m (LSS_013 transport);
`/a0/r` is q's arrow — m there would be the false member.

**(3) `pickyWrap` — the varLambda BLOCKED CELL: one lambda mid, two
instantiations, ONE contaminated.** `\x -> pick x` has an arity-1 head
whose RESULT is an arrow — exactly the `bodyVar` class. Its result set
comes from `pick`'s row; `pick` branches between a named top-level
function and a locally-built closure, so across instantiations the
lambda-home cell for `/r` collects disagreeing/incomplete evidence and
the `varLambda` strict cell BLOCKS the write (varlam|blocked). The row
keeps `var` at the position — honestly: writing either branch's set
alone would under-approximate.

**MEASURED (2026-09-02, LPartial + flowConnect defaults):** at PROBE
scale all three shapes come back 100 % covered and SOUNDLY named —
var = 0, ⊤ = 0:

    pos|mkAdd3v||k1:g;…mkAdd3v          head = the global
    pos|mkAdd3v|/r|kN                    stage arrow: honest multi-member
    pos|mkAdd3v|/r/r|kN                  q's arrow: multi-member, NOT m
    pos|useStage|/a0|k1:p;…mkAdd3v;1     the stage-1 fragment, NAMED —
                                         the p|g|1 successor anchors it
    pos|useStage|/a0/r|k1:m<inner>       q's arrow = the INNER lambda's
                                         own mid (flowConnect delivered)
                                         — exactly the sound outcome
    pos|pickyWrap|/a0|k1:l;…             the wrapper lambda per spec
    pos|pickyWrap|/a0/r|kN               BOTH branch closures (double +
                                         \y) — honest 2-set, unblocked

And the emitted MLIR lowers every probe site to DIRECT calls +
papCreates (`eco.call @…mkAdd3v_$_1(i64,i64)`, `eco.papCreate` for the
stage value and both pick branches) — no generic apply.

**What this means:** the shapes are handled correctly IN-ITEM. The
corpus residue (stageVar = 142, bodyVar = 274) is what remains when
these same row shapes are split across item/spec boundaries and the
transport of exactly these positions fails — the §5.1 lesson again:
one-module probes document the sound baseline; corpus counters measure
the transport losses. These rows are the reference for what the 142/274
SHOULD look like when construction-anchored repairs reach them.

-}

import Html exposing (text)


{-| Shape (1): arity-2 lambda returning a closure — 3-arrow spine,
LSS_013 boundary between arrow 2 (stage of m) and arrow 3 (q's).
-}
mkAdd3v : Int -> Int -> (Int -> Int)
mkAdd3v =
    \a b -> \c -> a + b + c


{-| Shape (2): consumes the STAGE-1 fragment across a definition
boundary. `/a0` = the fragment's head (stage of m); `/a0/r` = q's arrow.
-}
useStage : (Int -> (Int -> Int)) -> Int -> Int
useStage f n =
    (f n) 10


{-| Shape (3) support: a result that is one of TWO closures depending on
data — the honest multi-inhabitant / incomplete-evidence generator.
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


{-| Shape (3): the arity-1 lambda whose body-result cell contaminates —
the `bodyVar`/varlam|blocked class.
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
