module WavesTests exposing (suite)

{-| The interference pattern: the field graph against plain Elm, the phase gradient against central
differences, the bright bands where the textbook puts them, and the band solver.
-}

import Expect
import GradSolve
import Num
import Test exposing (Test, describe, test)
import Waves


near : Float -> Float -> Float -> Bool
near tol a b =
    abs (a - b) <= tol * max 1 (abs a)


at : ( Float, Float )
at =
    ( 300, 90 )


suite : Test
suite =
    describe "Waves"
        [ test "the field graph's picture is the plain one" <|
            \_ ->
                let
                    s =
                        Waves.make 90 30

                    plain =
                        List.concatMap
                            (\j ->
                                List.map
                                    (\i ->
                                        (1 + cos (2 * pi * Waves.phase Num.floats 90 30 ( Waves.cell * (toFloat i + 0.5), Waves.cell * (toFloat j + 0.5) ))) / 2
                                    )
                                    (List.range 0 (Waves.columns - 1))
                            )
                            (List.range 0 (Waves.rows - 1))
                in
                Expect.equal ( List.length s.field, List.all identity (List.map2 (near 1.0e-12) plain s.field) ) ( Waves.columns * Waves.rows, True )
        , test "the phase's gradient matches central differences" <|
            \_ ->
                let
                    h =
                        1.0e-6

                    d f =
                        (f h - f -h) / (2 * h)
                in
                case GradSolve.evaluate (Waves.problem at) [ 90, 30 ] of
                    Ok ( [ p ], [ [ ds, dw ] ] ) ->
                        Expect.equal
                            [ near 1.0e-12 (Waves.phase Num.floats 90 30 at) p
                            , near 1.0e-6 (d (\e -> Waves.phase Num.floats (90 + e) 30 at)) ds
                            , near 1.0e-6 (d (\e -> Waves.phase Num.floats 90 (30 + e) at)) dw
                            ]
                            [ True, True, True ]

                    _ ->
                        Expect.fail "no result"
        , test "far away, the bright bands are where d sin θ = mλ says" <|
            \_ ->
                let
                    -- a point at angle θ from the axis, far from the sources
                    far =
                        3.0e5

                    point angle =
                        ( 36 + far * cos angle, 150 - far * sin angle )

                    theta =
                        asin (2 * 30 / 90)
                in
                Expect.within (Expect.Absolute 1.0e-3) 2 (Waves.phase Num.floats 90 30 (point theta))
        , test "the solver moves the grabbed band under the pointer" <|
            \_ ->
                let
                    level =
                        Waves.phase Num.floats 90 30 ( 300, 90 )

                    s =
                        GradSolve.solve { maxEvaluations = 20, tolerance = 1.0e-6 } (Waves.problem ( 300, 60 )) [ level ] [ 90, 30 ]
                in
                case s.params of
                    [ sp, wl ] ->
                        Expect.within (Expect.Absolute 1.0e-6) level (Waves.phase Num.floats sp wl ( 300, 60 ))

                    _ ->
                        Expect.fail "no params"
        ]
