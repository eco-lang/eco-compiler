module Classify exposing
    ( State, init, view
    , Trainer, trainer, train
    , weights, score, net, scoreGraph, boundaryProblem, trainGraph, spec, contour
    )

{-| A 2 → 8 → 2 tanh classifier of red and blue points, trained in the browser (`Train.step`,
AdamW, softmax cross-entropy), with its decision boundary drawn where the two classes' scores are
equal.

  - **Drag a point**: the boundary follows as the network trains.
  - **Drag the boundary**: wherever you grab it, all 42 weights change so that the boundary passes
    under the pointer. The solver's target is a level, not a point: the score difference at the
    pointer must equal what it was where you grabbed (`Drag.varyWith`, with the gradient of the
    score difference with respect to the weights).

@docs State, init, view
@docs Trainer, trainer, train
@docs weights, score, net, scoreGraph, boundaryProblem, trainGraph, spec, contour

-}

import Array exposing (Array)
import Dict
import Evg exposing (Evg)
import Evg.Drag as Drag
import Evg.Path exposing (Path(..), PathSegment(..))
import GradSolve
import Graph exposing (Graph)
import Nn
import Optim
import Param
import Signature as Sig
import Tensor as T exposing (Dim, F64, R1, R2, Tensor)
import Tensor.Axis as Axis
import Tensor.Eval as Eval
import Train
import Training
import Transform


{-| The weights, and the points with their classes (0 red, 1 blue).
-}
type alias State =
    { params : List Float, points : List { at : ( Float, Float ), red : Bool } }


hidden : Int
hidden =
    8


{-| Input weights (2 × 8), hidden biases, output weights (8 × 2), output biases.
-}
weights : Int
weights =
    2 * hidden + hidden + 2 * hidden + 2


init : State
init =
    let
        moon sign dx dy k =
            let
                t =
                    toFloat k * pi / 6
            in
            ( 1.5 * cos t + dx, sign * 1.3 * sin t + dy )
    in
    { params = List.map (\i -> 0.8 * sin (toFloat (i * i) * 1.3 + 0.7)) (List.range 1 weights)
    , points =
        List.map (\k -> { at = moon 1 -0.7 -0.35 k, red = True }) (List.range 0 6)
            ++ List.map (\k -> { at = moon -1 0.7 0.35 k, red = False }) (List.range 0 6)
    }



-- THE NETWORK IN PLAIN ELM, FOR DRAWING


type alias Unpacked =
    { wx : List Float, wy : List Float, b : List Float, v : List Float, c : Float }


{-| The weights as the drawing needs them: per hidden unit its input weights and bias, and the
difference of its two output weights.
-}
unpack : List Float -> Unpacked
unpack params =
    let
        a =
            Array.fromList params

        at i =
            Array.get i a |> Maybe.withDefault 0

        units f =
            List.map f (List.range 0 (hidden - 1))
    in
    { wx = units (\j -> at j)
    , wy = units (\j -> at (hidden + j))
    , b = units (\j -> at (2 * hidden + j))
    , v = units (\j -> at (3 * hidden + 2 * j) - at (3 * hidden + 2 * j + 1))
    , c = at (5 * hidden) - at (5 * hidden + 1)
    }


scoreAt : Unpacked -> ( Float, Float ) -> Float
scoreAt u ( x, y ) =
    List.foldl (+) u.c (List.map2 (*) u.v (List.map3 (\wx wy b -> tanh (wx * x + wy * y + b)) u.wx u.wy u.b))


{-| The red score minus the blue score at a point, in plain Elm: the boundary is where it is 0.
-}
score : List Float -> ( Float, Float ) -> Float
score params =
    scoreAt (unpack params)


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


type W1
    = W1


type W2
    = W2


type H
    = H


type In
    = In


type Cls
    = Cls


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


inDim : Dim In
inDim =
    T.dim In 2


clsDim : Dim Cls
clsDim =
    T.dim Cls 2


nDim : Dim N
nDim =
    T.dim N 14


oneDim : Dim One
oneDim =
    T.dim One 1


{-| The class scores (red, blue) of a batch of points, from the flat weights.
-}
net : Tensor Float F64 (R1 W) -> Tensor Float F64 (R2 n In) -> Tensor Float F64 (R2 n Cls)
net w x =
    let
        w1 =
            w |> T.slice Axis.retag0of1 0 (T.dim W1 (2 * hidden)) |> T.reshape (T.r2 inDim hDim)

        b1 =
            w |> T.slice Axis.retag0of1 (2 * hidden) hDim

        w2 =
            w |> T.slice Axis.retag0of1 (3 * hidden) (T.dim W2 (2 * hidden)) |> T.reshape (T.r2 hDim clsDim)

        b2 =
            w |> T.slice Axis.retag0of1 (5 * hidden) clsDim
    in
    x |> T.matmul w1 |> T.plus (T.rows b1) |> T.tanh |> T.matmul w2 |> T.plus (T.rows b2)


