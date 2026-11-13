module Epidemic exposing
    ( State, init, view
    , Run, simulate, peak, peakOnScreen, graph, problem, solvePeak, days
    )

{-| An epidemic (the SIR model: susceptible, infected, recovered) over 150 days, from 0.1% infected,
in daily steps. Drag the peak of the infected curve: the infection rate β and the recovery rate γ
change so that the peak is under the pointer.

The peak is a smooth maximum, so that it has derivatives: its day and height are the means of the
days and of the infected fraction, weighted by I⁶⁴ (the days near the top count, the rest vanish).
The model is written once over `Num.Ops`; its Jacobian runs back through all 150 days.

@docs State, init, view
@docs Run, simulate, peak, peakOnScreen, graph, problem, solvePeak, days

-}

import Dict
import Evg exposing (Evg)
import Evg.Drag as Drag
import GradSolve
import Graph exposing (Graph)
import Num exposing (Ops)
import Signature as Sig
import Tensor as T exposing (Dim, F64, R0, R1, Tensor)
import Tensor.Axis as Axis
import Transform


{-| The infection rate β (new infections per infected person per day, in a wholly susceptible
population) and the recovery rate γ (1 / days infectious).
-}
type alias State =
    { beta : Float, gamma : Float }


init : State
init =
    { beta = 0.3, gamma = 0.1 }


days : Int
days =
    150


{-| Each day's susceptible, infected and recovered fractions, day 1 to `days`.
-}
type alias Run n =
    List { s : n, i : n, r : n }


simulate : Ops n -> n -> n -> Run n
simulate o beta gamma =
    let
        step _ ( day, acc ) =
            let
                infections =
                    o.mul beta (o.mul day.s day.i)

                recoveries =
                    o.mul gamma day.i

                next =
                    { s = o.sub day.s infections, i = o.sub (o.add day.i infections) recoveries, r = o.add day.r recoveries }
            in
            ( next, next :: acc )
    in
    List.foldl step ( { s = o.const 0.999, i = o.const 0.001, r = o.const 0 }, [] ) (List.range 1 days)
        |> Tuple.second
        |> List.reverse


{-| The peak's day and height: their means weighted by I⁶⁴.
-}
peak : Ops n -> Run n -> ( n, n )
peak o run =
    let
        power64 x =
            List.foldl (\_ v -> o.mul v v) x (List.range 1 6)

        weights =
            List.map (\d -> power64 d.i) run

        total =
            List.foldl o.add (o.const 0) weights

        mean values =
            o.div (List.foldl o.add (o.const 0) (List.map2 o.mul weights values)) total
    in
    ( mean (List.indexedMap (\k _ -> o.const (toFloat (k + 1))) run), mean (List.map .i run) )


{-| The peak in pixels.
-}
peakOnScreen : Ops n -> n -> n -> ( n, n )
peakOnScreen o beta gamma =
    let
        ( day, height ) =
            peak o (simulate o beta gamma)
    in
    ( toX o day, toY o height )


toX : Ops n -> n -> n
toX o day =
    o.add (o.const left) (o.mul (o.const dayWidth) day)


toY : Ops n -> n -> n
toY o fraction =
    o.sub (o.const bottom) (o.mul (o.const fractionHeight) fraction)


left : Float
left =
    44


dayWidth : Float
dayWidth =
    2.75


bottom : Float
bottom =
    262


fractionHeight : Float
fractionHeight =
    440



-- THE MODEL


type P
    = P


type One
    = One


pDim : Dim P
pDim =
    T.dim P 2


onScreen : Tensor Float F64 (R1 P) -> Tensor Float F64 (R1 P)
onScreen params =
    let
        o =
            Num.tensors (T.fromList T.float64 T.scalar [ 0 ])

        each : Int -> Tensor Float F64 R0
        each i =
            params |> T.slice Axis.retag0of1 i (T.dim One 1) |> T.sumAll

        ( x, y ) =
            peakOnScreen o (each 0) (each 1)
    in
    T.stack Axis.liftRank0 pDim [ x, y ]


{-| Inputs β and γ; outputs the peak in pixels and its Jacobian (2 × 2), through all 150 days.
-}
graph : Result (List String) Graph
graph =
    Graph.build "epidemic"
        (Sig.label "params" (Sig.tensor T.float64 (T.r1 pDim)))
        (Sig.pair (Sig.label "point" (Sig.tensor T.float64 (T.r1 pDim))) (Sig.label "jacobian" (Sig.tensor T.float64 (T.r2 pDim pDim))))
        (\params -> ( onScreen params, Transform.jacobian onScreen params ))


