module Tensor.Random exposing
    ( Seed, seed, salt, sig
    , uniform, normal
    , uniformLike, normalLike, bernoulliLike, gumbelLike
    , categorical
    )

{-| A graph that needs random values, for dropout, sampling or initialisation, gets them from this
module, which makes randomness part of the graph: a _draw_ is a tensor whose elements are random,
computed from a _seed_ tensor.

A draw is a tensor like any other, so making one computes no values (see `Tensor`). It is a pure
function of its seed, its distribution, the distribution's two parameters, its dtype and its shape:
two draws equal in all of these, the parameters bit for bit, are the same tensor, with the same
values. Calling `uniform` twice with the same arguments does not give two independent draws.

Separate random values therefore need separate seeds. A seed enters a graph as an input, through
`sig`, or is made from an integer scalar by `seed`, and `salt` derives further seeds from it inside
the graph, such as `salt 0 s` and `salt 1 s` for two different draws. `salt` says when two salts of
one seed are different seeds.

MAX and `Tensor.Eval` draw with different generators, so one seed gives different values on the
two. In `Tensor.Eval`, element j of a draw, counting in row-major order, is computed from random
numbers that depend only on the seed and j, so draws on one seed are related even when they differ
in shape, range or distribution: a smaller uniform draw holds the first elements of a larger one
with the same range, and two uniform draws of one shape with different ranges are the same numbers
scaled and shifted. Salt the seed for every draw that should be independent of the others.

`uniform` and `uniformLike` draw in the dtype of their result. `normal`, `normalLike` and
`gumbelLike` draw in `f32` and cast to the dtype of their result.

Under `Transform.vmap`, a draw made in the mapped function on a seed that is the same for every
example becomes one draw with the batch axis in front of its shape, so each example gets values of
its own, where applying the function to each example separately would give every example the same
ones. A draw made outside the mapped function and captured by it, or passed to `Transform.vmapWith`
through `Transform.keep`, is redrawn the same way: the examples read slices of one new draw, not
the draw that was made. A draw on a seed computed from a batched tensor is made once per example, on
that example's seed. A draw inside a `Tensor.Control.whileLoop` step or a function given to
`Transform.shared`, or inside a `Tensor.Control.cond` branch on a seed computed from the branch's
argument, is not batched: on a seed that is the same for every example, every example gets the same
values from it.


# Seeds

@docs Seed, seed, salt, sig


# Distributions

@docs uniform, normal


# Draws shaped like a tensor

These take their shape, and all but `bernoulliLike` their dtype, from a tensor `x`, whose values
they never read. As with `Tensor.zerosLike`, a broadcast axis of `x` is a real axis of size 1 in the
draw, and an `x` that failed to build fails the draw with its build error.

@docs uniformLike, normalLike, bernoulliLike, gumbelLike


# Sampling

@docs categorical

-}

import Signature exposing (Sig)
import Tensor exposing (DType, I64, Mask, R0, R1, R2, Shape, Tensor)
import Tensor.Axis as Axis
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P exposing (DT(..))
import Tensor.Internal.Types as I
import Tensor.Internal.Values exposing (Values(..))


{-| A random seed: a tensor of one `ui64` element, from which draws are computed.

A seed is obtained from `seed`, `sig` or `salt`.

-}
type alias Seed =
    I.Seed


{-| Returns the seed holding the integer scalar `x`, converted to `ui64`.
-}
seed : Tensor Int I64 R0 -> Seed
seed x =
    I.Seed (O.reshape [ 1 ] (O.cast UI64 (I.tensor x)))


{-| Returns the seed derived from a seed s and the salt `i`, computed in the graph as
s · 25214903917 + (2i + 1) in wrapping `ui64` arithmetic.

Where this arithmetic is exact, two different salts of one seed give different seeds, as long as
both lie between −2⁵² and 2⁵², because they add different odd numbers. Seeds salted from different
seeds can coincide: `salt i (salt j s)` is `salt (i + 25214903917) (salt (j - 1) s)`.

Under JavaScript an `Int` holds every integer only up to 2⁵³, so `Tensor.Eval` there refuses, as an
error, a salt whose result it cannot hold exactly; salting a seed larger than about 3.6 × 10⁵ in
magnitude, such as a seed that is already salted, usually is.

-}
salt : Int -> Seed -> Seed
salt i (I.Seed s) =
    I.Seed (O.add (O.mul s (E.constValues UI64 [ 1 ] (IntValues [ 25214903917 ]))) (E.constValues UI64 [ 1 ] (IntValues [ 2 * i + 1 ])))


