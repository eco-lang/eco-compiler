module MergeProbe exposing (main)

{-| H6.1 F3 pin: `<|`-styled partial application of a POINT-FREE alias
(kernel alias `Bitwise.and` and a user alias of it) merges into a
saturated call and intrinsifies (`eco.int.and`), exactly like the
direct-call style. Pre-F3, `specArities` only covered closure-literal
defines, so `calleeArity` returned Nothing for these specs and each
styled call emitted `papCreate + papExtend + papExtend` — the
Array.setHelp shape that dominated the H6.0 extends census. Kernel types
are stored STAGED; the merge bound is the FLAT arity (the convention the
emitted wrapper and papCreate `arity` attr use). This module compiles
with `partialMerges=2` under ECO_INLINE_REPORT.
-}

import Bitwise
import Html exposing (text)

-- CHECK: results: (3, 6)


userAnd : Int -> Int -> Int
userAnd =
    Bitwise.and


kernelStyled : Int -> Int
kernelStyled x =
    Bitwise.and 7 <| Bitwise.shiftRightZfBy 1 x


userStyled : Int -> Int
userStyled x =
    userAnd 15 <| Bitwise.shiftRightZfBy 1 x


main =
    let
        _ =
            Debug.log "results" ( kernelStyled 22, userStyled 44 )
    in
    text "done"
