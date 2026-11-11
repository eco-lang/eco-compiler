module Train exposing (step, measure, initial, initialFrom, loss, measured)

{-| Training graphs from a loss: the user writes the loss, `Train` writes the rest.

    trainStep =
        Train.step params (Optim.adamW 1.0e-3) (Sig.pair images labels) <|
            \p ( x, y ) -> network p x |> Nn.crossEntropyIndices y

The parameters and the optimizer state are **resident**: host buffers that outlive a run, which
the step's outputs replace. Only the batch (and the rate, for `Optim.PerStep`) crosses from Elm
with each run, and only the loss comes back.

-}

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as Decode
import Bytes.Encode as Encode
import Graph exposing (Graph)
import Optim exposing (Optimizer)
import Param
import Signature exposing (Sig)
import Tensor exposing (F32, Floating, R0, Tensor)
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Grad as Grad
import Tensor.Internal.Host as Host
import Tensor.Internal.Io as Io
import Tensor.Internal.Names exposing (names)
import Tensor.Internal.Ops as O
import Tensor.Internal.ParamInit as ParamInit
import Tensor.Internal.Prim as P exposing (DT(..))
import Tensor.Internal.Types as I


type alias Layout =
    { fields : List I.Field
    , paramNames : List String
    , stateNames : List String
    , hasStep : Bool
    , hasRate : Bool
    , slots : Int
    }


layout : Param.Spec r -> Optimizer -> Layout
layout (I.ParamBuilder ps) (I.Optimizer o) =
    let
        trainable =
            List.filter isTrainable ps.fields
    in
    { fields = ps.fields
    , paramNames = ParamInit.residentNames ps.fields
    , stateNames = names "state" (List.repeat (o.slots * List.length trainable) "state")
    , hasStep = o.slots > 0
    , hasRate = o.rate == I.PerStep
    , slots = o.slots
    }


isTrainable : I.Field -> Bool
isTrainable f =
    case f.kind of
        I.Trainable _ ->
            True

        _ ->
            False


resident : String -> Maybe DT -> Maybe (List Int) -> I.Slot
resident n dt s =
    { label = n, dtype = dt, shape = s, role = I.Resident n }


type alias Inputs r batch =
    { params : r, state : List Expr, step : Maybe Expr, rate : Maybe Expr, batch : batch }


