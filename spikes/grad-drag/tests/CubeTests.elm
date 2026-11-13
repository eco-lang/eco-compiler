module CubeTests exposing (suite)

{-| The cube's tensor projection against the plain one, its Jacobian against central differences,
the corner solver, and that turning keeps the cube a cube.
-}

import Cube
import Expect
import GradSolve
import Num
import Test exposing (Test, describe, test)


near : Float -> Float -> Float -> Bool
near tol a b =
    abs (a - b) <= tol * max 1 (abs a)


corner : Cube.Vec3 Float
corner =
    Cube.apply Cube.init ( 1, -1, 1 )


plain : List Float -> ( Float, Float )
plain angles =
    case angles of
        [ a, b, c ] ->
            Cube.project Num.floats (Cube.rotate Num.floats ( a, b, c ) corner)

        _ ->
            ( 0, 0 )


angles0 : List Float
angles0 =
    [ 0.3, -0.2, 0.5 ]


suite : Test
suite =
    describe "Cube"
        [ test "the tensor projection is the plain one" <|
            \_ ->
                case GradSolve.evaluate (Cube.problem corner) angles0 of
                    Ok ( [ x, y ], _ ) ->
                        Expect.equal ( near 1.0e-12 (Tuple.first (plain angles0)) x, near 1.0e-12 (Tuple.second (plain angles0)) y ) ( True, True )

                    _ ->
                        Expect.fail "no result"
        , test "its Jacobian matches central differences" <|
            \_ ->
                let
                    h =
                        1.0e-6

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
                                    angles0

                            ( x1, y1 ) =
                                plain (bump h)

                            ( x0, y0 ) =
                                plain (bump -h)
                        in
                        [ (x1 - x0) / (2 * h), (y1 - y0) / (2 * h) ]
                in
                case GradSolve.evaluate (Cube.problem corner) angles0 of
                    Ok ( _, [ rx, ry ] ) ->
                        let
                            cols =
                                List.map column [ 0, 1, 2 ]
                        in
                        Expect.equal
                            (List.map2 (near 1.0e-6) (List.map (List.head >> Maybe.withDefault 0) cols ++ List.map (List.drop 1 >> List.head >> Maybe.withDefault 0) cols) (rx ++ ry))
                            (List.repeat 6 True)

                    _ ->
                        Expect.fail "no Jacobian"
        , test "the solver turns the cube to put the corner on a target" <|
            \_ ->
                let
                    ( tx, ty ) =
                        plain [ 0.4, 0.5, -0.3 ]

                    s =
                        GradSolve.solve { maxEvaluations = 30, tolerance = 0.01 } (Cube.problem corner) [ tx, ty ] [ 0, 0, 0 ]
                in
                Expect.lessThan 0.01 s.error
        , test "turning keeps the axes unit length and at right angles" <|
            \_ ->
                let
                    s =
                        Cube.turn [ 1.1, -0.7, 2.3 ] Cube.init

                    dot ( a, b, c ) ( x, y, z ) =
                        a * x + b * y + c * z
                in
                Expect.equal
                    (List.map (near 1.0e-12 0) [ dot s.ex s.ey, dot s.ey s.ez, dot s.ex s.ez ] ++ List.map (near 1.0e-12 1) [ dot s.ex s.ex, dot s.ey s.ey, dot s.ez s.ez ])
                    (List.repeat 6 True)
        , test "the cube turns past half a turn: angles have no bound" <|
            \_ ->
                let
                    ( tx, ty ) =
                        plain [ 0, 0, pi + 0.5 ]

                    s =
                        GradSolve.solve { maxEvaluations = 30, tolerance = 0.01 } (Cube.problem corner) [ tx, ty ] [ 0, 0, pi - 0.1 ]
                in
                Expect.equal ( s.error < 0.01, Maybe.map (\c -> c > pi) (List.drop 2 s.params |> List.head) ) ( True, Just True )
        , test "there are 24 face-on orientations, all different and right-handed" <|
            \_ ->
                let
                    cross ( a, b, c ) ( x, y, z ) =
                        ( b * z - c * y, c * x - a * z, a * y - b * x )

                    distinct =
                        List.foldl
                            (\p acc ->
                                if List.member p acc then
                                    acc

                                else
                                    p :: acc
                            )
                            []
                            Cube.faceOn
                in
                Expect.equal ( List.length distinct, List.all (\p -> cross p.ex p.ey == p.ez) Cube.faceOn ) ( 24, True )
        , test "a release near a face-on view snaps to it; one far from every one stays" <|
            \_ ->
                let
                    square =
                        List.drop 5 Cube.faceOn |> List.head |> Maybe.withDefault Cube.init

                    near20 =
                        Cube.turn [ degrees 12, degrees -10, degrees 9 ] square
                in
                Expect.equal ( Cube.snap near20 == square, Cube.snap Cube.init == Cube.init ) ( True, True )
        , test "every face snaps to look at the camera, whatever its spin on the screen" <|
            \_ ->
                let
                    -- spun 35° on the screen (too far to square), then tilted 15° and 10° away
                    off p =
                        Cube.turn [ degrees 15, degrees -10, 0 ] (Cube.turn [ 0, 0, degrees 35 ] p)

                    facing q =
                        List.any (\( _, _, z ) -> abs (abs z - 1) < 1.0e-9) [ q.ex, q.ey, q.ez ]

                    snapped =
                        List.map (off >> Cube.snap) Cube.faceOn
                in
                Expect.equal ( List.all facing snapped, List.any (\q -> List.member q Cube.faceOn) snapped ) ( True, False )
        , test "a face spun less than the snap angle squares up too" <|
            \_ ->
                let
                    off p =
                        Cube.turn [ degrees 15, degrees -10, 0 ] (Cube.turn [ 0, 0, degrees 20 ] p)
                in
                Expect.equal (List.map (off >> Cube.snap) Cube.faceOn) Cube.faceOn
        ]
