module Train exposing
    ( step, measure
    , initial, initialFrom
    )

{-| Training a model means running one graph over and over: each run reads the model's parameters,
computes a loss on a batch of examples, and writes back the trainable parameters moved against the
loss's gradient. This module builds that graph from a parameter description (`Param.Spec`), an
optimizer (`Optim.Optimizer`) and a loss function, together with a graph that only evaluates a
function of the parameters and a batch, and the bytes that the graphs' buffers start with.

    trainStep =
        Train.step params (Optim.adamW 1.0e-3) (Sig.pair images labels) <|
            \p ( x, y ) -> network p x |> Nn.crossEntropyIndices y

What lets the parameters change from one run to the next is that they are kept in _resident
buffers_: buffers that whatever runs a graph keeps between runs, read by an input with the buffer's
_resident name_ and replaced by an output with the same one (see `Graph.Role`). Each tensor field of
the description is kept under the resident name `Param.names` gives it. An optimizer may keep
_state_ for each trainable field, such as a running average of its gradient. That state, and a
counter of the steps taken that comes with it, are resident too. So the only fed inputs of the
training graph are the batch and, when the optimizer's rate is `Optim.PerStep`, the learning rate,
and its only fed output is the loss.

The names of the optimizer's buffers are `state`, `state0`, `state1` .. and `step`, each prefixed
with `n.` when the description's first tensor field is in a `Param.named n` part, and not prefixed
otherwise. Two training graphs whose buffers one runtime keeps together share every optimizer
buffer whose name they both use, so two models trained side by side, such as the two halves of a
GAN, keep their optimizer buffers apart when each description starts with a field of its own
`Param.named` part.

Clipping and the optimizer's update are given f32 values whatever the parameters' dtypes: each
gradient is cast to f32 before it is clipped and handed to the optimizer, each parameter is cast to
f32 for the optimizer's update and the result back to the field's dtype, and the optimizer's state
is f32.


# Graphs

@docs step, measure


# Resident buffers

Before the first run the buffers need contents. `initial` and `initialFrom` give them as _first
contents_: a list of pairs, each a resident name and the bytes of the tensor that buffer starts
with. How the bytes reach the buffers is up to whatever runs the graphs. `Tensor.Eval` takes its
buffers as values, not bytes, so these are not for it: there, `Param.initInPlace` and
`Tensor.Eval.residentZeros` give the buffers' starting values.

The bytes `initial` gives are in the package's one encoding, which `Param.initial` uses too. A
tensor's elements are in row-major order, each little-endian at its dtype's width, with nothing
between or around them. An f16 or bf16 element is a 16-bit pattern rounded to nearest even from the
value's f32 pattern, so a value is rounded twice, and a value too large for the format becomes ±∞.
A mask element is one byte, 0 or 1. A 64-bit integer is its low 32 bits followed by its high 32
bits, the two's-complement pattern for a negative `Int`.

@docs initial, initialFrom

-}

import Bytes exposing (Bytes)
import Graph exposing (Graph)
import Optim exposing (Optimizer)
import Param
import Signature exposing (Sig)
import Tensor exposing (F32, R0, Tensor)
import Tensor.Internal.Encode as Elements
import Tensor.Internal.Expr as E exposing (Expr)
import Tensor.Internal.Grad as Grad
import Tensor.Internal.Io as Io
import Tensor.Internal.Names exposing (names)
import Tensor.Internal.Ops as O
import Tensor.Internal.ParamInit as ParamInit
import Tensor.Internal.Prim as P exposing (DT(..))
import Tensor.Internal.Types as I
import Tensor.Internal.Values as Values


{-| The buffers and inputs that a parameter description and an optimizer give a training graph,
worked out once so that `step`, `measure`, `initial` and `initialFrom` agree on them.

`paramNames` has one resident name per entry of `fields`. `stateNames` has one name per optimizer
state tensor, over every trainable field, `stepName` is the name of the step counter's buffer, and
`slots` is the number of state tensors per trainable field.

-}
type alias Layout =
    { fields : List I.Field
    , paramNames : List String
    , stateNames : List String
    , stepName : String
    , hasStep : Bool
    , hasRate : Bool
    , slots : Int
    }


