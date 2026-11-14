module Nn.Stack exposing
    ( Seq, Stack, Width, Activation
    , input, dense, denseTo
    , relu, gelu, none
    , params
    , apply, applyWithDropout
    )

{-| A multilayer perceptron has hidden layers whose widths matter only inside it, and this module
describes one without giving each hidden width an axis tag of its own.

A _dense layer_ maps each row x of its input to x · W + b and then applies its _activation_ to each
element, W being a weight of input width × output width and b a bias of output width. A _stack_ is
dense layers applied one after another, each layer's input width being the output width of the
layer before it.

A description of a stack (`Seq i o`) lists its layers, each with its output width and its
activation, and is written as a pipeline:

    mlp =
        Nn.Stack.input
            |> Nn.Stack.dense 512 Nn.Stack.relu
            |> Nn.Stack.dense 256 Nn.Stack.relu
            |> Nn.Stack.denseTo classes Nn.Stack.none

Only the two ends of a stack are tagged. `i` is the tag of its input features and `o` the tag of
its last layer's outputs. A _hidden width_ is the width of a layer that is not the last, and `dense`
gives one without a tag: it takes the layer's width as a plain `Int`, and when it adds the last
layer the stack's `o` is `Width` instead of a tag the program declares. `denseTo` takes a `Dim`, and its outputs carry that
`Dim`'s tag. When the stack is applied, the first layer's product compares the inputs' width with
that layer's weight.

`params` turns a description, a dtype and the input width into a `Param.Spec` of the weights and
biases, and `apply` and `applyWithDropout` apply the stack those parameters make.


# Types

@docs Seq, Stack, Width, Activation


# Describing a stack

@docs input, dense, denseTo


# Activations

@docs relu, gelu, none


# Parameters

@docs params


# Applying

@docs apply, applyWithDropout

-}

import Nn
import Param
import Tensor exposing (DType, Dim, R2, Tensor)
import Tensor.Internal.Expr exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P exposing (DT, Prim(..))
import Tensor.Internal.Types as I
import Tensor.Random as Random exposing (Seed)


{-| The tag of the outputs of a layer added by `dense`, standing for whatever width `dense` gave
that layer.

No value of this type can be made, so `Tensor.dim` cannot make a `Dim Width`.

-}
type Width
    = Width Never


{-| The function a layer applies to each element of x · W + b. It is one of `relu`, `gelu` and
`none`.
-}
type Activation
    = Relu
    | Gelu
    | None


{-| The activation that `Tensor.relu` computes: each element, or 0 where it is below 0.
-}
relu : Activation
relu =
    Relu


{-| The activation that `Tensor.gelu` computes: the erf form of GELU, not its tanh approximation.
-}
gelu : Activation
gelu =
    Gelu


{-| No activation: the layer's outputs are x · W + b itself.
-}
none : Activation
none =
    None


{-| A description of a stack: its layers in order, each with its output width and its activation,
from inputs tagged `i` to outputs tagged `o`.

One is started with `input` and extended with `dense` and `denseTo`. `o` is `i` while there is no
layer, `Width` when the last layer was added by `dense`, and the `Dim`'s tag when it was added by
`denseTo`. The input width is not part of a description; `params` takes it.

-}
type Seq i o
    = Seq (List ( Int, Activation ))


{-| The layers of a stack of dtype `d`, from inputs tagged `i` to outputs tagged `o`: each layer's
weight, bias and activation. A value is made by the `Param.Spec` that `params` returns, from the
tensors that spec is given. Given fewer tensors than the spec has fields, it holds fewer layers than
the `Seq` that `params` was given.
-}
type Stack d i o
    = Stack (List ( Expr, Expr, Activation ))


{-| The description with no layers. A stack made from it returns its inputs unchanged.
-}
input : Seq i i
input =
    Seq []


{-| Returns the description with a layer added after its last one: a layer of `n` outputs, tagged
`Width`, and activation `act`. Nothing in this module checks `n`, so a width of 0 or less is
accepted.
-}
dense : Int -> Activation -> Seq i o -> Seq i Width
dense n act (Seq ls) =
    Seq (ls ++ [ ( n, act ) ])


