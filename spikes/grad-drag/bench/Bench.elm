port module Bench exposing (main)

{-| Times the tentacle's two solvers on the same pointer path, under Node (`bench.js`): evg's
built-in (Levenberg–Marquardt over finite differences, each residual a re-render of the drawing and
`Layered.locate`, as `Evg.Drag.runVary` does) and the gradient solver (`Tentacle.solveFor`).

Flags: `{ method : "builtin" | "gradient", joint : Int, moves : Int }`. Each move nudges the target
along a loop the joint can reach; each solve starts from the previous answer, as during a drag.
Reports the mean and worst distance to the pointer, and for the gradient solver the graph runs.

-}

import Cannon
import Classify
import Cube
import Epidemic
import Evg.Drag as Drag
import Evg.Internal.Layered as Layered
import Evg.Internal.Optimize as Optimize
import Fit
import GradSolve
import Json.Decode as D
import Json.Encode as E
import Layout
import Lens
import Platform
import Tentacle
import Waves


port report : E.Value -> Cmd msg


targets : Int -> Int -> List ( Float, Float )
targets joint moves =
    let
        ( cx, cy ) =
            List.drop joint (Tentacle.positions Tentacle.init.angles) |> List.head |> Maybe.withDefault ( 0, 0 )

        reach =
            toFloat (joint + 1) * 19
    in
    List.map
        (\k ->
            let
                t =
                    toFloat k / toFloat moves * 2 * pi
            in
            ( cx + 0.35 * reach * sin t, cy + 0.25 * reach * (1 - cos t) )
        )
        (List.range 1 moves)


tip : Int -> List Float -> ( Float, Float )
tip joint angles =
    List.drop joint (Tentacle.positions angles) |> List.head |> Maybe.withDefault ( 0, 0 )


builtIn : Int -> ( Float, Float ) -> List Float -> List Float
builtIn joint ( px, py ) previous =
    let
        rest =
            List.drop (joint + 1) previous

        residuals candidate =
            let
                state =
                    { angles = candidate ++ rest }

                ( dx, dy ) =
                    case Layered.locate (Tentacle.handleKey joint) ( 0, 0 ) (Tentacle.drawing "#1c7ed6" (\i -> Drag.key (Tentacle.handleKey i)) state) of
                        Just ( x, y ) ->
                            ( x - px, y - py )

                        Nothing ->
                            ( 1.0e6, 1.0e6 )

                violations =
                    List.concatMap (\a -> [ 1000 * max 0 (-Tentacle.limit - a), 1000 * max 0 (a - Tentacle.limit) ]) (List.drop 1 candidate)
            in
            dx :: dy :: violations
    in
    Optimize.leastSquares { maxIterations = 20 } residuals (List.take (joint + 1) previous) ++ rest