{-| Returns the layout for a description and an optimizer.

The state tensors are named by numbering the label `state` over all of them, so a single one is
`state`. There is a `step` buffer only when the optimizer has state slots, and a `rate` input only
when its rate is `PerStep`. The state and step names are prefixed with `n.` when the first field
is in the group `n` (`Param.named`).

-}
layout : Param.Spec r -> Optimizer -> Layout
layout (I.ParamBuilder ps) (I.Optimizer o) =
    let
        trainable =
            List.filter isTrainable ps.fields

        prefix =
            case ps.fields of
                { name } :: _ ->
                    Maybe.withDefault "" (Maybe.map (\n -> n ++ ".") name)

                [] ->
                    ""
    in
    { fields = ps.fields
    , paramNames = ParamInit.residentNames ps.fields
    , stateNames = List.map ((++) prefix) (names "state" (List.repeat (o.slots * List.length trainable) "state"))
    , stepName = prefix ++ "step"
    , hasStep = o.slots > 0
    , hasRate = o.rate == I.PerStep
    , slots = o.slots
    }


{-| Returns whether a field is trainable, that is, updated by training.
-}
isTrainable : I.Field -> Bool
isTrainable f =
    case f.kind of
        I.Trainable _ ->
            True

        _ ->
            False


{-| Returns a slot labelled `n`, with the given dtype and shape, that is resident under the name
`n`.
-}
resident : String -> Maybe DT -> Maybe (List Int) -> I.Slot
resident n dt s =
    { label = n, dtype = dt, shape = s, role = I.Resident n }


