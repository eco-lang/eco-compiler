module ConstThunkFoldTest exposing (main)

{-| Constant-thunk folding (CGEN\_082,
plans/mlir-split-backend-04-constant-thunks.md T5): every reference to a
constant top-level value emits the value's own body instead of an `eco.call`
to its thunk — literals (phase 1), an alias chain (phase 1), the kernel
constant `pi`, and closed pure-arithmetic bodies (phase 2A), including the
`logBase` shape of elm/core's `Array.shiftStep` and the shift of `bitMask`.

R2 pin: `compute`'s own let group binds `base` and `number`, and `letLike`'s
folded body binds `base` too. The folded body is emitted under a fresh lexical
scope, so neither name may leak into, or reuse a placeholder of, the caller's
let group.

compute 1000 = modBy 67108864 (1000 * 5) + (21 + and 31 1000) = 5000 + 29.

-}

-- CHECK: compute: 5029
-- CHECK: lits: (67108864, 2.5, 'q')
-- CHECK: bool: True
-- CHECK: unit: ()
-- CHECK: shift: (5, 31, 21)
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
