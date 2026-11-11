module Param exposing
    ( Builder, Spec, Field, record, heUniform, heNormal, xavierUniform, xavierNormal, normal, zeros, ones
    , data, sub, list, config, frozen, sig, initial, initGraph, mapElems, count, byteSize, grad
    )

{-| A network's parameters, described once, in the style of `elm/json` decoders:

    params =
        Param.record Params
            |> Param.sub .l1 (Linear.params T.float32 pixels hidden)
            |> Param.sub .l2 (Linear.params T.float32 hidden classes)

The description gives the parameters as a graph argument (`sig`), their initial values (`initial`,
or `initGraph` for models too large to initialise in Elm), their byte layout, and their gradients.

Weights are initialised from the fan-in (the product of all dimensions but the last) and the
fan-out (the last dimension).

-}

import Bytes exposing (Bytes)
import Bytes.Encode as Encode
import Graph exposing (Graph)
import Signature exposing (Sig)
import Tensor exposing (DType, Elems, F32, Floating, R0, Shape, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Grad as Grad
import Tensor.Internal.Host as Host
import Tensor.Internal.Ops as O
import Tensor.Internal.ParamInit as ParamInit
import Tensor.Internal.Prim as P exposing (DT(..))
import Tensor.Internal.Types as I


type alias Builder r f =
    I.ParamBuilder r f


type alias Spec r =
    Builder r r


record : f -> Builder r f
record constructor =
    I.ParamBuilder { fields = [], build = \es -> ( constructor, es ), flatten = \_ -> [], checks = [] }


type alias Field r d s f =
    (r -> Tensor Floating d s) -> DType Floating d -> Shape s -> Builder r (Tensor Floating d s -> f) -> Builder r f


tensorField : I.FieldKind -> (r -> Tensor k d s) -> DType k d -> Shape s -> Builder r (Tensor k d s -> f) -> Builder r f
tensorField kind getter (I.DType dt) (I.Shape s) (I.ParamBuilder b) =
    I.ParamBuilder
        { fields = b.fields ++ [ { dtype = dt, shape = s, kind = kind } ]
        , build =
            \es ->
                let
                    ( f, rest ) =
                        b.build es
                in
                case rest of
                    e :: more ->
                        ( f (I.Tensor e), more )

                    [] ->
                        ( f (I.Tensor (E.scalar dt 0)), [] )
        , flatten = \r -> b.flatten r ++ [ I.tensor (getter r) ]
        , checks = b.checks
        }


{-| Uniform in ±√(6 / fan-in).
-}
heUniform : Field r d s f
heUniform =
    tensorField (I.Trainable I.HeUniform)


{-| Normal with standard deviation √(2 / fan-in).
-}
heNormal : Field r d s f
heNormal =
    tensorField (I.Trainable I.HeNormal)


{-| Uniform in ±√(6 / (fan-in + fan-out)).
-}
xavierUniform : Field r d s f
xavierUniform =
    tensorField (I.Trainable I.XavierUniform)


xavierNormal : Field r d s f
xavierNormal =
    tensorField (I.Trainable I.XavierNormal)


{-| Normal with mean 0 and standard deviation `std`.
-}
normal : Float -> Field r d s f
normal std =
    tensorField (I.Trainable (I.Normal std))


zeros : Field r d s f
zeros =
    tensorField (I.Trainable I.Zeros)


ones : Field r d s f
ones =
    tensorField (I.Trainable I.Ones)


{-| A tensor of any kind that is never trained and that `initial` leaves zero: the host loads it
(quantized codes, a pretrained table).
-}
data : (r -> Tensor k d s) -> DType k d -> Shape s -> Builder r (Tensor k d s -> f) -> Builder r f
data =
    tensorField I.Data


sub : (r -> p) -> Spec p -> Builder r (p -> f) -> Builder r f
sub getter (I.ParamBuilder s) (I.ParamBuilder b) =
    I.ParamBuilder
        { fields = b.fields ++ s.fields
        , build =
            \es ->
                let
                    ( f, r1 ) =
                        b.build es

                    ( p, r2 ) =
                        s.build r1
                in
                ( f p, r2 )
        , flatten = \r -> b.flatten r ++ s.flatten (getter r)
        , checks = b.checks ++ List.map (\c -> getter >> c) s.checks
        }


{-| `n` records of one description (the layers of a deep stack).
-}
list : Int -> Spec p -> Spec (List p)
list n (I.ParamBuilder s) =
    I.ParamBuilder
        { fields = List.concat (List.repeat n s.fields)
        , build =
            \es ->
                List.foldl
                    (\_ ( acc, rest ) ->
                        let
                            ( x, r ) =
                                s.build rest
                        in
                        ( x :: acc, r )
                    )
                    ( [], es )
                    (List.range 1 n)
                    |> Tuple.mapFirst List.reverse
        , flatten = List.concatMap s.flatten
        , checks =
            [ \ps ->
                if List.length ps /= n then
                    Just ("a list of " ++ String.fromInt n ++ " has " ++ String.fromInt (List.length ps))

                else
                    List.filterMap (\p -> List.filterMap (\c -> c p) s.checks |> List.head) ps |> List.head
            ]
        }


{-| A non-tensor field (a dimension, a constant) carried in the record unchanged. A record whose
field differs from `value` is refused when a graph is built.
-}
config : (r -> c) -> c -> Builder r (c -> f) -> Builder r f
config getter value (I.ParamBuilder b) =
    I.ParamBuilder
        { fields = b.fields
        , build =
            \es ->
                let
                    ( f, rest ) =
                        b.build es
                in
                ( f value, rest )
        , flatten = b.flatten
        , checks =
            b.checks
                ++ [ \r ->
                        if getter r == value then
                            Nothing

                        else
                            Just "a configuration field differs from the parameter description (it is a constant of the description)"
                   ]
        }


{-| The same parameters, not trained (a pretrained base under LoRA).
-}
frozen : Spec p -> Spec p
frozen (I.ParamBuilder s) =
    I.ParamBuilder
        { s
            | fields =
                List.map
                    (\f ->
                        case f.kind of
                            I.Trainable i ->
                                { f | kind = I.Frozen i }

                            _ ->
                                f
                    )
                    s.fields
        }


{-| The parameters as a signature: inputs `param0` .. (trainable), `frozen0` .., `data0` .. .
-}
sig : Spec r -> Sig r
sig (I.ParamBuilder s) =
    I.SigBuilder
        { slots = List.map (\f -> { label = ParamInit.kindLabel f.kind, dtype = Just f.dtype, shape = Just f.shape, role = I.Fed }) s.fields
        , build = s.build
        , flatten =
            \r ->
                case List.filterMap (\c -> c r) s.checks of
                    [] ->
                        s.flatten r

                    problem :: _ ->
                        List.map (E.failWith ("Param: " ++ problem)) (s.flatten r)
        }


{-| Every field's initial bytes in order, each padded to 16 bytes (the host's layout).
-}
initial : Spec r -> Int -> Bytes
initial (I.ParamBuilder s) seed0 =
    List.foldl
        (\f ( seed, acc ) ->
            let
                ( values, seed1 ) =
                    ParamInit.initValues f seed
            in
            ( seed1, Host.packed (Host.encodeValues f.dtype values) :: acc )
        )
        ( seed0, [] )
        s.fields
        |> Tuple.second
        |> List.reverse
        |> Encode.sequence
        |> Encode.encode