{-| Builds the graph `train_step`, which takes one step of training: it computes the loss on the
current parameters and a batch, and updates the trainable parameters and the optimizer's state with
the gradient of that loss. If the graph cannot be built, the result is the errors `Graph.build`
reports, each starting with `train_step` and a colon.

The graph's inputs, in order, are:

  - each tensor field of the description, in field order, with the field's dtype and shape,
    resident under its resident name (`Param.names`);
  - the optimizer's state: for each trainable field in field order, as many f32 tensors of the
    field's shape as the optimizer has state slots, resident under `state` when there is one in all
    and `state0`, `state1` .. otherwise, prefixed as the module documentation describes;
  - `step`, a resident `f32 [1]` counting the steps taken, only when the optimizer has state slots,
    under `step` prefixed in the same way;
  - `rate`, a fed `f32 [1]`, only when the optimizer's rate is `Optim.PerStep`;
  - the batch: one fed input for each slot of the batch signature, with the slot's dtype and shape,
    named `batch` when there is one and `batch0`, `batch1` .. otherwise, whatever the slots' labels.

Its outputs, in order, are the new value of each trainable field in field order, the new state
tensors in the order of their inputs, and, when the graph has a `step` input, the new `step`, one
more than the input. Each is resident under the same name as the input it replaces, and they are
named `next` when there is one and `next0`, `next1` .. otherwise. Last comes `loss`, fed: the loss
on the parameters the run was given. Frozen and data fields are inputs only, so the graph leaves
their buffers as they are.

The gradient is taken with respect to every tensor field, as `Param.grad` takes it, and only the
trainable fields' gradients are used, each cast to f32. When the optimizer clips
(`Optim.clipGlobalNorm`), each of them is multiplied by min(1, c / n), where c is the bound and n
is the square root of the sum of the squares of the elements of all those gradients. The optimizer's
update is then given each trainable field's value in f32, its gradient and its state tensors,
together with the rate, which is the `rate` input or the optimizer's fixed rate, and the step, which
is the new `step` when the graph has one and 1 otherwise.

The update must give back, for each trainable field, a new value of the field's shape and as many
new state tensors as the optimizer has state slots, each f32 of the field's shape. Otherwise the
graph is refused, with an error naming the field's resident name, unless the tensor at fault has
already failed, in which case its own error is the one reported. An optimizer with fewer than 0
state slots, and a `clipGlobalNorm` bound that is not greater than 0, are refused before the graph
is built, with an error beginning `train_step:`.

`step` and `rate` are declared `[1]` and read as scalars inside the graph, because the package
assumes that MAX's C API takes no rank-0 inputs. No other input is widened: a rank-0 field, state
tensor or batch slot is declared rank 0. `Tensor.Eval` too must be given `rate` with shape `[1]`.

-}
step : Param.Spec r -> Optimizer -> Sig batch -> (r -> batch -> Tensor Float F32 R0) -> Result (List String) Graph
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
                [ resident lay.stepName (Just F32) (Just [ 1 ]) ]

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
            List.filterMap identity
                (List.map2
                    (\n f ->
                        if isTrainable f then
                            Just n

                        else
                            Nothing
                    )
                    lay.paramNames
                    lay.fields
                )

        outSlots =
            List.map (\n -> { label = "next", dtype = Nothing, shape = Nothing, role = I.Resident n }) nextNames
                ++ List.map (\n -> { label = "next", dtype = Nothing, shape = Nothing, role = I.Resident n }) lay.stateNames
                ++ List.map (\_ -> { label = "next", dtype = Nothing, shape = Nothing, role = I.Resident lay.stepName }) stepSlots
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
                    List.filterMap identity
                        (List.map4
                            (\n f w g ->
                                if isTrainable f then
                                    Just ( ( n, f ), w, g )

                                else
                                    Nothing
                            )
                            lay.paramNames
                            lay.fields
                            values
                            grads
                        )

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

                -- [] when there are no slots, so map3 below is given [] for each field instead
                states =
                    chunk o.slots i.state

                updated =
                    List.map3
                        (\( ( n, f ), w, _ ) g st ->
                            let
                                ( w1, st1 ) =
                                    checkUpdate n f o.slots (o.update hyper (O.cast F32 w) g st)
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

        refusals =
            (if o.slots < 0 then
                [ "train_step: the optimizer keeps " ++ String.fromInt o.slots ++ " state slots, but it must keep 0 or more" ]

             else
                []
            )
                ++ (case o.clip of
                        Just maxNorm ->
                            if maxNorm > 0 then
                                []

                            else
                                [ "train_step: clipGlobalNorm's bound is " ++ String.fromFloat maxNorm ++ ", but it must be greater than 0" ]

                        Nothing ->
                            []
                   )
    in
    if List.isEmpty refusals then
        Graph.build "train_step" inSig outSig body

    else
        Err refusals


{-| Returns the update's result `( w1, st1 )` for the trainable field `f`, resident under `n`, when
`w1` has the field's shape and `st1` holds `slots` tensors, each f32 of the field's shape.
Otherwise it returns `w1` and `slots` state tensors, each carrying a build error that names `n`:
with the wrong number of state tensors every one of them fails, and otherwise each that differs. A
tensor that has already failed keeps its own error instead, and with the wrong number of state
tensors, each state tensor is `w1` with the error, so a failed `w1` makes them all carry its error.
-}
checkUpdate : String -> I.Field -> Int -> ( Expr, List Expr ) -> ( Expr, List Expr )
checkUpdate n f slots ( w1, st1 ) =
    let
        got =
            List.length st1
    in
    if got /= slots then
        let
            msg =
                "Train: the optimizer's update gives " ++ String.fromInt got ++ " state tensors for " ++ n ++ ", but the optimizer keeps " ++ String.fromInt slots
        in
        ( E.failWith msg w1, List.map (\_ -> E.failWith msg w1) (List.repeat (Basics.max 0 slots) ()) )

    else
        ( if E.shape w1 == f.shape then
            w1

          else
            E.failWith ("Train: the optimizer's update gives " ++ n ++ " as " ++ describe (E.dtype w1) (E.shape w1) ++ ", but the parameter is " ++ describe F32 f.shape) w1
        , List.indexedMap
            (\k e ->
                if E.dtype e == F32 && E.shape e == f.shape then
                    e

                else
                    E.failWith ("Train: the optimizer's update gives state " ++ String.fromInt k ++ " of " ++ n ++ " as " ++ describe (E.dtype e) (E.shape e) ++ ", but it must be " ++ describe F32 f.shape) e
            )
            st1
        )


{-| Returns a dtype and shape as the error messages here write them, such as `f32[3,4]`.
-}
describe : DT -> List Int -> String
describe dt shape =
    P.dtName dt ++ "[" ++ String.join "," (List.map String.fromInt shape) ++ "]"


{-| Returns the rate a `Fixed` rate carries. A `PerStep` rate gives 0, which is never used: the
graph then has a `rate` input and reads the rate from it.
-}
fixedRate : I.Rate -> Float
fixedRate r =
    case r of
        I.Fixed v ->
            v

        I.PerStep ->
            0


{-| Returns the first of `es` and the rest when `present` and `es` is not empty, and `Nothing` and
`es` unchanged otherwise.
-}
takeIf : Bool -> List Expr -> ( Maybe Expr, List Expr )
takeIf present es =
    case ( present, es ) of
        ( True, e :: rest ) ->
            ( Just e, rest )

        _ ->
            ( Nothing, es )


{-| Returns a list holding the value `m` holds, or an empty list for `Nothing`.
-}
maybeList : Maybe a -> List a
maybeList m =
    case m of
        Just x ->
            [ x ]

        Nothing ->
            []


{-| Splits `l` into consecutive lists of `n` elements, the last one shorter when `n` does not divide
its length. Gives an empty list when `n` is 0 or less, or `l` is empty.
-}
chunk : Int -> List a -> List (List a)
chunk n l =
    if n <= 0 || List.isEmpty l then
        []

    else
        List.take n l :: chunk n (List.drop n l)


{-| Builds the graph `measure`, which computes `f` of the parameters and a batch, such as a loss or
an accuracy, without training.

Its inputs are each tensor field of the description, resident under its resident name, followed by
the batch, fed and named as `step` names it. It therefore reads the same parameter buffers as a
training graph for the same description. Its one output is fed and named `result`. If the graph
cannot be built, the result is the errors `Graph.build` reports, each starting with `measure` and a
colon.

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


{-| Returns the first contents of every resident buffer of the graph `step` builds for the same
description and optimizer, with the parameters drawn from the seed in Elm.

First comes each tensor field's entry, in field order, exactly as `Param.initial` gives it:
trainable and frozen fields drawn as their initialisers say, data fields zeros. Then come zeros for
each optimizer state tensor, under its name and in the order of `step`'s inputs, and, when the
optimizer has state slots, the step counter at 0, under its name, so the first run's update sees
step 1.

Frozen fields are drawn rather than given, so a model built on given values, such as a pretrained
base, starts from `initialFrom` instead. Every value here is computed in Elm; `Param.initInPlace`
instead builds a graph that draws the parameters into their buffers where the graph runs, and its
drawn values need not agree with those drawn here for the same seed.

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
                    ( seed1, ( n, Elements.encodeValues f.dtype (Values.forDtype f.dtype values) ) :: acc )
                )
                ( seed0, [] )
                (List.map2 Tuple.pair lay.paramNames lay.fields)
    in
    List.reverse params ++ zeroState lay


{-| Returns the first contents of the optimizer's buffers: under each state name, an f32 tensor of
zeros with the shape of the trainable field it belongs to, then, under the step name, one f32 0
when the layout has a step.
-}
zeroState : Layout -> List ( String, Bytes )
zeroState lay =
    let
        trainable =
            List.filter isTrainable lay.fields

        shapes =
            List.concatMap (\f -> List.repeat lay.slots f.shape) trainable
    in
    List.map2 (\n s -> ( n, Elements.encodeValues F32 (Values.FloatValues (List.repeat (List.product s) 0)) )) lay.stateNames shapes
        ++ (if lay.hasStep then
                [ ( lay.stepName, Elements.encodeValues F32 (Values.FloatValues [ 0 ]) ) ]

            else
                []
           )


{-| Returns the first contents as `initial` does, but with every tensor field's bytes taken from
`given` instead of drawn: for each field in field order, frozen and data fields included, the first
entry of `given` under its resident name (`Param.names`). Zeros for the optimizer's state and `step`
follow, as in `initial`. Entries under any other name are ignored.

The bytes are expected in the package encoding, but only their length is checked: it must be the
field's dtype's width in bytes times its number of elements. When a field has no entry, or its
entry has another length, the result is an error naming the first such field in field order.

-}
initialFrom : Param.Spec r -> Optimizer -> List ( String, Bytes ) -> Result String (List ( String, Bytes ))
initialFrom spec opt given =
    let
        lay =
            layout spec opt

        one ( n, f ) acc =
            let
                expected =
                    P.dtSize f.dtype * List.product f.shape
            in
            case List.filter (\( m, _ ) -> m == n) given of
                ( _, b ) :: _ ->
                    if Bytes.width b == expected then
                        Result.map ((::) ( n, b )) acc

                    else
                        Err (n ++ ": " ++ String.fromInt (Bytes.width b) ++ " bytes, but its dtype and shape take " ++ String.fromInt expected)

                [] ->
                    Err ("no tensor for " ++ n)
    in
    List.foldr one (Ok []) (List.map2 Tuple.pair lay.paramNames lay.fields)
        |> Result.map (\params -> params ++ zeroState lay)