{-| The signature of a seed, for a graph input or the argument of a function given a signature: one
`ui64 [1]` slot labelled `seed`.

Given no tensor to build from, it gives a seed that fails with the build error
"Tensor.Random.sig: no tensor to build the seed from".

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
                        ( I.Seed (E.failWith "Tensor.Random.sig: no tensor to build the seed from" (E.constValues UI64 [ 1 ] (IntValues [ 0 ]))), [] )
        , flatten = \(I.Seed e) -> [ e ]
        }


{-| Returns a draw of dtype `d` and shape `s` whose elements are uniformly distributed between `low`
and `high`.
-}
uniform : { low : Float, high : Float } -> DType Float d -> Shape s -> Seed -> Tensor Float d s
uniform r (I.DType dt _) (I.Shape s) (I.Seed e) =
    I.Tensor (O.random 0 dt s r.low r.high e)


{-| Returns a draw of dtype `d` and shape `s` whose elements are normally distributed with mean
`mean` and standard deviation `std`. It is drawn in `f32` and cast to `d`.
-}
normal : { mean : Float, std : Float } -> DType Float d -> Shape s -> Seed -> Tensor Float d s
normal r (I.DType dt _) (I.Shape s) (I.Seed e) =
    I.Tensor (O.cast dt (O.random 1 F32 s r.mean r.std e))


{-| Returns a draw with `x`'s dtype and shape whose elements are uniformly distributed between
`low` and `high`.
-}
uniformLike : { low : Float, high : Float } -> Tensor Float d s -> Seed -> Tensor Float d s
uniformLike r x (I.Seed e) =
    let
        xe =
            I.tensor x
    in
    I.Tensor (O.random 0 (E.dtype xe) (E.shape xe) r.low r.high e |> E.inherit xe)


{-| Returns a draw with `x`'s dtype and shape whose elements are normally distributed with mean
`mean` and standard deviation `std`. It is drawn in `f32` and cast to `x`'s dtype.
-}
normalLike : { mean : Float, std : Float } -> Tensor Float d s -> Seed -> Tensor Float d s
normalLike r x (I.Seed e) =
    let
        xe =
            I.tensor x
    in
    I.Tensor (O.cast (E.dtype xe) (O.random 1 F32 (E.shape xe) r.mean r.std e) |> E.inherit xe)


{-| Returns a mask of `x`'s shape that is True where an `f32` uniform draw between 0 and 1 is below
`p`. For `p` between 0 and 1, each element is True with probability `p`.
-}
bernoulliLike : Float -> Tensor k d s -> Seed -> Mask s
bernoulliLike p x (I.Seed e) =
    let
        u =
            O.random 0 F32 (E.shape (I.tensor x)) 0 1 e
    in
    I.Mask (O.lt u (O.scalarLike p u) |> E.inherit (I.tensor x))


{-| Returns Gumbel noise with `x`'s dtype and shape: −log(−log u) for a uniform draw u.

u is drawn in `f32` between 2⁻²³ and 1 − 2⁻²³ instead of between 0 and 1, which keeps both
logarithms finite. The noise is computed in `f32` and cast to `x`'s dtype.

-}
gumbelLike : Tensor Float d s -> Seed -> Tensor Float d s
gumbelLike x (I.Seed e) =
    let
        xe =
            I.tensor x

        -- 2⁻²³
        eps =
            1.1920928955078125e-7

        u =
            O.random 0 F32 (E.shape xe) eps (1 - eps) e
    in
    I.Tensor (O.cast (E.dtype xe) (O.neg (O.unary P.Log (O.neg (O.unary P.Log u)))) |> E.inherit xe)


{-| Returns, for each row of `logits`, the index of a class drawn from the row's softmax.

It uses the Gumbel-max method: the result is, for each row, the position of the largest element of
the sum of `logits` and `gumbelLike` noise drawn from the seed. There is no temperature; dividing
the logits by a temperature first draws at that temperature.

-}
categorical : Tensor Float d (R2 n v) -> Seed -> Tensor Int I64 (R1 n)
categorical logits s =
    logits |> Tensor.plus (gumbelLike logits s) |> Tensor.argMax Axis.last2