{-| The graph `train_step`. Inputs: the parameters (`param0` .., `frozen0` .., `data0` ..), the
optimizer state (`state0` ..) and step counter (`step`), all resident; then `rate` if the rate is
`PerStep`, and the batch (`batch0` ..), fed. Outputs: the new parameters and state (replacing their
buffers) and `loss`.
-}
step : Param.Spec r -> Optimizer -> Sig batch -> (r -> batch -> Tensor Floating F32 R0) -> Result (List String) Graph
step ((I.ParamBuilder ps) as spec) ((I.Optimizer o) as opt) (I.SigBuilder bs) lossFn =
    let
        lay =
            layout spec opt

        trainable =
            List.filter isTrainable lay.fields

        paramSlots =
            List.map2 (\n f -> resident n (Just f.dtype) (Just f.shape)) lay.paramNames lay.fields

        stateShapes =
            List.concatMap (\f -> List.repeat o.slots f.shape) trainable

        stateSlots =
            List.map2 (\n s -> resident n (Just F32) (Just s)) lay.stateNames stateShapes

        stepSlots =
            if lay.hasStep then
                [ resident "step" (Just F32) (Just [ 1 ]) ]

            else
                []

        rateSlots =
            if lay.hasRate then
                [ { label = "rate", dtype = Just F32, shape = Just [ 1 ], role = I.Fed } ]

            else
                []

        batchSlots =
            List.map (\sl -> { sl | label = "batch", role = I.Fed }) bs.slots

        inSig =
            I.SigBuilder
                { slots = paramSlots ++ stateSlots ++ stepSlots ++ rateSlots ++ batchSlots
                , build =
                    \es ->
                        let
                            ( params, r1 ) =
                                ps.build es

                            st =
                                List.take (List.length stateSlots) r1

                            r2 =
                                List.drop (List.length stateSlots) r1

                            -- scalars travel as [1]: MAX does not take rank-0 inputs through its C API
                            ( stepE, r3 ) =
                                takeIf lay.hasStep r2 |> Tuple.mapFirst (Maybe.map (O.reshape []))

                            ( rateE, r4 ) =
                                takeIf lay.hasRate r3 |> Tuple.mapFirst (Maybe.map (O.reshape []))

                            ( b, r5 ) =
                                bs.build r4
                        in
                        ( { params = params, state = st, step = stepE, rate = rateE, batch = b }, r5 )
                , flatten =
                    \i -> ps.flatten i.params ++ i.state ++ maybeList (Maybe.map Io.unnarrow i.step) ++ maybeList (Maybe.map Io.unnarrow i.rate) ++ bs.flatten i.batch
                }

        nextNames =
            List.filterMap identity (List.map2 (\n f -> if isTrainable f then Just n else Nothing) lay.paramNames lay.fields)

        outSlots =
            List.map (\n -> { label = "next", dtype = Nothing, shape = Nothing, role = I.Resident n }) nextNames
                ++ List.map (\n -> { label = "next", dtype = Nothing, shape = Nothing, role = I.Resident n }) lay.stateNames
                ++ List.map (\_ -> { label = "next", dtype = Nothing, shape = Nothing, role = I.Resident "step" }) stepSlots
                ++ [ { label = "loss", dtype = Nothing, shape = Nothing, role = I.Fed } ]

        outSig =
            I.SigBuilder { slots = outSlots, build = \es -> ( es, [] ), flatten = identity }

        body i =
            let
                l =
                    I.tensor (lossFn i.params i.batch)

                ( _, gradRecord ) =
                    Grad.gradStructured (\es -> Tuple.first (ps.build es)) ps.flatten (\r -> I.tensor (lossFn r i.batch)) i.params

                values =
                    ps.flatten i.params

                grads =
                    ps.flatten gradRecord

                pairs =
                    List.filterMap identity (List.map3 (\f w g -> if isTrainable f then Just ( f, w, g ) else Nothing) lay.fields values grads)

                grads32 =
                    List.map (\( _, _, g ) -> O.cast F32 g) pairs

                clipped =
                    case o.clip of
                        Just maxNorm ->
                            let
                                norm =
                                    O.unary P.Sqrt (List.foldl (\g acc -> O.add acc (O.sumAll (O.square g))) (E.scalar F32 0) grads32)

                                factor =
                                    O.binary P.Min2 (E.scalar F32 1) (O.div (E.scalar F32 maxNorm) norm)
                            in
                            List.map (\g -> O.mul g (O.broadcastTo (E.shape g) factor)) grads32

                        Nothing ->
                            grads32

                newStep =
                    Maybe.map (\s -> O.add s (E.scalar F32 1)) i.step

                hyper =
                    { rate = Maybe.withDefault (E.scalar F32 (fixedRate o.rate)) i.rate
                    , step = Maybe.withDefault (E.scalar F32 1) newStep
                    }

                states =
                    chunk o.slots i.state

                updated =
                    List.map3
                        (\( f, w, _ ) g st ->
                            let
                                ( w1, st1 ) =
                                    o.update hyper (O.cast F32 w) g st
                            in
                            ( O.cast f.dtype w1, st1 )
                        )
                        pairs
                        clipped
                        (if o.slots == 0 then
                            List.map (\_ -> []) pairs

                         else
                            states
                        )
            in
            List.map Tuple.first updated ++ List.concatMap Tuple.second updated ++ maybeList (Maybe.map (O.reshape [ 1 ]) newStep) ++ [ l ]
    in
    Graph.build "train_step" inSig outSig body


fixedRate : I.Rate -> Float
fixedRate r =
    case r of
        I.Fixed v ->
            v

        I.PerStep ->
            0


takeIf : Bool -> List Expr -> ( Maybe Expr, List Expr )
takeIf present es =
    case ( present, es ) of
        ( True, e :: rest ) ->
            ( Just e, rest )

        _ ->
            ( Nothing, es )


