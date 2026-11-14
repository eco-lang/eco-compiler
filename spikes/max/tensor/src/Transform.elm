module Transform exposing
    ( grad, valueAndGrad, gradOf, valueAndGradOf, vjp, jvp, jacobian, hessianVector
    , vmap, vmap2, Batch, tensor, keep, pair, vmapWith
    , Shared, shared, call
    )

{-| Some things are made from a whole function of tensors rather than from a tensor: its
derivatives, a version of it that works on a whole batch at once, and a version of it whose
applications can share one body of operations. This module makes them, as _transforms_ that each
take an Elm function over tensors.

Every transform here _traces_ its function: it applies the function to _placeholders_, expressions
that stand for its arguments, and keeps the expressions the function returns, which are written in
terms of them. It then works on that trace. The derivatives differentiate it and `vmap` rewrites it
to work on a batch, and both then replace the placeholders with the actual arguments (for `vmap`,
the batched ones); a shared function keeps it as a body that its applications call.

Two things follow. A tensor the function reads without being given it as an argument is a constant
of the trace, so `grad (\y -> y |> T.times x) x` is `x`, not `2x`. And a function that applies a
transform is itself an ordinary function of tensors, so transforms nest: `hessianVector` is `grad`
of a function that calls `grad`.

The derivatives replace placeholders wherever the trace reads them, inside the bodies of
`Tensor.Control.whileLoop`, `Tensor.Control.cond` and shared functions included. `vmap` does too,
except inside the body of a shared function, which must not read `vmap`'s argument (see `shared`).
The derivatives give an argument that a loop's step body reads directly, rather than through the
loop's state, a gradient carrying the `whileLoop` build error described under Gradients, as for one
that reaches the loop's state. An argument read only by the loop's condition gets no gradient through
the loop, and no build error.


# Gradients

A gradient is made of the same operations as any other tensor, so it can be differentiated again,
batched with `vmap`, and run like any other. Some operations pass no gradient back to their
operands, and what would flow through them counts as zero: the comparisons and logical operations,
rounding, `argMax` and `argMin`, `modBy`, casts other than between two float dtypes, `stopGradient`,
random draws, and the indices of `take`, `rowsAt`, `put` and `putAdd`. Differentiating through the
values of `topK`, `bottomK` or `sort`, through a `whileLoop` (its state, or a tensor its body
reads), or with respect to a tensor that a shared function reads without being given it as an
argument, through operations that pass a gradient back, gives a gradient carrying a build error,
which `Graph.build` reports when that gradient reaches one of the graph's outputs (`jvp` gives it on
the tangents, as it says). Integer tensors have no derivatives: every transform here gives an
integer argument a zero gradient, cotangent or tangent, and gives an integer result a zero tangent.
The filter gradient of a strided
convolution, or of a strided transposed convolution, cannot be differentiated again: its own
derivatives carry a build error.

@docs grad, valueAndGrad, gradOf, valueAndGradOf, vjp, jvp, jacobian, hessianVector


# Vectorisation

`vmap` turns a function meant for one _example_ into one over a _batch_: a tensor whose leading
axis, the _batch axis_, holds `n` examples, example `k` being the slice at position `k` along that
axis, without the axis.

@docs vmap, vmap2, Batch, tensor, keep, pair, vmapWith


# Shared subgraphs

A function applied in several places would otherwise have its operations copied into the graph at
each one. A shared function records them as a body, which an application calls instead of copying
its operations, except where `shared` says otherwise.

@docs Shared, shared, call

-}

import Signature exposing (Sig)
import Tensor as T exposing (R0, R1, R2, Tensor)
import Tensor.Internal.Batch as B
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Grad as Grad
import Tensor.Internal.Prim
import Tensor.Internal.Shared as Sh
import Tensor.Internal.Types as I


