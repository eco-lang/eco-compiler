module Tensor.Control exposing (cond, whileLoop, scan, repeat)

{-| Control flow inside a graph.

`cond` and `whileLoop` run in MAX (`mo.if`, `mo.while`); `repeat` and `scan` are unrolled when the
graph is built (as Nabla's scan is), so they differentiate like straight-line code.

-}

import Signature exposing (Sig)
import Tensor as T exposing (Mask, R0, Tensor)
import Tensor.Internal.Batch as B
import Tensor.Internal.Control as C
import Tensor.Internal.Types as I


{-| `cond pred sigA sigB whenTrue whenFalse a`.
-}
cond : Mask R0 -> Sig a -> Sig b -> (a -> b) -> (a -> b) -> a -> b
cond (I.Mask p) sa sb t f a =
    C.cond p sa sb t f a


{-| Repeat `body` while `continue` holds. Forward only: a graph that differentiates through it is
refused when built (use `repeat` for a fixed count).
-}
whileLoop : Sig s -> (s -> Mask R0) -> (s -> s) -> s -> s
whileLoop ss continue body init =
    C.whileLoop ss (continue >> (\(I.Mask m) -> m)) body init


{-| `body` applied `n` times, unrolled.
-}
repeat : Int -> Sig s -> (s -> s) -> s -> s
repeat n _ body init =
    List.foldl (\_ s -> body s) init (List.range 1 n)


{-| `f` carried over the leading axis of `xs`, unrolled: the final carry and the stacked outputs.
-}
scan : T.Lift n x xs -> T.Lift n y ys -> (c -> Tensor k d x -> ( c, Tensor k2 d2 y )) -> c -> Tensor k d xs -> ( c, Tensor k2 d2 ys )
scan _ _ f c0 xs =
    let
        ( final, outs ) =
            List.foldl
                (\x ( c, acc ) ->
                    let
                        ( c1, y ) =
                            f c (I.Tensor x)
                    in
                    ( c1, I.tensor y :: acc )
                )
                ( c0, [] )
                (B.unstack (I.tensor xs))
    in
    ( final, I.Tensor (B.stack (List.reverse outs)) )
