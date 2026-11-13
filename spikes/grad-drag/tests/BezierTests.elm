module BezierTests exposing (suite)

{-| The Bézier curve's derived features: tensor models against plain Elm, Jacobians against central
differences, a textbook check of curvature, the nearest-point search, and each drag's solver.
-}

import Bezier
import Expect
import GradSolve
import Num
import Test exposing (Test, describe, test)


near : Float -> Float -> Float -> Bool
near tol a b =
    abs (a - b) <= tol * max 1 (abs a)


pts : Bezier.Pts Float
pts =
    Bezier.init.pts


inner : Bezier.Pts Float -> List Float
inner p =
    [ Tuple.first p.p1, Tuple.second p.p1, Tuple.first p.p2, Tuple.second p.p2 ]


withInner : List Float -> Bezier.Pts Float
withInner l =
    case l of
        [ a, b, c, d ] ->
            { pts | p1 = ( a, b ), p2 = ( c, d ) }

        _ ->
            pts


{-| Central differences of a plain function of the unknowns, as Jacobian rows.
-}
numeric : (List Float -> List Float) -> List Float -> List (List Float)
numeric f x =
    let
        h =
            1.0e-5

        column j =
            let
                bump d =
                    List.indexedMap
                        (\k v ->
                            if k == j then
                                v + d

                            else
                                v
                        )
                        x
            in
            List.map2 (\a b -> (a - b) / (2 * h)) (f (bump h)) (f (bump -h))

        cols =
            List.indexedMap (\j _ -> column j) x
    in
    List.indexedMap (\i _ -> List.map (\c -> List.drop i c |> List.head |> Maybe.withDefault 0) cols) (f x)


matches : (List Float -> List Float) -> GradSolve.Problem -> List Float -> Expect.Expectation
matches plain problem x =
    case GradSolve.evaluate problem x of
        Ok ( values, rows ) ->
            Expect.equal
                ( List.map2 (near 1.0e-10) (plain x) values, List.map2 (near 1.0e-5) (List.concat (numeric plain x)) (List.concat rows) )
                ( List.map (\_ -> True) values, List.map (\_ -> True) (List.concat rows) )

        Err e ->
            Expect.fail e


u0 : Float
u0 =
    0.35


curvePlain : List Float -> List Float
curvePlain l =
    let
        ( x, y ) =
            Bezier.point Num.floats (withInner (List.take 4 l)) ((List.drop 4 l |> List.head |> Maybe.withDefault 0) / Bezier.scaleU)
    in
    [ x, y ]


tangentPlain : List Float -> List Float
tangentPlain l =
    let
        p =
            withInner l

        ( x, y ) =
            Bezier.point Num.floats p u0

        ( tx, ty ) =
            Bezier.unitTangent Num.floats p u0
    in
    [ Bezier.holdWeight * x, Bezier.holdWeight * y, Bezier.tangentLength * tx, Bezier.tangentLength * ty ]


bendPlain : List Float -> List Float
bendPlain l =
    let
        p =
            withInner l

        ( x, y ) =
            Bezier.point Num.floats p u0

        ( tx, ty ) =
            Bezier.unitTangent Num.floats p u0

        w =
            Bezier.holdWeight
    in
    [ w * x, w * y, w * Bezier.tangentLength * tx, w * Bezier.tangentLength * ty, Bezier.bendScale * Bezier.curvature Num.floats p u0 ]


lowestPlain : List Float -> List Float
lowestPlain l =
    let
        ( x, y ) =
            Bezier.lowest Num.floats (withInner l)
    in
    [ x, y ]


