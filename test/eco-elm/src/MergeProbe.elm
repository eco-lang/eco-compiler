module MergeProbe exposing (main)

{-| A two-argument function applied to one argument and then, with `<|`, to a second computed argument gives the same result whether the function is `Bitwise.and` itself or a top-level value defined as `Bitwise.and` without parameters.

`kernelStyled 22` computes `Bitwise.and 7 <| Bitwise.shiftRightZfBy 1 22`,
which is `11` masked to `3`. `userStyled 44` does the same through `userAnd`
with mask `15`: `22` masked to `6`.

## eco

Exercises partial-application merging in the inliner
(compiler/src/Compiler/MonoOpt/InlineSimplify.elm). A `<|`-style partial application of a
point-free alias, the kernel `Bitwise.and` or a user alias of it, must merge into a saturated
call and become the `eco.int.and` intrinsic, as the direct call does. Before `specArities` covered
point-free defines, `calleeArity` found no arity for these and each call emitted `papCreate`
followed by two `papExtend`s, the shape of `Array.setHelp`. Kernel types are stored staged, so the
merge bound is the flat arity. With `ECO_INLINE_REPORT` this module reports `partialMerges=2`
(compiler/src/Builder/Generate.elm).

-}

import Bitwise
import Html exposing (text)

-- CHECK: results: (3,6)


{-| `Bitwise.and` under a new name, defined without parameters.
-}
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
