module Tensor.Control exposing
    ( cond
    , whileLoop, scan, repeat
    )

{-| Some computations branch or repeat, and this module gives a graph both, in two forms: as one
operation of the graph, decided when the graph runs (`cond`, `whileLoop`), or _unrolled_, written
out step by step while the tensors are made (`repeat`, `scan`).

There are two forms because making a tensor computes no element values, as `Tensor` describes. A
choice that depends on a tensor's values, such as which branch to take or whether to go round a
loop again, therefore cannot be made in Elm. `cond` and `whileLoop` put it into the graph: each
makes one operation that holds its functions, and the choice is made when the result is run, by
`Tensor.Eval` or by MAX, given the graph `Max` writes. To be held in the operation, each
function is _traced_: when `cond` or `whileLoop` is called, the function is applied to stand-in
tensors with the dtypes and shapes of its argument, and what it returns is kept.

A count known in Elm needs no such operation. `repeat` applies a function a given number of times,
and `scan` once for each slice of a tensor, both in Elm, so the result is what writing the
applications out by hand would give, and it differentiates like any other tensor.

What can be done with the result differs between the forms:

  - A gradient passes back through a `cond` to the float tensors of its argument and to those its
    branches read from outside them, a `whileLoop` within a branch included, but not to the
    predicate.
  - A `whileLoop` is not differentiated. A gradient that would pass back through one, to its
    initial state or to a tensor its step reads directly, carries instead the build error
    "whileLoop: a loop cannot be differentiated (use Control.repeat for a fixed count)", which
    `Graph.build` reports when a graph output depends on it (`Transform.jvp` differs, as it says).
    `Transform`'s module documentation says what reaches a tensor that only the test reads.
  - Under `Transform.vmap`, a `cond` or `whileLoop` that reads the batch (for a loop, in its initial
    state, its test or its step) is written once per example.
  - For a GPU, `Max` refuses to write a graph that uses `cond` or `whileLoop`.

`cond` and `whileLoop` take signatures (`Signature`) for a branch's argument and result and for a
loop's state, which may be records, tuples or lists of tensors. They use a signature only to turn
such a value into its list of tensors and back. It must describe the value's structure, which
nothing here checks (see `Signature`); the dtypes and shapes its slots declare are not used, so
`Signature.anyTensor` serves for each tensor in the value that is not a mask.

Inside a branch, and in a loop's test and step, a broadcast axis of the argument or the state, and
of a tensor read from outside, stays a broadcast axis, as it would outside. A `cond`'s results have
the broadcast axes of the first function's results, and a `whileLoop`'s those of its initial state.
So the two functions of a `cond` must agree on broadcast axes, and a loop's step must keep those of
the state: a broadcast axis on one side where the other has an ordinary axis of size 1 counts as a
difference of shape, with the build errors `cond` and `whileLoop` give for one.


# Branches

@docs cond


# Loops

@docs whileLoop, scan, repeat

-}

import Signature exposing (Sig)
import Tensor as T exposing (Mask, R0, Tensor)
import Tensor.Internal.Batch as B
import Tensor.Internal.Control as C
import Tensor.Internal.Types as I


{-| Returns the first function's result on the argument when the predicate holds, and the second's
when it does not, as one operation decided when the result is run. The first signature describes
the argument and the second the result.

Both functions are traced, and their results must agree: results that differ in number, shape
(broadcast axes included) or dtype give the build error "cond: the two branches' results differ in
shape or dtype". A predicate that failed to build reports only its own build error.

-}
cond : Mask R0 -> Sig a -> Sig b -> (a -> b) -> (a -> b) -> a -> b
cond (I.Mask p) sa sb t f a =
    C.cond p sa sb t f a


{-| Returns the final state of a loop that starts from the given state and, while the test holds for
the state, replaces it with the step applied to it, as one operation carried out when the result is
run. The signature describes the state.

The test and the step are traced. The step must keep the number of the state's tensors and their
shapes (broadcast axes included) and dtypes, or the results carry the build error "whileLoop: the
body must keep the state's shapes and dtypes". A test or step whose result failed to build makes
the results carry that build error instead. The test and the step may read tensors from outside the
state directly. A loop cannot be differentiated, as the module documentation describes; for a fixed
number of steps, `repeat` can. `Tensor.Eval` limits how many steps a loop may take.

-}
whileLoop : Sig s -> (s -> Mask R0) -> (s -> s) -> s -> s
whileLoop ss continue body init =
    C.whileLoop ss (continue >> (\(I.Mask m) -> m)) body init


{-| Returns the step applied the given number of times to the initial state, unrolled: the
applications are made in Elm, as if written out by hand. A count of 0 or less gives the initial
state. The signature is not used.
-}
repeat : Int -> Sig s -> (s -> s) -> s -> s
repeat n _ body init =
    List.foldl (\_ s -> body s) init (List.range 1 n)


{-| Returns the final carry and the stacked outputs of a step applied, unrolled, to each slice of
the tensor along its leading axis in turn, starting from the initial carry. Each application takes
the carry and one slice and gives the next carry and one output, and the outputs are stacked, in
order, along a new leading axis.

The carry may be any Elm value, since it is only handed from one application to the next in Elm.
The two `Lift` values state how the tensor and the stacked outputs relate to one slice and one
output. The stacked outputs are a build error when the outputs' shapes differ or the tensor has no
slices along its leading axis, and can be one when the tensor or the outputs have a broadcast axis.

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