suite : Test
suite =
    describe "Bezier"
        [ test "the curve graph (control points and the parameter) against plain Elm and central differences" <|
            \_ -> matches curvePlain (Bezier.curveProblem pts) (inner pts ++ [ Bezier.scaleU * u0 ])
        , test "the tangent graph" <|
            \_ -> matches tangentPlain (Bezier.tangentProblem pts u0) (inner pts)
        , test "the curvature graph" <|
            \_ -> matches bendPlain (Bezier.bendProblem pts u0) (inner pts)
        , test "the lowest-point graph" <|
            \_ -> matches lowestPlain (Bezier.lowestProblem pts) (inner pts)
        , test "a Bézier quarter circle has curvature 1/r in the middle, and starts along P1 − P0" <|
            \_ ->
                let
                    r =
                        100

                    c =
                        0.5522847498 * r

                    q =
                        { p0 = ( r, 0 ), p1 = ( r, c ), p2 = ( c, r ), p3 = ( 0, r ) }

                    ( tx, ty ) =
                        Bezier.unitTangent Num.floats q 0
                in
                Expect.equal ( near 1.0e-3 (1 / r) (Bezier.curvature Num.floats q 0.5), ( abs tx < 1.0e-12, near 1.0e-12 1 ty ) ) ( True, ( True, True ) )
        , test "the nearest-point search finds a point's own parameter" <|
            \_ ->
                Expect.within (Expect.Absolute 1.0e-6) 0.6180339 (Bezier.nearestU pts (Bezier.point Num.floats pts 0.6180339))
        , test "dragging the curve off itself: the grabbed point reaches the pointer" <|
            \_ ->
                let
                    ( x, y ) =
                        Bezier.point Num.floats pts u0

                    s =
                        GradSolve.solve { maxEvaluations = 20, tolerance = 0.01 } (Bezier.curveProblem pts) [ x + 25, y - 40 ] (inner pts ++ [ Bezier.scaleU * u0 ])
                in
                Expect.lessThan 0.01 s.error
        , test "turning the tangent: the direction is reached and the point stays" <|
            \_ ->
                let
                    ( x, y ) =
                        Bezier.point Num.floats pts u0

                    ( tx, ty ) =
                        Bezier.unitTangent Num.floats pts u0

                    a =
                        degrees 30

                    ( dx, dy ) =
                        ( tx * cos a - ty * sin a, tx * sin a + ty * cos a )

                    s =
                        GradSolve.solve { maxEvaluations = 30, tolerance = 1.0e-3 } (Bezier.tangentProblem pts u0) [ Bezier.holdWeight * x, Bezier.holdWeight * y, Bezier.tangentLength * dx, Bezier.tangentLength * dy ] (inner pts)

                    p =
                        withInner s.params

                    ( nx, ny ) =
                        Bezier.unitTangent Num.floats p u0

                    ( px, py ) =
                        Bezier.point Num.floats p u0
                in
                Expect.equal ( abs (nx - dx) + abs (ny - dy) < 1.0e-4, sqrt ((px - x) ^ 2 + (py - y) ^ 2) < 1.0e-3 ) ( True, True )
        , test "bending: the radius of curvature is reached, point and direction held" <|
            \_ ->
                let
                    ( x, y ) =
                        Bezier.point Num.floats pts u0

                    ( tx, ty ) =
                        Bezier.unitTangent Num.floats pts u0

                    k0 =
                        Bezier.curvature Num.floats pts u0

                    target =
                        k0 * 1.6

                    w =
                        Bezier.holdWeight

                    s =
                        GradSolve.solve { maxEvaluations = 30, tolerance = 1.0e-3 } (Bezier.bendProblem pts u0) [ w * x, w * y, w * Bezier.tangentLength * tx, w * Bezier.tangentLength * ty, Bezier.bendScale * target ] (inner pts)

                    p =
                        withInner s.params

                    ( px, py ) =
                        Bezier.point Num.floats p u0
                in
                Expect.equal ( near 1.0e-3 target (Bezier.curvature Num.floats p u0), sqrt ((px - x) ^ 2 + (py - y) ^ 2) < 1.0e-3 ) ( True, True )
        , test "the lowest point follows a target" <|
            \_ ->
                let
                    ( lx, ly ) =
                        Bezier.lowest Num.floats pts

                    s =
                        GradSolve.solve { maxEvaluations = 20, tolerance = 0.01 } (Bezier.lowestProblem pts) [ lx + 20, ly + 15 ] (inner pts)
                in
                Expect.lessThan 0.01 s.error
        ]