{-| Returns the description with a layer added after its last one. The added layer's output width is
the size of the given `Dim`, and its outputs carry that `Dim`'s tag. It can add any layer, not only
the last.
-}
denseTo : Dim o2 -> Activation -> Seq i o -> Seq i o2
denseTo (I.Dim n) act (Seq ls) =
    Seq (ls ++ [ ( n, act ) ])


{-| Returns the parameter description of the stack the `Seq` describes, of the given dtype, whose
first layer reads inputs of the width the `Dim i` gives.

Its tensor fields are, layer by layer, the weight, of input width × output width, and the bias, of
output width. All are trainable. A weight's first values are drawn as `Param.heUniform` describes,
and a bias's first values are zeros. Built from fewer tensors than it has fields, the stack has
only the layers whose weight and bias were both given; no missing tensor is filled in.

-}
params : DType Float d -> Dim i -> Seq i o -> Param.Spec (Stack d i o)
params (I.DType dt _) (I.Dim i) (Seq layers) =
    let
        widths =
            List.map Tuple.first layers

        ins =
            i :: widths

        fields =
            List.concat
                (List.map2
                    (\a b ->
                        [ { dtype = dt, shape = [ a, b ], kind = I.Trainable I.HeUniform, name = Nothing }
                        , { dtype = dt, shape = [ b ], kind = I.Trainable I.Zeros, name = Nothing }
                        ]
                    )
                    ins
                    widths
                )
    in
    I.ParamBuilder
        { fields = fields
        , build =
            \es ->
                let
                    n =
                        List.length layers

                    mine =
                        List.take (2 * n) es

                    pairs =
                        chunk2 mine
                in
                ( Stack (List.map2 (\( w, b ) ( _, act ) -> ( w, b, act )) pairs layers), List.drop (2 * n) es )
        , flatten = \(Stack ls) -> List.concatMap (\( w, b, _ ) -> [ w, b ]) ls
        , checks = []
        }


{-| Returns the elements of `l` in consecutive pairs, dropping a last element that has no partner.
-}
chunk2 : List a -> List ( a, a )
chunk2 l =
    case l of
        a :: b :: rest ->
            ( a, b ) :: chunk2 rest

        _ ->
            []


{-| Returns each row passed through the stack's layers in order: each multiplies it by its weight,
adds its bias and applies its activation. A stack with no layers returns the rows unchanged; rows
whose width differs from the first layer's input width are a build error.
-}
apply : Stack d i o -> Tensor Float d (R2 n i) -> Tensor Float d (R2 n o)
apply =
    run (\_ h -> h)


{-| Returns the rows passed through the stack as `apply` does, with dropout applied to the output of
every layer but the last, whether `dense` or `denseTo` added it. The output of layer k, counting
from 0, is passed through `Nn.dropout` with the given `rate` and `training` and the seed
`Tensor.Random.salt k seed`. When `training` is False or `rate` is 0 or less, the result is
`apply`'s.
-}
applyWithDropout : { rate : Float, training : Bool } -> Seed -> Stack d i o -> Tensor Float d (R2 n i) -> Tensor Float d (R2 n o)
applyWithDropout cfg seed =
    run (\k h -> I.tensor (Nn.dropout cfg (Random.salt k seed) (I.Tensor h)))


{-| Returns the rows `x` passed through every layer of the stack, with `between k` applied to the
output of each layer k but the last, counting from 0.
-}
run : (Int -> Expr -> Expr) -> Stack d i o -> Tensor Float d (R2 n i) -> Tensor Float d (R2 n o)
run between (Stack layers) x =
    let
        count =
            List.length layers

        one ( w, b, act ) h =
            let
                y =
                    O.add (O.matmul h w) (O.broadcastAxis 0 b)
            in
            case act of
                Relu ->
                    O.unary P.Relu y

                Gelu ->
                    O.unary P.Gelu y

                None ->
                    y

        step ( k, layer ) h =
            let
                y =
                    one layer h
            in
            if k < count - 1 then
                between k y

            else
                y
    in
    I.Tensor (List.foldl step (I.tensor x) (List.indexedMap Tuple.pair layers))