{-| The red score minus the blue score at one point.
-}
scoreAtPoint : Tensor Float F64 (R1 In) -> Tensor Float F64 (R1 W) -> Tensor Float F64 (R1 One)
scoreAtPoint at w =
    net w (T.reshape (T.r2 oneDim inDim) at) |> T.matVec (T.fromList T.float64 (T.r1 clsDim) [ 1, -1 ])


spec : Param.Spec { w : Tensor Float F64 (R1 W) }
spec =
    Param.record (\w -> { w = w })
        |> Param.normal 0.5 .w T.float64 (T.r1 wDim)


trainGraph : Result (List String) Graph
trainGraph =
    Train.step spec
        (Optim.adamW 0.05)
        (Sig.pair (Sig.label "x" (Sig.tensor T.float64 (T.r2 nDim inDim))) (Sig.label "label" (Sig.tensor T.int64 (T.r1 nDim))))
        (\p ( x, y ) -> net p.w x |> Nn.crossEntropyIndices y |> T.toFloat)


{-| Inputs the weights and a point; outputs the score difference there and its gradient with respect
to the weights (as a 1 × 42 Jacobian).
-}
scoreGraph : Result (List String) Graph
scoreGraph =
    Graph.build "classifyBoundary"
        (Sig.pair (Sig.label "params" (Sig.tensor T.float64 (T.r1 wDim))) (Sig.label "at" (Sig.tensor T.float64 (T.r1 inDim))))
        (Sig.pair (Sig.label "score" (Sig.tensor T.float64 (T.r1 oneDim))) (Sig.label "jacobian" (Sig.tensor T.float64 (T.r2 oneDim wDim))))
        (\( w, at ) -> ( scoreAtPoint at w, Transform.jacobian (scoreAtPoint at) w ))


compiled : GradSolve.Compiled
compiled =
    GradSolve.compile scoreGraph


{-| Moving the score at a point.
-}
boundaryProblem : ( Float, Float ) -> GradSolve.Problem
boundaryProblem ( x, y ) =
    { compiled = compiled
    , fixed = Dict.singleton "at" { dtype = "f64", shape = [ 2 ], data = Eval.Floats [ x, y ] }
    , lower = List.repeat weights -20
    , upper = List.repeat weights 20
    }



-- TRAINING


stepper : Training.Stepper
stepper =
    Training.stepper spec trainGraph


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
                [ { dtype = "f64", shape = [ 14, 2 ], data = Eval.Floats (List.concatMap (\p -> [ Tuple.first p.at, Tuple.second p.at ]) state.points) }
                , { dtype = ""
                  , shape = [ 14 ]
                  , data =
                        Eval.Ints
                            (List.map
                                (\p ->
                                    if p.red then
                                        0

                                    else
                                        1
                                )
                                state.points
                            )
                  }
                ]
                state.params
                t
    in
    ( { state | params = params }, after )



-- THE DRAWING


width : Float
width =
    480


height : Float
height =
    320


scale : Float
scale =
    64


toScreen : ( Float, Float ) -> ( Float, Float )
toScreen ( x, y ) =
    ( width / 2 + scale * x, height / 2 - scale * y )


fromScreen : ( Float, Float ) -> ( Float, Float )
fromScreen ( sx, sy ) =
    ( (sx - width / 2) / scale, (height / 2 - sy) / scale )


