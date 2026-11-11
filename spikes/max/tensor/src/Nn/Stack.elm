module Nn.Stack exposing (Seq, Stack, Width, Activation, input, dense, denseTo, relu, gelu, none, params, apply, applyWithDropout)

{-| Dense layers of different widths, described in a pipeline:

    Nn.Stack.input
        |> Nn.Stack.dense 512 Nn.Stack.relu
        |> Nn.Stack.dense 256 Nn.Stack.relu
        |> Nn.Stack.denseTo classes Nn.Stack.none

Hidden widths need no dimension types: they are `Width`, a tag no other code can make, so only the
ends of a stack are checked against the network around it.

-}

import Param
import Tensor exposing (DType, Dim, Floating, R2, Tensor)
import Tensor.Internal.Expr exposing (Expr)
import Tensor.Internal.Ops as O
import Tensor.Internal.Prim as P exposing (DT, Prim(..))
import Tensor.Internal.Types as I
import Tensor.Random as Random exposing (Seed)


type Width
    = Width Never


type Activation
    = Relu
    | Gelu
    | None


relu : Activation
relu =
    Relu


gelu : Activation
gelu =
    Gelu


none : Activation
none =
    None


type Seq i o
    = Seq (List ( Int, Activation ))


type Stack d i o
    = Stack (List ( Expr, Expr, Activation ))


input : Seq i i
input =
    Seq []


dense : Int -> Activation -> Seq i o -> Seq i Width
dense n act (Seq ls) =
    Seq (ls ++ [ ( n, act ) ])


denseTo : Dim o2 -> Activation -> Seq i o -> Seq i o2
denseTo (I.Dim n) act (Seq ls) =
    Seq (ls ++ [ ( n, act ) ])


{-| He-uniform weights, zero biases, layer by layer.
-}
params : DType Floating d -> Dim i -> Seq i o -> Param.Spec (Stack d i o)
params (I.DType dt) (I.Dim i) (Seq layers) =
    let
        widths =
            List.map Tuple.first layers

        ins =
            i :: widths

        fields =
            List.concat
                (List.map2
                    (\a b ->
                        [ { dtype = dt, shape = [ a, b ], kind = I.Trainable I.HeUniform }
                        , { dtype = dt, shape = [ b ], kind = I.Trainable I.Zeros }
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


chunk2 : List a -> List ( a, a )
chunk2 l =
    case l of
        a :: b :: rest ->
            ( a, b ) :: chunk2 rest

        _ ->
            []


apply : Stack d i o -> Tensor Floating d (R2 n i) -> Tensor Floating d (R2 n o)
apply =
    run (\_ h -> h)


{-| The same with inverted dropout after every hidden layer (each with its own salt of `seed`).
-}
applyWithDropout : { rate : Float, training : Bool } -> Seed -> Stack d i o -> Tensor Floating d (R2 n i) -> Tensor Floating d (R2 n o)
applyWithDropout cfg seed =
    run
        (\k h ->
            if not cfg.training || cfg.rate <= 0 then
                h

            else
                let
                    (I.Mask keep) =
                        Random.bernoulliLike (1 - cfg.rate) (I.Tensor h) (Random.salt k seed)
                in
                O.select keep (O.mul h (O.scalarLike (1 / (1 - cfg.rate)) h)) (O.zerosLike h)
        )


run : (Int -> Expr -> Expr) -> Stack d i o -> Tensor Floating d (R2 n i) -> Tensor Floating d (R2 n o)
run between (Stack layers) x =
    let
        count =
            List.length layers

        one _ ( w, b, act ) h =
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
                    one k layer h
            in
            if k < count - 1 then
                between k y

            else
                y
    in
    I.Tensor (List.foldl step (I.tensor x) (List.indexedMap Tuple.pair layers))
