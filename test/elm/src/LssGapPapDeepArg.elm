module LssGapPapDeepArg exposing (main)

{-| Q1(c1) probe: `injectPapMember` is HEAD-ONLY by identity (Translate.elm —
"one arrow deeper it is a DIFFERENT PAP"). `add3 10` is declared 3 / supplied 1,
residual depth 2: `p|add3|1` lands on `/a0`, `/a0/r` stays var, and
`papInject|deep|d2` bumps. The depth-1 control `add2 10` must be fully covered.

Expect: pos|useIt|/a0/r|var; no var rows for useOne.
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
