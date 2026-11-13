module TentacleTests exposing (suite)

{-| The tentacle's tensor model against its plain-Elm drawing, its Jacobian against finite
differences, and the gradient solver reaching targets within the joint limits.
-}

import Expect
import GradSolve
import Tentacle
import Test exposing (Test, describe, test)


angles : List Float
angles =
    [ 0.4, -0.3, 0.2, 0.5, -0.6, 0.1, 0.3, -0.2, 0.6, -0.1, 0.2, 0.4 ]


at : Int -> List a -> Maybe a
at i l =
    List.head (List.drop i l)


suite : Test
suite =
    describe "Tentacle"
        [ test "the tensor model puts every joint where the drawing does" <|
            \_ ->
                List.range 0 (Tentacle.count - 1)
                    |> List.map
                        (\i ->
                            case ( GradSolve.evaluate (Tentacle.problem i) angles, at i (Tentacle.positions angles) ) of
                                ( Ok ( [ x, y ], _ ), Just ( px, py ) ) ->
                                    abs (x - px) + abs (y - py) < 1.0e-9

                                _ ->
                                    False
                        )
                    |> Expect.equal (List.repeat Tentacle.count True)
        , test "the Jacobian matches central differences of the drawing" <|
            \_ ->
                let
                    i =
                        9

                    h =
                        1.0e-6

                    numeric =
                        List.indexedMap
                            (\j _ ->
                                let
                                    bump d =
                                        List.indexedMap
                                            (\k a ->
                                                if k == j then
                                                    a + d

                                                else
                                                    a
                                            )
                                            angles

                                    pos d =
                                        at i (Tentacle.positions (bump d)) |> Maybe.withDefault ( 0, 0 )

                                    ( x1, y1 ) =
                                        pos h

                                    ( x0, y0 ) =
                                        pos -h
                                in
                                ( (x1 - x0) / (2 * h), (y1 - y0) / (2 * h) )
                            )
                            angles
                in
                case GradSolve.evaluate (Tentacle.problem i) angles of
                    Ok ( _, [ jx, jy ] ) ->
                        List.map3 (\( nx, ny ) ax ay -> abs (nx - ax) + abs (ny - ay) < 1.0e-5) numeric jx jy
                            |> Expect.equal (List.repeat Tentacle.count True)

                    _ ->
                        Expect.fail "no Jacobian"
        , test "the solver reaches a reachable target and keeps the limits" <|
            \_ ->
                let
                    goal =
                        List.map (\a -> a * 0.8) angles

                    target =
                        at 11 (Tentacle.positions goal) |> Maybe.withDefault ( 0, 0 )

                    solved =
                        GradSolve.solve { maxEvaluations = 60, tolerance = 0.05 } (Tentacle.problem 11) [ Tuple.first target, Tuple.second target ] Tentacle.init.angles
                in
                Expect.equal ( solved.error < 0.05, List.all (\a -> abs a <= Tentacle.limit + 1.0e-12) (List.drop 1 solved.params) ) ( True, True )
        , test "an out-of-reach target stretches towards it" <|
            \_ ->
                let
                    solved =
                        GradSolve.solve { maxEvaluations = 60, tolerance = 0.05 } (Tentacle.problem 11) [ 160, -400 ] Tentacle.init.angles

                    tip =
                        at 11 (Tentacle.positions solved.params) |> Maybe.withDefault ( 0, 0 )
                in
                Expect.lessThan (262 - 12 * 19 + 1) (Tuple.second tip)
        , test "the base turns past half a turn: angles have no bound there" <|
            \_ ->
                let
                    start =
                        (pi - 0.05) :: List.drop 1 Tentacle.init.angles

                    goal =
                        (pi + 0.4) :: List.drop 1 Tentacle.init.angles

                    ( tx, ty ) =
                        List.drop 11 (Tentacle.positions goal) |> List.head |> Maybe.withDefault ( 0, 0 )

                    s =
                        GradSolve.solve { maxEvaluations = 60, tolerance = 0.05 } (Tentacle.problem 11) [ tx, ty ] start
                in
                Expect.equal ( s.error < 0.05, Maybe.map (\b -> b > pi) (List.head s.params) ) ( True, Just True )
        , test "with the tip pinned, a middle joint reaches a reachable target and the tip stays put" <|
            \_ ->
                let
                    pos k a =
                        List.drop k (Tentacle.positions a) |> List.head |> Maybe.withDefault ( 0, 0 )

                    ( jx, jy ) =
                        pos 5 Tentacle.init.angles

                    ( tx, ty ) =
                        pos 11 Tentacle.init.angles

                    w =
                        Tentacle.pinWeight

                    solveTo ( dx, dy ) =
                        GradSolve.solve { maxEvaluations = 40, tolerance = 0.05 } (Tentacle.pinnedProblem 5) [ jx + dx, jy + dy, w * tx, w * ty ] Tentacle.init.angles

                    drift p =
                        let
                            ( ax, ay ) =
                                pos 11 p
                        in
                        sqrt ((ax - tx) ^ 2 + (ay - ty) ^ 2)

                    miss ( dx, dy ) p =
                        let
                            ( bx, by ) =
                                pos 5 p
                        in
                        sqrt ((bx - jx - dx) ^ 2 + (by - jy - dy) ^ 2)

                    -- the tentacle starts nearly straight, so joint 6 can only move along the arc
                    -- it can still reach (sideways); away from the tip the rest of the arm is too short
                    near =
                        solveTo ( -10, 0 )

                    far =
                        solveTo ( 15, -10 )
                in
                Expect.equal
                    ( ( drift near.params < 0.1, miss ( -10, 0 ) near.params < 0.1 ), drift far.params < 0.5 )
                    ( ( True, True ), True )
        , test "the pinned graph's 4 × 12 Jacobian matches central differences" <|
            \_ ->
                let
                    h =
                        1.0e-6

                    four a =
                        let
                            ps =
                                Tentacle.positions a

                            pos k =
                                List.drop k ps |> List.head |> Maybe.withDefault ( 0, 0 )
                        in
                        [ Tuple.first (pos 5), Tuple.second (pos 5), Tentacle.pinWeight * Tuple.first (pos 11), Tentacle.pinWeight * Tuple.second (pos 11) ]

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
                                    Tentacle.init.angles
                        in
                        List.map2 (\a b -> (a - b) / (2 * h)) (four (bump h)) (four (bump -h))

                    numeric =
                        List.map column (List.range 0 11)
                in
                case GradSolve.evaluate (Tentacle.pinnedProblem 5) Tentacle.init.angles of
                    Ok ( _, rows ) ->
                        Expect.equal
                            (List.map2 (\a b -> abs (a - b) <= 1.0e-5 * max 1 (abs a)) (List.concat numeric) (List.concat (transposeRows rows)))
                            (List.repeat 48 True)

                    Err e ->
                        Expect.fail e
        ]


transposeRows : List (List Float) -> List (List Float)
transposeRows m =
    case m of
        [] ->
            []

        first :: _ ->
            List.indexedMap (\j _ -> List.filterMap (\row -> List.drop j row |> List.head) m) first
