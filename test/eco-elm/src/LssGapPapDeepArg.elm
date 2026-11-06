module LssGapPapDeepArg exposing (main)

{-| A function partially applied to one of three arguments can be passed where a two-argument function is expected.

`add3 10` is passed to `useIt`, which applies it to 1 and 2, giving 13. As a comparison,
`add2 10` (one argument of two supplied) is passed to `useOne`, which applies it to 2, giving 12.

## eco

A lambda-set specialization (LSS) probe: PAP member injection in
compiler/src/Compiler/Monomorphize/Solver/Translate.elm is head-only by
identity, since one arrow deeper it is a different PAP. `add3 10` (declared 3,
supplied 1) has residual depth 2: its member lands on `/a0` and `/a0/r` stays
unresolved. `add2 10`, residual depth 1, is the control and must be fully
covered.

Expected census rows (`ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1`):
`pos|useIt|/a0/r|var`, and no `var` rows for `useOne`.

-}

-- CHECK: papDeepArg: 13
-- CHECK: papDeepCtl: 12

import Html exposing (text)


add3 : Int -> Int -> Int -> Int
add3 a b c =
    a + b + c


add2 : Int -> Int -> Int
add2 a b =
    a + b


useIt : (Int -> Int -> Int) -> Int
useIt g =
    g 1 2


useOne : (Int -> Int) -> Int
useOne g =
    g 2


main =
    let
        _ =
            Debug.log "papDeepArg" (useIt (add3 10))

        _ =
            Debug.log "papDeepCtl" (useOne (add2 10))
    in
    text "hello"
