module Fit exposing
    ( State, init, view
    , Trainer, trainer, train
    , weights, hidden, predict, net, dragGraph, dragProblem, trainGraph, spec
    )

{-| A 1 → 8 → 1 tanh network fitted to ten points, trained in the browser: `Train.step` (AdamW, mean
squared error) run by `Tensor.Eval`, a few steps every animation frame.

  - **Drag a point** (evg's built-in `Drag.vary2`): the network chases it as it trains.
  - **Drag the curve**: wherever you grab it, all 25 weights change so the curve passes under the
    pointer at that x (`Drag.varyWith` with the gradient of the network's output). Let go and
    training pulls it back towards the data.

The weights are one flat vector, the single field of the network's `Param.Spec`, so the training
graph (whose resident buffer `param0` holds them) and the drag graph share it.

@docs State, init, view
@docs Trainer, trainer, train
@docs weights, hidden, predict, net, dragGraph, dragProblem, trainGraph, spec

-}

import Dict exposing (Dict)
import Evg exposing (Evg)
import Evg.Drag as Drag
import GradSolve
import Graph exposing (Graph)
import Nn
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (Dim, F64, R1, Tensor)
import Tensor.Axis as Axis
import Tensor.Eval as Eval
import Train
import Training
import Transform


type alias State =
    { params : List Float, points : List ( Float, Float ) }


hidden : Int
hidden =
    8


{-| Input weights, hidden biases, output weights, output bias.
-}
weights : Int
weights =
    3 * hidden + 1


init : State
init =
    { params = List.map (\i -> 0.9 * sin (toFloat (i * i) * 1.7 + 0.3)) (List.range 1 weights)
    , points =
        List.map (\i -> ( -2.7 + 0.6 * toFloat i, 1.1 * sin (1.3 * (-2.7 + 0.6 * toFloat i)) + 0.25 * cos (toFloat (7 * i)) ))
            (List.range 0 9)
    }


{-| The network on one input, in plain Elm, for drawing.
-}
predict : List Float -> Float -> Float
predict params x =
    let
        w1 =
            List.take hidden params

        b1 =
            List.take hidden (List.drop hidden params)

        w2 =
            List.take hidden (List.drop (2 * hidden) params)

        b2 =
            List.drop (3 * hidden) params |> List.head |> Maybe.withDefault 0
    in
    b2 + List.sum (List.map3 (\a b c -> c * tanh (a * x + b)) w1 b1 w2)


tanh : Float -> Float
tanh v =
    if v > 20 then
        1

    else if v < -20 then
        -1

    else
        let
            e2 =
                Basics.e ^ (2 * v)
        in
        (e2 - 1) / (e2 + 1)



-- THE MODEL


type W
    = W


type H
    = H


type N
    = N


type One
    = One


wDim : Dim W
wDim =
    T.dim W weights


hDim : Dim H
hDim =
    T.dim H hidden


nDim : Dim N
nDim =
    T.dim N 10


oneDim : Dim One
oneDim =
    T.dim One 1


{-| The network on a batch of inputs, from the flat weights.
-}
net : Tensor Float F64 (R1 W) -> Tensor Float F64 (R1 n) -> Tensor Float F64 (R1 n)
net w x =
    let
        part k =
            T.slice Axis.retag0of1 (k * hidden) hDim w

        b2 =
            T.slice Axis.retag0of1 (3 * hidden) oneDim w |> T.sumAll

        y =
            T.outer (part 0) x |> T.plus (T.rows (part 1)) |> T.tanh |> T.matVec (part 2)
    in
    y |> T.plus (T.fillLike b2 y)


spec : Param.Spec { w : Tensor Float F64 (R1 W) }
spec =
    Param.record (\w -> { w = w })
        |> Param.normal 0.5 .w T.float64 (T.r1 wDim)


trainGraph : Result (List String) Graph
trainGraph =
    Train.step spec
        (Optim.adamW 0.03)
        (Sig.pair (Sig.label "x" (Sig.tensor T.float64 (T.r1 nDim))) (Sig.label "y" (Sig.tensor T.float64 (T.r1 nDim))))
        (\p ( x, y ) -> Nn.mseLoss (net p.w x) y |> T.toFloat)


{-| Inputs the weights and the x being dragged; outputs the network's value there and its gradient
with respect to the weights (as a 1 × 25 Jacobian).
-}
dragGraph : Result (List String) Graph
dragGraph =
    Graph.build "fitDrag"
        (Sig.pair (Sig.label "params" (Sig.tensor T.float64 (T.r1 wDim))) (Sig.label "at" (Sig.tensor T.float64 (T.r1 oneDim))))
        (Sig.pair (Sig.label "point" (Sig.tensor T.float64 (T.r1 oneDim))) (Sig.label "jacobian" (Sig.tensor T.float64 (T.r2 oneDim wDim))))
        (\( w, at ) -> ( net w at, Transform.jacobian (\v -> net v at) w ))


dragCompiled : GradSolve.Compiled
dragCompiled =
    GradSolve.compile dragGraph


dragProblem : Float -> GradSolve.Problem
dragProblem x =
    { compiled = dragCompiled
    , fixed = Dict.singleton "at" { dtype = "f64", shape = [ 1 ], data = Eval.Floats [ x ] }
    , lower = List.repeat weights -20
    , upper = List.repeat weights 20
    }



-- TRAINING


stepper : Training.Stepper
stepper =
    Training.stepper spec trainGraph


{-| The training step's resident buffers (weights, AdamW's moments, the step count) and the last
loss.
-}
type alias Trainer =
    Training.Trainer


trainer : Trainer
trainer =
    Training.start stepper


{-| `n` training steps from the state's weights and points.
-}
train : Int -> State -> Trainer -> ( State, Trainer )
train n state t =
    let
        ( params, after ) =
            Training.train stepper
                n
                [ { dtype = "f64", shape = [ 10 ], data = Eval.Floats (List.map Tuple.first state.points) }
                , { dtype = "f64", shape = [ 10 ], data = Eval.Floats (List.map Tuple.second state.points) }
                ]
                state.params
                t
    in
    ( { state | params = params }, after )



-- THE DRAWING


toScreen : ( Float, Float ) -> ( Float, Float )
toScreen ( x, y ) =
    ( 240 + 66 * x, 150 - 55 * y )


fromScreen : ( Float, Float ) -> ( Float, Float )
fromScreen ( sx, sy ) =
    ( (sx - 240) / 66, (150 - sy) / 55 )


solveCurve : Drag.Solver -> List Float
solveCurve s =
    let
        ( gx, gy ) =
            fromScreen s.grab

        ( _, py ) =
            fromScreen s.pointer

        offset =
            gy - predict s.start gx
    in
    (GradSolve.solve { maxEvaluations = 8, tolerance = 1.0e-4 } (dragProblem gx) [ py - offset ] s.previous).params


view : Drag.View State msg
view ctx state =
    let
        curve =
            List.map (\k -> toScreen ( -3.6 + 0.06 * toFloat k, predict state.params (-3.6 + 0.06 * toFloat k) )) (List.range 0 120)

        setPoint i x y =
            { state
                | points =
                    List.indexedMap
                        (\j p ->
                            if j == i then
                                ( x, y )

                            else
                                p
                        )
                        state.points
            }

        -- The points sit on the fitted curve, inside its 22 px grab band: each point's own grab area,
        -- an invisible circle wider than the band and drawn over it, keeps a press near a point on the
        -- point.
        point i ( x, y ) =
            Evg.group [ Drag.onDrag ctx ("point" ++ String.fromInt i) (\() -> Drag.vary2 ( x, y ) (setPoint i)) ]
                [ Evg.circle [ Evg.fillStr "#1c7ed6", Evg.fillOpacity 0 ] { r = 15, center = toScreen ( x, y ) }
                , Evg.circle [ Evg.fillStr "#1c7ed6", Evg.strokeStr "white", Evg.strokeWidth 2 ] { r = 7, center = toScreen ( x, y ) }
                ]
    in
    Evg.group []
        ([ Evg.line [ Evg.strokeStr "#dee2e6" ] ( 0, 150 ) ( 480, 150 )
         , Evg.line [ Evg.strokeStr "#dee2e6" ] ( 240, 0 ) ( 240, 300 )
         , Evg.polyline
            [ Evg.strokeStr "#e8590c"
            , Evg.strokeWidth 3
            , Evg.fillStr "none"
            , Evg.linejoinRound
            ]
            curve
         , Evg.polyline
            [ Evg.strokeStr "#e8590c"
            , Evg.strokeOpacity 0
            , Evg.strokeWidth 22
            , Evg.fillStr "none"
            , Drag.onDrag ctx "curve" (\() -> Drag.varyWith solveCurve state.params (\p -> { state | params = p }))
            ]
            curve
         ]
            ++ List.indexedMap point state.points
        )
