module Tensor.Random exposing (Seed, seed, salt, sig, uniform, normal, uniformLike, normalLike, bernoulliLike)

{-| Counter-based randomness: a seed tensor (`ui64 [1]`, a graph input or computed from one) and
salts. Nothing is hidden: the same seed and shape give the same values.
-}

import Signature exposing (Sig)
import Tensor exposing (DType, Floating, I64, Integral, Mask, R0, Shape, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim exposing (DT(..))
import Tensor.Internal.Types as I


type alias Seed =
    I.Seed


{-| A seed from an integer scalar (a graph input).
-}
seed : Tensor Integral I64 R0 -> Seed
seed x =
    I.Seed (O.reshape [ 1 ] (O.cast UI64 (I.tensor x)))


{-| A new seed, computed in the graph as `seed * 25214903917 + (2i + 1)` (ui64, wrapping): distinct
salts, and nested salts, give distinct seeds.
-}
salt : Int -> Seed -> Seed
salt i (I.Seed s) =
    I.Seed (O.add (O.mul s (E.const UI64 [ 1 ] [ 25214903917 ])) (E.const UI64 [ 1 ] [ toFloat (2 * i + 1) ]))


{-| A seed as a graph input or a subgraph argument (`ui64 [1]`).
-}
sig : Sig Seed
sig =
    I.SigBuilder
        { slots = [ { label = "seed", dtype = Just UI64, shape = Just [ 1 ], role = I.Fed } ]
        , build =
            \es ->
                case es of
                    e :: rest ->
                        ( I.Seed e, rest )

                    [] ->
                        ( I.Seed (E.const UI64 [ 1 ] [ 0 ]), [] )
        , flatten = \(I.Seed e) -> [ e ]
        }


{-| Uniform in [low, high).
-}
uniform : { low : Float, high : Float } -> DType Floating d -> Shape s -> Seed -> Tensor Floating d s
uniform r (I.DType dt) (I.Shape s) (I.Seed e) =
    I.Tensor (O.random 0 dt s r.low r.high e)


normal : { mean : Float, std : Float } -> DType Floating d -> Shape s -> Seed -> Tensor Floating d s
normal r (I.DType dt) (I.Shape s) (I.Seed e) =
    I.Tensor (O.cast dt (O.random 1 F32 s r.mean r.std e))


uniformLike : { low : Float, high : Float } -> Tensor Floating d s -> Seed -> Tensor Floating d s
uniformLike r x (I.Seed e) =
    let
        xe =
            I.tensor x
    in
    I.Tensor (O.random 0 (E.dtype xe) (E.shape xe) r.low r.high e)


normalLike : { mean : Float, std : Float } -> Tensor Floating d s -> Seed -> Tensor Floating d s
normalLike r x (I.Seed e) =
    let
        xe =
            I.tensor x
    in
    I.Tensor (O.cast (E.dtype xe) (O.random 1 F32 (E.shape xe) r.mean r.std e))


{-| True with probability `p`, one draw per element of `x`'s shape.
-}
bernoulliLike : Float -> Tensor k d s -> Seed -> Mask s
bernoulliLike p x (I.Seed e) =
    let
        u =
            O.random 0 F32 (E.shape (I.tensor x)) 0 1 e
    in
    I.Mask (O.lt u (O.scalarLike p u))