maybeList : Maybe a -> List a
maybeList m =
    case m of
        Just x ->
            [ x ]

        Nothing ->
            []


chunk : Int -> List a -> List (List a)
chunk n l =
    if n <= 0 || List.isEmpty l then
        []

    else
        List.take n l :: chunk n (List.drop n l)


{-| The graph `measure`: one value from the (resident) parameters and a (fed) batch, as `result`.
-}
measure : Param.Spec r -> Sig batch -> (r -> batch -> Tensor k d R0) -> Result (List String) Graph
measure ((I.ParamBuilder ps) as spec) (I.SigBuilder bs) f =
    let
        lay =
            layout spec (Optim.sgd 0)

        inSig =
            I.SigBuilder
                { slots =
                    List.map2 (\n fl -> resident n (Just fl.dtype) (Just fl.shape)) lay.paramNames lay.fields
                        ++ List.map (\sl -> { sl | label = "batch", role = I.Fed }) bs.slots
                , build =
                    \es ->
                        let
                            ( p, r1 ) =
                                ps.build es

                            ( b, r2 ) =
                                bs.build r1
                        in
                        ( ( p, b ), r2 )
                , flatten = \( p, b ) -> ps.flatten p ++ bs.flatten b
                }
    in
    Graph.build "measure" inSig (Signature.label "result" Signature.anyTensor) (\( p, b ) -> f p b)


{-| The resident buffers' first contents, by name: the parameters drawn from `seed` in Elm (as
`Param.initial` draws them), zero optimizer state. For small models; large ones run
`Param.initGraph` and `put` its outputs.
-}
initial : Param.Spec r -> Optimizer -> Int -> List ( String, Bytes )
initial spec opt seed0 =
    let
        lay =
            layout spec opt

        ( _, params ) =
            List.foldl
                (\( n, f ) ( seed, acc ) ->
                    let
                        ( values, seed1 ) =
                            ParamInit.initValues f seed
                    in
                    ( seed1, ( n, Host.encodeValues f.dtype values ) :: acc )
                )
                ( seed0, [] )
                (List.map2 Tuple.pair lay.paramNames lay.fields)
    in
    List.reverse params ++ zeroState lay


zeroState : Layout -> List ( String, Bytes )
zeroState lay =
    let
        trainable =
            List.filter isTrainable lay.fields

        shapes =
            List.concatMap (\f -> List.repeat lay.slots f.shape) trainable
    in
    List.map2 (\n s -> ( n, Host.encodeValues F32 (List.repeat (List.product s) 0) )) lay.stateNames shapes
        ++ (if lay.hasStep then
                [ ( "step", Host.encodeValues F32 [ 0 ] ) ]

            else
                []
           )


{-| The same, starting from a saved parameter block (`Param.initial`'s layout: every field in
order, each padded to 16 bytes): a pretrained base, a checkpoint.
-}
initialFrom : Param.Spec r -> Optimizer -> Bytes -> List ( String, Bytes )
initialFrom spec opt block =
    let
        lay =
            layout spec opt

        slice offset len b =
            Decode.decode (Decode.bytes offset |> Decode.andThen (\_ -> Decode.bytes len)) b
                |> Maybe.withDefault (Encode.encode (Encode.sequence []))

        ( _, params ) =
            List.foldl
                (\( n, f ) ( off, acc ) ->
                    let
                        len =
                            P.dtSize f.dtype * List.product f.shape
                    in
                    ( off + Host.paddedSize len, ( n, slice off len block ) :: acc )
                )
                ( 0, [] )
                (List.map2 Tuple.pair lay.paramNames lay.fields)
    in
    List.reverse params ++ zeroState lay


{-| The loss in a `step` reply (the host returns only fed outputs, after a 16-byte header).
-}
loss : Bytes -> Float
loss =
    float32At 16


{-| The value in a `measure` reply.
-}
measured : Bytes -> Float
measured =
    float32At 16


float32At : Int -> Bytes -> Float
float32At offset b =
    Decode.decode (Decode.bytes offset |> Decode.andThen (\_ -> Decode.float32 LE)) b |> Maybe.withDefault 0
