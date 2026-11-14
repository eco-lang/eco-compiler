module Nn.Rotary exposing
    ( Rotary, Pairing(..)
    , apply
    )

{-| Rotary position embeddings (RoPE) put a vector's position into it by rotating it, so that the
dot product of two vectors rotated this way depends on their positions only through the difference
between them, up to rounding. This module applies them to a tensor of features per head and
position.

The tensor rotated, `x`, has three axes: heads, positions and features, of sizes `h`, `s` and `j`.
Each head's `j` features at one position are taken as `j / 2` pairs, and each pair `(a, b)` is
rotated as a point in the plane, becoming `(a cos θ − b sin θ, a sin θ + b cos θ)`. For pair `k`
at index `i` of the positions axis the angle is `θ = p · base^(−2k/j)` radians, where `p` is the
integer the positions tensor (below) holds at `i` and `base` is the field of that name in `Rotary`:
pair 0 turns by one radian per unit of `p`, and each later pair turns more slowly when `base` is
greater than 1. A `j` that is odd is a build error.

Which two features make up pair `k` is the _pairing_. There are two conventions, given by
`Pairing`, and they differ only in the order of the features.

The positions are a tensor of `s` integers, one for each index of the positions axis of `x`, so
they need not be known when the graph is built: they can be computed in the graph or given as an
input with each run. The positions axis of `x` and the axis of the positions tensor have one tag,
so a positions tensor whose axis has another tag is a compile error, and one of another size is a
build error.

The angles, and their cosines and sines, have the dtype `f32` whatever the dtype of `x`. The
cosines and sines are then cast to the dtype of `x`, and the rotation is computed in it.


# Configuration

@docs Rotary, Pairing


# Applying

@docs apply

-}

import Tensor exposing (I64, R1, R3, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P exposing (DT(..))
import Tensor.Internal.Types as I


{-| Which two of a head's `j` features are rotated together as pair `k`.

With `Interleaved`, pair `k` is features `2k` and `2k + 1`, two neighbours.

With `Halves`, pair `k` is features `k` and `k + j/2`, one from each half of the features.

In both, the first feature of the pair is the `a` of the rotation and the second the `b`, and pair
`k` turns at the same rate. So applying `Halves` gives the same values as reordering the features
so that each pair is adjacent, applying `Interleaved`, and putting the features back in their
order. Which of the two is right for `x` therefore depends only on how its features are ordered.

-}
type Pairing
    = Interleaved
    | Halves


{-| The settings of a rotary embedding: how fast its angles turn, and how features are paired.

`base` sets the rates: pair `k` of `j` features turns by `base^(−2k/j)` radians per unit of the
position value `p`.
Nothing checks it.

-}
type alias Rotary =
    { base : Float, pairing : Pairing }


{-| Returns `x` with the features of every head at index `i` of the positions axis rotated for the
position value `positions[i]`, pair by pair, with the rates and pairing of `r`.

The angles, cosines and sines are computed in `f32`; the cosines and sines are then cast to the
dtype of `x`, in which the rotation is computed. An odd number of features, or a `positions` whose
size is not that of the positions axis of `x`, is a build error.

-}
apply : Rotary -> Tensor Int I64 (R1 s) -> Tensor Float d (R3 h s j) -> Tensor Float d (R3 h s j)
apply r positions x =
    I.Tensor (rotate r (I.tensor positions) (I.tensor x))


{-| Returns `x`, of shape `[h, s, j]`, with its feature pairs rotated for `positions` as `apply`
describes.

An odd `j`, or a shape of other than three axes, gives `x` failed with a build error
(`Tensor.Internal.Expr.failWith`); an `x` that has already failed keeps its own message instead.

-}
rotate : Rotary -> Expr -> Expr -> Expr
rotate r positions x =
    case E.shape x of
        [ h, s, j ] ->
            if modBy 2 j /= 0 then
                E.failWith ("Rotary: a head of " ++ String.fromInt j ++ " features has no pairs (it must be even)") x

            else
                let
                    half =
                        j // 2

                    dt =
                        E.dtype x

                    inverseFrequencies =
                        E.const F32 [ half ] (List.map (\k -> r.base ^ (-2 * toFloat k / toFloat j)) (List.range 0 (half - 1)))

                    -- [s, half]: each broadcast axis takes its size from the other operand
                    angles =
                        O.mul (O.broadcastAxis 1 (O.cast F32 positions)) (O.broadcastAxis 0 inverseFrequencies)

                    cosA =
                        O.broadcastAxis 0 (O.cast dt (O.unary P.Cos angles))

                    sinA =
                        O.broadcastAxis 0 (O.cast dt (O.unary P.Sin angles))

                    turn a b =
                        ( O.sub (O.mul a cosA) (O.mul b sinA), O.add (O.mul a sinA) (O.mul b cosA) )
                in
                case r.pairing of
                    Halves ->
                        let
                            ( p, q ) =
                                turn (O.slice [ 0, 0, 0 ] [ h, s, half ] x) (O.slice [ 0, 0, half ] [ h, s, half ] x)
                        in
                        O.concat 2 [ p, q ]

                    Interleaved ->
                        let
                            pairs =
                                O.reshape [ h, s, half, 2 ] x

                            member i =
                                O.reshape [ h, s, half ] (O.slice [ 0, 0, 0, i ] [ h, s, half, 1 ] pairs)

                            ( p, q ) =
                                turn (member 0) (member 1)
                        in
                        O.reshape [ h, s, j ] (O.concat 3 [ O.insertAxis 3 p, O.insertAxis 3 q ])

        _ ->
            E.failWith "Rotary: needs heads × positions × features" x