{-| Returns the gradient of `f` at `x`: the derivative of `f`'s result with respect to each element
of `x`.
-}
grad : (Tensor Float d s -> Tensor Float d R0) -> Tensor Float d s -> Tensor Float d s
grad f x =
    I.Tensor (Grad.grad (\v -> I.tensor (f (I.Tensor v))) (I.tensor x))


{-| Returns `f x` together with `grad f x`.
-}
valueAndGrad : (Tensor Float d s -> Tensor Float d R0) -> Tensor Float d s -> ( Tensor Float d R0, Tensor Float d s )
valueAndGrad f x =
    ( f x, grad f x )


{-| Returns the gradient of `f` at `a` with respect to every tensor in `a`, as a value of `a`'s
structure that the signature `s` builds from one gradient per tensor. An integer tensor gets zeros.

What is differentiated is `f` applied to the value `s` builds from `a`'s tensors, which is `f a`
only when `s`'s round trip holds (see `Signature`); nothing here checks it.

-}
gradOf : Sig a -> (a -> Tensor Float d R0) -> a -> a
gradOf s f a =
    Tuple.second (valueAndGradOf s f a)


{-| Returns `f a` together with the gradient `gradOf` gives for the same arguments.
-}
valueAndGradOf : Sig a -> (a -> Tensor Float d R0) -> a -> ( Tensor Float d R0, a )
valueAndGradOf (I.SigBuilder s) f a =
    Grad.gradStructured (\es -> Tuple.first (s.build es)) s.flatten (f >> I.tensor) a
        |> Tuple.mapFirst I.Tensor


{-| Returns `f`'s result at `a` and its _pullback_. A _cotangent_ of a value is a value of the
same structure holding, for each of its tensors, the gradient with respect to that tensor of some
quantity being differentiated. The pullback takes a cotangent of `f`'s result to the cotangent of
`a` that it implies.

The first signature lists and rebuilds the tensors of `a`, the second those of `f`'s result. The
result, and what the pullback returns, are rebuilt through them, and are right only where the
signatures' round trips hold, which nothing here checks (see `Signature`).

An integer tensor of `a` gets a zero cotangent, whatever the cotangent of the result, and the
cotangent of an integer tensor of the result passes nothing back.

-}
vjp : Sig a -> Sig b -> (a -> b) -> a -> ( b, b -> a )
vjp (I.SigBuilder sa) (I.SigBuilder sb) f a =
    let
        lifted es =
            sb.flatten (f (Tuple.first (sa.build es)))

        ( outs, pullback ) =
            Grad.vjp lifted (sa.flatten a)
    in
    ( Tuple.first (sb.build outs), \cot -> Tuple.first (sa.build (pullback (sb.flatten cot))) )


{-| Returns `f`'s result at `a` and its _tangent_ along `t`. The tangent is how that result changes
as `a` moves in the direction `t`. An integer tensor of the result gets a zero tangent, and the
tangent given for an integer tensor of `a` is not read. The signatures are used as in `vjp`.

The tangent is computed from the pullback rather than by a forward pass of its own. The pullback is
linear in the cotangent it is given, and differentiating it in reverse with respect to that
cotangent, with `t` as the cotangent of what it returns, gives the tangent. Where the pullback
carries a build error, as through the values of `topK`, `bottomK` or `sort` or through a
`whileLoop`, the tangent of each result whose own pullback carries it is a tangent carrying that
error, and the tangents of the other results are kept. Differentiating the pullback through the
filter of a strided convolution or strided transposed convolution also gives a tangent carrying a
build error.

-}
jvp : Sig a -> Sig b -> (a -> b) -> a -> a -> ( b, b )
jvp (I.SigBuilder sa) (I.SigBuilder sb) f a t =
    let
        lifted es =
            sb.flatten (f (Tuple.first (sa.build es)))

        ( outs, tangents ) =
            Grad.jvp lifted (sa.flatten a) (sa.flatten t)
    in
    ( Tuple.first (sb.build outs), Tuple.first (sb.build tangents) )


