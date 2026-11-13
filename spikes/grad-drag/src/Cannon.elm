module Cannon exposing
    ( State, init, view
    , flightTime, steps, ballAt, trajectory, graph, problem, toScreen
    )

{-| A cannon with air drag. The ball's position 1.2 s after firing is drawn as a handle: drag it, and
the launch angle and speed change so that the ball is there at that moment. The position is the end
of a 40-step simulation with quadratic drag (`Control.repeat`), so the solver needs its derivatives
through all 40 steps: the tensor package computes them exactly.

@docs State, init, view
@docs flightTime, steps, ballAt, trajectory, graph, problem, toScreen

-}

import Dict
import Evg exposing (Evg)
import Evg.Drag as Drag
import Evg.Transform as Transform
import GradSolve
import Graph exposing (Graph)
import Signature as Sig
import Tensor as T exposing (Dim, F64, R1, Tensor)
import Tensor.Axis as Axis
import Tensor.Control as Control
import Transform


{-| Launch angle (radians above the horizontal) and speed (m/s).
-}
type alias State =
    { angle : Float, speed : Float }


init : State
init =
    { angle = degrees 50, speed = 28 }


gravity : Float
gravity =
    9.81


{-| Quadratic drag: acceleration −k |v| v.
-}
drag : Float
drag =
    0.012


steps : Int
steps =
    40


flightTime : Float
flightTime =
    1.2


dt : Float
dt =
    flightTime / toFloat steps


lower : List Float
lower =
    [ degrees 5, 5 ]


upper : List Float
upper =
    [ degrees 85, 60 ]


{-| Where the ball can be at `flightTime`, over a 16 × 16 grid of launch angles and speeds within
the limits: shown as dots while the ball is dragged.
-}
reachable : Evg Never
reachable =
    let
        steps16 lo hi =
            List.map (\k -> lo + (hi - lo) * toFloat k / 15) (List.range 0 15)

        dots =
            case ( lower, upper ) of
                ( [ a0, s0 ], [ a1, s1 ] ) ->
                    List.concatMap (\a -> List.map (\sp -> ballAt { angle = a, speed = sp }) (steps16 s0 s1)) (steps16 a0 a1)

                _ ->
                    []
    in
    Evg.group [] (List.map (\p -> Evg.circle [ Evg.fillStr "#adb5bd" ] { r = 1.6, center = toScreen p }) dots)


{-| World metres to drawing pixels: 4 px a metre, the cannon at (36, 262).
-}
toScreen : ( Float, Float ) -> ( Float, Float )
toScreen ( x, y ) =
    ( 36 + 4 * x, 262 - 4 * y )


fromScreenDelta : ( Float, Float ) -> ( Float, Float )
fromScreenDelta ( dx, dy ) =
    ( dx / 4, -dy / 4 )



-- PLAIN ELM, FOR DRAWING


type alias Body =
    { x : Float, y : Float, vx : Float, vy : Float }


step : Body -> Body
step b =
    let
        v =
            sqrt (b.vx * b.vx + b.vy * b.vy)

        ax =
            -drag * v * b.vx

        ay =
            -drag * v * b.vy - gravity
    in
    { x = b.x + dt * b.vx, y = b.y + dt * b.vy, vx = b.vx + dt * ax, vy = b.vy + dt * ay }


launch : State -> Body
launch s =
    { x = 0, y = 0, vx = s.speed * cos s.angle, vy = s.speed * sin s.angle }


{-| Where the ball is after `steps` steps.
-}
ballAt : State -> ( Float, Float )
ballAt s =
    List.foldl (\_ b -> step b) (launch s) (List.range 1 steps) |> (\b -> ( b.x, b.y ))


{-| The flight until the ball comes down (at most 8 s), in world coordinates.
-}
trajectory : State -> List ( Float, Float )
trajectory s =
    let
        go n b acc =
            if n > 8 * toFloat steps / flightTime || (b.y < 0 && n > 0) then
                List.reverse (( b.x, b.y ) :: acc)

            else
                go (n + 1) (step b) (( b.x, b.y ) :: acc)
    in
    go 0 (launch s) []



-- THE MODEL


type Two
    = Two


two : Dim Two
two =
    T.dim Two 2