main : Program D.Value () ()
main =
    Platform.worker
        { init =
            \flags ->
                let
                    field name decoder default =
                        D.decodeValue (D.field name decoder) flags |> Result.withDefault default

                    method =
                        field "method" D.string "gradient"

                    joint =
                        field "joint" D.int 11

                    moves =
                        field "moves" D.int 200

                    step target ( angles, errs, evals ) =
                        if method == "builtin" then
                            let
                                next =
                                    builtIn joint target angles

                                ( x, y ) =
                                    tip joint next
                            in
                            ( next, sqrt ((x - Tuple.first target) ^ 2 + (y - Tuple.second target) ^ 2) :: errs, evals )

                        else
                            let
                                s =
                                    GradSolve.solve { maxEvaluations = 12, tolerance = 0.05 } (Tentacle.problem joint) [ Tuple.first target, Tuple.second target ] angles
                            in
                            ( s.params, s.error :: errs, evals + s.evaluations )

                    ( _, errors, evaluations ) =
                        if method == "cannon" then
                            List.foldl
                                (\k ( params, errs, evals ) ->
                                    let
                                        t =
                                            toFloat k / toFloat moves

                                        ( tx, ty ) =
                                            Cannon.ballAt { angle = 0.5 + 0.6 * t, speed = 20 + 15 * t }

                                        s =
                                            GradSolve.solve { maxEvaluations = 8, tolerance = 0.02 } Cannon.problem [ tx, ty ] params
                                    in
                                    ( s.params, s.error :: errs, evals + s.evaluations )
                                )
                                ( [ 0.5, 20 ], [], 0 )
                                (List.range 1 moves)

                        else if method == "cannonEval" then
                            ( [], List.map (\_ -> GradSolve.evaluate Cannon.problem [ 0.7, 30 ] |> Result.map (\_ -> 0) |> Result.withDefault 1) (List.range 1 moves), moves )

                        else if method == "train" then
                            ( [], [ Fit.train moves Fit.init Fit.trainer |> Tuple.second |> .loss |> Maybe.withDefault -1 ], moves )

                        else if method == "lensEval" then
                            ( [], List.map (\_ -> GradSolve.evaluate (Lens.problem ( 2.6, 0.3 )) [ 0.4, -0.3, 0.1 ] |> Result.map (\_ -> 0) |> Result.withDefault 1) (List.range 1 moves), moves )

                        else if method == "lens" then
                            List.foldl
                                (\k ( params, errs, evals ) ->
                                    let
                                        t =
                                            toFloat k / toFloat moves

                                        s =
                                            GradSolve.solve { maxEvaluations = 3, tolerance = 1.0e-6 } (Lens.problem ( 2.9 - 0.6 * t, 0.5 * t )) (List.repeat 9 0) params
                                    in
                                    ( s.params, s.error :: errs, evals + s.evaluations )
                                )
                                ( [ 0.35, -0.35, 0 ], [], 0 )
                                (List.range 1 moves)

                        else if method == "cubeEval" then
                            ( [], List.map (\_ -> GradSolve.evaluate (Cube.problem ( 1, -1, 1 )) [ 0.1, 0.2, 0.3 ] |> Result.map (\_ -> 0) |> Result.withDefault 1) (List.range 1 moves), moves )

                        else if method == "epidemicEval" then
                            ( [], List.map (\_ -> GradSolve.evaluate Epidemic.problem [ 0.3, 0.1 ] |> Result.map (\_ -> 0) |> Result.withDefault 1) (List.range 1 moves), moves )

                        else if method == "layoutRelax" then
                            ( [], [ List.foldl (\_ st -> Layout.relax Nothing st |> Tuple.first) Layout.init (List.range 1 moves) |> .positions |> List.length |> toFloat ], moves )

                        else if method == "wavesField" then
                            ( [], List.map (\k -> Waves.make (60 + toFloat k) 24 |> .field |> List.length |> toFloat) (List.range 1 moves), moves )

                        else if method == "wavesEval" then
                            ( [], List.map (\_ -> GradSolve.evaluate (Waves.problem ( 300, 90 )) [ 70, 24 ] |> Result.map (\_ -> 0) |> Result.withDefault 1) (List.range 1 moves), moves )

                        else if method == "classifyEval" then
                            ( [], List.map (\_ -> GradSolve.evaluate (Classify.boundaryProblem ( 0.3, 0.2 )) Classify.init.params |> Result.map (\_ -> 0) |> Result.withDefault 1) (List.range 1 moves), moves )

                        else if method == "classifyTrain" then
                            ( [], [ Classify.train moves Classify.init Classify.trainer |> Tuple.second |> .loss |> Maybe.withDefault -1 ], moves )

                        else
                            List.foldl step ( Tentacle.init.angles, [], 0 ) (targets joint moves)
                in
                ( ()
                , report
                    (E.object
                        [ ( "method", E.string method )
                        , ( "joint", E.int joint )
                        , ( "moves", E.int moves )
                        , ( "meanError", E.float (List.sum errors / toFloat moves) )
                        , ( "worstError", E.float (List.maximum errors |> Maybe.withDefault 0) )
                        , ( "graphRuns", E.int evaluations )
                        ]
                    )
                )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