{-| Returns the Jacobian of `f` at `x`: the matrix whose row `i` is the gradient of element `i` of
`f x`.

It is `f`'s pullback at `x` (see `vjp`), batched with `vmap` over the rows of an identity matrix,
so what `vmapWith` says about batching applies to the pullback.

-}
jacobian : (Tensor Float d (R1 a) -> Tensor Float d (R1 b)) -> Tensor Float d (R1 a) -> Tensor Float d (R2 b a)
jacobian f x =
    let
        ( outs, pullback ) =
            Grad.vjp (\es -> List.map (\e -> I.tensor (f (I.Tensor e))) es) [ I.tensor x ]

        y =
            List.head outs |> Maybe.withDefault (I.tensor x)

        m =
            List.product (E.shape y)

        identity =
            E.const (E.dtype y)
                [ m, m ]
                (List.concatMap
                    (\i ->
                        List.map
                            (\j ->
                                if i == j then
                                    1

                                else
                                    0
                            )
                            (List.range 0 (m - 1))
                    )
                    (List.range 0 (m - 1))
                )

        ( _, rows ) =
            B.vmapRule [ ( identity, True ) ] (\basis -> ( (), pullback basis ))
    in
    I.Tensor (List.head rows |> Maybe.withDefault (I.tensor x))


{-| Returns the Hessian of `f` at `x` multiplied by `v`, without making the Hessian: it is the
gradient at `x` of the gradient of `f` multiplied by `v` and summed. `v` is a constant of that outer
gradient even when it is computed from `x`.
-}
hessianVector : (Tensor Float d s -> Tensor Float d R0) -> Tensor Float d s -> Tensor Float d s -> Tensor Float d s
hessianVector f x v =
    grad (\y -> grad f y |> T.times v |> T.sumAll) x


{-| Returns what `f` gives for each example of `x`, as one batch: example `k` of the result is,
except as `vmapWith` describes, `f` applied to example `k` of `x`.

The two `Lift` witnesses (`Tensor.Lift`) say, by their types alone, that `x`'s shape is `f`'s
argument shape with the batch axis in front, and that the result's is `f`'s result shape with it
in front.

-}
vmap : T.Lift n s t -> T.Lift n u v -> (Tensor k d s -> Tensor k2 d2 u) -> Tensor k d t -> Tensor k2 d2 v
vmap ls lu f x =
    vmapWith (tensor ls) (tensor lu) f x


{-| Returns what `f` gives for example `k` of `x` and example `k` of `y`, for each `k`, as one
batch, as `vmap` does for one tensor. The batch size is `x`'s leading size; when `y`'s differs,
every tensor of the result carries a build error such as "vmap: batched arguments have leading
sizes 4 and 3".
-}
vmap2 : T.Lift n s t -> T.Lift n s2 t2 -> T.Lift n u v -> (Tensor k d s -> Tensor k1 d1 s2 -> Tensor k2 d2 u) -> Tensor k d t -> Tensor k1 d1 t2 -> Tensor k2 d2 v
vmap2 la lb lu f x y =
    vmapWith (pair (tensor la) (tensor lb)) (tensor lu) (\( a, c ) -> f a c) ( x, y )


{-| A description, for `vmapWith`, of how a value for one example (`a`) corresponds to a value for
a whole batch (`b`): which of its tensors carry the batch axis. `tensor`, `keep` and `pair` make
one.
-}
type alias Batch a b =
    I.Batch a b


{-| Returns the description of a tensor whose leading axis is the batch axis: example `k` is its
slice at position `k` along that axis, without the axis. The `Lift` witness (`Tensor.Lift`) is used
for its type alone.
-}
tensor : T.Lift n s t -> Batch (Tensor k d s) (Tensor k d t)
tensor _ =
    I.Batch
        { leaves = \b -> [ ( I.tensor b, True ) ]
        , perExample =
            \_ es ->
                case es of
                    e :: rest ->
                        ( I.Tensor e, rest )

                    [] ->
                        ( I.Tensor (E.scalar Tensor.Internal.Prim.F32 0), [] )
        , flatten = \a -> [ I.tensor a ]
        , build =
            \_ es ->
                case es of
                    e :: rest ->
                        ( I.Tensor e, rest )

                    [] ->
                        ( I.Tensor (E.scalar Tensor.Internal.Prim.F32 0), [] )
        }


