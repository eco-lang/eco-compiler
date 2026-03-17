module ClosureCaptureBoolTest exposing (main)

{-| Test Bool captured in a closure via partial application.

A Bool value is captured in a closure (papCreate). Per REP_CLOSURE_001 and
FORBID_CLOSURE_001, Bool must be stored as !eco.value in closures, NOT as
bare i1. This test triggers the bug where the codegen produces an i1 capture
operand with unboxed_bitmap=0, creating a type mismatch (the runtime sees
the bit as "boxed pointer" but receives a bare i1 scalar).

The pattern: a function takes a Bool and an Int, partially applied with
just the Bool to create a closure, then the closure is called with the Int.
-}

-- CHECK: when_true: 1
-- CHECK: when_false: 0

import Html exposing (text)


boolToInt : Bool -> Int -> Int
boolToInt flag dummy =
    if flag then
        1
    else
        0


main =
    let
        trueF =
            boolToInt True

        falseF =
            boolToInt False

        _ = Debug.log "when_true" (trueF 0)
        _ = Debug.log "when_false" (falseF 0)
    in
    text "done"
