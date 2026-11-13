module ClassifyTests exposing (suite)

{-| The classifier's tensor score against its plain-Elm twin, its gradient against finite
differences, the boundary solver, training, and the contour tracer.
-}

import Classify
import Expect
import GradSolve
import Test exposing (Test, describe, test)


near : Float -> Float -> Float -> Bool
near tol a b =
    abs (a - b) <= tol * max 1 (abs a)


at : ( Float, Float )
at =
    ( 0.4, -0.3 )


suite : Test
suite =
    describe "Classify"
        [ test "the tensor network scores what the drawing draws" <|
            \_ ->
                case GradSolve.evaluate (Classify.boundaryProblem at) Classify.init.params of
                    Ok ( [ s ], _ ) ->
                        Expect.within (Expect.Absolute 1.0e-12) (Classify.score Classify.init.params at) s

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
                                            Classify.init.params
                                in
                                (Classify.score (bump h) at - Classify.score (bump -h) at) / (2 * h)
                            )
                            Classify.init.params
                in
                case GradSolve.evaluate (Classify.boundaryProblem at) Classify.init.params of
                    Ok ( _, [ g ] ) ->
                        Expect.equal (List.map2 (near 1.0e-6) numeric g) (List.repeat Classify.weights True)

                    _ ->
                        Expect.fail "no gradient"
        , test "dragging the boundary puts it under the pointer" <|
            \_ ->
                let
                    s =
                        GradSolve.solve { maxEvaluations = 8, tolerance = 1.0e-4 } (Classify.boundaryProblem at) [ 0 ] Classify.init.params
                in
                Expect.within (Expect.Absolute 1.0e-4) 0 (Classify.score s.params at)
        , test "training separates the points" <|
            \_ ->
                let
                    ( state, t ) =
                        Classify.train 200 Classify.init Classify.trainer

                    wrong =
                        List.filter (\p -> (Classify.score state.params p.at > 0) /= p.red) state.points
                in
                Expect.equal ( List.length wrong, Maybe.map (\l -> l < 0.05) t.loss ) ( 0, Just True )
        , test "the contour of a straight edge is that edge" <|
            \_ ->
                let
                    segments =
                        Classify.contour 10 (\( x, _ ) -> x - 245)
                in
                Expect.equal
                    ( List.length segments, List.all (\( ( x1, _ ), ( x2, _ ) ) -> abs (x1 - 245) < 1.0e-9 && abs (x2 - 245) < 1.0e-9) segments )
                    ( 32, True )
        ]
