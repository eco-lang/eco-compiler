module LensTests exposing (suite)

{-| The lens's optics: the tensor model against the plain trace, its Jacobian against finite
differences, two checks against textbook optics, and the focus solver.
-}

import Expect
import GradSolve
import Lens
import Num
import Test exposing (Test, describe, test)


near : Float -> Float -> Float -> Bool
near tol a b =
    abs (a - b) <= tol * max 1 (abs a)


state : Lens.State
state =
    { front = 0.42, back = -0.21, angle = 0.12 }


f : ( Float, Float )
f =
    ( 2.6, 0.4 )


plainMisses : Lens.State -> List Float
plainMisses s =
    let
        ( fx, fy ) =
            f
    in
    List.map
        (\h ->
            let
                r =
                    Lens.trace Num.floats s h

                ( px, py ) =
                    r.exit

                ( dx, dy ) =
                    r.direction
            in
            dx * (fy - py) - dy * (fx - px)
        )
        Lens.rays


suite : Test
suite =
    describe "Lens"
        [ test "the tensor model's misses are the plain trace's" <|
            \_ ->
                case GradSolve.evaluate (Lens.problem f) [ state.front, state.back, state.angle ] of
                    Ok ( ms, _ ) ->
                        Expect.equal (List.map2 (near 1.0e-12) (plainMisses state) ms) (List.repeat 9 True)

                    _ ->
                        Expect.fail "no result"
        , test "its Jacobian through both refractions matches central differences" <|
            \_ ->
                let
                    h =
                        1.0e-6

                    column g =
                        List.map2 (\a b -> (a - b) / (2 * h)) (plainMisses (g h)) (plainMisses (g -h))

                    numeric =
                        [ column (\d -> { state | front = state.front + d })
                        , column (\d -> { state | back = state.back + d })
                        , column (\d -> { state | angle = state.angle + d })
                        ]
                in
                case GradSolve.evaluate (Lens.problem f) [ state.front, state.back, state.angle ] of
                    Ok ( _, rows ) ->
                        Expect.equal
                            (List.map2 (near 1.0e-6) (List.concat numeric) (List.concat (transpose rows)))
                            (List.repeat 27 True)

                    _ ->
                        Expect.fail "no Jacobian"
        , test "a flat window leaves every ray's direction unchanged" <|
            \_ ->
                let
                    s =
                        { front = 0, back = 0, angle = 0.2 }

                    ok h =
                        let
                            r =
                                Lens.trace Num.floats s h
                        in
                        near 1.0e-12 (cos 0.2) (Tuple.first r.direction) && near 1.0e-12 (sin 0.2) (Tuple.second r.direction)
                in
                Expect.equal (List.map ok Lens.rays) (List.repeat 9 True)
        , test "a weak lens focuses where the thick-lens formula says" <|
            \_ ->
                let
                    -- lensmaker's equation for a thick lens, the focus measured from the back vertex
                    ( c1, c2, n ) =
                        ( 0.1, -0.1, 1.5 )

                    sag c y =
                        c * y * y / (1 + sqrt (1 - c * c * y * y))

                    t =
                        0.12 + sag c1 1.15 - sag c2 1.15

                    power =
                        (n - 1) * (c1 - c2 + (n - 1) * t * c1 * c2 / n)

                    backFocus =
                        (1 - (n - 1) * t * c1 / n) / power

                    ( fx, fy ) =
                        Lens.focus { front = c1, back = c2, angle = 0 }
                in
                Expect.equal ( near 0.01 (t / 2 + backFocus) fx, abs fy < 1.0e-9 ) ( True, True )
        , test "the solver focuses the rays on a reachable point" <|
            \_ ->
                let
                    target =
                        Lens.focus { front = 0.55, back = -0.15, angle = 0.1 }

                    s =
                        GradSolve.solve { maxEvaluations = 30, tolerance = 1.0e-9 } (Lens.problem target) (List.repeat 9 0) [ Lens.init.front, Lens.init.back, Lens.init.angle ]

                    ( fx, fy ) =
                        case s.params of
                            [ a, b, c ] ->
                                Lens.focus { front = a, back = b, angle = c }

                            _ ->
                                ( 0, 0 )
                in
                Expect.lessThan 0.02 (sqrt ((fx - Tuple.first target) ^ 2 + (fy - Tuple.second target) ^ 2))
        , test "the catalogue's foci are on the panel and at least 40 px apart; each is named" <|
            \_ ->
                let
                    xs =
                        List.map (\st -> 130 + 60 * Tuple.first (Lens.focus { front = st.front, back = st.back, angle = 0 })) Lens.catalogue

                    gaps =
                        List.map2 (\a b -> abs (a - b)) xs (List.drop 1 xs)
                in
                Expect.equal
                    ( List.all (\x -> x > 150 && x < 470) xs
                    , List.all (\g -> g >= 40) gaps
                    , List.map (\st -> Lens.stockName { front = st.front, back = st.back, angle = 0.1 }) Lens.catalogue
                    )
                    ( True, True, List.map (.name >> Just) Lens.catalogue )
        ]


transpose : List (List Float) -> List (List Float)
transpose m =
    case m of
        [] ->
            []

        first :: _ ->
            List.indexedMap (\j _ -> List.filterMap (\row -> List.drop j row |> List.head) m) first