{-| The description of a value that is not split into examples, which may be any value, not only a
tensor. As part of `vmapWith`'s argument it is passed to `f` as it is, except that a random draw in
it, and what is computed from one, is redrawn for each example, as `vmapWith` describes. As part of
the result it is returned as `f` gave it, with no batch axis.

A tensor kept in the result must not depend on the batch. One that does still reads the
placeholders `f` was traced on, and `Graph.build` refuses a graph whose outputs read it, with
"reads a tensor that is not an argument of the function it is used in".

-}
keep : Batch a a
keep =
    I.Batch
        { leaves = \_ -> []
        , perExample = \b es -> ( b, es )
        , flatten = \_ -> []
        , build = \a es -> ( a, es )
        }


{-| Returns the description of a pair whose parts are described by the two arguments, in order.
The first part's tensors are listed before the second's, which decides the batch size in
`vmapWith`.
-}
pair : Batch a b -> Batch c e -> Batch ( a, c ) ( b, e )
pair (I.Batch x) (I.Batch y) =
    I.Batch
        { leaves = \( b, e ) -> x.leaves b ++ y.leaves e
        , perExample =
            \( b, e ) es ->
                let
                    ( a, r1 ) =
                        x.perExample b es

                    ( c, r2 ) =
                        y.perExample e r1
                in
                ( ( a, c ), r2 )
        , flatten = \( a, c ) -> x.flatten a ++ y.flatten c
        , build =
            \( a, c ) es ->
                let
                    ( b, r1 ) =
                        x.build a es

                    ( e, r2 ) =
                        y.build c r1
                in
                ( ( b, e ), r2 )
        }


{-| Returns what `f` gives for each example of `x`, as one batched value. The first description says
how `x` holds the examples, and the second how the result is to hold them.

`f` is traced on placeholders with the dtype and shape of example 0 of each tensor of `x` that
carries the batch axis, and the trace is rewritten, operation by operation, into expressions over
the whole batch. An operation that does not depend on the batch is kept as it is, except a random
draw, as described below. One that does is rewritten by its _batching rule_ where it has one, and
otherwise _unrolled_: built once per example, with the results stacked along the batch axis, so the
graph holds `n` copies of it. Among those unrolled are `Tensor.Control.cond`, `whileLoop` and calls
of shared functions, `take`, `rowsAt`, `put` and `putAdd` with indices that depend on the batch, a
random draw on a seed that depends on the batch, the convolutions of `Nn.Conv2d`, the pooling of
`Nn` and its cross-entropies. A build error that a check recorded on an operation, such as those of
`Tensor.Control.cond` and `whileLoop`, is kept on its batched version.

The batch size `n` is the leading size of the first batched tensor of `x` that has an axis, in the
order the descriptions list them, or 1 when there is none. A batched tensor with no axes, with a
broadcast axis, with a leading size of 0 or with a leading size other than `n` is refused: every
tensor of the result carries a build error starting "vmap:" that says which, such as "vmap: batched
arguments have leading sizes 4 and 3". A result tensor that reads no batched tensor comes back
repeated `n` times along a new batch axis, a broadcast axis of it staying a broadcast axis.

A random draw whose seed does not depend on the batch is batched all the same: it becomes one draw
with `n` in front of its shape, of which example `k` reads slice `k`, so each example gets values of
its own. This holds wherever the draw was made: in `f`, or before `vmapWith` and captured by `f` or
passed in through `keep`, so a captured or kept draw is redrawn for each example, and the examples
read a new draw rather than the one that was captured or kept. A draw inside a `whileLoop` step or the body
of a shared function, or inside a `cond` branch on a seed computed from the branch's argument, is not
batched this way: when its seed is the same for every example, so are its values. A draw whose seed
depends on the batch is made once per example, on that example's seed.

Example `k` of the result is not always what `f` gives on example `k`:

  - A random draw on a seed that does not depend on the batch gives each example values of its
    own, as described above, where `f` applied to each example would give every example the same.
  - An operation that is unrolled, one of whose operands depends on the batch and has a broadcast
    axis, is refused with a build error, although it is valid for one example.

-}
vmapWith : Batch a ba -> Batch b bb -> (a -> b) -> ba -> bb
vmapWith (I.Batch bi) (I.Batch bo) f x =
    let
        ( perExampleOut, batchedLeaves ) =
            B.vmapRule (bi.leaves x)
                (\vs ->
                    let
                        y =
                            f (Tuple.first (bi.perExample x vs))
                    in
                    ( y, bo.flatten y )
                )
    in
    Tuple.first (bo.build perExampleOut batchedLeaves)