compiled : GradSolve.Compiled
compiled =
    GradSolve.compile graph


problem : GradSolve.Problem
problem =
    { compiled = compiled, fixed = Dict.empty, lower = [ 0.08, 0.04 ], upper = [ 1, 0.5 ] }


solvePeak : Drag.Solver -> List Float
solvePeak s =
    let
        ( mx, my ) =
            case s.start of
                [ b, g ] ->
                    peakOnScreen Num.floats b g

                _ ->
                    s.grab

        ( gx, gy ) =
            s.grab

        ( px, py ) =
            s.pointer
    in
    (GradSolve.solve { maxEvaluations = 2, tolerance = 0.1 } problem [ px - (gx - mx), py - (gy - my) ] s.previous).params



-- THE DRAWING


{-| Where the peak can be, over a 16 × 16 grid of rates within the limits: shown as dots while the
peak is dragged. (With R₀ below 1 there is no outbreak, and the peak is the first day.)
-}
reachable : Evg Never
reachable =
    let
        steps16 lo hi =
            List.map (\k -> lo + (hi - lo) * toFloat k / 15) (List.range 0 15)

        dots =
            List.concatMap (\b -> List.map (\g -> peakOnScreen Num.floats b g) (steps16 0.04 0.5)) (steps16 0.08 1)
    in
    Evg.group [] (List.map (\p -> Evg.circle [ Evg.fillStr "#adb5bd" ] { r = 1.6, center = p }) dots)


view : Drag.View State msg
view ctx state =
    let
        run =
            simulate Num.floats state.beta state.gamma

        curve f colour w dash =
            Evg.polyline
                ([ Evg.strokeStr colour, Evg.strokeWidth w, Evg.fillStr "none", Evg.linejoinRound ] ++ dash)
                (( left, toY Num.floats (f { s = 0.999, i = 0.001, r = 0 }) ) :: List.indexedMap (\k d -> ( toX Num.floats (toFloat (k + 1)), toY Num.floats (f d) )) run)

        ( px, py ) =
            peakOnScreen Num.floats state.beta state.gamma

        ( peakDay, peakHeight ) =
            peak Num.floats run

        label =
            "R₀ "
                ++ String.fromFloat (toFloat (round (10 * state.beta / state.gamma)) / 10)
                ++ "  ·  ill for "
                ++ String.fromFloat (toFloat (round (10 / state.gamma)) / 10)
                ++ " days  ·  peak on day "
                ++ String.fromInt (round peakDay)
                ++ ", "
                ++ String.fromInt (round (100 * peakHeight))
                ++ "% ill  ·  "
                ++ String.fromInt (round (100 * (List.reverse run |> List.head |> Maybe.map .r |> Maybe.withDefault 0)))
                ++ "% infected in all"

        gridLine f =
            Evg.group []
                [ Evg.line [ Evg.strokeStr "#e9ecef" ] ( left, toY Num.floats f ) ( toX Num.floats (toFloat days), toY Num.floats f )
                , Evg.text [ Evg.fillStr "#868e96", Evg.fontSize 11 ] { x = left - 6, y = toY Num.floats f + 4, anchor = Evg.End } (String.fromInt (round (100 * f)) ++ "%")
                ]
    in
    Evg.group []
        (List.map gridLine [ 0, 0.1, 0.2, 0.3, 0.4, 0.5 ]
            ++ [ Evg.text [ Evg.fillStr "#868e96", Evg.fontSize 11 ] { x = toX Num.floats (toFloat days), y = bottom + 16, anchor = Evg.End } "150 days"
               , curve .i "#e03131" 3 []
               , Evg.circle
                    [ Evg.fillStr "#e8590c"
                    , Evg.strokeStr "white"
                    , Evg.strokeWidth 2
                    , Drag.onDrag ctx
                        "peak"
                        (\() ->
                            Drag.varyWith solvePeak
                                [ state.beta, state.gamma ]
                                (\p ->
                                    case p of
                                        [ b, g ] ->
                                            { beta = b, gamma = g }

                                        _ ->
                                            state
                                )
                                |> Drag.withFloatingWith { ghost = Just 0.35, tether = Nothing }
                                |> Drag.withOverlay reachable
                        )
                    ]
                    { r = 8, center = ( px, py ) }
               , Evg.text [ Evg.fillStr "#495057", Evg.fontSize 12 ] { x = left, y = 16, anchor = Evg.Start } label
               ]
        )
