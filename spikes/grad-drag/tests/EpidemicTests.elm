module EpidemicTests exposing (suite)

{-| The epidemic's tensor model against the plain simulation, its Jacobian through 150 days against
central differences, the peak against the curve's true maximum, and the peak solver.
-}

import Epidemic
import Expect
import GradSolve
import Num
import Test exposing (Test, describe, test)


near : Float -> Float -> Float -> Bool
near tol a b =
    abs (a - b) <= tol * max 1 (abs a)


suite : Test
suite =
    describe "Epidemic"
        [ test "the tensor model's peak is the plain one's" <|
            \_ ->
                let
                    ( x, y ) =
                        Epidemic.peakOnScreen Num.floats 0.42 0.13
                in
                case GradSolve.evaluate Epidemic.problem [ 0.42, 0.13 ] of
                    Ok ( [ tx, ty ], _ ) ->
                        Expect.equal ( near 1.0e-10 x tx, near 1.0e-10 y ty ) ( True, True )

                    _ ->
                        Expect.fail "no result"
        , test "its Jacobian through 150 days matches central differences" <|
            \_ ->
                let
                    h =
                        1.0e-7

                    fd f =
                        let
                            ( x1, y1 ) =
                                f h

                            ( x0, y0 ) =
                                f -h
                        in
                        [ (x1 - x0) / (2 * h), (y1 - y0) / (2 * h) ]

                    dBeta =
                        fd (\d -> Epidemic.peakOnScreen Num.floats (0.42 + d) 0.13)

                    dGamma =
                        fd (\d -> Epidemic.peakOnScreen Num.floats 0.42 (0.13 + d))
                in
                case GradSolve.evaluate Epidemic.problem [ 0.42, 0.13 ] of
                    Ok ( _, [ [ a, b ], [ c, d ] ] ) ->
                        Expect.equal (List.map2 (near 1.0e-5) [ a, c, b, d ] (dBeta ++ dGamma)) [ True, True, True, True ]

                    _ ->
                        Expect.fail "no Jacobian"
        , test "the smooth peak is within a day and 1% of the curve's top" <|
            \_ ->
                let
                    run =
                        Epidemic.simulate Num.floats 0.3 0.1

                    ( day, height ) =
                        Epidemic.peak Num.floats run

                    ( topDay, top ) =
                        List.indexedMap (\k d -> ( toFloat (k + 1), d.i )) run
                            |> List.foldl
                                (\( k, v ) ( bk, bv ) ->
                                    if v > bv then
                                        ( k, v )

                                    else
                                        ( bk, bv )
                                )
                                ( 0, 0 )
                in
                Expect.equal ( abs (day - topDay) <= 1, abs (height - top) <= 0.01 * top ) ( True, True )
        , test "nobody is lost: S + I + R stays 1" <|
            \_ ->
                Expect.equal (List.all (\d -> abs (d.s + d.i + d.r - 1) < 1.0e-12) (Epidemic.simulate Num.floats 0.5 0.2)) True
        , test "the solver moves the peak to a reachable point" <|
            \_ ->
                let
                    ( tx, ty ) =
                        Epidemic.peakOnScreen Num.floats 0.22 0.09

                    s =
                        GradSolve.solve { maxEvaluations = 30, tolerance = 0.01 } Epidemic.problem [ tx, ty ] [ Epidemic.init.beta, Epidemic.init.gamma ]
                in
                Expect.lessThan 0.01 s.error
        ]