{-| The same simulation over tensors: position and velocity as 2-vectors, the drag factor |v|
spread over both components.
-}
ball : Tensor Float F64 (R1 Two) -> Tensor Float F64 (R1 Two)
ball params =
    let
        angle =
            T.take Axis.retag0of1 (T.fromList T.int64 (T.r1 (T.dim () 1)) [ 0 ]) params |> T.sumAll

        speed =
            T.take Axis.retag0of1 (T.fromList T.int64 (T.r1 (T.dim () 1)) [ 1 ]) params |> T.sumAll

        v0 =
            T.stack Axis.liftRank0 two [ T.times speed (T.cos angle), T.times speed (T.sin angle) ]

        g =
            T.fromList T.float64 (T.r1 two) [ 0, -gravity ]

        sig =
            Sig.pair (Sig.tensor T.float64 (T.r1 two)) (Sig.tensor T.float64 (T.r1 two))

        body ( p, v ) =
            let
                speedNow =
                    v |> T.times v |> T.sumAll |> T.sqrt

                a =
                    v |> T.times (T.fillLike speedNow v) |> T.scale -drag |> T.plus g
            in
            ( p |> T.plus (T.scale dt v), v |> T.plus (T.scale dt a) )
    in
    Control.repeat steps sig body ( T.zeros T.float64 (T.r1 two), v0 ) |> Tuple.first


{-| Input `params` (angle, speed); outputs the ball's position at `flightTime` and its Jacobian.
-}
graph : Result (List String) Graph
graph =
    Graph.build "cannon"
        (Sig.label "params" (Sig.tensor T.float64 (T.r1 two)))
        (Sig.pair (Sig.label "point" (Sig.tensor T.float64 (T.r1 two))) (Sig.label "jacobian" (Sig.tensor T.float64 (T.r2 two two))))
        (\params -> ( ball params, Transform.jacobian ball params ))


{-| `graph`, prepared once.
-}
compiled : GradSolve.Compiled
compiled =
    GradSolve.compile graph


problem : GradSolve.Problem
problem =
    { compiled = compiled, fixed = Dict.empty, lower = lower, upper = upper }


solve : Drag.Solver -> List Float
solve s =
    let
        start =
            stateOf s.start

        ( mx, my ) =
            toScreen (ballAt start)

        ( gx, gy ) =
            s.grab

        ( px, py ) =
            s.pointer

        ( tx, ty ) =
            fromScreenDelta ( px - (gx - mx) - 36, py - (gy - my) - 262 )
    in
    (GradSolve.solve { maxEvaluations = 8, tolerance = 0.02 } problem [ tx, ty ] s.previous).params


stateOf : List Float -> State
stateOf l =
    case l of
        [ a, s ] ->
            { angle = a, speed = s }

        _ ->
            init



-- THE DRAWING


view : Drag.View State msg
view ctx state =
    let
        path =
            List.map toScreen (trajectory state)

        ( bx, by ) =
            toScreen (ballAt state)

        early =
            List.take (steps + 1) path

        ( cx, cy ) =
            toScreen ( 0, 0 )
    in
    Evg.group []
        [ Evg.rect [ Evg.fillStr "#e9ecef" ] { x = 0, y = 262, width = 480, height = 38 }
        , Evg.polyline [ Evg.strokeStr "#adb5bd", Evg.strokeWidth 2, Evg.dashPattern [ 4, 5 ], Evg.fillStr "none" ] path
        , Evg.polyline [ Evg.strokeStr "#495057", Evg.strokeWidth 2.5, Evg.fillStr "none" ] early
        , Evg.group [ Transform.translate cx cy, Transform.rotate -(state.angle * 180 / pi) ]
            [ Evg.rect [ Evg.fillStr "#343a40", Evg.cornerRadius 3 ] { x = 0, y = -6, width = 28 + state.speed / 3, height = 12 } ]
        , Evg.circle [ Evg.fillStr "#495057" ] { r = 11, center = ( cx, cy ) }
        , Evg.circle
            [ Evg.fillStr "#e8590c"
            , Evg.strokeStr "white"
            , Evg.strokeWidth 2
            , Drag.onDrag ctx
                "ball"
                (\() ->
                    Drag.varyWith solve [ state.angle, state.speed ] stateOf
                        |> Drag.withFloatingWith { ghost = Just 0.35, tether = Nothing }
                        |> Drag.withOverlay reachable
                )
            ]
            { r = 10, center = ( bx, by ) }
        , Evg.text [ Evg.fillStr "#495057", Evg.fontSize 13 ]
            { x = 470, y = 24, anchor = Evg.End }
            ("angle " ++ String.fromInt (round (state.angle * 180 / pi)) ++ "°   speed " ++ String.fromFloat (toFloat (round (state.speed * 10)) / 10) ++ " m/s   ball at t = 1.2 s")
        ]