{-| The boundary (where `f` is 0) of a function sampled every `step` pixels, by marching squares:
line segments in screen coordinates.
-}
contour : Float -> (( Float, Float ) -> Float) -> List ( ( Float, Float ), ( Float, Float ) )
contour step f =
    let
        nx =
            round (width / step)

        ny =
            round (height / step)

        values =
            Array.initialize ((nx + 1) * (ny + 1))
                (\k -> f ( step * toFloat (modBy (nx + 1) k), step * toFloat (k // (nx + 1)) ))

        v i j =
            Array.get (j * (nx + 1) + i) values |> Maybe.withDefault 0

        pos i j =
            ( step * toFloat i, step * toFloat j )

        crossing ( p1, v1 ) ( p2, v2 ) =
            if (v1 > 0) /= (v2 > 0) then
                let
                    t =
                        v1 / (v1 - v2)
                in
                Just ( Tuple.first p1 + t * (Tuple.first p2 - Tuple.first p1), Tuple.second p1 + t * (Tuple.second p2 - Tuple.second p1) )

            else
                Nothing

        cell i j =
            let
                a =
                    ( pos i j, v i j )

                b =
                    ( pos (i + 1) j, v (i + 1) j )

                c =
                    ( pos (i + 1) (j + 1), v (i + 1) (j + 1) )

                d =
                    ( pos i (j + 1), v i (j + 1) )

                edges =
                    [ crossing a b, crossing b c, crossing c d, crossing d a ]
            in
            case List.filterMap identity edges of
                [ p, q ] ->
                    [ ( p, q ) ]

                [ e0, e1, e2, e3 ] ->
                    let
                        centre =
                            (Tuple.second a + Tuple.second b + Tuple.second c + Tuple.second d) / 4
                    in
                    if (centre > 0) == (Tuple.second a > 0) then
                        [ ( e0, e1 ), ( e2, e3 ) ]

                    else
                        [ ( e3, e0 ), ( e1, e2 ) ]

                _ ->
                    []
    in
    List.concatMap (\j -> List.concatMap (\i -> cell i j) (List.range 0 (nx - 1))) (List.range 0 (ny - 1))


solveBoundary : Drag.Solver -> List Float
solveBoundary s =
    let
        level =
            score s.start (fromScreen s.grab)
    in
    (GradSolve.solve { maxEvaluations = 6, tolerance = 1.0e-3 } (boundaryProblem (fromScreen s.pointer)) [ level ] s.previous).params


movePoint : Drag.Solver -> List Float
movePoint s =
    case s.start of
        [ x, y ] ->
            [ clamp -3.6 3.6 (x + (Tuple.first s.pointer - Tuple.first s.grab) / scale)
            , clamp -2.4 2.4 (y - (Tuple.second s.pointer - Tuple.second s.grab) / scale)
            ]

        _ ->
            s.start


colour : Float -> String
colour q =
    let
        mix r b =
            String.fromInt (round (q * r + (1 - q) * b))
    in
    "rgb(" ++ mix 255 165 ++ "," ++ mix 201 216 ++ "," ++ mix 201 255 ++ ")"


view : Drag.View State msg
view ctx state =
    let
        u =
            unpack state.params

        cellSize =
            20

        background =
            List.concatMap
                (\j ->
                    List.map
                        (\i ->
                            let
                                sx =
                                    cellSize * toFloat i

                                sy =
                                    cellSize * toFloat j

                                q =
                                    1 / (1 + Basics.e ^ -(scoreAt u (fromScreen ( sx + cellSize / 2, sy + cellSize / 2 ))))
                            in
                            Evg.rect [ Evg.fillStr (colour q) ] { x = sx, y = sy, width = cellSize + 0.5, height = cellSize + 0.5 }
                        )
                        (List.range 0 (round (width / cellSize) - 1))
                )
                (List.range 0 (round (height / cellSize) - 1))

        boundary =
            List.map (\( p, q ) -> M p [ L q ]) (contour 10 (fromScreen >> scoreAt u))

        setPoint i at =
            { state
                | points =
                    List.indexedMap
                        (\j p ->
                            if j == i then
                                { p | at = at }

                            else
                                p
                        )
                        state.points
            }

        point i p =
            Evg.circle
                [ Evg.fillStr
                    (if p.red then
                        "#e03131"

                     else
                        "#1971c2"
                    )
                , Evg.strokeStr "white"
                , Evg.strokeWidth 2
                , Drag.onDrag ctx
                    ("point" ++ String.fromInt i)
                    (\() ->
                        Drag.varyWith movePoint
                            [ Tuple.first p.at, Tuple.second p.at ]
                            (\xy ->
                                case xy of
                                    [ x, y ] ->
                                        setPoint i ( x, y )

                                    _ ->
                                        state
                            )
                    )
                ]
                { r = 7, center = toScreen p.at }
    in
    Evg.group []
        (background
            ++ [ Evg.path [ Evg.strokeStr "#212529", Evg.strokeWidth 2.5, Evg.fillStr "none", Evg.linecapRound ] boundary
               , Evg.path
                    [ Evg.strokeStr "#212529"
                    , Evg.strokeOpacity 0
                    , Evg.strokeWidth 22
                    , Evg.fillStr "none"
                    , Drag.onDrag ctx "boundary" (\() -> Drag.varyWith solveBoundary state.params (\p -> { state | params = p }))
                    ]
                    boundary
               ]
            ++ List.indexedMap point state.points
        )
