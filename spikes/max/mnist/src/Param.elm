module Param exposing
    ( Spec, Builder, record, weights, zeros
    , inputs, list, sgd, blockSize, initial, lcg
    )

{-| A network's parameters, described once, in the style of `elm/json` decoders:

    params =
        Param.record Params
            |> Param.weights "w1" .w1 [ 784, 128 ]
            |> Param.zeros "b1" .b1 [ 128 ]

The description gives the graph inputs (`inputs`), the list for a graph's input list (`list`), one
step of gradient descent with its `<name>_next` outputs (`sgd`), the packed byte layout the host
shares (`blockSize`), and the initial values (`initial`). All parameters are f32.

-}

import Bridge
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as Encode
import Tensor as T exposing (F32, Tensor)


type alias Field =
    { name : String, shape : List Int, init : Init }


type Init
    = HeUniform
    | Zeros


{-| A description in progress: `f` is what is still to be applied.
-}
type Builder r f
    = Builder
        { fields : List Field
        , get : r -> List (Tensor F32)
        , make : List (Tensor F32) -> ( f, List (Tensor F32) )
        }


type alias Spec r =
    Builder r r


record : f -> Builder r f
record constructor =
    Builder { fields = [], get = \_ -> [], make = \ts -> ( constructor, ts ) }


field : Init -> String -> (r -> Tensor F32) -> List Int -> Builder r (Tensor F32 -> f) -> Builder r f
field init name getter shape (Builder b) =
    Builder
        { fields = b.fields ++ [ { name = name, shape = shape, init = init } ]
        , get = \r -> b.get r ++ [ getter r ]
        , make =
            \ts ->
                let
                    ( f, rest ) =
                        b.make ts
                in
                case rest of
                    t :: more ->
                        ( f t, more )

                    [] ->
                        ( f (T.input name T.f32 shape), [] )
        }


{-| Weights, initialised He-uniform over the first dimension (the layer's inputs).
-}
weights : String -> (r -> Tensor F32) -> List Int -> Builder r (Tensor F32 -> f) -> Builder r f
weights =
    field HeUniform


{-| Biases, initialised to zero.
-}
zeros : String -> (r -> Tensor F32) -> List Int -> Builder r (Tensor F32 -> f) -> Builder r f
zeros =
    field Zeros


{-| The parameters as graph inputs, named as described.
-}
inputs : Spec r -> r
inputs (Builder b) =
    Tuple.first (b.make (List.map (\f -> T.input f.name T.f32 f.shape) b.fields))


{-| The parameters in the order described, for a graph's input list.
-}
list : Spec r -> r -> List (Tensor T.Any)
list (Builder b) r =
    List.map T.any (b.get r)


{-| One step of stochastic gradient descent on `loss`: each parameter minus `rate` times its
gradient, as the outputs `<name>_next`.
-}
sgd : Float -> Tensor F32 -> Spec r -> r -> List ( String, Tensor F32 )
sgd rate loss (Builder b) r =
    let
        ws =
            b.get r
    in
    List.map3 (\f w g -> ( f.name ++ "_next", w |> T.minus (g |> T.scale rate) ))
        b.fields
        ws
        (T.grad loss ws)


{-| The bytes of the packed parameter block (`Bridge.packed` per parameter).
-}
blockSize : Spec r -> Int
blockSize (Builder b) =
    List.sum (List.map (\f -> Bridge.paddedSize (4 * List.product f.shape)) b.fields)


{-| A 32-bit linear congruential generator: enough randomness for initialisation and shuffling.
-}
lcg : Int -> Int
lcg seed =
    modBy 4294967296 (1664525 * seed + 1013904223)


{-| The packed parameter block, initialised from `seed`; weights draw from the generator in the
order described, biases do not.
-}
initial : Spec r -> Int -> Bytes
initial (Builder b) seed0 =
    let
        one f ( seed, acc ) =
            let
                count =
                    List.product f.shape
            in
            case f.init of
                HeUniform ->
                    let
                        ( bytes, seed1 ) =
                            heUniform (Maybe.withDefault 1 (List.head f.shape)) count seed
                    in
                    ( seed1, bytes :: acc )

                Zeros ->
                    ( seed, Encode.encode (Encode.sequence (List.repeat count (Encode.float32 LE 0))) :: acc )
    in
    List.foldl one ( seed0, [] ) b.fields
        |> Tuple.second
        |> List.reverse
        |> List.map Bridge.packed
        |> Encode.sequence
        |> Encode.encode


{-| `count` He-uniform f32 values for a layer with `fanIn` inputs, and the seed after them.
-}
heUniform : Int -> Int -> Int -> ( Bytes, Int )
heUniform fanIn count seed0 =
    let
        bound =
            sqrt (6 / Basics.toFloat fanIn)

        go k seed acc =
            if k == 0 then
                ( acc, seed )

            else
                let
                    s =
                        lcg seed

                    u =
                        Basics.toFloat s / 4294967296
                in
                go (k - 1) s (Encode.float32 LE ((2 * u - 1) * bound) :: acc)

        ( encoders, seedOut ) =
            go count seed0 []
    in
    ( Encode.encode (Encode.sequence encoders), seedOut )
