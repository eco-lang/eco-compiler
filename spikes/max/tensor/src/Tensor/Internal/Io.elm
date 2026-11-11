module Tensor.Internal.Io exposing (widenSlot, narrowIn, unnarrow, isScalarSlot)

{-| Graph inputs at the host boundary. MAX's C API takes no rank-0 inputs, so a scalar input slot is
declared `[1]` (`widenSlot`), reshaped to `[]` where the graph reads it (`narrowIn`), and found again
by a signature's round trip through that reshape (`unnarrow`). Outputs may be rank 0.
-}

import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P
import Tensor.Internal.Types as I


isScalarSlot : I.Slot -> Bool
isScalarSlot sl =
    sl.shape == Just []


{-| A rank-0 slot as `[1]`; any other slot unchanged.
-}
widenSlot : I.Slot -> I.Slot
widenSlot sl =
    if isScalarSlot sl then
        { sl | shape = Just [ 1 ] }

    else
        sl


{-| The value a graph reads for an input of slot `sl` (before widening): the `[1]` input reshaped
to `[]` for a scalar slot, the input itself otherwise.
-}
narrowIn : I.Slot -> Expr -> Expr
narrowIn sl e =
    if isScalarSlot sl then
        O.reshape [] e

    else
        e


{-| The input a narrowed scalar came from (so a signature's round trip finds the input again).
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