{-| A _shared function_ from `a` to `b`: one whose operations are recorded as a body, which an
application calls rather than copying the operations where it is applied, except where `shared`
says otherwise. `shared` makes one, and says when applications share one body; `call` applies it.
-}
type alias Shared a b =
    I.Shared a b


{-| Returns the shared function named `name` that applies `f`, taking its argument through `sa` and
giving its result through `sb`.

When every slot of `sa` declares a dtype and a shape (which a `Signature.anyTensor` slot does not),
`f` is traced here, once, and every application calls that body, except one whose argument has a
broadcast axis, which is traced on its arguments. Otherwise `f` is traced at each application, on
the dtypes, shapes and broadcast axes of that application's arguments, and applications whose
arguments agree in those get the same body.

For MAX, a body can become a subgraph, named by its _symbol_: `name`, an underscore, and a number
below 10⁶ computed from the body. An application is written as an `mo.call`, MAX's call operation,
of that subgraph, except inside a `Tensor.Control.cond` branch or `whileLoop` body, where it is
inlined: its operations are written in place, applications in its body included. Two different
bodies under one name can get the same number; each is still written as a subgraph of its own, the
later ones named with `_c1`, `_c2`, … appended to the symbol. `Tensor.Eval` runs the body at every
application. Differentiating through an application adds a call of a second body, whose symbol is
this one's followed by `_vjp`, and which recomputes the values the gradient needs.

The body may read only `f`'s arguments and tensors computed from constants. When an application
reaches a graph's outputs, `Graph.build` refuses a body that reads a graph input, directly or
through tensors computed from it, with "a shared function reads a tensor that is not one of its
arguments (pass it in its signature)", or the argument of an enclosing `vmap`, with "reads a tensor
that is not an argument of the function it is used in". Differentiating with respect to a tensor
that the body reads, through operations that pass a gradient back, gives a gradient carrying the
build error "a shared function or cond branch reads a tensor being differentiated that is not one of
its arguments, so its gradient cannot be found (pass it in the signature)".

When `f` was traced here, an application whose arguments differ from `sa` in number, dtype or
shape gets a build error such as "shared sq: argument 0 is f32[4], the signature says f32[3]". A
result whose dtype or shape differs from what `sb` declares, or a body giving another number of
tensors than `sb` describes, gets one such as "shared f: result 0 is f32[4], the signature says
f32[3]". An argument's broadcast axis stays a broadcast axis inside the body.

-}
shared : String -> Sig a -> Sig b -> (a -> b) -> Shared a b
shared name sa sb f =
    Sh.shared name sa sb f


{-| Applies a shared function to an argument. The result is read from one call of a body of the
function, and rebuilt through its second signature; `shared` says which body is called and how the
call is written for MAX.
-}
call : Shared a b -> a -> b
call (I.Shared s) =
    s.apply