{-| A graph with one input, the seed (`ui64 [1]`), that returns every field's initial values drawn
by MAX's own random ops (fields named `param0` .., as `sig` names them): for models too large to
initialise in Elm.
-}
initGraph : String -> Spec r -> Result (List String) Graph
initGraph graphName (I.ParamBuilder s) =
    let
        seedSig =
            I.SigBuilder
                { slots = [ { label = "seed", dtype = Just UI64, shape = Just [ 1 ], role = I.Fed } ]
                , build = \es -> ( List.head es |> Maybe.withDefault (E.scalar UI64 0), List.drop 1 es )
                , flatten = \e -> [ e ]
                }

        outSig =
            I.SigBuilder
                { slots = List.map (\f -> { label = ParamInit.kindLabel f.kind, dtype = Just f.dtype, shape = Just f.shape, role = I.Fed }) s.fields
                , build = \es -> ( es, [] )
                , flatten = identity
                }

        one i f seed =
            let
                ( fanIn, fanOut ) =
                    ParamInit.fans f.shape

                salted =
                    O.add (O.mul seed (E.const UI64 [ 1 ] [ 25214903917 ])) (E.const UI64 [ 1 ] [ toFloat (2 * i + 1) ])

                drawIn lo hi =
                    O.cast f.dtype (O.random 0 F32 f.shape lo hi salted)

                drawN std =
                    O.cast f.dtype (O.random 1 F32 f.shape 0 std salted)

                init =
                    case f.kind of
                        I.Trainable x ->
                            Just x

                        I.Frozen x ->
                            Just x

                        I.Data ->
                            Nothing
            in
            case init of
                Just I.HeUniform ->
                    drawIn -(sqrt (6 / toFloat fanIn)) (sqrt (6 / toFloat fanIn))

                Just I.XavierUniform ->
                    drawIn -(sqrt (6 / toFloat (fanIn + fanOut))) (sqrt (6 / toFloat (fanIn + fanOut)))

                Just I.HeNormal ->
                    drawN (sqrt (2 / toFloat fanIn))

                Just I.XavierNormal ->
                    drawN (sqrt (2 / toFloat (fanIn + fanOut)))

                Just (I.Normal std) ->
                    drawN std

                Just I.Ones ->
                    O.broadcastTo f.shape (E.scalar f.dtype 1)

                _ ->
                    O.broadcastTo f.shape (E.scalar f.dtype 0)
    in
    Graph.build graphName seedSig outSig (\seed -> List.indexedMap (\i f -> one i f seed) s.fields)


{-| The same element-wise function applied to every trainable tensor (in f32; frozen and data
fields are left as they are).
-}
mapElems : (Tensor Floating F32 Elems -> Tensor Floating F32 Elems) -> Spec r -> r -> r
mapElems f (I.ParamBuilder s) r =
    let
        apply field e =
            case field.kind of
                I.Trainable _ ->
                    O.cast field.dtype (I.tensor (f (I.Tensor (O.cast F32 e))))

                _ ->
                    e
    in
    Tuple.first (s.build (List.map2 apply s.fields (s.flatten r)))


count : Spec r -> Int
count (I.ParamBuilder s) =
    List.length s.fields


{-| The bytes of the packed parameter block.
-}
byteSize : Spec r -> Int
byteSize (I.ParamBuilder s) =
    List.sum (List.map (\f -> Host.paddedSize (P.dtSize f.dtype * List.product f.shape)) s.fields)


{-| The gradient of a scalar loss with respect to every parameter: a record of the same type.
-}
grad : Spec r -> (r -> Tensor Floating d R0) -> r -> r
grad (I.ParamBuilder s) loss r =
    Grad.gradStructured (\es -> Tuple.first (s.build es)) s.flatten (loss >> I.tensor) r
        |> Tuple.second
