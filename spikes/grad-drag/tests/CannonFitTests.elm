module CannonFitTests exposing (suite)

{-| The cannon's tensor simulation and the fit network against their plain-Elm twins, their
derivatives against finite differences, the solvers reaching targets, and training lowering the
loss.
-}

import Cannon
import Expect
import Fit
import GradSolve
import Test exposing (Test, describe, test)


near : Float -> Float -> Float -> Bool
near tol a b =
    abs (a - b) <= tol * max 1 (abs a)


suite : Test
suite =
    describe "Cannon and Fit"
        [ test "the tensor simulation lands where the plain one does" <|
            \_ ->
                let
                    s =
                        { angle = 0.9, speed = 31 }

                    ( x, y ) =
                        Cannon.ballAt s
                in
                case GradSolve.evaluate Cannon.problem [ s.angle, s.speed ] of
                    Ok ( [ tx, ty ], _ ) ->
                        Expect.equal ( near 1.0e-9 x tx, near 1.0e-9 y ty ) ( True, True )

                    _ ->
                        Expect.fail "no result"
        , test "its Jacobian through 60 steps matches central differences" <|
            \_ ->
                let
                    h =
                        1.0e-6

                    fd f =
                        let
                            ( x1, y1 ) =
                                Cannon.ballAt (f h)

                            ( x0, y0 ) =
                                Cannon.ballAt (f -h)
                        in
                        [ (x1 - x0) / (2 * h), (y1 - y0) / (2 * h) ]

                    dAngle =
                        fd (\d -> { angle = 0.9 + d, speed = 31 })

                    dSpeed =
                        fd (\d -> { angle = 0.9, speed = 31 + d })
                in
                case GradSolve.evaluate Cannon.problem [ 0.9, 31 ] of
                    Ok ( _, [ [ a, b ], [ c, d ] ] ) ->
                        Expect.equal (List.map2 (near 1.0e-6) [ a, c, b, d ] (dAngle ++ dSpeed)) [ True, True, True, True ]

                    _ ->
                        Expect.fail "no Jacobian"
        , test "the solver finds a launch that puts the ball at a target" <|
            \_ ->
                let
                    ( tx, ty ) =
                        Cannon.ballAt { angle = 0.6, speed = 40 }

                    s =
                        GradSolve.solve { maxEvaluations = 30, tolerance = 1.0e-4 } Cannon.problem [ tx, ty ] [ 1.1, 20 ]
                in
                Expect.lessThan 1.0e-4 s.error
        , test "the tensor network computes what the drawing draws" <|
            \_ ->
                case GradSolve.evaluate (Fit.dragProblem 0.7) Fit.init.params of
                    Ok ( [ y ], _ ) ->
                        Expect.within (Expect.Absolute 1.0e-12) (Fit.predict Fit.init.params 0.7) y

                    _ ->
                        Expect.fail "no result"
        , test "its gradient matches central differences" <|
            \_ ->
                let
                    h =
                        1.0e-6

                    numeric =
                        List.indexedMap
                            (\j _ ->
                                let
                                    bump d =
                                        List.indexedMap
                                            (\k v ->
                                                if k == j then
                                                    v + d

                                                else
                                                    v
                                            )
                                            Fit.init.params
                                in
                                (Fit.predict (bump h) 0.7 - Fit.predict (bump -h) 0.7) / (2 * h)
                            )
                            Fit.init.params
                in
                case GradSolve.evaluate (Fit.dragProblem 0.7) Fit.init.params of
                    Ok ( _, [ g ] ) ->
                        Expect.equal (List.map2 (near 1.0e-6) numeric g) (List.repeat Fit.weights True)

                    _ ->
                        Expect.fail "no gradient"
        , test "dragging the curve moves it to the pointer at that x" <|
            \_ ->
                let
                    s =
                        GradSolve.solve { maxEvaluations = 8, tolerance = 1.0e-4 } (Fit.dragProblem 0.7) [ 1.5 ] Fit.init.params
                in
                Expect.within (Expect.Absolute 1.0e-4) 1.5 (Fit.predict s.params 0.7)
        , test "training lowers the loss" <|
            \_ ->
                let
                    ( _, first ) =
                        Fit.train 1 Fit.init Fit.trainer

                    ( _, later ) =
                        Fit.train 150 Fit.init Fit.trainer
                in
                case ( first.loss, later.loss ) of
                    ( Just a, Just b ) ->
                        Expect.lessThan (a / 4) b

                    _ ->
                        Expect.fail "no loss"
        ]
