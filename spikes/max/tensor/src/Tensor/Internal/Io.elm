module Tensor.Internal.Io exposing (isScalarSlot, narrowIn, unnarrow, widenSlot)

{-| Lets a graph take a scalar input in the form MAX's C API accepts. The package assumes that
API takes no rank-0 inputs, so a scalar input this module adapts is declared with shape `[1]` and
reshaped to `[]` inside the graph.

To _widen_ a slot (`widenSlot`) is to declare it `[1]` where it
declared `[]`. To _narrow_ an input (`narrowIn`) is to reshape the `[1]` input to `[]`, so that the
value built from the graph's inputs holds the rank-0 tensor its signature describes. To _unnarrow_
(`unnarrow`) is to undo that reshape, which the signature's `flatten` needs: `Graph.build` checks
that flattening the value built from its inputs gives back those same inputs, and after narrowing
the value holds the reshapes instead.

`Graph.build` widens nothing, so a scalar input is `[1]` only where the signature given to
`Graph.build` declares it so. Only inputs are involved; nothing here touches a graph's outputs.

-}

import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P
import Tensor.Internal.Types as I


{-| Returns `True` when `sl` declares the shape `[]`, and `False` when it declares any other shape
or none.
-}
isScalarSlot : I.Slot -> Bool
isScalarSlot sl =
    sl.shape == Just []


{-| Returns `sl` declaring the shape `[1]` when it declares `[]`, and `sl` unchanged otherwise.
-}
widenSlot : I.Slot -> I.Slot
widenSlot sl =
    if isScalarSlot sl then
        { sl | shape = Just [ 1 ] }

    else
        sl


{-| Returns `e` reshaped to `[]` when `sl` declares `[]`, and `e` itself otherwise.

`sl` is the slot as declared, before `widenSlot`. Given the widened slot, which declares `[1]`, this
returns `e` unchanged.

-}
narrowIn : I.Slot -> Expr -> Expr
narrowIn sl e =
    if isScalarSlot sl then
        O.reshape [] e

    else
        e


{-| Returns the operand of `e` when `e` is a reshape from `[1]` to `[]`, and `e` itself otherwise.

This undoes `narrowIn` on a `[1]` input. Applied in a signature's `flatten`, it lets flattening a
value built from narrowed inputs give back the inputs themselves. It recognises any reshape from
`[1]` to `[]`, whether or not `narrowIn` made it.

-}
unnarrow : Expr -> Expr
unnarrow e =
    case E.op e of
        E.P P.Reshape [ x ] _ ->
            if E.shape e == [] && E.shape x == [ 1 ] then
                x

            else
                e

        _ ->
            e
