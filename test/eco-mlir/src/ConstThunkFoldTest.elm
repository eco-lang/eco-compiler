module ConstThunkFoldTest exposing (main)

{-| References to constant top-level values, from plain literals to constants
computed from other constants, give the values those definitions describe.

The constants cover `Int`, `Float`, `Char`, `Bool` and `()` literals, a
constant defined as another constant, `pi`, a `logBase` computation
(`shiftLike`), a `Bitwise.shiftRightZfBy` mask derived from it (`maskLike`),
and a constant with its own `let` (`letLike`). `compute` binds `base` in its
own `let` as `letLike` does, and the two bindings must not interfere.

`compute 1000` is `modBy 67108864 (1000 * 5) + (21 + Bitwise.and 31 1000)`,
which is `5000 + 29`.

## eco

Exercises constant-thunk folding (CGEN_082 in design_docs/invariants.csv; the constant thunk
work in plans/mlir-split-backend-04-constant-thunks.md): every reference to a constant top-level
value emits the value's own body instead of an `eco.call` to its thunk. The constants cover
literals, an alias chain, the kernel constant `pi`, and closed pure-arithmetic bodies, including
the `logBase` shape of elm/core's `Array.shiftStep` and the shift of its bit mask. The
CHECK-MLIR-NOT lines assert no call to any of these thunks remains; the CHECK-MLIR line asserts
the `shiftLike` thunk function is still emitted.

`compute` binding `base` pins scoping: the folded body of `letLike` is emitted under a fresh
lexical scope, so its `base` may neither leak into nor reuse a placeholder of the caller's let
group.

-}

-- CHECK: compute: 5029
-- CHECK: lits: (67108864,2.5,'q')
-- CHECK: bool: True
-- CHECK: unit: ()
-- CHECK: shift: (5,31,21)
-- CHECK: pi: True
-- CHECK-MLIR-NOT: callee = @ConstThunkFoldTest_intLit
-- CHECK-MLIR-NOT: callee = @ConstThunkFoldTest_floatLit
-- CHECK-MLIR-NOT: callee = @ConstThunkFoldTest_charLit
-- CHECK-MLIR-NOT: callee = @ConstThunkFoldTest_boolLit
-- CHECK-MLIR-NOT: callee = @ConstThunkFoldTest_aliasLit
-- CHECK-MLIR-NOT: callee = @ConstThunkFoldTest_shiftLike
-- CHECK-MLIR-NOT: callee = @ConstThunkFoldTest_maskLike
-- CHECK-MLIR-NOT: callee = @ConstThunkFoldTest_letLike
-- CHECK-MLIR-NOT: callee = @ConstThunkFoldTest_piLike
-- CHECK-MLIR: func.func private @ConstThunkFoldTest_shiftLike


import Bitwise
import Html exposing (text)


intLit : Int
intLit =
    67108864


floatLit : Float
floatLit =
    2.5


charLit : Char
charLit =
    'q'


boolLit : Bool
boolLit =
    True


unitLit : ()
unitLit =
    ()


aliasLit : Int
aliasLit =
    intLit


branchLike : Int
branchLike =
    32


shiftLike : Int
shiftLike =
    ceiling (logBase 2 (toFloat branchLike))


maskLike : Int
maskLike =
    Bitwise.shiftRightZfBy (32 - shiftLike) 0xFFFFFFFF


letLike : Int
letLike =
    let
        base =
            7
    in
    base * 3


piLike : Float
piLike =
    pi


compute : Int -> Int
compute n =
    let
        base =
            modBy aliasLit (n * shiftLike)

        number =
            letLike + Bitwise.and maskLike n
    in
    base + number


main =
    let
        _ =
            Debug.log "compute" (compute 1000)

        _ =
            Debug.log "lits" ( intLit, floatLit, charLit )

        _ =
            Debug.log "bool" boolLit

        _ =
            Debug.log "unit" unitLit

        _ =
            Debug.log "shift" ( shiftLike, maskLike, letLike )

        _ =
            Debug.log "pi" (piLike > 3.14)
    in
    text "done"
